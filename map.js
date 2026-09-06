import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";

const COLORS = [0xdbdad9, 0xa19f9b];
const TAG_SIZE_M = 0.2;

const BASE_FROM_GL = new THREE.Matrix4().makeBasis(
  new THREE.Vector3(0, -1, 0),
  new THREE.Vector3(0, 0, 1),
  new THREE.Vector3(-1, 0, 0),
);

function makeLabelSprite(text, color) {
  const canvas = document.createElement("canvas");
  canvas.width = 640;
  canvas.height = 160;
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "rgba(22,21,20,0.88)";
  ctx.fillRect(8, 24, 624, 112);
  ctx.strokeStyle = `#${color.toString(16).padStart(6, "0")}`;
  ctx.lineWidth = 3;
  ctx.strokeRect(8, 24, 624, 112);
  ctx.fillStyle = "#DBDAD9";
  ctx.font = "600 56px Inter, sans-serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, 320, 80);
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  const spr = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true }));
  spr.scale.set(0.58, 0.145, 1);
  spr.renderOrder = 20;
  return spr;
}

function makeUserGroup(color, label, x, y, z, yaw, trailPts) {
  const g = new THREE.Group();
  const threeColor = new THREE.Color(color);
  const bodyMat = new THREE.MeshStandardMaterial({
    color,
    roughness: 0.38,
    metalness: 0.08,
    emissive: color,
    emissiveIntensity: 0.28,
  });
  const darkMat = new THREE.MeshStandardMaterial({
    color: 0x2b2a28,
    roughness: 0.45,
    metalness: 0.2,
  });

  const holder = new THREE.Group();
  holder.rotation.x = Math.PI / 2;
  const body = new THREE.Group();
  const capsule = new THREE.Mesh(new THREE.CapsuleGeometry(0.06, 0.24, 6, 10), bodyMat);
  capsule.position.y = 0.18;
  const head = new THREE.Mesh(new THREE.SphereGeometry(0.05, 12, 10), bodyMat);
  head.position.y = 0.41;
  body.add(capsule, head);
  body.position.y = -0.42;
  holder.add(body);

  const cam = new THREE.Group();
  const camInner = new THREE.Group();
  camInner.quaternion.setFromRotationMatrix(BASE_FROM_GL);
  const phone = new THREE.Mesh(new THREE.BoxGeometry(0.028, 0.056, 0.006), darkMat);
  phone.position.set(0, 0, -0.02);
  const frustumGeom = new THREE.ConeGeometry(0.11, 0.34, 4, 1, true);
  frustumGeom.rotateX(-Math.PI / 2);
  frustumGeom.translate(0, 0, -0.17);
  const frustum = new THREE.Mesh(
    frustumGeom,
    new THREE.MeshBasicMaterial({
      color,
      transparent: true,
      opacity: 0.42,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
  );
  const frustumWire = new THREE.LineSegments(
    new THREE.EdgesGeometry(frustumGeom),
    new THREE.LineBasicMaterial({ color: 0xdbdad9 }),
  );
  camInner.add(phone, frustum, frustumWire);
  cam.add(camInner);
  cam.add(new THREE.AxesHelper(0.16));
  cam.rotation.set(0, 0, yaw);

  const labelSpr = makeLabelSprite(label, threeColor);
  labelSpr.position.set(0, 0, 0.2);

  g.add(holder, cam, labelSpr);
  g.position.set(x, y, z);

  const pts = trailPts.map(([tx, ty]) => new THREE.Vector3(tx, ty, z));
  const trail = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints(pts),
    new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.45 }),
  );
  return { marker: g, trail };
}

function gToThree(v) {
  return new THREE.Vector3(-v.y, v.z, -v.x);
}

function vertexMean(geom) {
  const pos = geom.getAttribute("position");
  const sum = new THREE.Vector3();
  for (let i = 0; i < pos.count; i += 1) {
    sum.x += pos.getX(i);
    sum.y += pos.getY(i);
    sum.z += pos.getZ(i);
  }
  return sum.multiplyScalar(1 / Math.max(pos.count, 1));
}

function pickHighPoint(geom) {
  const pos = geom.getAttribute("position");
  const ys = [];
  const step = Math.max(1, Math.floor(pos.count / 8000));
  for (let i = 0; i < pos.count; i += step) {
    ys.push(pos.getY(i));
  }
  ys.sort((a, b) => a - b);
  const hi = ys[Math.min(ys.length - 1, Math.floor(ys.length * 0.9))];
  const tmp = new THREE.Vector3();
  const best = new THREE.Vector3();
  let bestScore = Infinity;
  for (let i = 0; i < pos.count; i += step) {
    tmp.set(pos.getX(i), pos.getY(i), pos.getZ(i));
    const score = Math.abs(tmp.y - hi) * 1.4 + Math.hypot(tmp.x, tmp.z) * 0.3;
    if (score < bestScore) {
      bestScore = score;
      best.copy(tmp);
    }
  }
  return best;
}

function pickSurfacePoint(geom) {
  const pos = geom.getAttribute("position");
  const tmp = new THREE.Vector3();
  const best = new THREE.Vector3();
  let bestScore = Infinity;
  const step = Math.max(1, Math.floor(pos.count / 5000));
  for (let i = 0; i < pos.count; i += step) {
    tmp.set(pos.getX(i), pos.getY(i), pos.getZ(i));
    const score = Math.abs(tmp.y - 0.4) * 1.8 + Math.hypot(tmp.x, tmp.z) * 0.32;
    if (score < bestScore) {
      bestScore = score;
      best.copy(tmp);
    }
  }
  return best;
}

function pickScanPoint(geom) {
  const pos = geom.getAttribute("position");
  const tmp = new THREE.Vector3();
  const best = new THREE.Vector3();
  let bestScore = Infinity;
  const step = Math.max(1, Math.floor(pos.count / 5000));
  for (let i = 0; i < pos.count; i += step) {
    tmp.set(pos.getX(i), pos.getY(i), pos.getZ(i));
    const score = Math.abs(tmp.y - 1.05) * 1.1 + Math.abs(Math.hypot(tmp.x, tmp.z) - 2.1) * 0.85;
    if (score < bestScore) {
      bestScore = score;
      best.copy(tmp);
    }
  }
  return best;
}

function percentileRadius(geom, center, pct) {
  const pos = geom.getAttribute("position");
  const dist = new Float64Array(pos.count);
  const tmp = new THREE.Vector3();
  for (let i = 0; i < pos.count; i += 1) {
    tmp.set(pos.getX(i), pos.getY(i), pos.getZ(i));
    dist[i] = tmp.distanceTo(center);
  }
  dist.sort();
  const idx = Math.min(dist.length - 1, Math.floor(dist.length * pct));
  return Math.max(dist[idx], 1.5);
}

export function initMap() {
  const wrap = document.getElementById("map-wrap");
  const canvas = document.getElementById("map");
  if (!wrap || !canvas) {
    return null;
  }

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0x161514, 1);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(60, 1, 0.05, 200);
  camera.position.set(6.2, 4.4, 7.4);

  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  controls.enablePan = true;
  controls.screenSpacePanning = true;
  controls.autoRotate = true;
  controls.autoRotateSpeed = 0.35;
  controls.minDistance = 0.12;
  controls.maxDistance = 80;
  controls.target.set(0, 0, 0);

  const gBasis = new THREE.Matrix4().makeBasis(
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(-1, 0, 0),
    new THREE.Vector3(0, 1, 0),
  );
  const world = new THREE.Group();
  scene.add(world);

  scene.add(new THREE.AmbientLight(0xdbdad9, 0.32));
  scene.add(new THREE.HemisphereLight(0xdbdad9, 0x1f1e1d, 0.62));
  const key = new THREE.DirectionalLight(0xdbdad9, 0.85);
  key.position.set(2.4, 4.2, 2.8);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xa19f9b, 0.18);
  fill.position.set(-2.2, 1.4, -1.6);
  scene.add(fill);

  const origin = new THREE.Mesh(
    new THREE.SphereGeometry(0.04, 12, 10),
    new THREE.MeshBasicMaterial({ color: 0xa19f9b }),
  );
  world.add(origin);
  const tagPlane = new THREE.Mesh(
    new THREE.PlaneGeometry(TAG_SIZE_M, TAG_SIZE_M),
    new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, transparent: true, opacity: 0.55 }),
  );
  tagPlane.rotation.y = Math.PI / 2;
  world.add(tagPlane);

  let scanRadius = 8;
  let scanMesh = null;
  let readyResolve = () => {};
  const ready = new Promise((resolve) => {
    readyResolve = resolve;
  });
  const noteTargets = {
    unit1: new THREE.Vector3(),
    unit2: new THREE.Vector3(),
    mesh: new THREE.Vector3(),
    floors: new THREE.Vector3(),
    scan: new THREE.Vector3(),
  };
  const noteEls = {
    unit1: document.querySelector('[data-note="unit1"]'),
    unit2: document.querySelector('[data-note="unit2"]'),
    mesh: document.querySelector('[data-note="mesh"]'),
    floors: document.querySelector('[data-note="floors"]'),
    scan: document.querySelector('[data-note="scan"]'),
  };
  const pinEls = {
    unit1: document.querySelector('[data-pin="unit1"]'),
    unit2: document.querySelector('[data-pin="unit2"]'),
    mesh: document.querySelector('[data-pin="mesh"]'),
    floors: document.querySelector('[data-pin="floors"]'),
    scan: document.querySelector('[data-pin="scan"]'),
  };
  const lineEls = {
    unit1: document.querySelector('[data-line="unit1"]'),
    unit2: document.querySelector('[data-line="unit2"]'),
    mesh: document.querySelector('[data-line="mesh"]'),
    floors: document.querySelector('[data-line="floors"]'),
    scan: document.querySelector('[data-line="scan"]'),
  };
  const projectTmp = new THREE.Vector3();
  const camPos = new THREE.Vector3();
  const camDir = new THREE.Vector3();
  const lookTmp = new THREE.Vector3();

  const unit1 = makeUserGroup(
    COLORS[0],
    "UNIT-01 / A31C",
    0.63,
    -1.526,
    0.32,
    -1.044,
    [
      [-0.375, 0.034],
      [0.376, 0.129],
      [-0.041, 0.344],
      [0.063, -0.552],
      [0.63, -1.526],
    ],
  );
  const unit2 = makeUserGroup(
    COLORS[1],
    "UNIT-02 / 9F04",
    2.727,
    2.043,
    1.204,
    0.448,
    [
      [0.863, -1.8],
      [0.925, -1.024],
      [-1.172, -0.166],
      [-1.55, 1.779],
      [2.727, 2.043],
    ],
  );
  world.add(unit1.marker, unit1.trail, unit2.marker, unit2.trail);

  function attachScan(geom, tex) {
    geom.applyMatrix4(gBasis);
    const mean = vertexMean(geom);
    geom.translate(-mean.x, -mean.y, -mean.z);
    geom.computeVertexNormals();
    scanRadius = percentileRadius(geom, new THREE.Vector3(), 0.84);
    const hasUv = !!geom.getAttribute("uv");
    const hasColor = !!geom.getAttribute("color");
    geom.computeBoundingBox();
    const mat = tex && hasUv
      ? new THREE.MeshBasicMaterial({ map: tex, side: THREE.DoubleSide })
      : new THREE.MeshStandardMaterial({
          vertexColors: hasColor,
          color: hasColor ? 0xffffff : 0xa19f9b,
          roughness: 0.88,
          metalness: 0.02,
          side: THREE.DoubleSide,
        });
    if (scanMesh) {
      world.remove(scanMesh);
      scanMesh.geometry.dispose();
      scanMesh.material.dispose();
    }
    scanMesh = new THREE.Mesh(geom, mat);
    world.add(scanMesh);
    [unit1.marker, unit2.marker, unit1.trail, unit2.trail, origin, tagPlane].forEach((obj) => {
      // Rotate the whole object into the three.js (y-up) frame, not just its
      // position, so the unit figures stand upright instead of lying sideways.
      obj.applyMatrix4(gBasis);
      obj.position.sub(mean);
    });
    noteTargets.unit1.copy(unit1.marker.position);
    noteTargets.unit2.copy(unit2.marker.position);
    noteTargets.mesh.copy(pickSurfacePoint(geom));
    noteTargets.floors.copy(pickHighPoint(geom));
    noteTargets.scan.copy(pickScanPoint(geom));
    resize();
    requestAnimationFrame(fit);
    readyResolve();
  }

  new PLYLoader().load("assets/map.ply?v=15", (geom) => {
    const hasUv = !!geom.getAttribute("uv");
    if (!hasUv) {
      attachScan(geom, null);
      return;
    }
    new THREE.TextureLoader().load(
      "assets/map.bake.jpg?v=15",
      (tex) => {
        tex.colorSpace = THREE.SRGBColorSpace;
        tex.anisotropy = renderer.capabilities.getMaxAnisotropy();
        tex.generateMipmaps = true;
        tex.minFilter = THREE.LinearMipmapLinearFilter;
        attachScan(geom, tex);
      },
      undefined,
      () => attachScan(geom, null),
    );
  }, undefined, () => readyResolve());

  function resize() {
    const w = Math.max(1, wrap.clientWidth);
    const h = Math.max(1, wrap.clientHeight);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
    canvas.style.width = "100%";
    canvas.style.height = "100%";
  }

  function projectedBounds() {
    const box = scanMesh?.geometry.boundingBox;
    if (!box) {
      return null;
    }
    const corners = [
      new THREE.Vector3(box.min.x, box.min.y, box.min.z),
      new THREE.Vector3(box.min.x, box.min.y, box.max.z),
      new THREE.Vector3(box.min.x, box.max.y, box.min.z),
      new THREE.Vector3(box.min.x, box.max.y, box.max.z),
      new THREE.Vector3(box.max.x, box.min.y, box.min.z),
      new THREE.Vector3(box.max.x, box.min.y, box.max.z),
      new THREE.Vector3(box.max.x, box.max.y, box.min.z),
      new THREE.Vector3(box.max.x, box.max.y, box.max.z),
    ];
    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;
    corners.forEach((corner) => {
      corner.project(camera);
      minX = Math.min(minX, corner.x);
      maxX = Math.max(maxX, corner.x);
      minY = Math.min(minY, corner.y);
      maxY = Math.max(maxY, corner.y);
    });
    return { minX, maxX, minY, maxY };
  }

  function panToNdc(ndcX, ndcY) {
    const focus = new THREE.Vector3(0, 0, 0.5).unproject(camera);
    const shifted = new THREE.Vector3(ndcX, ndcY, 0.5).unproject(camera);
    const pan = shifted.sub(focus);
    camera.position.add(pan);
    controls.target.add(pan);
  }

  const homePos = new THREE.Vector3();
  const homeTarget = new THREE.Vector3();
  let homeReady = false;

  function rememberHome() {
    homePos.copy(camera.position);
    homeTarget.copy(controls.target);
    homeReady = true;
  }

  function fit() {
    const vfov = (camera.fov * Math.PI) / 180;
    const hfov = 2 * Math.atan(Math.tan(vfov / 2) * Math.max(camera.aspect, 0.2));
    const dist = (scanRadius / Math.sin(Math.min(vfov, hfov) / 2)) * 0.94;
    camera.position.set(dist * 0.3, dist * 0.72, dist * 0.52);
    controls.target.set(0, 0, 0);
    camera.updateMatrixWorld(true);
    const bounds = projectedBounds();
    if (bounds) {
      const midX = (bounds.minX + bounds.maxX) / 2;
      const midY = (bounds.minY + bounds.maxY) / 2;
      panToNdc(midX * 0.55, midY * 0.55);
      camera.updateMatrixWorld(true);
    }
    controls.update();
    rememberHome();
  }

  function projectToView(worldPos) {
    projectTmp.copy(worldPos).project(camera);
    const rect = wrap.getBoundingClientRect();
    camera.getWorldPosition(camPos);
    camera.getWorldDirection(camDir);
    const inFront = lookTmp.copy(worldPos).sub(camPos).dot(camDir) > 0.08;
    return {
      x: rect.left + (projectTmp.x * 0.5 + 0.5) * rect.width,
      y: rect.top + (-projectTmp.y * 0.5 + 0.5) * rect.height,
      inFront,
    };
  }

  function boxAnchor(el, toX, toY) {
    const rect = el.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const dx = (toX - cx) / Math.max(rect.width, 1);
    const dy = (toY - cy) / Math.max(rect.height, 1);
    if (Math.abs(dx) > Math.abs(dy)) {
      return { x: dx > 0 ? rect.right : rect.left, y: cy };
    }
    return { x: cx, y: dy > 0 ? rect.bottom : rect.top };
  }

  const NOTE_IDS = ["unit1", "unit2", "mesh", "floors", "scan"];

  function slotsFor(count, side) {
    if (side === "l") {
      if (count <= 1) {
        return ["tl"];
      }
      if (count === 2) {
        return ["tl", "bl"];
      }
      return ["tl", "ml", "bl"];
    }
    if (count <= 1) {
      return ["tr"];
    }
    if (count === 2) {
      return ["tr", "br"];
    }
    return ["tr", "mr", "br"];
  }

  function placeNotes(items) {
    const vis = items.filter((it) => it.on);
    vis.sort((a, b) => a.pt.x - b.pt.x || a.pt.y - b.pt.y);
    const mid = Math.ceil(vis.length / 2);
    const left = vis.slice(0, mid).sort((a, b) => a.pt.y - b.pt.y);
    const right = vis.slice(mid).sort((a, b) => a.pt.y - b.pt.y);
    const leftSlots = slotsFor(left.length, "l");
    const rightSlots = slotsFor(right.length, "r");
    left.forEach((it, i) => {
      it.slot = leftSlots[i];
    });
    right.forEach((it, i) => {
      it.slot = rightSlots[i];
    });
  }

  function syncNotes() {
    const active = document.body.classList.contains("is-map-full");
    if (!active) {
      return;
    }
    const items = NOTE_IDS.map((id) => {
      const pt = projectToView(noteTargets[id]);
      const on = pt.inFront && pt.x > -80 && pt.x < window.innerWidth + 80 && pt.y > -80 && pt.y < window.innerHeight + 80;
      return { id, pt, on };
    });
    placeNotes(items);
    items.forEach((it) => {
      const note = noteEls[it.id];
      const pin = pinEls[it.id];
      const line = lineEls[it.id];
      if (!note || !pin || !line) {
        return;
      }
      note.classList.toggle("is-off", !it.on);
      if (it.slot) {
        note.dataset.slot = it.slot;
      }
      pin.style.display = it.on ? "block" : "none";
      line.style.display = it.on ? "block" : "none";
      if (!it.on) {
        return;
      }
      pin.style.transform = `translate3d(${it.pt.x}px, ${it.pt.y}px, 0)`;
    });
    items.forEach((it) => {
      if (!it.on) {
        return;
      }
      const note = noteEls[it.id];
      const line = lineEls[it.id];
      if (!note || !line) {
        return;
      }
      const from = boxAnchor(note, it.pt.x, it.pt.y);
      line.setAttribute("x1", String(from.x));
      line.setAttribute("y1", String(from.y));
      line.setAttribute("x2", String(it.pt.x));
      line.setAttribute("y2", String(it.pt.y));
    });
  }

  function setEnter(t) {
    if (!homeReady) {
      return;
    }
    const amount = Math.min(1, Math.max(0, t));
    const dir = homePos.clone().sub(homeTarget);
    const dist = dir.length() * (1 - amount * 0.42);
    if (dist < 0.05) {
      return;
    }
    camera.position.copy(homeTarget).addScaledVector(dir.normalize(), dist);
    controls.target.copy(homeTarget);
    camera.updateMatrixWorld(true);
    controls.update();
  }

  function tick() {
    requestAnimationFrame(tick);
    controls.update();
    renderer.render(scene, camera);
    syncNotes();
  }

  resize();
  tick();
  window.addEventListener("resize", resize);
  canvas.addEventListener("pointerdown", () => {
    controls.autoRotate = false;
  });

  return { resize, fit, setEnter, ready };
}
