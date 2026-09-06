import * as THREE from "/static/vendor/three.module.js";
import { OrbitControls } from "/static/vendor/OrbitControls.js";
import { GLTFLoader } from "/static/vendor/GLTFLoader.js";

const STORAGE_KEY = "mapanything-world-id";
const fileInput = document.querySelector("#file-input");
const drop = document.querySelector("#drop");
const browse = document.querySelector("#browse");
const sourcesEl = document.querySelector("#sources");
const sourceCount = document.querySelector("#source-count");
const statusEl = document.querySelector("#status");
const emptyEl = document.querySelector("#empty");
const downloadEl = document.querySelector("#download");
const worldIdEl = document.querySelector("#world-id");
const runtimePill = document.querySelector("#runtime-pill");
const showCameras = document.querySelector("#show-cameras");

const INGEST_RESOLUTIONS = [518, 770, 1036];

const fields = {
  interval: document.querySelector("#interval"),
  maxFrames: document.querySelector("#max-frames"),
  confidence: document.querySelector("#confidence"),
  resolution: document.querySelector("#resolution"),
  asMesh: document.querySelector("#as-mesh"),
};
const outputs = {
  interval: document.querySelector("#interval-out"),
  maxFrames: document.querySelector("#max-frames-out"),
  confidence: document.querySelector("#confidence-out"),
  resolution: document.querySelector("#resolution-out"),
};

function resolutionFromSlider(value) {
  const index = Math.min(
    INGEST_RESOLUTIONS.length - 1,
    Math.max(0, Number(value) || 0)
  );
  return INGEST_RESOLUTIONS[index];
}

function sliderFromResolution(value) {
  const resolved = Number(value);
  let best = 0;
  let bestDist = Infinity;
  INGEST_RESOLUTIONS.forEach((item, index) => {
    const dist = Math.abs(item - resolved);
    if (dist < bestDist) {
      best = index;
      bestDist = dist;
    }
  });
  return String(best);
}

let worldId = localStorage.getItem(STORAGE_KEY);
let pollTimer = null;
let lastModelUrl = null;
let modelLoading = false;
let lastSourceSignature = "";
let selectedSourceId = null;
let flipCameras = false;
let lastWorld = null;
let settingsHydrated = false;
let settingsDirty = false;
let persistSeq = 0;

const renderer = new THREE.WebGLRenderer({
  canvas: document.querySelector("#view"),
  antialias: true,
  alpha: true,
});
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(0x0e1217, 1);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, 1, 0.05, 400);
camera.position.set(4.2, 3.2, 4.8);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.target.set(1, 0.6, 1);

scene.add(new THREE.AmbientLight(0xffffff, 0.7));
const key = new THREE.DirectionalLight(0xffe1b5, 1.1);
key.position.set(4, 8, 3);
scene.add(key);

const worldGroup = new THREE.Group();
const cameraGroup = new THREE.Group();
scene.add(worldGroup, cameraGroup);

const loader = new GLTFLoader();
const palette = [0xe3a04a, 0x4db8be, 0x7dce8a, 0xd07ad0, 0x6ea8ff, 0xf0d36a];

function settings() {
  return {
    seconds_between_frames: fields.interval.value,
    max_frames: fields.maxFrames.value,
    confidence_percentile: fields.confidence.value,
    as_mesh: fields.asMesh.checked ? "true" : "false",
    ingest_resolution: fields.resolution
      ? resolutionFromSlider(fields.resolution.value)
      : 518,
  };
}

function fillForm(data) {
  const body = new FormData();
  Object.entries(data).forEach(([key, value]) => body.append(key, value));
  return body;
}

function bindSliders() {
  const pairs = [
    [fields.interval, outputs.interval],
    [fields.maxFrames, outputs.maxFrames],
    [fields.confidence, outputs.confidence],
  ];
  for (const [input, output] of pairs) {
    if (!input || !output) continue;
    const sync = () => { output.textContent = input.value; };
    input.addEventListener("input", sync);
    sync();
  }
  if (fields.resolution && outputs.resolution) {
    const syncResolution = () => {
      outputs.resolution.textContent = String(resolutionFromSlider(fields.resolution.value));
    };
    fields.resolution.addEventListener("input", syncResolution);
    syncResolution();
  }
}

function hydrateSettingsFromWorld(world) {
  if (!world.settings) return;
  fields.interval.value = world.settings.seconds_between_frames;
  fields.maxFrames.value = world.settings.max_frames;
  fields.confidence.value = world.settings.confidence_percentile;
  fields.asMesh.checked = Boolean(world.settings.as_mesh);
  if (fields.resolution) {
    fields.resolution.value = sliderFromResolution(world.settings.ingest_resolution);
  }
  outputs.interval.textContent = fields.interval.value;
  outputs.maxFrames.textContent = fields.maxFrames.value;
  outputs.confidence.textContent = fields.confidence.value;
  if (outputs.resolution && fields.resolution) {
    outputs.resolution.textContent = String(resolutionFromSlider(fields.resolution.value));
  }
}

function resize() {
  const canvas = renderer.domElement;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== width || canvas.height !== height) {
    renderer.setSize(width, height, false);
    camera.aspect = width / Math.max(height, 1);
    camera.updateProjectionMatrix();
  }
}

function animate() {
  resize();
  controls.update();
  renderer.render(scene, camera);
  requestAnimationFrame(animate);
}

function worldToView(values) {
  const vector = new THREE.Vector3().fromArray(values);
  if (flipCameras) {
    vector.y *= -1;
    vector.z *= -1;
  }
  return vector;
}

function sceneBox() {
  const box = new THREE.Box3();
  const roots = [worldGroup, cameraGroup];
  for (const root of roots) {
    root.updateWorldMatrix(true, true);
    root.traverse((node) => {
      const pos = node.geometry?.attributes?.position;
      if (!pos || !pos.count) return;
      const local = new THREE.Box3().setFromBufferAttribute(pos);
      if (local.isEmpty()) return;
      local.applyMatrix4(node.matrixWorld);
      box.union(local);
    });
  }
  return box;
}

function fitScene() {
  const box = sceneBox();
  if (box.isEmpty()) return;
  const size = Math.max(box.getSize(new THREE.Vector3()).length(), 0.4);
  const center = box.getCenter(new THREE.Vector3());
  controls.target.copy(center);
  camera.position.copy(center).add(new THREE.Vector3(size * 0.35, size * 0.22, size * 0.4));
  camera.near = Math.max(size / 400, 0.02);
  camera.far = Math.max(size * 40, 50);
  camera.updateProjectionMatrix();
}

function setEmptyVisible(show) {
  emptyEl.classList.toggle("hidden", !show);
}

function styleWorld(root) {
  root.traverse((node) => {
    if (node.isPoints) {
      const hasColors = Boolean(node.geometry?.attributes?.color);
      node.material = new THREE.PointsMaterial({
        size: 3,
        sizeAttenuation: false,
        vertexColors: hasColors,
        color: 0xffffff,
      });
      node.frustumCulled = false;
      return;
    }
    if (node.isMesh && node.material && node.geometry?.attributes?.color) {
      node.material.vertexColors = true;
    }
  });
}

function clearGroup(group) {
  while (group.children.length) {
    const child = group.children.pop();
    child.traverse((node) => {
      if (node.geometry) node.geometry.dispose();
      if (node.material) {
        const materials = Array.isArray(node.material) ? node.material : [node.material];
        materials.forEach((material) => material.dispose());
      }
    });
  }
}

function loadModel(url) {
  if (!url) return;
  if (url === lastModelUrl && (worldGroup.children.length || modelLoading)) {
    if (worldGroup.children.length) setEmptyVisible(false);
    return;
  }
  lastModelUrl = url;
  modelLoading = true;
  loader.load(
    url,
    (gltf) => {
      modelLoading = false;
      clearGroup(worldGroup);
      styleWorld(gltf.scene);
      worldGroup.add(gltf.scene);
      if (lastWorld) drawCameras(lastWorld.sources);
      fitScene();
      setEmptyVisible(false);
      if (lastWorld?.message) statusEl.textContent = lastWorld.message;
    },
    undefined,
    (error) => {
      modelLoading = false;
      lastModelUrl = null;
      const detail = error?.message || String(error);
      statusEl.textContent = `Twin is ready, but the 3D view could not load: ${detail}`;
    }
  );
}

function frustumScale() {
  if (!worldGroup.children.length) return 1;
  const span = sceneBox().getSize(new THREE.Vector3()).length();
  return Math.min(Math.max(span / 70, 1), 16);
}

function makeFrustum(color) {
  const group = new THREE.Group();
  const scale = frustumScale();
  const body = new THREE.Mesh(
    new THREE.ConeGeometry(0.07, 0.16, 5),
    new THREE.MeshStandardMaterial({ color, roughness: 0.45, metalness: 0.1 })
  );
  body.rotation.x = Math.PI / 2;
  body.position.z = 0.08;
  const core = new THREE.Mesh(
    new THREE.SphereGeometry(0.035, 12, 12),
    new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.25 })
  );
  group.add(body, core);
  group.scale.setScalar(scale);
  return group;
}

function drawCameras(sources) {
  clearGroup(cameraGroup);
  if (!showCameras.checked) return;
  sources.forEach((source, index) => {
    const color = palette[index % palette.length];
    const cameras = source.cameras?.length
      ? source.cameras
      : source.position
        ? [{ position: source.position, forward: source.forward || [0, 0, 1] }]
        : [];
    cameras.forEach((cam) => {
      const marker = makeFrustum(selectedSourceId === source.id ? 0xffffff : color);
      const position = worldToView(cam.position);
      const forward = worldToView(cam.forward || [0, 0, 1]).normalize();
      marker.position.copy(position);
      const aim = position.clone().add(forward);
      marker.lookAt(aim);
      marker.userData.sourceId = source.id;
      cameraGroup.add(marker);
    });
  });
}

function formatStatus(source) {
  if (source.status === "localized" && source.position) {
    const [x, y, z] = source.position;
    return `Localized ${x.toFixed(2)}, ${y.toFixed(2)}, ${z.toFixed(2)}`;
  }
  if (source.status === "failed") return source.error || "Failed";
  if (source.status === "processing") return "Estimating pose";
  return "Queued";
}

function renderSources(world) {
  const signature = JSON.stringify(world.sources);
  sourceCount.textContent = String(world.sources.length);
  document.querySelector("#stat-videos").textContent = world.stats.videos;
  document.querySelector("#stat-photos").textContent = world.stats.photos;
  document.querySelector("#stat-localized").textContent = world.stats.localized;
  document.querySelector("#stat-updates").textContent = world.updates;
  if (signature === lastSourceSignature) return;
  lastSourceSignature = signature;
  sourcesEl.innerHTML = "";
  if (!world.sources.length) {
    sourcesEl.innerHTML = `<li class="source empty-source"><div class="ph">--</div><div><h4>No sources yet</h4><div class="meta">Upload a clip or still from any room.</div></div></li>`;
    return;
  }
  for (const source of world.sources) {
    const item = document.createElement("li");
    item.className = `source${selectedSourceId === source.id ? " active" : ""}`;
    item.innerHTML = `
      ${source.thumbnail_url ? `<img src="${source.thumbnail_url}" alt="" />` : `<div class="ph">${source.kind}</div>`}
      <div>
        <h4 title="${source.filename}">${source.filename}</h4>
        <div class="meta">
          <span class="badge ${source.kind}">${source.kind}</span>
          <span class="status ${source.status}">${formatStatus(source)}</span>
          ${source.view_count ? `<span>${source.view_count} views</span>` : ""}
        </div>
      </div>
    `;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "source-delete";
    remove.title = "Remove this viewpoint";
    remove.setAttribute("aria-label", `Remove ${source.filename}`);
    remove.textContent = "Remove";
    remove.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const label = source.filename || "this viewpoint";
      if (!window.confirm(`Remove "${label}" from this world? The twin will rebuild from remaining viewpoints.`)) {
        return;
      }
      deleteSource(source.id);
    });
    item.appendChild(remove);
    item.addEventListener("click", () => {
      selectedSourceId = source.id;
      lastSourceSignature = "";
      renderSources(world);
      drawCameras(world.sources);
      if (source.position) {
        const target = worldToView(source.position);
        const span = Math.max(sceneBox().getSize(new THREE.Vector3()).length(), 2);
        controls.target.copy(target);
        camera.position.copy(target).add(new THREE.Vector3(span * 0.08, span * 0.06, span * 0.08));
      }
    });
    sourcesEl.appendChild(item);
  }
}

function applyWorld(world, options = {}) {
  lastWorld = world;
  worldId = world.id;
  localStorage.setItem(STORAGE_KEY, worldId);
  worldIdEl.textContent = worldId;
  if (!modelLoading) {
    statusEl.textContent = world.message || "Ready.";
  }
  if (world.settings && (options.hydrateSettings || !settingsHydrated)) {
    hydrateSettingsFromWorld(world);
    settingsHydrated = true;
    settingsDirty = false;
  }
  const runtime = world.runtime || {};
  flipCameras = Boolean(runtime.cuda) && !runtime.mock;
  if (runtime.mock) {
    runtimePill.textContent = "Preview mode";
    runtimePill.className = "pill mock";
  } else if (runtime.cuda) {
    runtimePill.textContent = "GPU ready";
    runtimePill.className = "pill gpu";
  } else {
    runtimePill.textContent = "No GPU";
    runtimePill.className = "pill cpu";
  }
  renderSources(world);
  drawCameras(world.sources);
  const hasContent = Boolean(
    world.has_model || world.stats?.localized || worldGroup.children.length || cameraGroup.children.length
  );
  if (world.has_model && world.model_url) {
    downloadEl.href = world.download_url || world.model_url;
    downloadEl.classList.remove("hidden");
    setEmptyVisible(false);
    if (!modelLoading && !worldGroup.children.length) {
      statusEl.textContent = world.message
        ? `${world.message} Loading the 3D twin.`
        : "Loading the 3D twin.";
    }
    loadModel(world.model_url);
  } else {
    downloadEl.classList.add("hidden");
    setEmptyVisible(!hasContent);
    if (lastModelUrl || worldGroup.children.length) {
      lastModelUrl = null;
      modelLoading = false;
      clearGroup(worldGroup);
    }
  }
}

async function deleteSource(sourceId) {
  if (!worldId) return;
  statusEl.textContent = "Removing viewpoint.";
  try {
    const world = await api(`/api/worlds/${worldId}/sources/${sourceId}`, { method: "DELETE" });
    lastSourceSignature = "";
    if (selectedSourceId === sourceId) selectedSourceId = null;
    if (!world.has_model) {
      lastModelUrl = null;
      modelLoading = false;
      clearGroup(worldGroup);
    }
    applyWorld(world);
    schedulePoll(world);
  } catch (error) {
    statusEl.textContent = error.message;
  }
}

async function api(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try {
      const payload = await response.json();
      detail = payload.detail || detail;
    } catch {
      try { detail = await response.text(); } catch { /* keep status */ }
    }
    throw new Error(detail);
  }
  return response.json();
}

async function ensureWorld() {
  if (worldId) {
    try {
      const world = await api(`/api/worlds/${worldId}`);
      applyWorld(world);
      return world;
    } catch {
      localStorage.removeItem(STORAGE_KEY);
      worldId = null;
    }
  }
  const world = await api("/api/worlds", { method: "POST", body: fillForm(settings()) });
  applyWorld(world);
  return world;
}

async function refresh() {
  if (!worldId) return null;
  try {
    const world = await api(`/api/worlds/${worldId}`);
    applyWorld(world);
    return world;
  } catch (error) {
    statusEl.textContent = error.message;
    return null;
  }
}

function schedulePoll(world) {
  clearTimeout(pollTimer);
  const busy = Boolean(
    world && (world.status === "processing" || world.stats?.queued || world.stats?.processing)
  );
  pollTimer = setTimeout(async () => {
    schedulePoll(await refresh());
  }, busy ? 1500 : 4000);
}

async function upload(fileList) {
  const files = [...fileList];
  if (!files.length) return;
  if (!worldId) await ensureWorld();
  statusEl.textContent = `Uploading ${files.length} source(s). The model will assign each location.`;
  const body = fillForm(settings());
  files.forEach((file) => body.append("files", file));
  try {
    const world = await api(`/api/worlds/${worldId}/sources`, { method: "POST", body });
    applyWorld(world);
    schedulePoll(world);
  } catch (error) {
    statusEl.textContent = error.message;
  }
}

function wireUploads() {
  browse.addEventListener("click", () => fileInput.click());
  fileInput.addEventListener("change", () => {
    upload(fileInput.files);
    fileInput.value = "";
  });
  ["dragenter", "dragover"].forEach((eventName) => {
    drop.addEventListener(eventName, (event) => {
      event.preventDefault();
      drop.classList.add("over");
    });
  });
  ["dragleave", "drop"].forEach((eventName) => {
    drop.addEventListener(eventName, (event) => {
      event.preventDefault();
      drop.classList.remove("over");
    });
  });
  drop.addEventListener("drop", (event) => upload(event.dataTransfer.files));
}

document.querySelector("#new-world").addEventListener("click", async () => {
  localStorage.removeItem(STORAGE_KEY);
  worldId = null;
  lastModelUrl = null;
  lastSourceSignature = "";
  selectedSourceId = null;
  lastWorld = null;
  modelLoading = false;
  settingsHydrated = false;
  settingsDirty = false;
  clearGroup(worldGroup);
  clearGroup(cameraGroup);
  setEmptyVisible(true);
  applyWorld(
    await api("/api/worlds", { method: "POST", body: fillForm(settings()) }),
    { hydrateSettings: true }
  );
});

document.querySelector("#fit").addEventListener("click", fitScene);
showCameras.addEventListener("change", () => refresh());

async function persistSettings() {
  if (!worldId) return;
  const seq = ++persistSeq;
  settingsDirty = true;
  try {
    const world = await api(`/api/worlds/${worldId}`, {
      method: "PATCH",
      body: fillForm(settings()),
    });
    if (seq !== persistSeq) return;
    applyWorld(world);
    settingsDirty = false;
  } catch (error) {
    statusEl.textContent = error.message;
  }
}

async function rebuildWithSettings() {
  if (!worldId) await ensureWorld();
  await persistSettings();
  statusEl.textContent = "Rebuilding with current settings.";
  try {
    const world = await api(`/api/worlds/${worldId}/rebuild`, { method: "POST" });
    lastSourceSignature = "";
    lastModelUrl = null;
    modelLoading = false;
    clearGroup(worldGroup);
    applyWorld(world);
    schedulePoll(world);
  } catch (error) {
    statusEl.textContent = error.message;
  }
}

Object.values(fields).forEach((field) => {
  if (!field) return;
  field.addEventListener("input", () => {
    settingsDirty = true;
  });
  field.addEventListener("change", persistSettings);
});

const rebuildButton = document.querySelector("#rebuild-settings");
if (rebuildButton) {
  rebuildButton.addEventListener("click", rebuildWithSettings);
}

bindSliders();
wireUploads();
animate();
ensureWorld().then(schedulePoll).catch((error) => {
  statusEl.textContent = error.message;
});
