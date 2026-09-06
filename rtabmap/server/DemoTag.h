#ifndef COLLAB_DEMO_TAG_H
#define COLLAB_DEMO_TAG_H

#include <sstream>
#include <string>

namespace collab {

// Shared start-tag constants. Keep in sync with iOS DemoTag in TagCalibrator.swift.
// Family is OpenCV ArUco DICT_4X4_50. Same tag id for every phone.
const int kDemoTagId = 0;
const float kDemoTagSizeM = 0.20f;
const char * const kDemoTagFamily = "4x4_50";

// POST /calibrate body is T_arkitWorld_from_tag (tx,ty,tz + qx,qy,qz,qw):
// the tag pose in the client's ARKit world frame. On the phone, rtabmap's
// MarkerDetector returns T_base_from_tag (camera base_link: x forward, y left,
// z up); TagCalibrator composes ARKit camera * T_arkitCam_from_base * that.
// The server converts to the shared frame G (tag frame in rtabmap convention,
// z up) and stores T_G_from_clientRtabmapWorld, which it applies to that
// client's node poses. GET /pull sends the inverse, T_clientWorld_from_G, as
// X-Client-To-Global so the phone can place other users' G-frame nodes in
// its own rtabmap world.

// OpenCV-generated DICT_4X4_50 id 0 PNG (quiet zone included). Served at /tag.png.
std::string demoTagPng();

inline std::string demoTagSvg(int pixelSize = 720)
{
	// Verified against OpenCV 5 generateImageMarker(DICT_4X4_50, id=0, 6, borderBits=1).
	// 6x6 including the black border. 1 is white. Prefer demoTagPng() on the admin page.
	static const unsigned char kBits[6][6] = {
		{0, 0, 0, 0, 0, 0},
		{0, 1, 0, 1, 1, 0},
		{0, 0, 1, 0, 1, 0},
		{0, 0, 0, 1, 1, 0},
		{0, 0, 0, 1, 0, 0},
		{0, 0, 0, 0, 0, 0}
	};
	const int n = 6;
	const int quiet = 2;
	const int cells = n + quiet * 2;
	std::ostringstream oss;
	oss << "<svg id=\"calib-tag-svg\" xmlns=\"http://www.w3.org/2000/svg\" "
		<< "viewBox=\"0 0 " << cells << " " << cells << "\" "
		<< "width=\"" << pixelSize << "\" height=\"" << pixelSize << "\" "
		<< "shape-rendering=\"crispEdges\" role=\"img\" "
		<< "aria-label=\"ArUco 4x4 start tag id " << kDemoTagId << "\">";
	oss << "<rect width=\"" << cells << "\" height=\"" << cells << "\" fill=\"#ffffff\"/>";
	for(int r = 0; r < n; ++r)
	{
		for(int c = 0; c < n; ++c)
		{
			if(kBits[r][c] == 0)
			{
				oss << "<rect x=\"" << (c + quiet) << "\" y=\"" << (r + quiet)
					<< "\" width=\"1\" height=\"1\" fill=\"#000000\"/>";
			}
		}
	}
	oss << "</svg>";
	return oss.str();
}

inline std::string adminPageHtml()
{
	std::ostringstream oss;
	oss << R"HTML(<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CMCS</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@500;600;700&family=IBM+Plex+Mono:wght@400;500&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root{
  --ink:#05070A;
  --ink-2:#0A0D11;
  --panel:#101318;
  --panel-2:#161A1F;
  --line:rgba(243,245,244,.14);
  --line-2:rgba(243,245,244,.08);
  --text:#F3F5F4;
  --muted:rgba(243,245,244,.58);
  --dim:rgba(243,245,244,.34);
  --orange:#E3942A;
  --orange-2:#C96A1A;
  --go:#47FF51;
  --go-dim:rgba(71,255,81,.16);
  --forest:#6B8A5A;
  --bad:#E06B5C;
  --cta:#F3F5F4;
}
*{box-sizing:border-box;}
html,body{margin:0;height:100%;background:var(--ink);color:var(--text);
  font-family:Inter, "Segoe UI", sans-serif; letter-spacing:.01em;}
body{display:flex;flex-direction:column;min-height:100%;background:
  radial-gradient(1200px 700px at 70% -10%, rgba(227,148,42,.08), transparent 55%),
  radial-gradient(900px 500px at -10% 110%, rgba(71,255,81,.04), transparent 50%),
  var(--ink);}
#banner{display:none;}
#top{
  flex:0 0 58px;display:flex;align-items:center;justify-content:space-between;
  padding:0 22px;border-bottom:1px solid var(--line);background:rgba(5,7,10,.86);
  backdrop-filter:blur(10px);z-index:3;
}
.brand{display:flex;align-items:center;gap:14px;min-width:0;}
.mark{width:28px;height:28px;flex:0 0 28px;}
.brand-copy{display:flex;flex-direction:column;gap:2px;min-width:0;}
.brand-kicker{font:600 10px/1 Barlow Condensed, sans-serif;letter-spacing:.22em;
  text-transform:uppercase;color:var(--forest);}
.brand-name{font:700 22px/.9 Barlow Condensed, sans-serif;letter-spacing:.08em;}
.phases{display:flex;align-items:stretch;gap:0;height:58px;}
.phase{display:flex;align-items:center;gap:10px;padding:0 18px;position:relative;
  color:var(--dim);border-left:1px solid var(--line-2);}
.phase:first-child{border-left:0;}
.phase span{font:600 11px/1 Barlow Condensed, sans-serif;letter-spacing:.16em;text-transform:uppercase;}
.phase.on{color:var(--text);}
.phase.on:after{content:"";position:absolute;left:18px;right:18px;bottom:0;height:2px;background:var(--orange);}
.meta{display:flex;align-items:center;gap:16px;font:400 11px/1 "IBM Plex Mono", ui-monospace, monospace;color:var(--muted);}
.link{display:flex;align-items:center;gap:8px;}
.pulse{width:7px;height:7px;border-radius:50%;background:var(--bad);box-shadow:0 0 0 0 rgba(224,107,92,.4);}
.link.ok .pulse{background:var(--go);box-shadow:0 0 0 4px var(--go-dim);animation:pulse 1.8s ease-out infinite;}
@keyframes pulse{0%{box-shadow:0 0 0 0 var(--go-dim);}70%{box-shadow:0 0 0 8px transparent;}100%{box-shadow:0 0 0 0 transparent;}}
#shell{flex:1 1 auto;min-height:0;display:grid;grid-template-columns:280px minmax(0,1fr);gap:0;}
#side{min-height:0;display:flex;flex-direction:column;background:var(--panel);border-right:1px solid var(--line);overflow:auto;}
.side-head{padding:18px 18px 10px;display:flex;align-items:baseline;justify-content:space-between;}
.side-head h2{margin:0;font:600 12px/1 Barlow Condensed, sans-serif;letter-spacing:.2em;text-transform:uppercase;color:var(--muted);}
.side-head em{font:400 11px/1 "IBM Plex Mono", ui-monospace, monospace;color:var(--dim);font-style:normal;}
#dots{display:flex;flex-direction:column;gap:8px;margin:0;padding:0 14px 14px;}
.dot{display:flex;align-items:flex-start;gap:10px;padding:12px 12px 13px;border:1px solid var(--line);
  background:var(--ink-2);position:relative;overflow:hidden;}
.lamp{width:8px;height:8px;margin-top:5px;flex:0 0 8px;border-radius:50%;background:#2a2f34;}
.lamp.on{background:var(--go);box-shadow:0 0 0 4px var(--go-dim);}
.dot-meta{min-width:0;flex:1;position:relative;z-index:1;}
.dot-id{font:600 13px/1.15 Inter, sans-serif;}
.dot-state{margin-top:4px;font:500 11px/1 "IBM Plex Mono", ui-monospace, monospace;color:var(--orange);letter-spacing:.08em;}
.dot.on .dot-state{color:var(--go);}
.dot-pose{margin-top:8px;font:400 11px/1.45 "IBM Plex Mono", ui-monospace, monospace;color:var(--muted);white-space:pre;}
.side-actions{margin-top:auto;padding:14px;display:flex;flex-direction:column;gap:8px;border-top:1px solid var(--line);}
.btn{appearance:none;height:36px;border:1px solid var(--line);background:transparent;
  color:var(--text);font:600 12px/1 Barlow Condensed, sans-serif;letter-spacing:.16em;
  text-transform:uppercase;cursor:pointer;text-decoration:none;display:flex;align-items:center;justify-content:center;gap:8px;}
.btn:hover{border-color:var(--orange);color:#fff;}
.btn:disabled{opacity:.4;cursor:wait;border-color:var(--line);}
.btn.solid{background:var(--cta);color:var(--ink);border-color:var(--cta);}
.btn.solid:hover{background:#fff;border-color:#fff;}
.btn.ghost-bad:hover{border-color:var(--bad);color:var(--bad);}
.viewport{min-height:0;display:flex;flex-direction:column;background:#05070A;position:relative;}
.view-stage{flex:1;min-height:0;position:relative;display:flex;}
#calib-tag{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:36px 28px 48px;gap:22px;}
.tag-kicker{font:600 11px/1 Barlow Condensed, sans-serif;letter-spacing:.22em;text-transform:uppercase;color:var(--forest);}
.tag-title{margin:0;font:700 42px/.9 Barlow Condensed, sans-serif;letter-spacing:.02em;text-align:center;}
.tag-copy{margin:0;max-width:420px;text-align:center;color:var(--muted);font:400 14px/1.45 Inter, sans-serif;}
.reticle{position:relative;padding:22px;background:#fff;}
.reticle img{display:block;width:min(42vh,42vw,420px);height:min(42vh,42vw,420px);
  background:#fff;image-rendering:pixelated;image-rendering:crisp-edges;}
.tag-spec{font:400 11px/1 "IBM Plex Mono", ui-monospace, monospace;color:var(--dim);letter-spacing:.06em;}
#live{display:none;flex:1;min-height:0;width:100%;height:100%;}
#live.show{display:flex;}
#map-wrap{position:relative;flex:1;width:100%;height:100%;background:#05070A;border:0;}
#map{width:100%;height:100%;display:block;}
#map-msg{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;pointer-events:none;
  font:600 13px/1 Barlow Condensed, sans-serif;letter-spacing:.18em;text-transform:uppercase;color:var(--muted);}
#map-msg.hidden{display:none;}
.view-tools{position:absolute;left:16px;bottom:16px;display:flex;gap:8px;z-index:2;}
.chip{appearance:none;height:28px;padding:0 12px;border:1px solid var(--line);background:rgba(5,7,10,.72);
  color:var(--text);font:600 11px/1 Barlow Condensed, sans-serif;letter-spacing:.14em;text-transform:uppercase;cursor:pointer;}
.chip:hover,.chip.on{border-color:var(--orange);color:#fff;}
.live-stats{position:absolute;top:14px;right:16px;display:flex;gap:8px;z-index:2;pointer-events:none;}
.stat{min-width:72px;padding:8px 10px;border:1px solid var(--line);background:rgba(5,7,10,.72);}
.stat b{display:block;font:500 10px/1 Barlow Condensed, sans-serif;letter-spacing:.16em;text-transform:uppercase;color:var(--dim);}
.stat em{display:block;margin-top:5px;font:600 14px/1 "IBM Plex Mono", ui-monospace, monospace;font-style:normal;color:var(--text);}
#foot{
  flex:0 0 30px;display:flex;align-items:center;padding:0 16px;
  border-top:1px solid var(--line);background:var(--ink-2);
  font:400 11px/1 "IBM Plex Mono", ui-monospace, monospace;color:var(--muted);
}
#footer{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
#confirm{display:none;position:fixed;inset:0;background:rgba(5,7,10,.72);z-index:20;
  align-items:center;justify-content:center;padding:24px;}
#confirm.open{display:flex;}
.sheet{width:min(420px,100%);background:var(--panel);border:1px solid var(--line);padding:28px 26px 22px;
  box-shadow:0 24px 80px rgba(0,0,0,.45);}
.sheet:before{content:"";display:block;height:2px;background:var(--orange);margin:-28px -26px 20px;}
.sheet h3{margin:0 0 8px;font:700 28px/.9 Barlow Condensed, sans-serif;letter-spacing:.04em;}
.sheet p{margin:0 0 22px;color:var(--muted);font:400 14px/1.45 Inter, sans-serif;}
.sheet-row{display:flex;gap:8px;}
.sheet-row .btn{flex:1;}
@media (max-width:900px){
  .phases{display:none;}
  #shell{grid-template-columns:1fr;}
  #side{max-height:34vh;border-right:0;border-bottom:1px solid var(--line);}
  .tag-title{font-size:32px;}
}
</style>
<script type="importmap">
{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.160.1/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.1/examples/jsm/"}}
</script>
</head>
<body>
<div id="banner"></div>
<header id="top">
  <div class="brand">
    <svg class="mark" viewBox="0 0 28 28" aria-hidden="true">
      <path d="M3 8 L14 3 L25 8 L25 20 L14 25 L3 20 Z" fill="none" stroke="#E3942A" stroke-width="1.4"/>
      <path d="M8 14 L14 8 L20 14" fill="none" stroke="#F3F5F4" stroke-width="1.4"/>
      <path d="M8 18 L14 12 L20 18" fill="none" stroke="#E3942A" stroke-width="1.4"/>
    </svg>
    <div class="brand-copy">
      <div class="brand-kicker">Collaborative mapping</div>
      <div class="brand-name">CMCS</div>
    </div>
  </div>
  <nav class="phases" id="phases" aria-label="Mission phases">
    <div class="phase on" data-i="0"><span>Acquire</span></div>
    <div class="phase" data-i="1"><span>Lock</span></div>
    <div class="phase" data-i="2"><span>Map</span></div>
    <div class="phase" data-i="3"><span>Operate</span></div>
  </nav>
  <div class="meta">
    <div class="link" id="link"><i class="pulse"></i><span id="link-txt">DISCONNECTED</span></div>
    <div id="clock">00:00:00</div>
  </div>
</header>
<div id="shell">
  <aside id="side">
    <div class="side-head"><h2>Soldiers</h2><em id="sta-count">0 / 2</em></div>
    <div id="dots"></div>
    <div class="side-actions">
      <button type="button" class="btn" id="opt-btn">Optimize</button>
      <a class="btn" id="dl-db" href="/map.db">Map.db</a>
      <a class="btn" id="dl-ply" href="/map.ply">Map.ply</a>
      <button type="button" class="btn ghost-bad" id="reset-btn">Reset</button>
    </div>
  </aside>
  <section class="viewport">
    <div class="view-stage">
      <div id="calib-tag">
        <div class="tag-kicker">Start mark</div>
        <h1 class="tag-title">Point both phones here.</h1>
        <p class="tag-copy">Lock the shared frame, then walk the room. The live mesh appears the moment the second soldier locks.</p>
        <div class="reticle">
          <img id="calib-tag-img" src="/tag.png" alt="ArUco 4x4 start tag id 0"/>
        </div>
        <div class="tag-spec">ArUco 4x4_50  ·  id 0  ·  0.20 m</div>
      </div>
      <div id="live">
        <div id="map-wrap">
          <canvas id="map"></canvas>
          <div id="map-msg">Awaiting keyframes</div>
          <div class="live-stats">
            <div class="stat"><b>Nodes</b><em id="stat-nodes">0</em></div>
            <div class="stat"><b>Mesh</b><em id="stat-mesh">0</em></div>
            <div class="stat"><b>Align</b><em id="stat-align">NO</em></div>
          </div>
          <div class="view-tools">
            <button type="button" class="chip" id="fit-btn">Fit</button>
            <button type="button" class="chip on" id="grid-btn">Grid</button>
          </div>
        </div>
      </div>
    </div>
  </section>
</div>
<div id="foot">
  <div id="footer">Assumed on-screen tag width: 0.20 m (ArUco )HTML"
		<< kDemoTagFamily << " id " << kDemoTagId << R"HTML(). Fullscreen the browser so the tag is large enough for both phones.</div>
</div>
<div id="confirm">
  <div class="sheet" role="dialog" aria-labelledby="confirm-title">
    <h3 id="confirm-title">Reset the room?</h3>
    <p>Clears the session lock and calibration. The stored map stays on disk.</p>
    <div class="sheet-row">
      <button type="button" class="btn" id="confirm-no">Cancel</button>
      <button type="button" class="btn solid" id="confirm-go">Reset &gt;&gt;</button>
    </div>
  </div>
</div>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
const TAG_SIZE_M = )HTML" << kDemoTagSizeM << R"HTML(;
const COLORS = ['#E3942A', '#47FF51', '#F3F5F4', '#C96A1A'];
function shouldShowTag(demo) {
  return demo.show_tag === true && demo.locked !== true;
}
function hideTag() {
  const tag = document.getElementById('calib-tag');
  if (tag) tag.style.display = 'none';
}
function hideLive() {
  const live = document.getElementById('live');
  if (live) { live.style.display = 'none'; live.classList.remove('show'); }
}
function shortId(id) {
  if (!id) return 'STA';
  return id.length > 10 ? id.slice(0, 8) : id;
}
function pad2(n) { return n < 10 ? '0' + n : '' + n; }
function esc(s) {
  return String(s).replace(/[&<>"'`]/g, function(c) {
    return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;','`':'&#96;'}[c]);
  });
}
function findClient(demo, id) {
  const list = demo.clients || [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i];
  }
  return null;
}
function clientNodes(id) {
  const list = (lastStatus && lastStatus.clients) || [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i].nodes;
  }
  return null;
}
function fmtPose(c) {
  if (!c || typeof c.x !== 'number') return 'NO FIX';
  function n(v) { return (v >= 0 ? '+' : '') + v.toFixed(2); }
  return 'E ' + n(c.x) + '\nN ' + n(c.y) + '\nU ' + n(c.z);
}
function phaseIndex(demo) {
  if (demo.locked && demo.aligned) return 3;
  if (demo.locked) return 2;
  if ((demo.calibrated_count || 0) >= 1) return 1;
  return 0;
}
function setPhases(demo) {
  const i = phaseIndex(demo);
  document.querySelectorAll('.phase').forEach(function(el) {
    el.classList.toggle('on', Number(el.getAttribute('data-i')) === i);
  });
}
function setStats(demo) {
  const nodes = document.getElementById('stat-nodes');
  const mesh = document.getElementById('stat-mesh');
  const align = document.getElementById('stat-align');
  if (nodes) nodes.textContent = String(demo.global_nodes || 0);
  if (mesh) mesh.textContent = String(demo.mesh_gen || 0);
  if (align) align.textContent = demo.aligned ? 'YES' : 'NO';
  const count = document.getElementById('sta-count');
  if (count) count.textContent = (demo.calibrated_count || 0) + ' / 2';
}
function setLink(ok) {
  const el = document.getElementById('link');
  const txt = document.getElementById('link-txt');
  if (!el || !txt) return;
  el.classList.toggle('ok', !!ok);
  txt.textContent = ok ? 'LIVE' : 'DISCONNECTED';
}
const sessionStart = Date.now();
function tickClock() {
  const el = document.getElementById('clock');
  if (!el) return;
  const s = Math.max(0, Math.floor((Date.now() - sessionStart) / 1000));
  el.textContent = pad2(Math.floor(s / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
}
function renderDots(demo) {
  const dots = document.getElementById('dots');
  if (!dots) return;
  const items = (demo.calibrated || []).slice();
  while (items.length < 2) items.push({id: 'waiting', locked: false});
  dots.innerHTML = items.slice(0, 4).map(function(c, i) {
    const on = c.locked ? ' on' : '';
    const waiting = c.id === 'waiting';
    const label = waiting ? ('SOL-' + pad2(i + 1)) : shortId(c.id);
    const state = c.locked ? 'LOCKED' : 'STBY';
    const cl = waiting ? null : findClient(demo, c.id);
    let pose = waiting ? 'NO FIX' : fmtPose(cl);
    const n = waiting ? null : clientNodes(c.id);
    if (n != null) pose += '\nKF ' + n;
    return '<div class="dot' + on + '"><span class="lamp' + on + '"></span><div class="dot-meta"><div class="dot-id">' + esc(label) + '</div><div class="dot-state">' + state + '</div><div class="dot-pose">' + esc(pose) + '</div></div></div>';
  }).join('');
}
function setBanner(demo, live) {
  renderDots(demo);
  setPhases(demo);
  setStats(demo);
}
function showCalib(demo) {
  const tag = document.getElementById('calib-tag');
  if (tag) tag.style.display = 'flex';
  hideLive();
  setBanner(demo, false);
  document.getElementById('footer').textContent =
    'Assumed on-screen tag width: ' + TAG_SIZE_M.toFixed(2) +
    ' m. Fullscreen the browser so the tag is large enough for both phones.';
}
function setMapMsg(text) {
  const msg = document.getElementById('map-msg');
  if (!msg) return;
  if (!text) { msg.textContent = ''; msg.classList.add('hidden'); return; }
  msg.textContent = text;
  msg.classList.remove('hidden');
}
let renderer = null, scene = null, camera = null, controls = null;
// Everything the server sends (mesh vertices, phone poses, trails) is in the
// shared frame G: rtabmap convention, x forward, y left, z up, origin at the
// start tag. three.js is y-up, so all G content lives under this group, whose
// fixed rotation maps G axes onto three axes (G.x -> -Z, G.y -> -X, G.z -> +Y).
// No guessing of the up axis from mesh extents.
let world = null, grid = null;
let liveMesh = null, meshReady = false, meshFramed = false;
let lastMeshNodes = -1, lastMeshGen = -1, meshLoading = false, lastMeshAt = 0;
let lastStatus = null, gridOn = true;
const userGroups = {};
function hexColor(hex) { return new THREE.Color(hex); }
function gToThree(v) {
  // Same mapping as the world group, for camera framing in scene coordinates.
  return new THREE.Vector3(-v.y, v.z, -v.x);
}
function disposeLiveMesh() {
  if (!liveMesh) return;
  world.remove(liveMesh);
  if (liveMesh.geometry) liveMesh.geometry.dispose();
  if (liveMesh.material) liveMesh.material.dispose();
  liveMesh = null;
}
function fitCameraToMesh(geom) {
  if (!geom) return;
  geom.computeBoundingBox();
  const box = geom.boundingBox;
  if (!box) return;
  const size = new THREE.Vector3();
  const centerG = new THREE.Vector3();
  box.getSize(size);
  box.getCenter(centerG);
  if (!isFinite(size.lengthSq()) || size.lengthSq() < 1e-8) return;
  // Frame from an elevated three-quarter view. Robust to outlier nodes: use
  // the bulk extent (clamped) rather than the full AABB diagonal.
  const extent = Math.min(Math.max(size.length() * 0.55, 1.5), 12);
  const center = gToThree(centerG);
  camera.position.set(center.x + extent * 0.7, center.y + extent * 0.6, center.z + extent * 0.7);
  controls.target.copy(center);
  controls.update();
  // Ground grid at the lowest mesh height (G z-min maps to three y).
  if (grid) grid.position.y = box.min.z;
  meshFramed = true;
}
function refit() {
  if (liveMesh && liveMesh.geometry) {
    meshFramed = false;
    fitCameraToMesh(liveMesh.geometry);
  }
}
function toggleGrid() {
  gridOn = !gridOn;
  if (grid) grid.visible = gridOn;
  const btn = document.getElementById('grid-btn');
  if (btn) btn.classList.toggle('on', gridOn);
}
function copyArrayBuffer(buf) {
  return buf.slice(0);
}
function headerInt(r, name) {
  const v = r.headers.get(name);
  if (v == null || v === '') return NaN;
  const n = parseInt(v, 10);
  return isFinite(n) ? n : NaN;
}
function fetchMeshBuffer(url) {
  return fetch(url, {cache: 'no-store'}).then(function(r) {
    if (r.status === 404) {
      console.info('mesh 404', url);
      return null;
    }
    if (!r.ok) {
      console.warn('mesh http', url, r.status);
      throw new Error('mesh http ' + r.status);
    }
    const verts = headerInt(r, 'X-Vertex-Count');
    const faces = headerInt(r, 'X-Face-Count');
    const kind = r.headers.get('X-Mesh-Kind') || '';
    if (verts === 0 || faces === 0) {
      console.info('mesh empty', url, 'kind=' + kind, 'verts=' + verts, 'faces=' + faces);
      return r.arrayBuffer().then(function() { return null; });
    }
    return r.arrayBuffer().then(function(buf) {
      if (!buf || buf.byteLength < 20) {
        console.info('mesh tiny body', url, buf && buf.byteLength);
        return null;
      }
      console.info('mesh fetched', url, 'kind=' + kind, 'bytes=' + buf.byteLength, 'verts=' + verts, 'faces=' + faces);
      return buf;
    });
  });
}
function applyMeshBuffer(buf) {
  if (!buf || buf.byteLength < 20) {
    if (!meshReady) setMapMsg('Awaiting keyframes');
    return false;
  }
  let geom = null;
  try {
    geom = new PLYLoader().parse(copyArrayBuffer(buf));
  } catch (e) {
    console.warn('PLY parse failed', e);
    if (!meshReady) setMapMsg('Awaiting keyframes');
    return false;
  }
  const pos = geom.getAttribute('position');
  const idx = geom.getIndex();
  const nPos = pos ? pos.count : 0;
  const nIdx = idx ? idx.count : 0;
  const hasColor = !!geom.getAttribute('color');
  if (nPos <= 0) {
    if (!meshReady) setMapMsg('Awaiting keyframes');
    return false;
  }
  disposeLiveMesh();
  if (nIdx >= 3) {
    geom.computeVertexNormals();
    geom.computeBoundingSphere();
    liveMesh = new THREE.Mesh(geom, new THREE.MeshStandardMaterial({
      vertexColors: hasColor,
      color: hasColor ? 0xffffff : 0x9aa3ad,
      roughness: 0.88,
      metalness: 0.02,
      side: THREE.DoubleSide
    }));
  } else {
    console.info('mesh has no faces, drawing points', nPos);
    liveMesh = new THREE.Points(geom, new THREE.PointsMaterial({
      size: 0.03, vertexColors: hasColor, color: hasColor ? 0xffffff : 0x9aa3ad
    }));
  }
  world.add(liveMesh);
  meshReady = true;
  setMapMsg('');
  if (!meshFramed) fitCameraToMesh(geom);
  return true;
}
function loadMesh(nodes, meshGen) {
  if (meshLoading) return;
  const changed = nodes !== lastMeshNodes || meshGen !== lastMeshGen;
  if (!changed && meshReady) return;
  meshLoading = true;
  fetchMeshBuffer('/map.mesh').then(function(buf) {
    lastMeshNodes = nodes;
    lastMeshGen = meshGen;
    lastMeshAt = Date.now();
    if (!buf) {
      if (!meshReady) setMapMsg('Awaiting keyframes');
      return;
    }
    applyMeshBuffer(buf);
  }).catch(function(err) {
    console.warn('mesh load failed', err);
    if (!meshReady) setMapMsg('Awaiting keyframes');
  }).then(function() { meshLoading = false; });
}
function phoneMarkerLabel(id, index) {
  const last4 = (id && id.length >= 4) ? id.slice(-4) : (id || ('P' + (index + 1)));
  return 'SOL-' + pad2(index + 1) + ' / ' + last4;
}
function hasClientQuat(c) {
  if (typeof c.qx !== 'number' || typeof c.qy !== 'number' || typeof c.qz !== 'number' || typeof c.qw !== 'number') return false;
  return (c.qx * c.qx + c.qy * c.qy + c.qz * c.qz + c.qw * c.qw) > 0.25;
}
function meshBounds() {
  if (!liveMesh || !liveMesh.geometry) return null;
  if (!liveMesh.geometry.boundingBox) liveMesh.geometry.computeBoundingBox();
  return liveMesh.geometry.boundingBox;
}
// Rotation that turns three.js camera-style geometry (looks down -Z, up +Y)
// into a rtabmap base_link body (looks down +X, up +Z). Applied inside each
// marker so the phone's G-frame quaternion can be used directly.
const BASE_FROM_GL = new THREE.Matrix4().makeBasis(
  new THREE.Vector3(0, -1, 0),
  new THREE.Vector3(0, 0, 1),
  new THREE.Vector3(-1, 0, 0));
function makeLabelSprite(text, color) {
  const canvas = document.createElement('canvas');
  canvas.width = 640;
  canvas.height = 160;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = 'rgba(5,7,10,0.88)';
  ctx.beginPath();
  ctx.rect(8, 24, 624, 112);
  ctx.fill();
  ctx.strokeStyle = color.getStyle ? color.getStyle() : '#E3942A';
  ctx.lineWidth = 3;
  ctx.stroke();
  ctx.fillStyle = '#F3F5F4';
  ctx.font = '600 56px "IBM Plex Mono", monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, 320, 80);
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  const spr = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true }));
  spr.scale.set(0.58, 0.145, 1);
  spr.renderOrder = 20;
  return spr;
}
function makeUserGroup(color, label) {
  const g = new THREE.Group();
  const bodyMat = new THREE.MeshStandardMaterial({
    color: color, roughness: 0.38, metalness: 0.08,
    emissive: color, emissiveIntensity: 0.28
  });
  const darkMat = new THREE.MeshStandardMaterial({ color: 0x1a1a1a, roughness: 0.45, metalness: 0.2 });
  // Body: built y-up, then rotated so its up is G's +Z. Hangs below the camera.
  const holder = new THREE.Group();
  holder.rotation.x = Math.PI / 2;
  const body = new THREE.Group();
  const capsule = new THREE.Mesh(new THREE.CapsuleGeometry(0.06, 0.24, 6, 10), bodyMat);
  capsule.position.y = 0.18;
  const head = new THREE.Mesh(new THREE.SphereGeometry(0.05, 12, 10), bodyMat);
  head.position.y = 0.41;
  body.add(capsule);
  body.add(head);
  body.position.y = -0.42;
  holder.add(body);
  // Camera: G-frame quaternion goes on `cam`; the inner group turns the
  // three.js-style frustum (looks down -Z) into a base_link body (looks down +X).
  const cam = new THREE.Group();
  const camInner = new THREE.Group();
  camInner.quaternion.setFromRotationMatrix(BASE_FROM_GL);
  const phone = new THREE.Mesh(new THREE.BoxGeometry(0.028, 0.056, 0.006), darkMat);
  phone.position.set(0, 0, -0.02);
  camInner.add(phone);
  const frustumGeom = new THREE.ConeGeometry(0.11, 0.34, 4, 1, true);
  frustumGeom.rotateX(-Math.PI / 2);
  frustumGeom.translate(0, 0, -0.17);
  const frustum = new THREE.Mesh(frustumGeom, new THREE.MeshBasicMaterial({
    color: color, transparent: true, opacity: 0.42, side: THREE.DoubleSide, depthWrite: false
  }));
  const frustumWire = new THREE.LineSegments(
    new THREE.EdgesGeometry(frustumGeom),
    new THREE.LineBasicMaterial({ color: 0xffffff })
  );
  camInner.add(frustum);
  camInner.add(frustumWire);
  cam.add(camInner);
  cam.add(new THREE.AxesHelper(0.16));
  const labelSpr = makeLabelSprite(label, color);
  labelSpr.position.set(0, 0, 0.20);
  const trail = new THREE.Line(
    new THREE.BufferGeometry(),
    new THREE.LineBasicMaterial({ color: color, transparent: true, opacity: 0.45, linewidth: 2 })
  );
  g.add(holder);
  g.add(cam);
  g.add(labelSpr);
  // Trail is in G world coordinates, so it is a sibling of the marker, not a child.
  world.add(trail);
  g.userData.holder = holder;
  g.userData.cam = cam;
  g.userData.trail = trail;
  g.userData.label = labelSpr;
  return g;
}
function disposeUserGroup(g) {
  world.remove(g);
  if (g.userData.trail) {
    world.remove(g.userData.trail);
    g.userData.trail.geometry.dispose();
    g.userData.trail.material.dispose();
  }
  g.traverse(function(obj) {
    if (obj.geometry) obj.geometry.dispose();
    if (obj.material) {
      const mats = Array.isArray(obj.material) ? obj.material : [obj.material];
      mats.forEach(function(m) {
        if (m.map) m.map.dispose();
        m.dispose();
      });
    }
  });
}
function updateUsers(demo) {
  if (!scene || !world) return;
  const clients = demo.clients || [];
  const seen = {};
  clients.forEach(function(c, i) {
    const id = c.id || ('phone-' + i);
    seen[id] = true;
    if (!userGroups[id]) {
      userGroups[id] = makeUserGroup(hexColor(COLORS[i % COLORS.length]), phoneMarkerLabel(id, i));
      world.add(userGroups[id]);
    }
    const g = userGroups[id];
    // Pose is the phone camera in G (z up). Marker sits at the camera.
    const x = (typeof c.x === 'number') ? c.x : 0;
    const y = (typeof c.y === 'number') ? c.y : 0;
    const z = (typeof c.z === 'number') ? c.z : 0;
    g.position.set(x, y, z);
    // Trail points are G ground-plane (x, y) samples; draw them at the camera height.
    const trail = c.trail || [];
    const pts = [];
    trail.forEach(function(p) { pts.push(new THREE.Vector3(p[0], p[1], z)); });
    if (pts.length === 0) pts.push(g.position.clone());
    g.userData.trail.geometry.dispose();
    g.userData.trail.geometry = new THREE.BufferGeometry().setFromPoints(pts);
    if (hasClientQuat(c)) {
      // Full orientation of the camera base_link in G (compass heading included).
      g.userData.cam.quaternion.set(c.qx, c.qy, c.qz, c.qw);
    } else if (typeof c.yaw === 'number' && isFinite(c.yaw)) {
      // Heading only: yaw about G's up axis (z).
      g.userData.cam.rotation.set(0, 0, c.yaw);
    } else if (pts.length >= 2) {
      const a = pts[pts.length - 2], b = pts[pts.length - 1];
      const dx = b.x - a.x, dy = b.y - a.y;
      if (dx * dx + dy * dy > 1e-6) g.userData.cam.rotation.set(0, 0, Math.atan2(dy, dx));
    }
  });
  Object.keys(userGroups).forEach(function(id) {
    if (!seen[id]) {
      disposeUserGroup(userGroups[id]);
      delete userGroups[id];
    }
  });
}
function tick() {
  requestAnimationFrame(tick);
  if (controls) controls.update();
  if (renderer && scene && camera) renderer.render(scene, camera);
}
function resizeViewer() {
  const wrap = document.getElementById('map-wrap');
  const canvas = document.getElementById('map');
  if (!wrap || !renderer || !camera) return;
  const w = Math.max(1, wrap.clientWidth);
  const h = Math.max(1, wrap.clientHeight);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h, false);
  canvas.style.width = '100%';
  canvas.style.height = '100%';
}
function initViewer() {
  if (renderer) return true;
  const canvas = document.getElementById('map');
  if (!canvas) return false;
  try {
    renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true, alpha: false });
  } catch (e) {
    setMapMsg('3D view unavailable in this browser');
    return false;
  }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(0x05070A, 1);
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(60, 1, 0.05, 200);
  camera.position.set(2.2, 1.8, 2.2);
  controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  controls.target.set(0, 0, 0);
  // G (rtabmap, z up) -> three (y up): G.x -> -Z, G.y -> -X, G.z -> +Y.
  world = new THREE.Group();
  world.matrixAutoUpdate = false;
  world.matrix.makeBasis(
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(-1, 0, 0),
    new THREE.Vector3(0, 1, 0));
  scene.add(world);
  scene.add(new THREE.AmbientLight(0xffffff, 0.32));
  scene.add(new THREE.HemisphereLight(0xf3f5f4, 0x3a2a18, 0.62));
  const key = new THREE.DirectionalLight(0xfff4e0, 0.85);
  key.position.set(2.4, 4.2, 2.8);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xe3942a, 0.18);
  fill.position.set(-2.2, 1.4, -1.6);
  scene.add(fill);
  grid = new THREE.GridHelper(12, 24, 0x2a2418, 0x16140f);
  grid.visible = gridOn;
  scene.add(grid);
  // Start tag origin, drawn as a small square in the tag plane (G y-z plane).
  const origin = new THREE.Mesh(new THREE.SphereGeometry(0.04, 12, 10), new THREE.MeshBasicMaterial({ color: 0xE3942A }));
  world.add(origin);
  const tagPlane = new THREE.Mesh(
    new THREE.PlaneGeometry(TAG_SIZE_M, TAG_SIZE_M),
    new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, transparent: true, opacity: 0.55 }));
  tagPlane.rotation.y = Math.PI / 2;
  world.add(tagPlane);
  window.addEventListener('resize', resizeViewer);
  resizeViewer();
  tick();
  return true;
}
function showLive(demo) {
  hideTag();
  const live = document.getElementById('live');
  live.style.display = 'flex';
  live.classList.add('show');
  setBanner(demo, true);
  document.getElementById('footer').textContent =
    'Live keyframe meshes (organizedFastMesh + RGB), same as the phone. Drag to orbit, scroll to zoom. Origin is the start tag.';
  if (!initViewer()) return;
  resizeViewer();
  updateUsers(demo);
  const nodes = demo.global_nodes || 0;
  const meshGen = demo.mesh_gen || 0;
  if (!meshReady) setMapMsg('Awaiting keyframes');
  loadMesh(nodes, meshGen);
}
function applyDemo(demo) {
  if (!demo || demo.ok === false) return;
  if (shouldShowTag(demo) || demo.locked !== true) showCalib(demo);
  else showLive(demo);
}
function resetRoom() {
  lastMeshNodes = -1;
  lastMeshGen = -1;
  lastMeshAt = 0;
  meshReady = false;
  meshFramed = false;
  if (scene) disposeLiveMesh();
  fetch('/reset', {method: 'POST', cache: 'no-store'}).then(function(r) { return r.json(); }).then(function() {
    return fetch('/demo', {cache: 'no-store'}).then(function(r) { return r.json(); });
  }).then(applyDemo).catch(function() {});
}
function optimizeNow() {
  const btn = document.getElementById('opt-btn');
  if (btn) btn.disabled = true;
  fetch('/optimize', {method: 'POST', cache: 'no-store'}).then(function(r) {
    return r.json();
  }).then(function() {
    lastMeshNodes = -1;
    lastMeshGen = -1;
  }).catch(function() {}).then(function() {
    if (btn) btn.disabled = false;
  });
}
function setConfirm(open) {
  const el = document.getElementById('confirm');
  if (el) el.classList.toggle('open', !!open);
}
function poll() {
  fetch('/demo', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(demo) {
    setLink(true);
    applyDemo(demo);
  }).catch(function() { setLink(false); });
}
function pollStatus() {
  fetch('/status', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(st) {
    lastStatus = st;
  }).catch(function() {});
}
document.getElementById('reset-btn').addEventListener('click', function() { setConfirm(true); });
document.getElementById('confirm-no').addEventListener('click', function() { setConfirm(false); });
document.getElementById('confirm-go').addEventListener('click', function() { setConfirm(false); resetRoom(); });
document.getElementById('confirm').addEventListener('click', function(e) {
  if (e.target === this) setConfirm(false);
});
document.getElementById('opt-btn').addEventListener('click', optimizeNow);
document.getElementById('fit-btn').addEventListener('click', refit);
document.getElementById('grid-btn').addEventListener('click', toggleGrid);
window.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') setConfirm(false);
  if (e.key === 'f' || e.key === 'F') refit();
  if (e.key === 'g' || e.key === 'G') toggleGrid();
});
tickClock();
setInterval(tickClock, 1000);
poll();
pollStatus();
setInterval(poll, 250);
setInterval(pollStatus, 2000);
</script>
</body>
</html>
)HTML";
	return oss.str();
}

}

#endif
