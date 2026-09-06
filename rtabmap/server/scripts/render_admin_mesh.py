#!/usr/bin/env python3
"""Render a live organizedFastMesh PLY to /tmp/admin-mesh-verify.png.

Uses the same three.js MeshStandardMaterial + vertex colors as the admin
page when Chrome/Playwright is available. Falls back to a matplotlib 3D
view of downsampled triangles. Exits 2 if the mesh is a flat sheet.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time


def read_ply(path: str):
    with open(path, "rb") as f:
        header = b""
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("truncated ply header")
            header += line
            if line.strip() == b"end_header":
                break
        text = header.decode("ascii", "replace")
        verts = faces = 0
        for line in text.splitlines():
            if line.startswith("element vertex"):
                verts = int(line.split()[-1])
            elif line.startswith("element face"):
                faces = int(line.split()[-1])
        xyz = []
        rgb = []
        for _ in range(verts):
            x, y, z = struct.unpack("<fff", f.read(12))
            r, g, b = struct.unpack("BBB", f.read(3))
            xyz.append((x, y, z))
            rgb.append((r, g, b))
        faces_i = []
        for _ in range(faces):
            n = struct.unpack("B", f.read(1))[0]
            idx = struct.unpack("<" + "i" * n, f.read(4 * n))
            if n >= 3:
                faces_i.append((idx[0], idx[1], idx[2]))
        return xyz, rgb, faces_i


def mesh_stats(xyz):
    xs = [p[0] for p in xyz]
    ys = [p[1] for p in xyz]
    zs = [p[2] for p in xyz]
    spans = sorted((max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)))
    return {
        "n": len(xyz),
        "xmin": min(xs), "xmax": max(xs),
        "ymin": min(ys), "ymax": max(ys),
        "zmin": min(zs), "zmax": max(zs),
        "thin": spans[0], "mid": spans[1], "thick": spans[2],
        "ratio": spans[0] / max(spans[2], 1e-6),
    }


def is_sheet(stats: dict) -> bool:
    return stats["thin"] < 0.25 and stats["thick"] > 1.0


def write_html(html_path: str, mesh_url: str) -> None:
    html_path = os.path.abspath(html_path)
    with open(html_path, "w") as f:
        f.write(
            """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>admin mesh verify</title>
<script type="importmap">
{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.160.1/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.1/examples/jsm/"}}
</script></head>
<body style="margin:0;background:#0b0b0b">
<canvas id="c" width="1280" height="720"></canvas>
<script type="module">
import * as THREE from 'three';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
const renderer = new THREE.WebGLRenderer({ canvas: document.getElementById('c'), antialias: true });
renderer.setSize(1280, 720, false);
renderer.setClearColor(0x0b0b0b, 1);
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(55, 1280/720, 0.05, 200);
scene.add(new THREE.AmbientLight(0xffffff, 0.32));
scene.add(new THREE.HemisphereLight(0xe8eef6, 0x3a3228, 0.62));
const key = new THREE.DirectionalLight(0xffffff, 0.85);
key.position.set(2.4, 4.2, 2.8);
scene.add(key);
const loader = new PLYLoader();
loader.load(MESH_URL, (geom) => {
  geom.computeVertexNormals();
  geom.computeBoundingBox();
  const hasColor = !!geom.getAttribute('color');
  const mesh = new THREE.Mesh(geom, new THREE.MeshStandardMaterial({
    vertexColors: hasColor, color: hasColor ? 0xffffff : 0x9aa3ad,
    roughness: 0.88, metalness: 0.02, side: THREE.DoubleSide
  }));
  scene.add(mesh);
  const box = geom.boundingBox;
  const size = new THREE.Vector3();
  const center = new THREE.Vector3();
  box.getSize(size);
  box.getCenter(center);
  const radius = Math.max(size.length() * 0.55, 1.5);
  camera.position.set(center.x + radius * 0.75, center.y + radius * 0.45, center.z + radius * 0.75);
  camera.lookAt(center);
  renderer.render(scene, camera);
  document.title = 'READY ' + geom.getAttribute('position').count;
}, undefined, (e) => { document.title = 'FAIL'; console.error(e); });
</script></body></html>
""".replace("MESH_URL", json.dumps(mesh_url))
        )


def render_software(xyz, rgb, faces, out_png: str, view: str = "three-quarter") -> bool:
    """Painter's-algorithm raster of the mesh. The mesh is in the shared demo
    frame G (rtabmap convention: z up), so the camera orbits above the x,y
    ground plane. Triangles behind the camera are culled instead of clamped,
    which is what produced the earlier screen-filling shards."""
    import numpy as np
    import cv2

    verts = np.asarray(xyz, dtype=np.float64)
    cols = np.asarray(rgb, dtype=np.float64)
    tris = np.asarray(faces, dtype=np.int64)
    if verts.size == 0 or tris.size == 0:
        return False
    ok = (tris >= 0).all(axis=1) & (tris < len(verts)).all(axis=1)
    tris = tris[ok]
    if len(tris) == 0:
        return False
    # Robust framing: the bulk of the geometry, not outlier nodes.
    lo = np.percentile(verts, 5, axis=0)
    hi = np.percentile(verts, 95, axis=0)
    center = (lo + hi) * 0.5
    span = float(np.linalg.norm(hi - lo))
    radius = max(span * 0.9, 2.0)
    if view == "top":
        eye = center + np.array([0.0, 0.0, radius])
        up_hint = np.array([1.0, 0.0, 0.0])
    else:
        eye = center + np.array([radius * 0.75, -radius * 0.75, radius * 0.55])
        up_hint = np.array([0.0, 0.0, 1.0])
    forward = center - eye
    forward /= max(float(np.linalg.norm(forward)), 1e-9)
    right = np.cross(forward, up_hint)
    right /= max(float(np.linalg.norm(right)), 1e-9)
    up = np.cross(right, forward)
    rel = verts - eye
    xc = rel @ right
    yc = rel @ up
    zc = rel @ forward  # positive in front of the camera
    w, h = 1280, 720
    f = 0.9 * h
    near = 0.1
    safe_z = np.where(zc > near, zc, near)
    u = (xc / safe_z) * f + w * 0.5
    v = (-yc / safe_z) * f + h * 0.5
    in_front = zc > near
    tri_ok = in_front[tris].all(axis=1)
    tris = tris[tri_ok]
    if len(tris) == 0:
        return False
    # Flat shading from the face normal so depth reads even with flat colors.
    p0, p1, p2 = verts[tris[:, 0]], verts[tris[:, 1]], verts[tris[:, 2]]
    n = np.cross(p1 - p0, p2 - p0)
    nn = np.linalg.norm(n, axis=1)
    nn[nn < 1e-12] = 1e-12
    n /= nn[:, None]
    light = np.array([0.4, -0.5, 0.75])
    light /= np.linalg.norm(light)
    shade = 0.55 + 0.45 * np.abs(n @ light)
    face_col = (cols[tris[:, 0]] + cols[tris[:, 1]] + cols[tris[:, 2]]) / 3.0
    face_col = np.clip(face_col * shade[:, None], 0, 255)
    depth = zc[tris].mean(axis=1)
    order = np.argsort(-depth)
    img = np.zeros((h, w, 3), dtype=np.uint8)
    img[:] = (16, 13, 11)
    uv = np.stack([u, v], axis=1)
    for i in order:
        a, b, c = tris[i]
        pts = np.array([uv[a], uv[b], uv[c]], dtype=np.int32)
        x, y, bw, bh = cv2.boundingRect(pts)
        if bw == 0 or bh == 0 or x + bw < 0 or y + bh < 0 or x > w or y > h:
            continue
        col = face_col[i]
        cv2.fillConvexPoly(img, pts, (int(col[2]), int(col[1]), int(col[0])), lineType=cv2.LINE_8)
    # Axes at the tag origin: x red, y green, z blue (G frame).
    origin = np.zeros(3)
    axes = [(np.array([0.5, 0, 0]), (0, 0, 255)), (np.array([0, 0.5, 0]), (0, 255, 0)), (np.array([0, 0, 0.5]), (255, 0, 0))]
    def proj(p):
        r = p - eye
        z = r @ forward
        if z <= near:
            return None
        return (int((r @ right) / z * f + w * 0.5), int(-(r @ up) / z * f + h * 0.5))
    o = proj(origin)
    for d, colr in axes:
        e = proj(origin + d)
        if o and e:
            cv2.line(img, o, e, colr, 2, cv2.LINE_AA)
    cv2.imwrite(out_png, img)
    return os.path.exists(out_png) and os.path.getsize(out_png) > 8000


def render_matplotlib(xyz, rgb, faces, out_png: str) -> bool:
    return render_software(xyz, rgb, faces, out_png)


def render_three(ply_path: str, out_png: str) -> bool:
    chrome = None
    for candidate in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        shutil.which("google-chrome"),
        shutil.which("chromium"),
        shutil.which("chrome"),
    ):
        if candidate and os.path.exists(candidate):
            chrome = candidate
            break
    if not chrome:
        return False
    work = tempfile.mkdtemp(prefix="admin-mesh-verify-")
    try:
        shutil.copy(ply_path, os.path.join(work, "map.mesh.ply"))
        write_html(os.path.join(work, "index.html"), "/map.mesh.ply")

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

        os.chdir(work)
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{port}/index.html"
        cmd = [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--window-size=1280,720",
            f"--screenshot={out_png}",
            "--virtual-time-budget=12000",
            url,
        ]
        try:
            subprocess.run(cmd, check=True, timeout=40, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            httpd.shutdown()
            return False
        httpd.shutdown()
        return os.path.exists(out_png) and os.path.getsize(out_png) > 2000
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ply")
    ap.add_argument("-o", "--out", default="/tmp/admin-mesh-verify.png")
    ap.add_argument("--view", choices=["three-quarter", "top"], default="three-quarter")
    args = ap.parse_args()
    xyz, rgb, faces = read_ply(args.ply)
    stats = mesh_stats(xyz)
    print(json.dumps({"ply": args.ply, "faces": len(faces), **stats}, indent=2))
    if not xyz or not faces:
        print("FAIL: empty mesh")
        return 2
    if is_sheet(stats):
        print("FAIL: mesh AABB is a sheet")
        return 2
    rendered = render_software(xyz, rgb, faces, args.out, args.view)
    if not rendered:
        print("software raster failed, trying three.js/chrome")
        rendered = render_three(args.ply, args.out)
    if not rendered or not os.path.exists(args.out) or os.path.getsize(args.out) < 8000:
        print("FAIL: could not write a useful PNG")
        return 2
    print("wrote", args.out, "bytes", os.path.getsize(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
