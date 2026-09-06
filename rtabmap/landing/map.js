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
  controls.target.set(0.8, 0.8, 0.4);

  const world = new THREE.Group();
  world.matrixAutoUpdate = false;
  world.matrix.makeBasis(
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(-1, 0, 0),
    new THREE.Vector3(0, 1, 0),
  );
  world.matrixWorldNeedsUpdate = true;
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

  const unit1 = makeUserGroup(
    COLORS[0],
    "UNIT-01 / A31C",
    2.41,
    -1.082,
    0.214,
    -0.4,
    [
      [0.2, -0.1],
      [0.8, -0.35],
      [1.4, -0.7],
      [1.95, -0.95],
      [2.41, -1.082],
    ],
  );
  const unit2 = makeUserGroup(
    COLORS[1],
    "UNIT-02 / 9F04",
    6.2,
    3.4,
    0.22,
    1.1,
    [
      [1.1, 0.4],
      [2.8, 1.5],
      [4.6, 2.6],
      [6.2, 3.4],
    ],
  );
  world.add(unit1.marker, unit1.trail, unit2.marker, unit2.trail);

  new PLYLoader().load("assets/map.ply", (geom) => {
    const mean = vertexMean(geom);
    geom.translate(-mean.x, -mean.y, -mean.z);
    geom.computeVertexNormals();
    scanRadius = percentileRadius(geom, new THREE.Vector3(), 0.86);
    const hasColor = !!geom.getAttribute("color");
    world.add(new THREE.Mesh(
      geom,
      new THREE.MeshStandardMaterial({
        vertexColors: hasColor,
        color: hasColor ? 0xffffff : 0xa19f9b,
        roughness: 0.88,
        metalness: 0.02,
        side: THREE.DoubleSide,
      }),
    ));
    unit1.marker.position.sub(mean);
    unit2.marker.position.sub(mean);
    unit1.trail.position.sub(mean);
    unit2.trail.position.sub(mean);
    origin.position.sub(mean);
    tagPlane.position.sub(mean);
    resize();
    requestAnimationFrame(fit);
  });

  function resize() {
    const w = Math.max(1, wrap.clientWidth);
    const h = Math.max(1, wrap.clientHeight);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
    canvas.style.width = "100%";
    canvas.style.height = "100%";
  }

  function fit() {
    world.updateMatrixWorld(true);
    const center = new THREE.Vector3();
    const vfov = (camera.fov * Math.PI) / 180;
    const hfov = 2 * Math.atan(Math.tan(vfov / 2) * Math.max(camera.aspect, 0.2));
    const dist = (scanRadius / Math.sin(Math.min(vfov, hfov) / 2)) * 1.12;
    const dir = new THREE.Vector3(0.55, 0.38, 0.74).normalize();
    camera.position.copy(center).addScaledVector(dir, Math.min(dist, 36));
    controls.target.copy(center);
    controls.update();
  }

  function tick() {
    requestAnimationFrame(tick);
    controls.update();
    renderer.render(scene, camera);
  }

  resize();
  tick();
  window.addEventListener("resize", resize);
  document.getElementById("fit-btn")?.addEventListener("click", fit);
  canvas.addEventListener("pointerdown", () => {
    controls.autoRotate = false;
  });

  return { resize, fit };
}
