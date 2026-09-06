#!/usr/bin/env python3
"""End-to-end demo of the collab start-tag lock and live map.

Starts a TEMP server on a free port with an empty data dir. Does not touch
the live LaunchAgent collab-data directory.
"""

from __future__ import annotations

import json
import os
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SERVER_BIN = os.path.join(REPO, "build", "bin", "rtabmap-collab-server")
TAG_ID = 0
TAG_SIZE_M = 0.20

PASS = 0
FAIL = 0


def check(cond: bool, name: str, detail: str = "") -> bool:
    global PASS, FAIL
    if cond:
        PASS += 1
        line = f"PASS  {name}"
    else:
        FAIL += 1
        line = f"FAIL  {name}"
    if detail:
        line += f"  ({detail})"
    print(line, flush=True)
    return cond


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def http(
    method: str,
    url: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 20.0,
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


def http_json(method: str, url: str, payload: Any = None, client: str = "", timeout: float = 20.0) -> dict[str, Any]:
    body = None
    headers = {"Accept": "application/json"}
    if client:
        headers["X-Client-Id"] = client
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    status, _hdrs, raw = http(method, url, body, headers, timeout=timeout)
    try:
        obj = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        obj = {"_raw": raw.decode("utf-8", "replace")}
    if isinstance(obj, dict):
        obj["_http"] = status
    return obj if isinstance(obj, dict) else {"_http": status}


def wait_up(base: str, timeout: float = 15.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status, _, _ = http("GET", base + "/demo", timeout=1.5)
            if status == 200:
                return True
        except Exception:
            time.sleep(0.15)
    return False


def pose(tag_id: int = TAG_ID, tx: float = 0.05, ty: float = 0.0, tz: float = 0.45, detected: bool = True) -> dict[str, Any]:
    return {
        "tag_id": tag_id,
        "detected": detected,
        "tx": tx,
        "ty": ty,
        "tz": tz,
        "qx": 0.0,
        "qy": 0.0,
        "qz": 0.0,
        "qw": 1.0,
    }


def should_show_tag(demo: dict[str, Any]) -> bool:
    return demo.get("show_tag") is True and demo.get("locked") is not True


def write_delta(path: str, local_id: int, x: float, y: float, z: float) -> bool:
    cmd = [
        SERVER_BIN,
        "--write-delta",
        path,
        "--delta-id",
        str(local_id),
        "--delta-x",
        str(x),
        "--delta-y",
        str(y),
        "--delta-z",
        str(z),
    ]
    rc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if rc.returncode != 0:
        print(rc.stdout)
        print(rc.stderr, file=sys.stderr)
        return False
    return os.path.isfile(path) and os.path.getsize(path) > 100


def sync_delta(base: str, client: str, path: str, since_id: int = 0) -> dict[str, Any]:
    with open(path, "rb") as f:
        body = f.read()
    headers = {
        "X-Client-Id": client,
        "X-Since-Id": str(since_id),
        "Content-Type": "application/octet-stream",
    }
    status, _hdrs, raw = http("POST", base + "/sync", body, headers, timeout=60.0)
    try:
        obj = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        obj = {}
    obj["_http"] = status
    return obj


def pull(base: str, client: str, since: int = 0) -> tuple[dict[str, str], bytes]:
    status, hdrs, raw = http(
        "GET",
        f"{base}/pull?since_global_id={since}",
        headers={"X-Client-Id": client, "X-Since-Global-Id": str(since)},
        timeout=30.0,
    )
    hdrs["_http"] = str(status)
    return hdrs, raw


def main() -> int:
    if not os.path.isfile(SERVER_BIN):
        print(f"missing server binary: {SERVER_BIN}", file=sys.stderr)
        print("Build with: cmake --build build --target rtabmap-collab-server", file=sys.stderr)
        return 2

    port = free_port()
    work = tempfile.mkdtemp(prefix="rtabmap-demo-e2e-")
    leftover = os.path.join(work, "clients.json")
    now = int(time.time())
    with open(leftover, "w", encoding="utf-8") as f:
        json.dump(
            {
                "next_global_id": 10,
                "next_map_id_base": 2,
                "global_nodes": 8,
                "room_locked": True,
                "locked_tag_id": 0,
                "clients": {
                    "85998EDD-LEFTOVER": {
                        "last_seen": now,
                        "calibrated": True,
                        "tag_id": 0,
                    },
                    "ED4D51E2-LEFTOVER": {
                        "last_seen": now,
                        "calibrated": True,
                        "tag_id": 0,
                    },
                },
            },
            f,
        )
    log_path = os.path.join(work, "server.log")
    print(f"temp server port={port} data={work}", flush=True)
    logf = open(log_path, "w")
    proc = subprocess.Popen(
        [SERVER_BIN, "--port", str(port), "--data", work],
        cwd=REPO,
        stdout=logf,
        stderr=subprocess.STDOUT,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        if not wait_up(base):
            check(False, "server_up", f"no /demo on {base}")
            return 1
        check(True, "server_up", base)

        status, _hdrs, html = http("GET", base + "/")
        page = html.decode("utf-8", "replace")
        check(status == 200, "GET / html", f"status={status}")
        check("/tag.png" in page and "calib-tag" in page, "admin contains tag png")
        check("shouldShowTag" in page, "admin JS hide helper present")
        check("reset-btn" in page and "/reset" in page, "admin Reset button present")
        check("hideTagFromDom" not in page, "admin keeps tag in DOM")
        check("tag-size-input" in page and "/tag_size" in page, "admin reports displayed tag size")
        check("Mesh refreshes every" not in page, "admin does not advertise 10s bake")
        check("organizedFastMesh" in page, "admin documents live organizedFastMesh")
        check("map.mesh?live=1" not in page, "admin does not fall back to bake then live")
        check("setInterval(poll, 250)" in page, "admin polls /demo at 250ms")

        admin_status, _, admin_html = http("GET", base + "/admin")
        check(admin_status == 200 and b"calib-tag" in admin_html, "GET /admin")

        demo = http_json("GET", base + "/demo")
        check(demo.get("_http") == 200, "GET /demo")
        check(demo.get("show_tag") is True, "show_tag true before lock")
        check(demo.get("locked") is False, "locked false before lock")
        check(demo.get("calibrated_count") == 0, "leftover calibrated ignored")
        check(demo.get("tag_id") == TAG_ID, f"tag_id={demo.get('tag_id')}")
        check(abs(float(demo.get("tag_size_m", 0)) - TAG_SIZE_M) < 1e-6, "tag_size_m")
        check(should_show_tag(demo), "shouldShowTag(demo) true at start")
        check(len(demo.get("calibrated") or []) == 0, "leftover lock clients not shown")

        # The admin page reports the physical size of the marker it displays;
        # phones pick it up from /join and /demo.
        ts = http_json("POST", base + "/tag_size", {"tag_size_m": 0.085})
        check(ts.get("ok") is True and abs(float(ts.get("tag_size_m", 0)) - 0.085) < 1e-6, "POST /tag_size accepted", json.dumps(ts))
        demo_ts = http_json("GET", base + "/demo")
        check(abs(float(demo_ts.get("tag_size_m", 0)) - 0.085) < 1e-6, "demo reports the displayed tag size")
        join_ts = http_json("POST", base + "/join", {}, "sim-size")
        check(abs(float(join_ts.get("tag_size_m", 0)) - 0.085) < 1e-6, "join reports the displayed tag size")
        bad_ts = http_json("POST", base + "/tag_size", {"tag_size_m": 5.0})
        check(bad_ts.get("ok") is False and bad_ts.get("_http") == 400, "reject absurd tag size")
        http_json("POST", base + "/tag_size", {"tag_size_m": TAG_SIZE_M})
        http_json("POST", base + "/reset", {})

        bad = http_json("POST", base + "/calibrate", {"tag_id": 99, "detected": True, "tx": 0, "ty": 0, "tz": 0.4, "qx": 0, "qy": 0, "qz": 0, "qw": 1}, "sim-a")
        check(bad.get("ok") is False and bad.get("_http") == 400, "reject bad tag_id")
        missing = http_json("POST", base + "/calibrate", {"tag_id": 0, "tx": 0, "ty": 0, "tz": 0.4, "qx": 0, "qy": 0, "qz": 0, "qw": 1}, "sim-a")
        check(missing.get("ok") is False and missing.get("_http") == 400, "reject missing detected")
        fake = http_json("POST", base + "/calibrate", pose(detected=False), "sim-a")
        check(fake.get("ok") is False and fake.get("_http") == 400, "reject detected=false")

        join_a = http_json("POST", base + "/join", {}, "sim-a")
        check(join_a.get("ok") is True, "join sim-a")
        check(join_a.get("must_wait_for_lock") is True, "join must_wait_for_lock")
        check(join_a.get("locked") is False and join_a.get("show_tag") is True, "join not locked")

        cal_a = http_json("POST", base + "/calibrate", pose(tx=0.04, tz=0.42), "sim-a")
        check(cal_a.get("ok") is True, "calibrate A")
        check(cal_a.get("locked") is True, "one phone locks the room")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is True, "GET /demo locked after A")
        check(demo.get("show_tag") is False, "tag hidden after A")
        check(int(demo.get("calibrated_count") or 0) == 1, f"calibrated_count={demo.get('calibrated_count')}")
        check(should_show_tag(demo) is False, "shouldShowTag false after one-phone lock")

        cal_b = http_json("POST", base + "/calibrate", pose(tx=-0.03, tz=0.40), "sim-b")
        check(cal_b.get("ok") is True, "calibrate B")
        check(cal_b.get("locked") is True, "second phone stays locked")
        check(cal_b.get("show_tag") is False, "show_tag false after lock")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is True, "GET /demo locked")
        check(demo.get("mesh_kind") == "live", "demo mesh_kind live")
        pose_live = http_json("POST", base + "/pose", {
            "tx": 0.20, "ty": 0.05, "tz": 0.80,
            "qx": 0.0, "qy": 0.2588, "qz": 0.0, "qw": 0.9659,
        }, "sim-a")
        check(pose_live.get("ok") is True, "POST /pose after lock")
        demo = http_json("GET", base + "/demo")
        clients = demo.get("clients") or []
        a = next((c for c in clients if c.get("id") == "sim-a"), None)
        check(a is not None, "demo has sim-a after /pose")
        if a:
            check(abs(float(a.get("qx", 0))) + abs(float(a.get("qy", 0))) + abs(float(a.get("qz", 0))) + abs(float(a.get("qw", 0))) > 0.5, "pose quat present")
            check("yaw" in a, "pose yaw present")
        mesh_status, mesh_hdrs, _ = http("GET", base + "/map.mesh")
        check(mesh_status == 200, "GET /map.mesh")
        check((mesh_hdrs.get("x-mesh-kind") or "") == "live", f"X-Mesh-Kind={mesh_hdrs.get('x-mesh-kind')}")
        check(demo.get("show_tag") is False, "GET /demo show_tag false")
        check(demo.get("show_tag") is False and demo.get("locked") is True, "show_tag false iff locked")
        check(not should_show_tag(demo), "JS shouldShowTag hides tag")
        check(int(demo.get("calibrated_count") or 0) >= 2, "calibrated_count >= 2")

        join_b = http_json("POST", base + "/join", {}, "sim-b")
        check(join_b.get("locked") is True and join_b.get("must_wait_for_lock") is False, "join after lock allows mapping")

        # Stay locked if A walks away (no new calibrate, just heartbeat).
        hb = http_json("POST", base + "/heartbeat", {}, "sim-a")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is True and demo.get("show_tag") is False, "stay locked after walk-away heartbeat")

        reset_mid = http_json("POST", base + "/reset", {})
        check(reset_mid.get("ok") is True, "POST /reset after first lock")
        demo_reset = http_json("GET", base + "/demo")
        check(demo_reset.get("locked") is False and demo_reset.get("show_tag") is True, "reset unlocks")
        check(demo_reset.get("calibrated_count") == 0, "reset calibrated_count 0")
        http_json("POST", base + "/join", {}, "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=0.04, tz=0.42), "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=-0.03, tz=0.40), "sim-b")

        delta_a = os.path.join(work, "delta-a.db")
        delta_b = os.path.join(work, "delta-b.db")
        made_a = write_delta(delta_a, 1, 0.25, 0.0, 0.10)
        made_b = write_delta(delta_b, 1, -0.20, 0.0, 0.18)
        check(made_a and made_b, "write demo deltas")

        # Mapping + lag: A syncs, B pulls immediately, /demo trail grows.
        lags_pull: list[float] = []
        lags_demo: list[float] = []
        demo_before = http_json("GET", base + "/demo")
        trail_a0 = 0
        for c in demo_before.get("clients") or []:
            if c.get("id") == "sim-a":
                trail_a0 = len(c.get("trail") or [])

        t0 = time.perf_counter()
        sync_a = sync_delta(base, "sim-a", delta_a, 0)
        check(sync_a.get("ok") is True and sync_a.get("_http") == 200, "POST /sync A", str(sync_a.get("accepted")))
        hdrs, raw = pull(base, "sim-b", 0)
        pull_ms = (time.perf_counter() - t0) * 1000.0
        lags_pull.append(pull_ms)
        nodes = int(hdrs.get("x-nodes-count") or 0)
        check(hdrs.get("_http") == "200", "GET /pull B after A sync")
        check(nodes > 0 or sync_a.get("accepted", 0) == 0, f"pull saw nodes={nodes} bytes={len(raw)}")

        t1 = time.perf_counter()
        demo = http_json("GET", base + "/demo")
        demo_ms = (time.perf_counter() - t1) * 1000.0
        lags_demo.append(demo_ms + pull_ms)
        trail_a1 = 0
        for c in demo.get("clients") or []:
            if c.get("id") == "sim-a":
                trail_a1 = len(c.get("trail") or [])
        check(trail_a1 >= trail_a0, f"A trail grew {trail_a0} -> {trail_a1}")

        t0 = time.perf_counter()
        sync_b = sync_delta(base, "sim-b", delta_b, 0)
        check(sync_b.get("ok") is True and sync_b.get("_http") == 200, "POST /sync B", str(sync_b.get("accepted")))
        hdrs, raw = pull(base, "sim-a", 0)
        pull_ms = (time.perf_counter() - t0) * 1000.0
        lags_pull.append(pull_ms)
        demo = http_json("GET", base + "/demo")
        demo_ms = (time.perf_counter() - t0) * 1000.0
        lags_demo.append(demo_ms)
        nodes = int(hdrs.get("x-nodes-count") or 0)
        check(hdrs.get("_http") == "200", "GET /pull A after B sync")
        check(nodes > 0 or sync_b.get("accepted", 0) == 0, f"pull A saw nodes={nodes}")
        trails = 0
        for c in demo.get("clients") or []:
            trails += len(c.get("trail") or [])
        check(trails >= 2, f"demo trails total points={trails}")

        def pct(values: list[float], p: float) -> float:
            if not values:
                return 0.0
            s = sorted(values)
            k = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
            return s[k]

        extra_pulls = []
        for i in range(6):
            extra = os.path.join(work, f"delta-lag-{i}.db")
            if not write_delta(extra, 2 + i, 0.3 + 0.05 * i, 0.0, 0.12 + 0.03 * i):
                continue
            t0 = time.perf_counter()
            sync_delta(base, "sim-a", extra, 0)
            pull(base, "sim-b", 0)
            extra_pulls.append((time.perf_counter() - t0) * 1000.0)
            http_json("GET", base + "/demo")
        lags_pull.extend(extra_pulls)
        p50 = statistics.median(lags_pull) if lags_pull else 0.0
        p95 = pct(lags_pull, 95)
        print(f"LAG   pull p50={p50:.1f}ms p95={p95:.1f}ms n={len(lags_pull)}", flush=True)
        print(f"LAG   demo-after-sync p50={statistics.median(lags_demo):.1f}ms n={len(lags_demo)}", flush=True)
        check(p95 < 5000.0, "lag p95 under 5s", f"p95={p95:.1f}ms")
        check(p50 < 3000.0, "lag p50 under 3s", f"p50={p50:.1f}ms")

        # Phone-style assembled surface (Poisson bake) and the live overlay of
        # nodes newer than it. Synthetic frames are 128x96 tilted walls, so
        # both the live mesh and the bake must have real faces.
        live_status, live_hdrs, _ = http("GET", base + "/map.mesh")
        live_faces = int(live_hdrs.get("x-face-count") or 0)
        check(live_status == 200 and live_faces > 0, "live mesh has faces", f"faces={live_faces}")
        status_before = http_json("GET", base + "/status")
        max_node = int(status_before.get("global_nodes") or 0)
        t_bake = time.perf_counter()
        bake = http_json("POST", base + "/bake", {})
        bake_s = time.perf_counter() - t_bake
        check(bake.get("ok") is True and bake.get("mesh_baked") is True, "POST /bake", json.dumps({k: bake.get(k) for k in ("ok", "mesh_baked", "bake_gen", "bake_max_node", "error")}))
        check(int(bake.get("bake_max_node") or 0) >= max_node and max_node > 0, "bake covers every node", f"bake_max_node={bake.get('bake_max_node')} nodes={max_node}")
        check(bake_s < 30.0, "bake under 30s on the sim room", f"{bake_s:.1f}s")
        bk_status, bk_hdrs, bk_body = http("GET", base + "/map.mesh?bake=1")
        bk_faces = int(bk_hdrs.get("x-face-count") or 0)
        check(bk_status == 200 and (bk_hdrs.get("x-mesh-kind") or "") == "baked" and bk_faces > 0, "GET /map.mesh?bake=1 is the baked surface", f"kind={bk_hdrs.get('x-mesh-kind')} faces={bk_faces} bytes={len(bk_body)}")
        check(bk_body.startswith(b"ply\n"), "baked mesh is PLY")
        bake_max = int(bake.get("bake_max_node") or 0)
        ov_status, ov_hdrs, _ = http("GET", base + f"/map.mesh?since_node={bake_max}")
        check(ov_status == 200 and int(ov_hdrs.get("x-node-count") or -1) == 0 and int(ov_hdrs.get("x-face-count") or -1) == 0, "overlay empty right after the bake", f"nodes={ov_hdrs.get('x-node-count')}")
        ov0_status, ov0_hdrs, _ = http("GET", base + "/map.mesh?since_node=0")
        check(ov0_status == 200 and int(ov0_hdrs.get("x-node-count") or 0) == max_node, "overlay since 0 carries every node", f"nodes={ov0_hdrs.get('x-node-count')} expected={max_node}")
        # A new upload shows up in the overlay before the next bake.
        extra_bake = os.path.join(work, "delta-after-bake.db")
        if write_delta(extra_bake, 20, 0.9, 0.0, 0.2):
            sync_delta(base, "sim-b", extra_bake, 0)
            deadline = time.time() + 10.0
            ov_nodes = 0
            while time.time() < deadline:
                _s, ov_hdrs2, _b = http("GET", base + f"/map.mesh?since_node={bake_max}")
                ov_nodes = int(ov_hdrs2.get("x-node-count") or 0)
                if ov_nodes > 0:
                    break
                time.sleep(0.3)
            check(ov_nodes == 1, "overlay carries the node uploaded after the bake", f"nodes={ov_nodes}")
            demo_ob = http_json("GET", base + "/demo")
            check(demo_ob.get("mesh_baked") is True and int(demo_ob.get("bake_max_node") or 0) == bake_max, "demo keeps bake coverage until the next bake")
        # The bake is textured like the phone's Assemble: PLY carries UVs and
        # the atlas is served as JPEG.
        check(bake.get("bake_textured") is True and (bk_hdrs.get("x-mesh-textured") or "") == "1", "bake is textured", f"bake_textured={bake.get('bake_textured')} hdr={bk_hdrs.get('x-mesh-textured')}")
        check(b"property float s\n" in bk_body[:600] and b"property float t\n" in bk_body[:600], "baked PLY has s/t texture coordinates")
        at_status, at_hdrs, at_body = http("GET", base + "/map.bake.jpg")
        check(at_status == 200 and (at_hdrs.get("content-type") or "").startswith("image/jpeg") and at_body[:2] == b"\xff\xd8", "GET /map.bake.jpg is a JPEG atlas", f"status={at_status} bytes={len(at_body)}")
        # Scan recordings: phone uploads an .mp4 at stop, admin lists and streams it.
        fake_video = bytes(range(256)) * 4096  # 1 MiB, deterministic
        vs, vh, vraw = http("POST", base + "/video", fake_video, {
            "X-Client-Id": "sim-a", "X-Video-Name": "../260906-e2e.mp4", "X-Video-Duration": "42.5",
            "X-Address": "123 Main St", "X-Latitude": "37.7749", "X-Longitude": "-122.4194",
            "Content-Type": "video/mp4"}, timeout=60.0)
        vres = json.loads(vraw.decode("utf-8") or "{}") if vs == 200 else {}
        check(vs == 200 and vres.get("ok") is True and vres.get("name") == "260906-e2e.mp4", "POST /video stores the recording under a safe name", f"status={vs} body={vraw[:120]!r}")
        ls, _lh, lraw = http("GET", base + "/videos")
        vlist = json.loads(lraw.decode("utf-8") or "{}").get("videos", []) if ls == 200 else []
        mine = next((v for v in vlist if v.get("name") == "260906-e2e.mp4"), None)
        check(mine is not None and mine.get("client") == "sim-a" and int(mine.get("bytes") or 0) == len(fake_video) and abs(float(mine.get("duration_s") or 0) - 42.5) < 1e-6, "GET /videos lists it with client, size, duration", json.dumps(mine))
        check(mine.get("current") is True, "uploaded recording belongs to the current run", json.dumps(mine))
        check(mine.get("address") == "123 Main St" and "123 Main St" in str(mine.get("title") or ""), "recording carries address metadata and title", json.dumps(mine))
        demo_run = http_json("GET", base + "/demo")
        check(demo_run.get("run_address") == "123 Main St" and "123 Main St" in str(demo_run.get("run_name") or ""), "demo run name is address + timestamp", json.dumps({k: demo_run.get(k) for k in ("run_id", "run_address", "run_name", "run_started")}))
        rs_run, _rh_run, rraw_run = http("GET", base + "/runs")
        runs = json.loads(rraw_run.decode("utf-8") or "{}") if rs_run == 200 else {}
        check(rs_run == 200 and (runs.get("current") or {}).get("address") == "123 Main St", "GET /runs stores the current address", json.dumps(runs.get("current")))
        cur = runs.get("current") or {}
        check(abs(float(cur.get("lat") or 0) - 37.7749) < 1e-4 and abs(float(cur.get("lng") or 0) + 122.4194) < 1e-4, "GET /runs stores the current GPS fix", json.dumps(cur))
        check(abs(float(mine.get("lat") or 0) - 37.7749) < 1e-4 and abs(float(mine.get("lng") or 0) + 122.4194) < 1e-4, "GET /videos includes scan coordinates", json.dumps(mine))
        cur_users = (runs.get("current") or {}).get("users") or []
        check("sim-a" in cur_users and "sim-b" in cur_users, "GET /runs stores which users did the current run", json.dumps(runs.get("current")))
        check("sim-a" in (demo_run.get("run_users") or []) and "sim-b" in (demo_run.get("run_users") or []), "demo run_users lists the phones on this run", json.dumps(demo_run.get("run_users")))
        check(mine.get("summary_status") in ("pending", "processing", "unavailable", "error", "ready", ""), "GET /videos includes summary_status", json.dumps(mine))
        an_s, _an_h, an_raw = http("GET", base + "/videos/260906-e2e.mp4/analysis")
        analysis = json.loads(an_raw.decode("utf-8") or "{}") if an_s == 200 else {}
        check(an_s == 200 and analysis.get("ok") is True and isinstance(analysis.get("tasks"), list), "GET /videos/<name>/analysis returns a summary payload", f"status={an_s} body={an_raw[:160]!r}")
        fixture = {
            "ok": True,
            "status": "ready",
            "name": "260906-e2e.mp4",
            "summary": "Walked the hall and cleared the doorway.",
            "tasks": [{
                "id": "260906-e2e:t01",
                "index": 1,
                "video": "260906-e2e.mp4",
                "title": "Cleared doorway",
                "description": "Inspected the door and entered the hall.",
                "start_s": 0.0,
                "end_s": 12.0,
                "status": "completed",
                "objects": ["door"],
                "location": "hall",
                "embed_text": "Completed task: Cleared doorway. Inspected the door and entered the hall. Location: hall. Objects: door. Recording 260906-e2e.mp4 0.0-12.0s.",
                "embedding": [0.1, 0.2, 0.3],
            }],
            "task_count": 1,
            "embedding_dim": 3,
            "error": "",
        }
        with open(os.path.join(work, "videos", "260906-e2e.mp4.analysis.json"), "w", encoding="utf-8") as f:
            json.dump(fixture, f)
        with open(os.path.join(work, "videos", "tasks.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps(fixture["tasks"][0]) + "\n")
        an2_s, _an2_h, an2_raw = http("GET", base + "/videos/260906-e2e.mp4/analysis")
        analysis2 = json.loads(an2_raw.decode("utf-8") or "{}") if an2_s == 200 else {}
        check(an2_s == 200 and analysis2.get("status") == "ready" and analysis2.get("summary") == fixture["summary"] and len(analysis2.get("tasks") or []) == 1, "analysis file is served to the player", json.dumps({k: analysis2.get(k) for k in ("status", "summary", "task_count")}))
        ts_s, _ts_h, ts_raw = http("GET", base + "/videos/tasks")
        corpus = json.loads(ts_raw.decode("utf-8") or "{}") if ts_s == 200 else {}
        check(ts_s == 200 and any(t.get("id") == "260906-e2e:t01" and t.get("embedding") for t in (corpus.get("tasks") or [])), "GET /videos/tasks is the vector-search corpus", f"status={ts_s} count={len(corpus.get('tasks') or [])}")
        sr_s, _sr_h, sr_raw = http("GET", base + "/search?q=doorway")
        search = json.loads(sr_raw.decode("utf-8") or "{}") if sr_s == 200 else {}
        search_hits = search.get("hits") or []
        check(sr_s == 200 and any("door" in str(h.get("label") or "").lower() or "door" in str(h.get("id") or "") for h in search_hits), "GET /search finds the indexed doorway task", f"status={sr_s} hits={search_hits[:3]!r}")
        empty_s, _eh, empty_raw = http("GET", base + "/search?q=")
        empty = json.loads(empty_raw.decode("utf-8") or "{}") if empty_s == 200 else {}
        check(empty_s == 200 and empty.get("hits") == [], "GET /search with an empty query returns no hits")
        sm_s, _sm_h, sm_raw = http("POST", base + "/videos/260906-e2e.mp4/summarize")
        check(sm_s == 200, "POST /videos/<name>/summarize is accepted", f"status={sm_s} body={sm_raw[:120]!r}")
        trav, _th2, _tb2 = http("GET", base + "/videos/..%2Fclients.json/analysis")
        check(trav == 404, "analysis path traversal rejected")
        check("v.current !== true" in page and "renderRecordings" in page and "treeFolder('recordings'" in page,
            "admin has a current-run Recordings folder and keeps those out of History")
        check("focusHistoryRecordings" in page and "videosForHistoryModel" in page,
            "admin switches the recordings folder when a history model is opened")
        rs, rh, rraw = http("GET", base + "/videos/260906-e2e.mp4", None, {"Range": "bytes=100-199"})
        check(rs == 206 and rh.get("content-range") == f"bytes 100-199/{len(fake_video)}" and rraw == fake_video[100:200], "GET /videos/<name> honors byte ranges (206)", f"status={rs} range={rh.get('content-range')}")
        fs_, fh, fraw = http("GET", base + "/videos/260906-e2e.mp4")
        check(fs_ == 200 and fraw == fake_video and (fh.get("accept-ranges") or "") == "bytes", "GET /videos/<name> full file with Accept-Ranges")
        ts_, _th, _tb = http("GET", base + "/videos/..%2Fclients.json")
        check(ts_ == 404, "recording path traversal rejected")
        check("History" in page and "/videos" in page and "player-video" in page, "admin page has the History folder and player")
        check('id="scan-map"' in page and "side-rule" in page and "tile.openstreetmap.org" in page, "admin sidebar has the OpenStreetMap site map above Units")
        check("nominatim.openstreetmap.org" in page and "cartocdn" not in page and "ipapi.co" not in page, "site map uses OSM tiles and Nominatim, no keyed geo APIs")
        check("openLatestSite" in page and "refreshScanMap" in page, "admin map opens the latest scan for a site")
        check('id="scan-search"' in page and "filteredHistoryModels" in page and "nominatim.openstreetmap.org/search" in page, "admin History search filters folder rows")
        check("/search?q=" in page and "historySearch" in page and "Search history" in page, "history search also matches indexed tasks and places")
        check("historySearchHtml" in page and "tree-search" in page and page.find("historySearchHtml()") < page.find("treeFolder('history/models'"), "history folder opens with the search box first")
        check("scan-search-hits" not in page and "runScanSearch" not in page, "history search does not show suggestion hits")
        check("openHistoryModel(modelName)" in page and "openPlayer(video.name, {dock: true})" in page, "map site click loads the latest 3D model and docks the recording")
        check('id="player"' in page and page.find('class="viewport"') < page.find('id="player"') < page.find('id="confirm"'), "player lives in the 3D viewport, not the shell grid")
        check("isolation:isolate" in page and "#player.open.docked" in page, "site map stacking is contained and the docked player is a side panel")
        check("player-summary" in page and "player-tasks" in page and "/analysis" in page, "admin player has the summary panel")
        check("Gemini" not in page and "GEMINI" not in page, "admin player copy does not mention Gemini")
        check("/models" in page and "data-model" in page and "history/models" in page, "admin History lists archived 3D models")

        # POST /reset wipes the room. The assembled mesh is kept under History.
        ms, _mh, mraw = http("GET", base + "/models")
        models_before = json.loads(mraw.decode("utf-8") or "{}").get("models", []) if ms == 200 else []
        http_json("POST", base + "/reset", {})
        ls_v2, _lh_v2, lraw_v2 = http("GET", base + "/videos")
        vlist2 = json.loads(lraw_v2.decode("utf-8") or "{}").get("videos", []) if ls_v2 == 200 else []
        mine2 = next((v for v in vlist2 if v.get("name") == "260906-e2e.mp4"), None)
        check(mine2 is not None and mine2.get("current") is not True, "reset moves the recording into History", json.dumps(mine2))
        demo_rb = http_json("GET", base + "/demo")
        check(demo_rb.get("mesh_baked") is not True and int(demo_rb.get("global_nodes") or 0) == 0, "reset wipes the map and bake")
        rb_status, rb_hdrs, _ = http("GET", base + "/map.mesh?bake=1")
        check(rb_status == 200 and int(rb_hdrs.get("x-face-count") or 0) == 0, "no baked surface after reset")
        ls_m, _lh_m, lraw_m = http("GET", base + "/models")
        models = json.loads(lraw_m.decode("utf-8") or "{}").get("models", []) if ls_m == 200 else []
        check(ls_m == 200 and len(models) >= 1, "GET /models lists the archived room", f"count={len(models)} before={len(models_before)}")
        archived = models[0]
        check(int(archived.get("nodes") or 0) > 0 and int(archived.get("bytes") or 0) > 0, "archived model has nodes and bytes", json.dumps({k: archived.get(k) for k in ("name", "nodes", "bytes", "textured", "kind")}))
        check(archived.get("index_status") in ("pending", "processing", "unavailable", "error", "ready", ""), "archived model is queued for indexing", json.dumps({k: archived.get(k) for k in ("name", "index_status", "place_count")}))
        model_fixture = {
            "ok": True,
            "status": "ready",
            "name": archived["name"],
            "kind": "model",
            "summary": "A hall with a doorway and stairs.",
            "places": [
                {
                    "id": "archive:model",
                    "kind": "model",
                    "index": 0,
                    "model": archived["name"],
                    "title": "123 Main St hall",
                    "description": "A hall with a doorway and stairs.",
                    "objects": ["door", "stairs"],
                    "location": "hall",
                    "address": "123 Main St",
                    "embed_text": "3D model of 123 Main St hall. A hall with a doorway and stairs.",
                    "embedding": [0.1, 0.2, 0.3],
                },
                {
                    "id": "archive:p01",
                    "kind": "place",
                    "index": 1,
                    "model": archived["name"],
                    "title": "Stair landing",
                    "description": "Stairs rise past the doorway.",
                    "objects": ["stairs"],
                    "location": "landing",
                    "address": "123 Main St",
                    "embed_text": "3D model place: Stair landing. Stairs rise past the doorway.",
                    "embedding": [0.2, 0.1, 0.0],
                },
            ],
            "place_count": 1,
            "embedding_dim": 3,
            "error": "",
        }
        with open(os.path.join(work, "models", archived["name"] + ".analysis.json"), "w", encoding="utf-8") as f:
            json.dump(model_fixture, f)
        with open(os.path.join(work, "models", "index.jsonl"), "w", encoding="utf-8") as f:
            for place in model_fixture["places"]:
                f.write(json.dumps(place) + "\n")
        sidecar_path = os.path.join(work, "models", archived["name"] + ".json")
        try:
            sidecar = json.loads(open(sidecar_path, encoding="utf-8").read() or "{}")
        except (OSError, json.JSONDecodeError):
            sidecar = {}
        sidecar["index_status"] = "ready"
        sidecar["place_count"] = 1
        with open(sidecar_path, "w", encoding="utf-8") as f:
            json.dump(sidecar, f)
        man_s, _man_h, man_raw = http("GET", base + "/models/" + archived["name"] + "/analysis")
        man = json.loads(man_raw.decode("utf-8") or "{}") if man_s == 200 else {}
        check(man_s == 200 and man.get("status") == "ready" and len(man.get("places") or []) == 2, "GET /models/<name>/analysis returns the model index", f"status={man_s} body={man_raw[:160]!r}")
        mi_s, _mi_h, mi_raw = http("GET", base + "/models/index")
        mi = json.loads(mi_raw.decode("utf-8") or "{}") if mi_s == 200 else {}
        check(mi_s == 200 and any(p.get("id") == "archive:p01" for p in (mi.get("places") or [])), "GET /models/index is the model corpus", f"status={mi_s} count={len(mi.get('places') or [])}")
        ms2_s, _ms2_h, ms2_raw = http("GET", base + "/models")
        models2 = json.loads(ms2_raw.decode("utf-8") or "{}").get("models", []) if ms2_s == 200 else []
        archived2 = next((m for m in models2 if m.get("name") == archived["name"]), None) or {}
        check(archived2.get("index_status") == "ready" and int(archived2.get("place_count") or 0) == 1, "GET /models includes index_status and place_count", json.dumps({k: archived2.get(k) for k in ("name", "index_status", "place_count")}))
        sr2_s, _sr2_h, sr2_raw = http("GET", base + "/search?q=stairs")
        search2 = json.loads(sr2_raw.decode("utf-8") or "{}") if sr2_s == 200 else {}
        hits2 = search2.get("hits") or []
        check(sr2_s == 200 and any(h.get("kind") in ("model", "place") and archived["name"] in str(h.get("model") or "") for h in hits2), "GET /search finds the indexed model place", f"status={sr2_s} hits={hits2[:3]!r}")
        ix_s, _ix_h, ix_raw = http("POST", base + "/models/" + archived["name"] + "/index")
        check(ix_s == 200, "POST /models/<name>/index is accepted", f"status={ix_s} body={ix_raw[:120]!r}")
        trav_m, _tmh, _tmb = http("GET", base + "/models/..%2Fclients.json/analysis")
        check(trav_m == 404, "model analysis path traversal rejected")
        archived_users = archived.get("users") or []
        check("sim-a" in archived_users and "sim-b" in archived_users, "archived model stores which users did the run", json.dumps({k: archived.get(k) for k in ("name", "users", "run")}))
        rs_past, _rh_past, rraw_past = http("GET", base + "/runs")
        runs_past = json.loads(rraw_past.decode("utf-8") or "{}") if rs_past == 200 else {}
        closed = next((r for r in (runs_past.get("runs") or []) if "sim-a" in (r.get("users") or [])), None)
        check(closed is not None and "sim-b" in (closed.get("users") or []), "closed run stores which users did it", json.dumps(closed))
        as_, ah, abody = http("GET", base + "/models/" + archived["name"])
        check(as_ == 200 and abody.startswith(b"ply\n") and (ah.get("x-mesh-kind") or "") == "archive", "GET /models/<name> is the archived PLY", f"status={as_} kind={ah.get('x-mesh-kind')} bytes={len(abody)}")
        if archived.get("textured") and archived.get("atlas_url"):
            ats, ath, atb = http("GET", base + archived["atlas_url"])
            check(ats == 200 and (ath.get("content-type") or "").startswith("image/jpeg") and atb[:2] == b"\xff\xd8", "archived atlas is a JPEG")
        bad_m, _bh, _bb = http("GET", base + "/models/..%2Fclients.json")
        check(bad_m == 404, "model path traversal rejected")
        http_json("POST", base + "/join", {}, "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=0.04, tz=0.42), "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=-0.03, tz=0.40), "sim-b")

        # 10x lock reliability with pose noise.
        locks = 0
        hides = 0
        for i in range(10):
            reset = http_json("POST", base + "/reset", {})
            if reset.get("ok") is not True:
                continue
            a = f"sim-a-{i}"
            b = f"sim-b-{i}"
            http_json("POST", base + "/join", {}, a)
            noise = 0.01 * (i + 1)
            r1 = http_json("POST", base + "/calibrate", pose(tx=0.02 + noise, tz=0.40 + noise), a)
            demo1 = http_json("GET", base + "/demo")
            if r1.get("locked") is True and demo1.get("locked") is True and demo1.get("show_tag") is False:
                locks += 1
                hides += 1
        check(locks == 10, "10/10 lock with pose noise", f"{locks}/10")
        check(hides == 10, "10/10 hide tag after lock", f"{hides}/10")

        admin_reset_status, _, admin_reset_html = http("GET", base + "/admin?reset=1")
        check(admin_reset_status == 200 and b"calib-tag" in admin_reset_html, "GET /admin?reset=1")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is False and demo.get("show_tag") is True, "admin?reset=1 unlocks")
        check(demo.get("calibrated_count") == 0, "admin?reset=1 calibrated_count 0")

        # Unit-test the admin JS condition against the last /demo.
        demo = http_json("GET", base + "/demo")
        js_match = re.search(r"function shouldShowTag\(demo\) \{\s*return demo\.show_tag === true && demo\.locked !== true;\s*\}", page)
        check(js_match is not None, "admin JS hide condition")
        check(should_show_tag(demo) is True, "condition shows tag after reset")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        logf.close()

    print(f"\nRESULT  pass={PASS} fail={FAIL}", flush=True)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
