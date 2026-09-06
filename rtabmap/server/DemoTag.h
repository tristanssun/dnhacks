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
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
:root{
  --page:#161514;
  --panel:#1F1E1D;
  --card:#2B2A28;
  --border:#454340;
  --text-2:#A19F9B;
  --text-1:#DBDAD9;
  --sans:Inter, "Segoe UI", system-ui, sans-serif;
  --mono:"IBM Plex Mono", ui-monospace, monospace;
}
*{box-sizing:border-box;}
html,body{margin:0;height:100%;background:var(--page);color:var(--text-1);
  font-family:var(--sans);font-size:14px;font-weight:400;line-height:1.4;}
body{display:flex;flex-direction:column;min-height:100%;background:var(--page);}
#banner{display:none;}
#top{
  flex:0 0 56px;display:flex;align-items:center;justify-content:space-between;
  padding:0 22px;border-bottom:1px solid var(--border);background:var(--panel);
  backdrop-filter:blur(10px);z-index:3;
}
.brand{display:flex;align-items:center;gap:12px;min-width:0;}
.mark{width:24px;height:24px;flex:0 0 24px;}
.brand-copy{display:flex;flex-direction:column;gap:1px;min-width:0;}
.brand-kicker{font-size:12px;font-weight:400;line-height:1.2;color:var(--text-2);}
.brand-name{font-size:16px;font-weight:600;line-height:1.2;}
.phases{display:flex;align-items:stretch;gap:0;height:56px;}
.phase{display:flex;align-items:center;gap:10px;padding:0 16px;position:relative;
  color:var(--text-2);border-left:1px solid var(--border);}
.phase:first-child{border-left:0;}
.phase span{font-size:13px;font-weight:500;letter-spacing:.03em;text-transform:uppercase;}
.phase.on{color:var(--text-1);}
.phase.on:after{content:"";position:absolute;left:16px;right:16px;bottom:0;height:2px;background:var(--text-1);}
.meta{display:flex;align-items:center;gap:16px;font-size:13px;font-weight:400;color:var(--text-2);}
.link{display:flex;align-items:center;gap:8px;}
.pulse{width:7px;height:7px;border-radius:50%;background:var(--text-2);}
.link.ok .pulse{background:var(--text-1);}
#clock{font-family:var(--mono);font-size:13px;font-weight:400;color:var(--text-1);}
#shell{flex:1 1 auto;min-height:0;display:grid;grid-template-columns:300px minmax(0,1fr);gap:0;}
#side{grid-column:1;grid-row:1;min-height:0;display:flex;flex-direction:column;background:var(--panel);border-right:1px solid var(--border);overflow:hidden;}
#side-map{flex:0 0 auto;padding:10px 10px 0;position:relative;}
.tree-search{position:relative;margin:4px 10px 8px calc(8px + var(--d,1)*14px);}
#scan-search{width:100%;height:28px;border:1px solid var(--border);background:var(--card);
  color:var(--text-1);font-family:var(--sans);font-size:12px;padding:0 8px;}
#scan-search:focus{outline:none;border-color:var(--text-1);}
.scan-map-wrap{position:relative;}
#scan-map{height:168px;border:1px solid var(--border);background:var(--card);position:relative;z-index:0;isolation:isolate;}
#scan-map .leaflet-container{background:var(--card);font-family:var(--sans);}
#scan-map .leaflet-control-zoom{border:1px solid var(--border);border-radius:0;margin:6px;box-shadow:none;}
#scan-map .leaflet-control-zoom a{background:var(--card);color:var(--text-1);width:22px;height:22px;
  line-height:22px;font-size:14px;border-bottom:1px solid var(--border);}
#scan-map .leaflet-control-zoom a:hover{background:var(--panel);color:var(--text-1);}
#scan-map .leaflet-control-zoom a.leaflet-disabled{opacity:.35;color:var(--text-2);}
#scan-map .leaflet-control-attribution{font-size:9px;background:rgba(31,30,29,.72);color:var(--text-2);}
#scan-map .leaflet-control-attribution a{color:var(--text-2);}
.scan-map-empty{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  pointer-events:none;font-size:12px;font-weight:500;color:var(--text-2);}
.scan-map-empty.hide{display:none;}
.scan-pin{width:14px;height:14px;margin-left:-7px;margin-top:-7px;border-radius:50%;
  background:var(--text-1);border:2px solid var(--page);box-shadow:0 0 0 1px var(--border);}
.side-rule{flex:0 0 auto;height:1px;margin:10px 10px 0;border:0;background:#5C5A56;}
.tree{margin:0;padding:8px 0;flex:1 1 auto;min-height:0;overflow:auto;}
.tree-kids{display:none;}
.tree-node.open>.tree-kids{display:block;}
.tree-row{display:flex;align-items:center;gap:6px;height:26px;padding:0 10px 0 calc(8px + var(--d,0)*14px);
  cursor:default;user-select:none;}
.tree-row[data-toggle]{cursor:pointer;}
.tree-row:hover{background:var(--card);}
.tree-chev,.tree-ico{flex:0 0 12px;width:12px;height:12px;color:var(--text-2);display:block;}
.tree-ico{width:14px;height:14px;flex:0 0 14px;}
.tree-chev{transform:rotate(0deg);transform-origin:50% 50%;transition:transform .12s ease;}
.tree-row.open .tree-chev{transform:rotate(90deg);}
.tree-name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  font-size:13px;font-weight:400;color:var(--text-1);}
.tree-row.leaf .tree-name{color:var(--text-2);}
.tree-id{font-weight:600;text-transform:uppercase;}
.tree-val{flex:0 1 auto;font-family:var(--mono);font-size:12px;font-weight:400;color:var(--text-1);}
.tree-state{font-size:12px;font-weight:400;color:var(--text-2);}
.lamp{width:7px;height:7px;flex:0 0 7px;border-radius:50%;background:var(--border);}
.lamp.on{background:var(--text-1);}
.side-actions{margin-top:auto;padding:14px;display:flex;flex-direction:column;gap:8px;border-top:1px solid var(--border);}
.btn{appearance:none;height:36px;border:1px solid var(--border);background:transparent;
  color:var(--text-1);font-family:var(--sans);font-size:13px;font-weight:500;line-height:1;
  cursor:pointer;text-decoration:none;display:flex;align-items:center;justify-content:center;gap:8px;}
.btn:hover{border-color:var(--text-1);color:var(--text-1);}
.btn:disabled{opacity:.4;cursor:wait;border-color:var(--border);}
.btn.solid{background:var(--text-1);color:var(--page);border-color:var(--text-1);}
.btn.solid:hover{background:var(--text-1);border-color:var(--text-1);}
.btn.ghost-bad:hover{border-color:var(--text-2);color:var(--text-2);}
.viewport{grid-column:2;grid-row:1;min-height:0;min-width:0;display:flex;flex-direction:row;background:var(--page);position:relative;}
.view-stage{flex:1 1 auto;min-height:0;min-width:0;position:relative;display:flex;z-index:0;}
#calib-tag{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;}
.reticle{position:relative;padding:8px;background:#fff;flex:0 0 auto;
  display:flex;align-items:center;justify-content:center;
  max-width:min(72vmin,100%);max-height:min(72vmin,100%);}
/* The PNG already carries a 1-cell quiet zone: the black square is 60% of the
   image. Size against the remaining pane. */
.reticle img{display:block;width:min(72vmin,100%);height:auto;max-height:min(72vmin,100%);aspect-ratio:1/1;
  background:#fff;image-rendering:pixelated;image-rendering:crisp-edges;}
#live{display:none;flex:1;min-height:0;width:100%;height:100%;}
#live.show{display:flex;}
#map-wrap{position:relative;flex:1;width:100%;height:100%;background:var(--page);border:0;}
#map{width:100%;height:100%;display:block;}
#map-msg{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;pointer-events:none;
  font-size:13px;font-weight:500;color:var(--text-2);}
#map-msg.hidden{display:none;}
.view-tools{position:absolute;left:16px;bottom:16px;display:flex;gap:8px;z-index:2;}
.chip{appearance:none;height:28px;padding:0 12px;border:1px solid var(--border);background:var(--card);
  color:var(--text-1);font-family:var(--sans);font-size:13px;font-weight:500;cursor:pointer;}
.chip:hover,.chip.on{border-color:var(--text-1);color:var(--text-1);}
.live-stats{position:absolute;top:14px;right:16px;display:flex;gap:8px;z-index:2;pointer-events:none;}
.stat{min-width:72px;padding:8px 10px;border:1px solid var(--border);background:var(--card);}
.stat b{display:block;font-size:12px;font-weight:400;color:var(--text-2);}
.stat em{display:block;margin-top:4px;font-family:var(--mono);font-size:13px;font-weight:500;font-style:normal;color:var(--text-1);}
#confirm{display:none;position:fixed;inset:0;background:var(--page);z-index:20;
  align-items:center;justify-content:center;padding:24px;}
#confirm.open{display:flex;}
.sheet{width:min(420px,100%);background:var(--panel);border:1px solid var(--border);padding:24px;}
.sheet:before{content:"";display:block;height:2px;background:var(--text-1);margin:-24px -24px 20px;}
.sheet h3{margin:0 0 8px;font-size:16px;font-weight:600;line-height:1.25;}
.sheet p{margin:0 0 22px;color:var(--text-2);font-size:14px;font-weight:400;line-height:1.45;}
.sheet-row{display:flex;gap:8px;}
.sheet-row .btn{flex:1;}
/* scan recording player (sidebar > History) */
#player{display:none;position:fixed;inset:0;background:rgba(0,0,0,.72);z-index:21;
  align-items:center;justify-content:center;padding:24px;}
#player.open{display:flex;}
#player.open.docked{position:relative;inset:auto;width:380px;flex:0 0 380px;height:auto;
  align-self:stretch;padding:12px 12px 12px 0;background:transparent;
  align-items:stretch;justify-content:stretch;pointer-events:none;z-index:2;}
#player.open.docked .player-box{pointer-events:auto;width:100%;height:100%;max-height:none;
  transform:translateZ(0);}
#player.open.docked .player-body{grid-template-columns:1fr;grid-template-rows:minmax(0,1fr) minmax(140px,38%);}
#player.open.docked #player-video{max-height:none;height:100%;}
#player.open.docked .player-summary{max-height:none;}
@media (max-width:900px){
  .viewport{flex-direction:column;}
  #player.open.docked{width:auto;flex:0 0 auto;max-height:42vh;padding:0 12px 12px;}
  #player.open.docked .player-box{max-height:42vh;}
}
.player-box{width:min(1180px,100%);max-height:calc(100vh - 48px);display:flex;flex-direction:column;
  background:var(--panel);border:1px solid var(--border);padding:12px;min-height:0;}
.player-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px;flex:0 0 auto;}
.player-head span{font-family:var(--mono);font-size:13px;color:var(--text-1);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.player-head .btn{height:30px;padding:0 12px;}
.player-body{display:grid;grid-template-columns:minmax(0,1fr) 320px;grid-template-rows:minmax(0,72vh);
  gap:12px;align-items:stretch;min-height:0;flex:1 1 auto;overflow:hidden;}
#player-video{display:block;width:100%;height:100%;max-height:72vh;background:#000;object-fit:contain;}
.player-summary{min-height:0;max-height:100%;overflow:hidden;display:flex;flex-direction:column;
  border:1px solid var(--border);background:var(--card);padding:10px 12px;}
.player-sum-head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px;flex:0 0 auto;}
.player-sum-head b{font-size:12px;font-weight:500;letter-spacing:.03em;text-transform:uppercase;color:var(--text-2);}
.player-sum-head .btn{height:28px;padding:0 10px;}
#player-sum-text{margin:0 0 10px;font-size:13px;line-height:1.45;color:var(--text-1);flex:0 0 auto;}
#player-sum-text.muted{color:var(--text-2);}
#player-tasks{flex:1 1 auto;min-height:0;overflow:auto;display:flex;flex-direction:column;gap:4px;}
.player-task{appearance:none;width:100%;text-align:left;border:1px solid transparent;background:transparent;
  color:var(--text-1);padding:8px 8px;cursor:pointer;font:inherit;}
.player-task:hover,.player-task.on{border-color:var(--border);background:var(--panel);}
.player-task .t{display:flex;align-items:baseline;justify-content:space-between;gap:8px;}
.player-task .t em{font-family:var(--mono);font-size:12px;font-style:normal;color:var(--text-2);}
.player-task .t span{font-size:13px;font-weight:500;}
.player-task p{margin:4px 0 0;font-size:12px;line-height:1.4;color:var(--text-2);}
@media (max-width:900px){
  .player-body{grid-template-columns:1fr;}
  #player-video{max-height:42vh;}
  .player-summary{max-height:32vh;}
}
.tree-row.rec,.tree-row.model{cursor:pointer;}
.tree-row.rec .tree-name,.tree-row.model .tree-name{color:var(--text-1);}
.tree-row.model.on,.tree-row.rec.on,.tree-row.on{background:var(--card);}
.tree-row.model .tree-val,.tree-row.rec .tree-val{flex:0 0 auto;}
#view-banner{display:none;position:absolute;top:14px;left:16px;z-index:2;
  padding:8px 10px;border:1px solid var(--border);background:var(--card);
  font-size:12px;font-weight:500;color:var(--text-1);pointer-events:none;}
#view-banner.show{display:block;}
@media (max-width:900px){
  .phases{display:none;}
  #shell{grid-template-columns:1fr;}
  #side{grid-column:1;grid-row:1;max-height:48vh;border-right:0;border-bottom:1px solid var(--border);}
  .viewport{grid-column:1;grid-row:2;}
}
</style>
<script type="importmap">
{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.160.1/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.1/examples/jsm/"}}
</script>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
</head>
<body>
<div id="banner"></div>
<header id="top">
  <div class="brand">
    <svg class="mark" viewBox="0 0 28 28" aria-hidden="true">
      <path d="M3 8 L14 3 L25 8 L25 20 L14 25 L3 20 Z" fill="none" stroke="#DBDAD9" stroke-width="1.4"/>
      <path d="M8 14 L14 8 L20 14" fill="none" stroke="#A19F9B" stroke-width="1.4"/>
      <path d="M8 18 L14 12 L20 18" fill="none" stroke="#DBDAD9" stroke-width="1.4"/>
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
    <div class="link" id="link"><i class="pulse"></i><span id="link-txt">Disconnected</span></div>
    <div id="clock">00:00:00</div>
  </div>
</header>
<div id="shell">
  <aside id="side">
    <div id="side-map">
      <div class="scan-map-wrap">
        <div id="scan-map" aria-label="Scanned sites"></div>
        <div id="scan-map-empty" class="scan-map-empty">Locating sites</div>
      </div>
    </div>
    <hr class="side-rule">
    <div id="dots" class="tree"></div>
    <div class="side-actions">
      <button type="button" class="btn" id="opt-btn">Optimize</button>
      <button type="button" class="btn ghost-bad" id="reset-btn">Reset</button>
    </div>
  </aside>
  <section class="viewport">
    <div class="view-stage">
      <div id="calib-tag">
        <div class="reticle">
          <img id="calib-tag-img" src="/tag.png" alt="ArUco 4x4 start tag id 0"/>
        </div>
      </div>
      <div id="live">
        <div id="map-wrap">
          <canvas id="map"></canvas>
          <div id="map-msg">Awaiting keyframes</div>
          <div class="live-stats">
            <div class="stat"><b>Nodes</b><em id="stat-nodes">0</em></div>
            <div class="stat"><b>Mesh</b><em id="stat-mesh">0</em></div>
            <div class="stat"><b>Align</b><em id="stat-align">No</em></div>
          </div>
          <div id="view-banner"></div>
          <div class="view-tools">
            <button type="button" class="chip on" id="live-btn">Live</button>
            <button type="button" class="chip" id="fit-btn">Fit</button>
          </div>
        </div>
      </div>
    </div>
    <div id="player" class="player">
      <div class="player-box">
        <div class="player-head"><span id="player-title"></span><button type="button" class="btn" id="player-close">Close</button></div>
        <div class="player-body">
          <video id="player-video" controls playsinline preload="metadata"></video>
          <aside class="player-summary" id="player-summary">
            <div class="player-sum-head">
              <b>Summary</b>
              <button type="button" class="btn" id="player-summarize">Summarize</button>
            </div>
            <p id="player-sum-text" class="muted">Open a recording to summarize completed tasks.</p>
            <div id="player-tasks"></div>
          </aside>
        </div>
      </div>
    </div>
  </section>
</div>
<div id="confirm">
  <div class="sheet" role="dialog" aria-labelledby="confirm-title">
    <h3 id="confirm-title">Reset the room?</h3>
    <p>Deletes the stored map and unlocks the session. Both phones must join and point at the tag again.</p>
    <div class="sheet-row">
      <button type="button" class="btn" id="confirm-no">Cancel</button>
      <button type="button" class="btn solid" id="confirm-go">Reset</button>
    </div>
  </div>
</div>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
// Assumed on-screen tag width: 0.20 m. Live view uses organizedFastMesh + RGB.
const TAG_SIZE_M = )HTML" << kDemoTagSizeM << R"HTML(;
const COLORS = ['#DBDAD9', '#A19F9B', '#454340', '#2B2A28'];
function shouldShowTag(demo) {
  return demo.show_tag === true && demo.locked !== true;
}
// ?view=map keeps the 3D map up even when the room is not locked.
const FORCE_MAP = new URLSearchParams(location.search).get('view') === 'map';
// After a server restart the session lock is gone, but the map is still on
// disk. Keep the 3D view up whenever there is already a map (or the room is
// locked). The tag is only for a fresh empty room.
function shouldShowMap(demo) {
  if (FORCE_MAP) return true;
  if (demo.locked === true) return true;
  return (demo.global_nodes || 0) > 0;
}
function hideTag() {
  const tag = document.getElementById('calib-tag');
  if (tag) tag.style.display = 'none';
}
function hideLive() {
  const live = document.getElementById('live');
  if (live) { live.style.display = 'none'; live.classList.remove('show'); }
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
function clientStatus(id) {
  const list = (lastStatus && lastStatus.clients) || [];
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) return list[i];
  }
  return null;
}
function numOr(v, fallback) {
  return (typeof v === 'number' && isFinite(v)) ? v : fallback;
}
function fmtSigned(v, digits) {
  if (typeof v !== 'number' || !isFinite(v)) return 'n/a';
  return (v >= 0 ? '+' : '') + v.toFixed(digits);
}
function fmtMeters(v) {
  if (typeof v !== 'number' || !isFinite(v)) return 'n/a';
  return v.toFixed(3) + ' m';
}
function fmtDeg(rad) {
  if (typeof rad !== 'number' || !isFinite(rad)) return 'n/a';
  return (rad * 180 / Math.PI).toFixed(1) + '\u00b0';
}
function headingDeg(rad) {
  if (typeof rad !== 'number' || !isFinite(rad)) return 'n/a';
  let d = rad * 180 / Math.PI;
  d = ((d % 360) + 360) % 360;
  return d.toFixed(1) + '\u00b0';
}
function eulerFromQuat(qx, qy, qz, qw) {
  const sinp = 2 * (qw * qy - qz * qx);
  const pitch = Math.abs(sinp) >= 1 ? Math.sign(sinp) * Math.PI / 2 : Math.asin(sinp);
  return {
    roll: Math.atan2(2 * (qw * qx + qy * qz), 1 - 2 * (qx * qx + qy * qy)),
    pitch: pitch,
    yaw: Math.atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qy * qy + qz * qz))
  };
}
function rpyOf(cl) {
  const have = function(v) { return typeof v === 'number' && isFinite(v); };
  if (have(cl.roll) && have(cl.pitch) && (Math.abs(cl.roll) + Math.abs(cl.pitch) > 1e-5)) {
    return { roll: cl.roll, pitch: cl.pitch, yaw: cl.yaw };
  }
  if (have(cl.qx) && have(cl.qy) && have(cl.qz) && have(cl.qw)) {
    const e = eulerFromQuat(cl.qx, cl.qy, cl.qz, cl.qw);
    if (have(cl.yaw)) e.yaw = cl.yaw;
    return e;
  }
  return { roll: cl.roll, pitch: cl.pitch, yaw: cl.yaw };
}
function unitItems(demo) {
  const seen = {};
  const items = [];
  function add(c) {
    if (!c || !c.id || c.id === 'waiting' || seen[c.id]) return;
    seen[c.id] = true;
    items.push({ id: c.id, locked: !!c.locked });
  }
  (demo.calibrated || []).forEach(add);
  const now = numOr(demo.server_now, Date.now() / 1000);
  (demo.clients || []).forEach(function(c) {
    const age = (c.last_seen > 0) ? (now - c.last_seen) : 1e9;
    if (c.locked || age < 45) add(c);
  });
  return items;
}
function ageLabel(unix, now) {
  if (!unix || unix <= 0) return 'n/a';
  const s = Math.max(0, now - unix);
  if (s < 1) return '<1s';
  if (s < 60) return Math.round(s) + 's';
  const m = Math.floor(s / 60);
  return m + 'm ' + Math.round(s % 60) + 's';
}
function shortClientId(id) {
  const s = String(id || '');
  if (s.length <= 8) return s;
  return s.slice(-8);
}
const treeOpen = {};
function folderOpen(path, fallback) {
  return Object.prototype.hasOwnProperty.call(treeOpen, path) ? treeOpen[path] : fallback;
}
function ico(kind) {
  if (kind === 'chev') {
    return '<svg class="tree-chev" viewBox="0 0 12 12" aria-hidden="true"><path d="M4 2.5 L8.5 6 L4 9.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }
  if (kind === 'folder') {
    return '<svg class="tree-ico" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 4.6h4.1l1.2 1.5H14V13H2z" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>';
  }
  if (kind === 'video') {
    return '<svg class="tree-ico" viewBox="0 0 16 16" aria-hidden="true"><rect x="2.2" y="3.6" width="11.6" height="8.8" rx="1.4" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M6.6 6.1 L10.4 8 L6.6 9.9 Z" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>';
  }
  if (kind === 'mesh') {
    return '<svg class="tree-ico" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.2 L13.4 5.2 V11 L8 14 L2.6 11 V5.2 Z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M8 2.2 V8.2 L13.4 11 M8 8.2 L2.6 11" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>';
  }
  return '<svg class="tree-ico" viewBox="0 0 16 16" aria-hidden="true"><rect x="4.2" y="3.4" width="7.6" height="9.2" rx="0.8" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>';
}
function treeFolder(path, depth, name, extra, kids, openDefault, icon, selected) {
  const open = folderOpen(path, openDefault);
  let html = '<div class="tree-node' + (open ? ' open' : '') + '">';
  html += '<div class="tree-row' + (open ? ' open' : '') + (selected ? ' on' : '') + '" style="--d:' + depth + '" data-toggle="' + esc(path) + '">';
  html += ico('chev') + ico(icon || 'folder') + '<span class="tree-name' + (depth === 1 ? ' tree-id' : '') + '">' + esc(name) + '</span>' + (extra || '') + '</div>';
  html += '<div class="tree-kids">' + kids + '</div></div>';
  return html;
}
function treeLeaf(depth, name, value, key) {
  return '<div class="tree-row leaf" style="--d:' + depth + '"' +
    (key ? ' data-leaf="' + esc(key) + '"' : '') + '>' + ico('file') +
    '<span class="tree-name">' + esc(name) + '</span>' +
    (value != null ? '<span class="tree-val">' + esc(value) + '</span>' : '') + '</div>';
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
  // live generation, plus the assembled-surface generation once one exists
  if (mesh) mesh.textContent = String(demo.mesh_gen || 0) + (demo.mesh_baked ? (' / B' + (demo.bake_gen || 0)) : '');
  if (align) align.textContent = demo.aligned ? 'Yes' : 'No';
}
function setLink(ok) {
  const el = document.getElementById('link');
  const txt = document.getElementById('link-txt');
  if (!el || !txt) return;
  el.classList.toggle('ok', !!ok);
  txt.textContent = ok ? 'Live' : 'Disconnected';
}
const sessionStart = Date.now();
function tickClock() {
  const el = document.getElementById('clock');
  if (!el) return;
  const s = Math.max(0, Math.floor((Date.now() - sessionStart) / 1000));
  el.textContent = pad2(Math.floor(s / 3600)) + ':' + pad2(Math.floor((s % 3600) / 60)) + ':' + pad2(s % 60);
}
function cssEsc(s) {
  return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
}
function unitFields(demo, c) {
  const cl = findClient(demo, c.id) || {};
  const st = clientStatus(c.id) || {};
  const rpy = rpyOf(cl);
  const now = numOr(demo.server_now, Date.now() / 1000);
  const seen = numOr(cl.last_seen, st.last_seen);
  const poseAt = numOr(cl.last_pose_at, 0);
  const seenAge = (seen > 0) ? (now - seen) : 1e9;
  const live = seenAge < 5;
  const stale = seen > 0 && seenAge >= 45;
  const locked = !!(c.locked || cl.locked);
  let state = 'Standby';
  if (stale) state = 'Stale';
  else if (locked) state = 'Locked';
  else if (seen <= 0) state = 'Offline';
  const x = cl.x, y = cl.y, z = cl.z;
  const hasPos = typeof x === 'number' && typeof y === 'number' && typeof z === 'number';
  const range = hasPos ? Math.hypot(x, y, z) : NaN;
  const ground = hasPos ? Math.hypot(x, y) : NaN;
  const nodes = numOr(cl.nodes, st.nodes);
  const localId = numOr(cl.last_local_id, st.last_local_id);
  const session = numOr(cl.session_map_id, -1);
  const mapBase = numOr(cl.map_id_base, -1);
  const pathM = numOr(cl.path_m, NaN);
  const trailN = numOr(cl.trail_n, (cl.trail || []).length);
  const tagId = numOr(cl.tag_id, -1);
  const hasQuat = [cl.qx, cl.qy, cl.qz, cl.qw].every(function(v) {
    return typeof v === 'number' && isFinite(v);
  });
  return {
    path: c.id, state: state, live: live,
    e: hasPos ? fmtSigned(x, 3) + ' m' : 'n/a',
    n: hasPos ? fmtSigned(y, 3) + ' m' : 'n/a',
    u: hasPos ? fmtSigned(z, 3) + ' m' : 'n/a',
    range: isFinite(range) ? fmtMeters(range) : 'n/a',
    ground: isFinite(ground) ? fmtMeters(ground) : 'n/a',
    heading: headingDeg(rpy.yaw),
    yaw: fmtDeg(rpy.yaw), pitch: fmtDeg(rpy.pitch), roll: fmtDeg(rpy.roll),
    quat: hasQuat ? fmtSigned(cl.qx, 2) + ' ' + fmtSigned(cl.qy, 2) + ' ' + fmtSigned(cl.qz, 2) + ' ' + fmtSigned(cl.qw, 2) : 'n/a',
    nodes: nodes != null ? String(nodes) : 'n/a',
    localId: localId != null ? String(localId) : 'n/a',
    session: session >= 0 ? String(session) : 'n/a',
    mapBase: mapBase >= 0 ? String(mapBase) : 'n/a',
    pathM: isFinite(pathM) ? fmtMeters(pathM) : 'n/a',
    samples: String(trailN || 0),
    fix: cl.has_fix === true ? 'Yes' : (cl.has_fix === false ? 'No' : 'n/a'),
    tag: tagId >= 0 ? String(tagId) : 'n/a',
    seen: ageLabel(seen, now),
    pose: ageLabel(poseAt, now)
  };
}
function sidebarStructureKey(demo) {
  return JSON.stringify({
    u: unitItems(demo).map(function(c) { return c.id; }),
    v: currentVideoList.map(function(v) { return v.name; }),
    p: videoList.map(function(v) { return v.name; }),
    m: modelList.map(function(v) { return v.name; }),
    h: historyView && historyView.name,
    q: historyFilterKey()
  });
}
let lastSidebarKey = '';
function setLeafVal(root, key, value) {
  const row = root.querySelector('[data-leaf="' + cssEsc(key) + '"]');
  if (!row) return;
  const val = row.querySelector('.tree-val');
  if (val && val.textContent !== value) val.textContent = value;
}
function updateDotsValues(demo) {
  const dots = document.getElementById('dots');
  if (!dots) return;
  const items = unitItems(demo);
  const count = document.getElementById('dot-count');
  if (count) count.textContent = String(items.length);
  items.slice(0, 4).forEach(function(c) {
    const f = unitFields(demo, c);
    const p = f.path;
    const state = dots.querySelector('[data-unit-state="' + cssEsc(p) + '"]');
    if (state && state.textContent !== f.state) state.textContent = f.state;
    const lamp = dots.querySelector('[data-unit-lamp="' + cssEsc(p) + '"]');
    if (lamp) lamp.classList.toggle('on', f.live);
    setLeafVal(dots, p + '/e', f.e);
    setLeafVal(dots, p + '/n', f.n);
    setLeafVal(dots, p + '/u', f.u);
    setLeafVal(dots, p + '/range', f.range);
    setLeafVal(dots, p + '/ground', f.ground);
    setLeafVal(dots, p + '/heading', f.heading);
    setLeafVal(dots, p + '/yaw', f.yaw);
    setLeafVal(dots, p + '/pitch', f.pitch);
    setLeafVal(dots, p + '/roll', f.roll);
    setLeafVal(dots, p + '/quat', f.quat);
    setLeafVal(dots, p + '/nodes', f.nodes);
    setLeafVal(dots, p + '/local', f.localId);
    setLeafVal(dots, p + '/session', f.session);
    setLeafVal(dots, p + '/mapbase', f.mapBase);
    setLeafVal(dots, p + '/path', f.pathM);
    setLeafVal(dots, p + '/samples', f.samples);
    setLeafVal(dots, p + '/fix', f.fix);
    setLeafVal(dots, p + '/tag', f.tag);
    setLeafVal(dots, p + '/seen', f.seen);
    setLeafVal(dots, p + '/pose', f.pose);
  });
}
function renderDots(demo) {
  const dots = document.getElementById('dots');
  if (!dots) return;
  const key = sidebarStructureKey(demo);
  if (key === lastSidebarKey && dots.firstChild) {
    updateDotsValues(demo);
    return;
  }
  lastSidebarKey = key;
  const items = unitItems(demo);
  const kids = items.slice(0, 4).map(function(c, i) {
    const f = unitFields(demo, c);
    const path = f.path;
    const extra = '<span class="tree-state" data-unit-state="' + esc(path) + '">' + esc(f.state) + '</span>' +
      '<span class="lamp' + (f.live ? ' on' : '') + '" data-unit-lamp="' + esc(path) + '"></span>';
    let body = treeLeaf(2, shortClientId(c.id));
    body += treeFolder(path + '/position', 2, 'Position', '',
      treeLeaf(3, 'E', f.e, path + '/e') +
      treeLeaf(3, 'N', f.n, path + '/n') +
      treeLeaf(3, 'U', f.u, path + '/u') +
      treeLeaf(3, 'Range', f.range, path + '/range') +
      treeLeaf(3, 'Ground', f.ground, path + '/ground') +
      treeLeaf(3, 'Heading', f.heading, path + '/heading'), true);
    body += treeFolder(path + '/attitude', 2, 'Attitude', '',
      treeLeaf(3, 'Yaw', f.yaw, path + '/yaw') +
      treeLeaf(3, 'Pitch', f.pitch, path + '/pitch') +
      treeLeaf(3, 'Roll', f.roll, path + '/roll') +
      treeLeaf(3, 'Quat', f.quat, path + '/quat'), true);
    body += treeFolder(path + '/mapping', 2, 'Mapping', '',
      treeLeaf(3, 'Keyframes', f.nodes, path + '/nodes') +
      treeLeaf(3, 'Local id', f.localId, path + '/local') +
      treeLeaf(3, 'Session', f.session, path + '/session') +
      treeLeaf(3, 'Map base', f.mapBase, path + '/mapbase') +
      treeLeaf(3, 'Path', f.pathM, path + '/path') +
      treeLeaf(3, 'Samples', f.samples, path + '/samples') +
      treeLeaf(3, 'Fix', f.fix, path + '/fix') +
      treeLeaf(3, 'Tag', f.tag, path + '/tag'), true);
    body += treeFolder(path + '/link', 2, 'Link', '',
      treeLeaf(3, 'Seen', f.seen, path + '/seen') +
      treeLeaf(3, 'Pose', f.pose, path + '/pose'), true);
    return treeFolder(path, 1, 'UNIT-' + pad2(i + 1), extra, body, true);
  }).join('');
  const searchEl = document.getElementById('scan-search');
  const keepFocus = !!(searchEl && document.activeElement === searchEl);
  if (searchEl) lastSearchQuery = searchEl.value;
  dots.innerHTML = treeFolder('units', 0, 'Units',
    '<span class="tree-val" id="dot-count">' + items.length + '</span>', kids, true) +
    renderRecordings() +
    renderHistory();
  restoreHistorySearch(keepFocus);
}
// Current-run recordings live in the sidebar Recordings folder. After reset
// they move into History > Recordings. Models are archived room meshes.
let currentVideoList = [];
let videoList = [];
let modelList = [];
let historyView = null;
let currentRunName = '';
let lastSearchQuery = '';
let historyFilterHits = {models: {}, videos: {}};
function historyFilterKey() {
  const q = String(lastSearchQuery || '').trim().toLowerCase();
  if (!q) return '';
  return q + '|' + Object.keys(historyFilterHits.models).sort().join(',') +
    '|' + Object.keys(historyFilterHits.videos).sort().join(',');
}
function historyItemText(it) {
  return [
    it && it.name, it && it.title, it && it.address, recName(it || {}),
    recTimeLabel(it || {}), userLabels(it && it.users), it && it.kind, it && it.client
  ].join(' ').toLowerCase();
}
function historyItemMatches(it, q) {
  if (!q) return true;
  if (!it) return false;
  if (historyItemText(it).indexOf(q) >= 0) return true;
  if (it.name && (historyFilterHits.models[it.name] || historyFilterHits.videos[it.name])) return true;
  return false;
}
function filteredHistoryModels() {
  const q = String(lastSearchQuery || '').trim().toLowerCase();
  if (!q) return modelList;
  return modelList.filter(function(m) { return historyItemMatches(m, q); });
}
function filteredHistoryVideos() {
  const q = String(lastSearchQuery || '').trim().toLowerCase();
  if (!q) return videoList;
  return videoList.filter(function(v) { return historyItemMatches(v, q); });
}
function fmtBytes(b) {
  if (!(b > 0)) return '0 MB';
  return b >= 1024 * 1024 * 1024 ? (b / (1024 * 1024 * 1024)).toFixed(2) + ' GB' : (b / (1024 * 1024)).toFixed(0) + ' MB';
}
function fmtDuration(s) {
  if (!(s > 0)) return '';
  const m = Math.floor(s / 60), r = Math.round(s - m * 60);
  return m + ':' + (r < 10 ? '0' : '') + r;
}
function unitLabelForClient(clientId) {
  if (!clientId || !lastDemo || !Array.isArray(lastDemo.clients)) return '';
  const idx = lastDemo.clients.findIndex(function(c) { return c.id === clientId; });
  return idx >= 0 ? 'UNIT-' + pad2(idx + 1) : '';
}
function userLabels(users) {
  if (!Array.isArray(users) || users.length === 0) return '';
  return users.map(function(id) {
    const unit = unitLabelForClient(id);
    if (unit) return unit;
    const s = String(id || '');
    return s.length > 4 ? s.slice(-4) : s;
  }).filter(Boolean).join(' · ');
}
function dayKeyFromStamp(v) {
  const m = String(v.name || '').match(/^(\d{2})(\d{2})(\d{2})-/);
  if (m) return (2000 + Number(m[1])) + '-' + m[2] + '-' + m[3];
  const unix = numOr(v.mtime, 0);
  if (unix > 0) {
    const d = new Date(unix * 1000);
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
  }
  return 'unknown';
}
function dayLabel(key) {
  if (key === 'unknown') return 'Unknown';
  const parts = key.split('-');
  const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  const today = new Date();
  const todayKey = today.getFullYear() + '-' + pad2(today.getMonth() + 1) + '-' + pad2(today.getDate());
  const yest = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  const yestKey = yest.getFullYear() + '-' + pad2(yest.getMonth() + 1) + '-' + pad2(yest.getDate());
  if (key === todayKey) return 'Today';
  if (key === yestKey) return 'Yesterday';
  return d.toLocaleDateString(undefined, {weekday: 'short', month: 'short', day: 'numeric'});
}
function recTimeLabel(v) {
  const m = String(v.name || '').match(/^\d{6}-(\d{2})(\d{2})(\d{2})/);
  if (m) return m[1] + ':' + m[2] + ':' + m[3];
  const unix = numOr(v.mtime, 0);
  if (unix > 0) {
    const d = new Date(unix * 1000);
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  }
  return String(v.name || '').replace(/\.(mp4|ply)$/, '');
}
function recName(v) {
  if (v && v.title) return v.title;
  const time = recTimeLabel(v || {});
  if (v && v.address) return v.address + ' · ' + time;
  return time;
}
function currentRunLabel() {
  if (lastDemo && lastDemo.run_name) return lastDemo.run_name;
  if (currentRunName) return currentRunName;
  return 'Recordings';
}
function groupByDay(list) {
  const groups = [];
  const byDay = {};
  list.forEach(function(v) {
    const key = dayKeyFromStamp(v);
    if (!byDay[key]) {
      byDay[key] = [];
      groups.push(key);
    }
    byDay[key].push(v);
  });
  return {groups: groups, byDay: byDay};
}
function renderDayGroups(pathPrefix, list, emptyText, rowFn, depth) {
  const g = groupByDay(list);
  if (g.groups.length === 0) {
    return '<div class="tree-row leaf" style="--d:' + depth + '"><span class="tree-name">' + esc(emptyText) + '</span></div>';
  }
  return g.groups.map(function(key, i) {
    const rows = g.byDay[key].map(rowFn).join('');
    return treeFolder(pathPrefix + '/' + key, depth, dayLabel(key),
      '<span class="tree-val">' + g.byDay[key].length + '</span>', rows, i === 0);
  }).join('');
}
function recRow(v, depth) {
  const meta = [unitLabelForClient(v.client), fmtDuration(v.duration_s), fmtBytes(v.bytes)].filter(Boolean).join(' · ');
  return '<div class="tree-row leaf rec" style="--d:' + depth + '" data-video="' + esc(v.name) + '" title="' + esc(recName(v)) + '">' + ico('video') +
    '<span class="tree-name">' + esc(recTimeLabel(v)) + '</span>' +
    '<span class="tree-val">' + esc(meta) + '</span></div>';
}
function recordingKey(item) {
  if (item && item.run > 0) return 'run-' + item.run;
  return item ? dayKeyFromStamp(item) : '';
}
function videosForHistoryModel(model) {
  if (!model) return [];
  const past = videoList.slice();
  if (model.run > 0) {
    const hits = past.filter(function(v) { return Number(v.run) === Number(model.run); });
    if (hits.length) return hits;
  }
  if (model.title) {
    const hits = past.filter(function(v) { return v.title && v.title === model.title; });
    if (hits.length) return hits;
  }
  const t = itemWhen(model);
  if (!t) return [];
  let best = null, bestDt = 15 * 60;
  past.forEach(function(v) {
    const vt = itemWhen(v);
    if (!vt) return;
    const dt = Math.abs(vt - t);
    if (dt < bestDt) {
      bestDt = dt;
      best = v;
    }
  });
  if (!best) return [];
  const key = recordingKey(best);
  return past.filter(function(v) { return recordingKey(v) === key; });
}
function activeRecordingKey() {
  if (!historyView) return '';
  const vids = videosForHistoryModel(historyView);
  return vids.length ? recordingKey(vids[0]) : '';
}
function focusHistoryRecordings(model) {
  treeOpen['recordings'] = true;
  const videos = videosForHistoryModel(model);
  if (!videos.length) return;
  const key = recordingKey(videos[0]);
  treeOpen['history'] = true;
  treeOpen['history/recordings'] = true;
  groupByRun(videoList).groups.forEach(function(k) {
    treeOpen['history/recordings/' + k] = (k === key);
  });
}
function groupByRun(list) {
  const groups = [];
  const byRun = {};
  list.forEach(function(v) {
    const key = recordingKey(v);
    if (!byRun[key]) {
      byRun[key] = [];
      groups.push(key);
    }
    byRun[key].push(v);
  });
  return {groups: groups, byRun: byRun};
}
function renderRunGroups(pathPrefix, list, emptyText, rowFn, depth) {
  const g = groupByRun(list);
  if (g.groups.length === 0) {
    return '<div class="tree-row leaf" style="--d:' + depth + '"><span class="tree-name">' + esc(emptyText) + '</span></div>';
  }
  const selected = activeRecordingKey();
  return g.groups.map(function(key, i) {
    const rows = g.byRun[key];
    const openDefault = selected ? key === selected : i === 0;
    return treeFolder(pathPrefix + '/' + key, depth, recName(rows[0]),
      '<span class="tree-val">' + rows.length + '</span>', rows.map(rowFn).join(''), openDefault, 'video', key === selected);
  }).join('');
}
function renderRecordings() {
  const hist = historyView ? videosForHistoryModel(historyView) : null;
  const videos = hist || currentVideoList;
  const label = hist
    ? (hist.length ? recName(hist[0]) : recName(historyView))
    : currentRunLabel();
  const empty = '<div class="tree-row leaf" style="--d:1"><span class="tree-name">No recordings yet</span></div>';
  const kids = videos.length === 0 ? empty : videos.map(function(v) {
    return recRow(v, 1);
  }).join('');
  return treeFolder('recordings', 0, label,
    '<span class="tree-val">' + videos.length + '</span>', kids, true, 'video', !!hist);
}
function historySearchHtml() {
  return '<div class="tree-search scan-search" style="--d:1">' +
    '<input id="scan-search" type="search" placeholder="Search history" autocomplete="off" spellcheck="false" value="' + esc(lastSearchQuery) + '">' +
    '</div>';
}
function restoreHistorySearch(keepFocus) {
  const input = document.getElementById('scan-search');
  if (input && lastSearchQuery && input.value !== lastSearchQuery) input.value = lastSearchQuery;
  bindScanSearch();
  if (input && keepFocus) {
    input.focus();
    const n = input.value.length;
    try { input.setSelectionRange(n, n); } catch (e) {}
  }
}
function renderHistory() {
  const q = String(lastSearchQuery || '').trim();
  const models = filteredHistoryModels();
  const videos = filteredHistoryVideos();
  const emptyModels = q ? 'No matches' : 'No models yet';
  const emptyVideos = q ? 'No matches' : 'No recordings yet';
  if (q) {
    treeOpen['history'] = true;
    treeOpen['history/models'] = true;
    treeOpen['history/recordings'] = true;
  }
  const modelRows = models.length === 0
    ? '<div class="tree-row leaf" style="--d:2"><span class="tree-name">' + esc(emptyModels) + '</span></div>'
    : models.map(function(v) {
        const meta = [
          userLabels(v.users),
          (v.nodes > 0 ? String(v.nodes) : ''),
          fmtBytes(v.bytes)
        ].filter(Boolean).join(' · ');
        const on = historyView && historyView.name === v.name;
        return '<div class="tree-row leaf model' + (on ? ' on' : '') + '" style="--d:2" data-model="' + esc(v.name) + '" title="' + esc(recName(v)) + '">' + ico('mesh') +
          '<span class="tree-name">' + esc(recName(v)) + '</span>' +
          '<span class="tree-val">' + esc(meta) + '</span></div>';
      }).join('');
  const recRows = renderRunGroups('history/recordings', videos, emptyVideos, function(v) {
    return recRow(v, 3);
  }, 2);
  const kids =
    historySearchHtml() +
    treeFolder('history/models', 1, 'Models',
      '<span class="tree-val">' + models.length + '</span>', modelRows, true) +
    treeFolder('history/recordings', 1, 'Recordings',
      '<span class="tree-val">' + videos.length + '</span>', recRows, !!activeRecordingKey() || (videos.length > 0 && models.length === 0), 'video', !!activeRecordingKey());
  return treeFolder('history', 0, 'History',
    '<span class="tree-val">' + (models.length + videos.length) + '</span>', kids, true);
}
function historyChanged(a, b, keys) {
  return JSON.stringify(a.map(function(v) { return keys.map(function(k) { return v[k]; }); })) !==
    JSON.stringify(b.map(function(v) { return keys.map(function(k) { return v[k]; }); }));
}
function pollVideos() {
  fetch('/videos', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(res) {
    const all = (res && Array.isArray(res.videos)) ? res.videos : [];
    const current = all.filter(function(v) { return v.current === true; });
    const past = all.filter(function(v) { return v.current !== true; });
    if (res && res.run_name) currentRunName = res.run_name;
    const changed = historyChanged(current, currentVideoList, ['name', 'bytes', 'run', 'summary_status', 'task_count', 'address', 'title', 'lat', 'lng']) ||
      historyChanged(past, videoList, ['name', 'bytes', 'run', 'summary_status', 'task_count', 'address', 'title', 'lat', 'lng']);
    currentVideoList = current;
    videoList = past;
    if (changed && lastDemo) renderDots(lastDemo);
    refreshScanMap();
  }).catch(function() {});
}
function pollModels() {
  fetch('/models', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(res) {
    const list = (res && Array.isArray(res.models)) ? res.models : [];
    const changed = historyChanged(list, modelList, ['name', 'bytes', 'address', 'title', 'users', 'lat', 'lng', 'run', 'index_status', 'place_count']);
    modelList = list;
    if (changed && lastDemo) renderDots(lastDemo);
    refreshScanMap();
  }).catch(function() {});
}
let runList = [];
let currentRunRec = null;
function pollRuns() {
  fetch('/runs', {cache: 'no-store'}).then(function(r) { return r.json(); }).then(function(res) {
    currentRunRec = (res && res.current) ? res.current : null;
    runList = (res && Array.isArray(res.runs)) ? res.runs : [];
    refreshScanMap();
  }).catch(function() {});
}
let scanMap = null;
let scanLayer = null;
let scanFittedKey = '';
let operatorGeo = null;
let geoCache = {};
try { geoCache = JSON.parse(localStorage.getItem('cmcs-geo-v1') || '{}') || {}; } catch (e) { geoCache = {}; }
let geocodeBusy = false;
const geocodeQueue = [];
function hasGeo(lat, lng) {
  const a = Number(lat), b = Number(lng);
  return Number.isFinite(a) && Number.isFinite(b) && !(a === 0 && b === 0) && a >= -90 && a <= 90 && b >= -180 && b <= 180;
}
function saveGeoCache() {
  try { localStorage.setItem('cmcs-geo-v1', JSON.stringify(geoCache)); } catch (e) {}
}
function geocodeAddress(address) {
  return new Promise(function(resolve) {
    const key = String(address || '').trim().toLowerCase();
    if (!key) { resolve(null); return; }
    if (geoCache[key] && hasGeo(geoCache[key].lat, geoCache[key].lng)) {
      resolve(geoCache[key]);
      return;
    }
    geocodeQueue.push({key: key, address: address, resolve: resolve});
    drainGeocode();
  });
}
function drainGeocode() {
  if (geocodeBusy || geocodeQueue.length === 0) return;
  geocodeBusy = true;
  const job = geocodeQueue.shift();
  const url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&q=' + encodeURIComponent(job.address);
  fetch(url, {headers: {'Accept': 'application/json'}}).then(function(r) { return r.json(); }).then(function(rows) {
    const hit = rows && rows[0];
    const pos = hit ? {lat: Number(hit.lat), lng: Number(hit.lon)} : null;
    if (pos && hasGeo(pos.lat, pos.lng)) {
      geoCache[job.key] = pos;
      saveGeoCache();
    }
    job.resolve(pos && hasGeo(pos.lat, pos.lng) ? pos : null);
  }).catch(function() { job.resolve(null); }).then(function() {
    geocodeBusy = false;
    setTimeout(drainGeocode, 1100);
  });
}
function setOperatorGeo(lat, lng) {
  if (operatorGeo || !hasGeo(lat, lng)) return;
  operatorGeo = {lat: Number(lat), lng: Number(lng)};
  refreshScanMap();
}
function ensureOperatorGeo() {
  if (operatorGeo || !navigator.geolocation) return;
  navigator.geolocation.getCurrentPosition(function(p) {
    setOperatorGeo(p.coords.latitude, p.coords.longitude);
  }, function() {}, {maximumAge: 600000, timeout: 8000, enableHighAccuracy: false});
}
function findRunRec(id) {
  if (currentRunRec && Number(currentRunRec.id) === Number(id)) return currentRunRec;
  for (let i = 0; i < runList.length; i++) {
    if (Number(runList[i].id) === Number(id)) return runList[i];
  }
  return null;
}
function itemWhen(it) {
  const m = String((it && it.name) || '').match(/^(\d{2})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/);
  if (m) {
    return Date.UTC(2000 + Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])) / 1000;
  }
  return Number((it && (it.mtime || it.uploaded || it.ended || it.started)) || 0);
}
function siteKey(it) {
  const addr = String(it.address || '').trim().toLowerCase().replace(/\s+/g, ' ');
  if (addr) return 'a:' + addr;
  if (hasGeo(it.lat, it.lng)) return 'g:' + Number(it.lat).toFixed(4) + ',' + Number(it.lng).toFixed(4);
  return 'interior';
}
function siteLabel(it) {
  const addr = String((it && it.address) || '').trim();
  return addr || 'Interior';
}
function enrichPlace(it) {
  const out = Object.assign({}, it);
  const rec = findRunRec(out.run || out.id);
  if (rec) {
    if (!out.address && rec.address) out.address = rec.address;
    if (!hasGeo(out.lat, out.lng) && hasGeo(rec.lat, rec.lng)) {
      out.lat = rec.lat;
      out.lng = rec.lng;
    }
  }
  return out;
}
function collectSites() {
  const items = [];
  currentVideoList.concat(videoList).forEach(function(v) {
    items.push(enrichPlace(Object.assign({}, v, {kind: 'video'})));
  });
  modelList.forEach(function(m) {
    items.push(enrichPlace(Object.assign({}, m, {kind: 'model'})));
  });
  const runs = (currentRunRec ? [currentRunRec] : []).concat(runList);
  runs.forEach(function(r) {
    if (!r || !(r.address || hasGeo(r.lat, r.lng) || r.model)) return;
    items.push(enrichPlace(Object.assign({}, r, {kind: 'run', mtime: r.ended || r.started || 0})));
  });
  const byKey = {};
  const order = [];
  items.forEach(function(it) {
    const key = siteKey(it);
    if (!byKey[key]) {
      byKey[key] = {key: key, label: siteLabel(it), items: [], lat: 0, lng: 0};
      order.push(key);
    }
    const site = byKey[key];
    site.items.push(it);
    if (!site.label || site.label === 'Interior') site.label = siteLabel(it);
    if (!hasGeo(site.lat, site.lng) && hasGeo(it.lat, it.lng)) {
      site.lat = Number(it.lat);
      site.lng = Number(it.lng);
    }
  });
  return order.map(function(k) { return byKey[k]; });
}
function latestSiteItems(site, kind) {
  return (site && site.items ? site.items : []).filter(function(it) {
    if (kind === 'model') return (it.kind === 'model' && it.name) || (it.kind === 'run' && it.model);
    if (kind === 'video') return it.kind === 'video' && it.name;
    return false;
  }).sort(function(a, b) { return itemWhen(b) - itemWhen(a); });
}
function openLatestSite(site) {
  if (!site) return;
  const fresh = collectSites().filter(function(s) { return s.key === site.key; })[0] || site;
  const model = latestSiteItems(fresh, 'model')[0];
  const video = latestSiteItems(fresh, 'video')[0];
  const modelName = model ? (model.kind === 'run' ? model.model : model.name) : '';
  if (modelName) openHistoryModel(modelName);
  if (video && video.name) openPlayer(video.name, {dock: true});
}
function initScanMap() {
  const el = document.getElementById('scan-map');
  const Lmap = window.L;
  if (!el || !Lmap || scanMap) return;
  scanMap = Lmap.map(el, {attributionControl: false, scrollWheelZoom: true});
  Lmap.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    subdomains: 'abc',
    maxZoom: 19
  }).addTo(scanMap);
  Lmap.control.attribution({prefix: false, position: 'bottomright'}).addTo(scanMap);
  scanLayer = Lmap.layerGroup().addTo(scanMap);
  scanMap.setView([20, 0], 1);
  setTimeout(function() { if (scanMap) scanMap.invalidateSize(); }, 80);
  ensureOperatorGeo();
  refreshScanMap();
  bindScanSearch();
}
function refreshScanMap() {
  if (!scanMap || !scanLayer) return;
  const sites = collectSites();
  const empty = document.getElementById('scan-map-empty');
  const pending = [];
  sites.forEach(function(site) {
    if (hasGeo(site.lat, site.lng)) return;
    const withAddr = site.items.find(function(it) { return String(it.address || '').trim(); });
    if (withAddr) pending.push(geocodeAddress(withAddr.address).then(function(pos) {
      if (pos) { site.lat = pos.lat; site.lng = pos.lng; }
    }));
  });
  Promise.all(pending).then(function() {
    scanLayer.clearLayers();
    const placed = [];
    sites.forEach(function(site) {
      if (!hasGeo(site.lat, site.lng) && site.key === 'interior' && operatorGeo) {
        site.lat = operatorGeo.lat;
        site.lng = operatorGeo.lng;
      }
      if (!hasGeo(site.lat, site.lng)) return;
      placed.push(site);
      const Lmap = window.L;
      if (!Lmap) return;
      const icon = Lmap.divIcon({className: '', html: '<div class="scan-pin"></div>', iconSize: [14, 14], iconAnchor: [7, 7]});
      const marker = Lmap.marker([site.lat, site.lng], {icon: icon, title: site.label + ' (latest)'});
      marker.on('click', function() { openLatestSite(site); });
      marker.bindTooltip(site.label, {direction: 'top', offset: [0, -8], opacity: 0.95});
      marker.addTo(scanLayer);
    });
    if (empty) empty.classList.toggle('hide', placed.length > 0);
    const key = placed.map(function(s) { return s.key + ':' + s.lat.toFixed(4) + ',' + s.lng.toFixed(4); }).join('|');
    if (placed.length === 0) {
      scanFittedKey = '';
      return;
    }
    if (key === scanFittedKey) return;
    scanFittedKey = key;
    if (placed.length === 1) {
      scanMap.setView([placed[0].lat, placed[0].lng], 16);
    } else {
      scanMap.fitBounds(placed.map(function(s) { return [s.lat, s.lng]; }), {padding: [18, 18], maxZoom: 16});
    }
    scanMap.invalidateSize();
  });
  if (sites.some(function(s) { return !hasGeo(s.lat, s.lng); })) ensureOperatorGeo();
}
let searchTimer = 0;
function historySearch(q) {
  return fetch('/search?q=' + encodeURIComponent(q), {cache: 'no-store'}).then(function(r) {
    return r.json();
  }).then(function(res) {
    return (res && Array.isArray(res.hits)) ? res.hits : [];
  }).catch(function() { return []; });
}
function refreshHistoryFilter(keepFocus) {
  lastSidebarKey = '';
  if (lastDemo) renderDots(lastDemo);
  else restoreHistorySearch(keepFocus);
}
function fetchHistoryMatches(q) {
  historySearch(q).then(function(hits) {
    if (String(lastSearchQuery || '').trim() !== q) return;
    const next = {models: {}, videos: {}};
    (hits || []).forEach(function(h) {
      if (h && h.model) next.models[h.model] = true;
      if (h && h.video) next.videos[h.video] = true;
    });
    historyFilterHits = next;
    refreshHistoryFilter(true);
  });
}
function bindScanSearch() {
  const input = document.getElementById('scan-search');
  if (!input || input.getAttribute('data-bound')) return;
  input.setAttribute('data-bound', '1');
  input.addEventListener('input', function() {
    lastSearchQuery = input.value;
    historyFilterHits = {models: {}, videos: {}};
    refreshHistoryFilter(true);
    clearTimeout(searchTimer);
    const q = input.value.trim();
    if (!q) return;
    searchTimer = setTimeout(function() { fetchHistoryMatches(q); }, 280);
  });
  input.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
      lastSearchQuery = '';
      historyFilterHits = {models: {}, videos: {}};
      input.value = '';
      refreshHistoryFilter(false);
      input.blur();
    }
  });
}
let playerName = '';
let playerTasks = [];
let playerPoll = 0;
function fmtClock(s) {
  const n = Math.max(0, Math.round(Number(s) || 0));
  const m = Math.floor(n / 60);
  const r = n - m * 60;
  return m + ':' + (r < 10 ? '0' : '') + r;
}
function findListedVideo(name) {
  const all = currentVideoList.concat(videoList);
  for (let i = 0; i < all.length; i++) {
    if (all[i].name === name) return all[i];
  }
  return null;
}
function setSummarizeBtn(status) {
  const btn = document.getElementById('player-summarize');
  if (!btn) return;
  const busy = status === 'pending' || status === 'processing';
  btn.disabled = busy;
  if (busy) btn.textContent = 'Summarizing';
  else if (status === 'ready') btn.textContent = 'Refresh';
  else btn.textContent = 'Summarize';
}
function highlightPlayerTask(t) {
  const box = document.getElementById('player-tasks');
  if (!box) return;
  const rows = box.querySelectorAll('[data-task]');
  for (let i = 0; i < rows.length; i++) {
    const task = playerTasks[i];
    if (!task) continue;
    const start = Number(task.start_s) || 0;
    const end = Number(task.end_s) || start;
    const on = t >= start && (i === playerTasks.length - 1 ? t <= end + 0.4 : t < end);
    rows[i].classList.toggle('on', on);
  }
}
function renderPlayerTasks(tasks, t) {
  const box = document.getElementById('player-tasks');
  if (!box) return;
  playerTasks = Array.isArray(tasks) ? tasks : [];
  if (!playerTasks.length) {
    box.innerHTML = '';
    return;
  }
  box.innerHTML = playerTasks.map(function(task, i) {
    const start = Number(task.start_s) || 0;
    return '<button type="button" class="player-task" data-task="' + i + '">' +
      '<div class="t"><em>' + esc(fmtClock(start)) + '</em><span>' + esc(task.title || ('Task ' + (i + 1))) + '</span></div>' +
      (task.description ? '<p>' + esc(task.description) + '</p>' : '') +
      '</button>';
  }).join('');
  highlightPlayerTask(t);
}
function applyAnalysis(data) {
  const text = document.getElementById('player-sum-text');
  const status = (data && data.status) || '';
  const summary = (data && data.summary) || '';
  setSummarizeBtn(status);
  if (status === 'ready' && summary) {
    text.classList.remove('muted');
    text.textContent = summary;
    renderPlayerTasks(data.tasks || [], document.getElementById('player-video').currentTime || 0);
    return;
  }
  text.classList.add('muted');
  renderPlayerTasks([], 0);
  if (status === 'pending' || status === 'processing') {
    text.textContent = 'Summarizing...';
  } else if (status === 'unavailable') {
    text.textContent = 'Summary is unavailable.';
  } else if (status === 'error') {
    text.textContent = 'Could not summarize. Try again.';
  } else {
    text.textContent = 'Summarize this walk to list completed tasks.';
  }
}
function stopPlayerPoll() {
  if (playerPoll) {
    clearInterval(playerPoll);
    playerPoll = 0;
  }
}
function loadAnalysis(name, kick) {
  if (!name) return;
  const req = kick
    ? fetch('/videos/' + encodeURIComponent(name) + '/summarize', {method: 'POST', cache: 'no-store'})
    : fetch('/videos/' + encodeURIComponent(name) + '/analysis', {cache: 'no-store'});
  req.then(function(r) { return r.json(); }).then(function(data) {
    if (playerName !== name) return;
    applyAnalysis(data);
    const status = (data && data.status) || '';
    if (status === 'pending' || status === 'processing') {
      if (!playerPoll) playerPoll = setInterval(function() { loadAnalysis(name, false); }, 2500);
    } else {
      stopPlayerPoll();
    }
  }).catch(function() {});
}
function openPlayer(name, opts) {
  const wrap = document.getElementById('player');
  const video = document.getElementById('player-video');
  const title = document.getElementById('player-title');
  if (!wrap || !video) return;
  playerName = name;
  const meta = (currentVideoList.concat(videoList)).find(function(v) { return v.name === name; });
  title.textContent = recName(meta || {name: name});
  video.src = '/videos/' + encodeURIComponent(name);
  wrap.classList.toggle('docked', !!(opts && opts.dock));
  wrap.classList.add('open');
  requestAnimationFrame(function() { resizeViewer(); });
  applyAnalysis({status: 'idle'});
  const rec = findListedVideo(name);
  const status = rec && rec.summary_status;
  loadAnalysis(name, !status || status === 'idle' || status === 'unavailable' || status === 'error');
  if (opts && opts.seek != null) {
    const seek = Number(opts.seek) || 0;
    const onMeta = function() {
      video.removeEventListener('loadedmetadata', onMeta);
      video.currentTime = seek;
    };
    video.addEventListener('loadedmetadata', onMeta);
  }
  video.play().catch(function() {});
}
function closePlayer() {
  const wrap = document.getElementById('player');
  const video = document.getElementById('player-video');
  if (!wrap || !video) return;
  stopPlayerPoll();
  playerName = '';
  playerTasks = [];
  video.pause();
  video.removeAttribute('src');
  video.load();
  wrap.classList.remove('open', 'docked');
  requestAnimationFrame(function() { resizeViewer(); });
}
function modelByName(name) {
  for (let i = 0; i < modelList.length; i++) {
    if (modelList[i].name === name) return modelList[i];
  }
  return null;
}
function setHistoryBanner(text) {
  const el = document.getElementById('view-banner');
  const liveBtn = document.getElementById('live-btn');
  if (el) {
    el.textContent = text || '';
    el.classList.toggle('show', !!text);
  }
  if (liveBtn) liveBtn.classList.toggle('on', !historyView);
}
function setLiveLayersVisible(on) {
  if (liveMesh) liveMesh.visible = on;
  if (bakedMesh) bakedMesh.visible = on;
  Object.keys(userGroups).forEach(function(id) {
    const g = userGroups[id];
    if (!g) return;
    g.visible = on;
    if (g.userData.trail) g.userData.trail.visible = on;
  });
}
function disposeHistoryMesh() {
  if (!historyMesh) return;
  if (historyMesh.material && historyMesh.material.map) historyMesh.material.map.dispose();
  disposeObj(historyMesh);
  historyMesh = null;
}
function closeHistoryModel() {
  if (!historyView && !historyMesh) return;
  historyView = null;
  treeOpen['recordings'] = true;
  disposeHistoryMesh();
  setLiveLayersVisible(true);
  setHistoryBanner('');
  lastMeshGen = -1;
  lastBakeGen = -1;
  if (lastDemo) applyDemo(lastDemo);
}
function openHistoryModel(name) {
  const meta = modelByName(name) || {name: name};
  historyView = meta;
  focusHistoryRecordings(meta);
  hideTag();
  const live = document.getElementById('live');
  if (live) {
    live.style.display = 'flex';
    live.classList.add('show');
  }
  if (!initViewer()) return;
  resizeViewer();
  setLiveLayersVisible(false);
  setHistoryBanner('Archive  ' + recName(meta));
  if (lastDemo) renderDots(lastDemo);
  setMapMsg('Loading model');
  const atlas = meta.atlas_url || '';
  const textured = meta.textured === true && !!atlas;
  fetchMeshBuffer('/models/' + encodeURIComponent(name)).then(function(buf) {
    if (!historyView || historyView.name !== name) return false;
    const geom = parsePly(buf);
    if (!geom) return false;
    const hasUv = !!geom.getAttribute('uv');
    if (!(textured && hasUv)) {
      return Promise.resolve(meshFromGeometry(geom, vertexColorMaterial(geom, true)));
    }
    return new Promise(function(resolve) {
      new THREE.TextureLoader().load(atlas, function(tex) {
        tex.colorSpace = THREE.SRGBColorSpace;
        tex.anisotropy = renderer ? renderer.capabilities.getMaxAnisotropy() : 1;
        tex.generateMipmaps = true;
        tex.minFilter = THREE.LinearMipmapLinearFilter;
        resolve(meshFromGeometry(geom, new THREE.MeshBasicMaterial({map: tex, side: THREE.DoubleSide})));
      }, undefined, function() {
        resolve(meshFromGeometry(geom, vertexColorMaterial(geom, true)));
      });
    });
  }).then(function(obj) {
    if (!historyView || historyView.name !== name) return;
    if (!obj) {
      setMapMsg('Model unavailable');
      return;
    }
    disposeHistoryMesh();
    historyMesh = obj;
    world.add(historyMesh);
    setLiveLayersVisible(false);
    setMapMsg('');
    meshFramed = false;
    fitCameraToMesh(obj.geometry);
  }).catch(function(err) {
    console.warn('archive load failed', err);
    if (historyView && historyView.name === name) setMapMsg('Model unavailable');
  });
}
function setBanner(demo, live) {
  renderDots(demo);
  setPhases(demo);
  setStats(demo);
}
// Physical size of the displayed marker. Browsers do not expose screen DPI, so
// estimate mm per CSS pixel from known Apple panels (the demo laptop), fall back
// to a typical value, and let the operator override with a ruler measurement.
// Whatever value wins is POSTed to /tag_size; phones read it back from /join
// and /demo, so their tag-distance estimate matches what is on the screen.
const TAG_BLACK_FRACTION = 0.6; // black square / PNG width (1-cell quiet zone each side)
let serverTagSizeM = TAG_SIZE_M;
let lastReportedTagM = 0;
function mmPerCssPx() {
  const w = screen.width, h = screen.height, dpr = window.devicePixelRatio || 1;
  const known = {
    '1512x982': 0.201,  // MacBook Pro 14 (2021+)
    '1728x1117': 0.200, // MacBook Pro 16 (2021+)
    '1470x956': 0.203,  // MacBook Air 13.6
    '1440x900': 0.199,  // MacBook Pro 13 / Air 13.3 (2x)
    '1280x832': 0.224,  // MacBook Air 13.3 at "more space"
    '1710x1112': 0.185, // MacBook Air 15
  };
  const key = w + 'x' + h;
  if (known[key]) return known[key];
  return dpr >= 2 ? 0.20 : 0.27;
}
function displayedBlackSquareMeters() {
  const img = document.getElementById('calib-tag-img');
  if (!img) return 0;
  const r = img.getBoundingClientRect();
  if (!r.width) return 0;
  return r.width * TAG_BLACK_FRACTION * mmPerCssPx() / 1000.0;
}
function manualTagSizeM() {
  const v = parseFloat(localStorage.getItem('collabTagSizeCm') || '');
  return (isFinite(v) && v > 2 && v < 200) ? v / 100.0 : 0;
}
function postTagSize(m) {
  if (!(m > 0.02 && m < 2.0)) return;
  if (Math.abs(m - lastReportedTagM) < 0.0005) return;
  lastReportedTagM = m;
  fetch('/tag_size', {method: 'POST', cache: 'no-store', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({tag_size_m: m})}).then(function(r) { return r.json(); }).then(function(res) {
    if (res && res.tag_size_m) serverTagSizeM = res.tag_size_m;
    refreshTagSizeLabel();
  }).catch(function() {});
}
function refreshTagSizeLabel() {
  const est = displayedBlackSquareMeters();
  const manual = manualTagSizeM();
  return manual || est;
}
function reportTagSize() {
  const used = refreshTagSizeLabel();
  if (used > 0) postTagSize(used);
}
(function wireTagSize() {
  const input = document.getElementById('tag-size-input');
  if (input) {
    input.addEventListener('change', function() {
      const cm = parseFloat(input.value);
      if (isFinite(cm) && cm > 2 && cm < 200) {
        localStorage.setItem('collabTagSizeCm', String(cm));
      } else {
        localStorage.removeItem('collabTagSizeCm');
      }
      lastReportedTagM = 0;
      reportTagSize();
    });
  }
  window.addEventListener('resize', function() { lastReportedTagM = 0; reportTagSize(); });
  const img = document.getElementById('calib-tag-img');
  if (img) img.addEventListener('load', reportTagSize);
})();
function showCalib(demo) {
  const tag = document.getElementById('calib-tag');
  if (tag) tag.style.display = 'flex';
  hideLive();
  setBanner(demo, false);
  if (typeof demo.tag_size_m === 'number') serverTagSizeM = demo.tag_size_m;
  reportTagSize();
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
let world = null;
// Two layers. bakedMesh: the phone-style assembled surface (Poisson, colored,
// cleaned) the server rebuilds when the phones pause. liveMesh: per-keyframe
// organizedFastMesh for everything newer than the bake, so new scans show up
// within a couple of seconds and get absorbed into the smooth surface later.
let liveMesh = null, bakedMesh = null, historyMesh = null, meshReady = false, meshFramed = false;
let lastMeshNodes = -1, lastMeshGen = -1, meshLoading = false, lastMeshAt = 0;
let lastBakeGen = -1, bakeMaxNode = 0, bakeLoading = false;
let lastStatus = null, lastDemo = null;
const userGroups = {};
function hexColor(hex) { return new THREE.Color(hex); }
function gToThree(v) {
  // Same mapping as the world group, for camera framing in scene coordinates.
  return new THREE.Vector3(-v.y, v.z, -v.x);
}
function disposeObj(obj) {
  if (!obj) return;
  world.remove(obj);
  if (obj.geometry) obj.geometry.dispose();
  if (obj.material) obj.material.dispose();
}
function disposeLiveMesh() {
  disposeObj(liveMesh);
  liveMesh = null;
}
function disposeBakedMesh() {
  disposeObj(bakedMesh);
  bakedMesh = null;
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
  // Frame from an elevated three-quarter view so the whole walk fits: the
  // camera backs off with the AABB diagonal (a 22 m loop needs ~15 m).
  const extent = Math.min(Math.max(size.length() * 0.7, 2.0), 40);
  const center = gToThree(centerG);
  camera.position.set(center.x + extent * 0.7, center.y + extent * 0.6, center.z + extent * 0.7);
  controls.target.copy(center);
  controls.update();
  meshFramed = true;
}
function refit() {
  const target = historyMesh || bakedMesh || liveMesh;
  if (target && target.geometry) {
    meshFramed = false;
    fitCameraToMesh(target.geometry);
  }
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
function parsePly(buf) {
  if (!buf || buf.byteLength < 20) return null;
  let geom = null;
  try {
    geom = new PLYLoader().parse(copyArrayBuffer(buf));
  } catch (e) {
    console.warn('PLY parse failed', e);
    return null;
  }
  const pos = geom.getAttribute('position');
  if (!pos || pos.count <= 0) return null;
  return geom;
}
function meshFromGeometry(geom, material) {
  const idx = geom.getIndex();
  const nIdx = idx ? idx.count : 0;
  const hasColor = !!geom.getAttribute('color');
  if (nIdx >= 3) {
    geom.computeVertexNormals();
    geom.computeBoundingSphere();
    return new THREE.Mesh(geom, material);
  }
  console.info('mesh has no faces, drawing points', geom.getAttribute('position').count);
  return new THREE.Points(geom, new THREE.PointsMaterial({
    size: 0.03, vertexColors: hasColor, color: hasColor ? 0xffffff : 0xA19F9B
  }));
}
function vertexColorMaterial(geom, baked) {
  const hasColor = !!geom.getAttribute('color');
  return new THREE.MeshStandardMaterial({
    vertexColors: hasColor,
    color: hasColor ? 0xffffff : 0xA19F9B,
    roughness: baked ? 0.82 : 0.88,
    metalness: 0.02,
    side: THREE.DoubleSide
  });
}
function buildMeshObject(buf, baked) {
  const geom = parsePly(buf);
  if (!geom) return null;
  return meshFromGeometry(geom, vertexColorMaterial(geom, baked));
}
// The bake's photo atlas, drawn unlit exactly like the phone's textured mesh.
function loadBakeTexture(gen) {
  return new Promise(function(resolve) {
    new THREE.TextureLoader().load('/map.bake.jpg?g=' + gen, function(tex) {
      tex.colorSpace = THREE.SRGBColorSpace;
      tex.anisotropy = renderer ? renderer.capabilities.getMaxAnisotropy() : 1;
      tex.generateMipmaps = true;
      tex.minFilter = THREE.LinearMipmapLinearFilter;
      resolve(tex);
    }, undefined, function(err) {
      console.warn('bake atlas failed', err);
      resolve(null);
    });
  });
}
function applyMeshBuffer(buf) {
  const obj = buildMeshObject(buf, false);
  disposeLiveMesh();
  if (!obj) {
    if (!meshReady) setMapMsg('Awaiting keyframes');
    return false;
  }
  liveMesh = obj;
  world.add(liveMesh);
  meshReady = true;
  setMapMsg('');
  if (!meshFramed) fitCameraToMesh(obj.geometry);
  return true;
}
function placeBaked(obj) {
  disposeBakedMesh();
  bakedMesh = obj;
  world.add(bakedMesh);
  meshReady = true;
  setMapMsg('');
  if (!meshFramed) fitCameraToMesh(obj.geometry);
  return true;
}
// Textured when the PLY carries UVs and the atlas downloads; vertex colors otherwise.
function applyBakedBuffer(buf, textured, gen) {
  const geom = parsePly(buf);
  if (!geom) return Promise.resolve(false);
  const hasUv = !!geom.getAttribute('uv');
  if (!(textured && hasUv)) {
    return Promise.resolve(placeBaked(meshFromGeometry(geom, vertexColorMaterial(geom, true))));
  }
  return loadBakeTexture(gen).then(function(tex) {
    if (!tex) return placeBaked(meshFromGeometry(geom, vertexColorMaterial(geom, true)));
    const mat = new THREE.MeshBasicMaterial({ map: tex, side: THREE.DoubleSide });
    console.info('bake textured atlas ' + tex.image.width + 'x' + tex.image.height);
    return placeBaked(meshFromGeometry(geom, mat));
  });
}
// Assembled surface: refetch when the server reports a new bake generation.
function loadBake(bakeGen, maxNode, textured) {
  if (bakeLoading) return;
  if (!(bakeGen > 0) || bakeGen === lastBakeGen) return;
  bakeLoading = true;
  fetchMeshBuffer('/map.mesh?bake=1').then(function(buf) {
    lastBakeGen = bakeGen;
    if (!buf) return false;
    return applyBakedBuffer(buf, textured === true, bakeGen);
  }).then(function(ok) {
    if (ok) {
      bakeMaxNode = maxNode || 0;
      // The overlay must now only carry nodes newer than this bake.
      lastMeshGen = -1;
      console.info('bake applied gen=' + bakeGen + ' up to node ' + bakeMaxNode);
    }
  }).catch(function(err) {
    console.warn('bake load failed', err);
  }).then(function() { bakeLoading = false; });
}
// Live layer: everything (no bake yet) or only nodes newer than the bake.
function loadMesh(nodes, meshGen) {
  if (meshLoading) return;
  const changed = nodes !== lastMeshNodes || meshGen !== lastMeshGen;
  if (!changed && meshReady) return;
  meshLoading = true;
  // Overlay only when the bake actually covers most of the room. A leftover
  // bake of a couple of nodes (typical after a restart) must not hide the
  // live mesh of the rest of the walk.
  const bakeCoversRoom = !!(bakedMesh && bakeMaxNode > 0 && nodes > 0 && bakeMaxNode * 2 >= nodes);
  const reqSince = bakeCoversRoom ? bakeMaxNode : -1;
  const url = reqSince >= 0 ? ('/map.mesh?since_node=' + reqSince) : '/map.mesh';
  fetchMeshBuffer(url).then(function(buf) {
    lastMeshNodes = nodes;
    lastMeshGen = meshGen;
    lastMeshAt = Date.now();
    if (!buf) {
      // Nothing newer than the bake (or nothing at all yet).
      if (bakedMesh) { disposeLiveMesh(); }
      else if (!meshReady) setMapMsg('Awaiting keyframes');
    } else {
      applyMeshBuffer(buf);
    }
    if ((bakedMesh ? bakeMaxNode : -1) !== reqSince) lastMeshGen = -1;
  }).catch(function(err) {
    console.warn('mesh load failed', err);
    if (!meshReady) setMapMsg('Awaiting keyframes');
  }).then(function() { meshLoading = false; });
}
function phoneMarkerLabel(id, index) {
  const last4 = (id && id.length >= 4) ? id.slice(-4) : (id || ('P' + (index + 1)));
  return 'UNIT-' + pad2(index + 1) + ' / ' + last4;
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
  ctx.fillStyle = 'rgba(22,21,20,0.88)';
  ctx.beginPath();
  ctx.rect(8, 24, 624, 112);
  ctx.fill();
  ctx.strokeStyle = color.getStyle ? color.getStyle() : '#A19F9B';
  ctx.lineWidth = 3;
  ctx.stroke();
  ctx.fillStyle = '#DBDAD9';
  ctx.font = '600 56px Inter, sans-serif';
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
  const darkMat = new THREE.MeshStandardMaterial({ color: 0x2B2A28, roughness: 0.45, metalness: 0.2 });
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
    new THREE.LineBasicMaterial({ color: 0xDBDAD9 })
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
const held = Object.create(null);
const flyClock = new THREE.Clock();
function typingInField() {
  const el = document.activeElement;
  if (!el) return false;
  const tag = (el.tagName || '').toLowerCase();
  if (tag === 'textarea' || tag === 'select') return true;
  if (tag === 'input') {
    const type = String(el.type || 'text').toLowerCase();
    return type !== 'button' && type !== 'submit' && type !== 'checkbox' && type !== 'radio' &&
      type !== 'range' && type !== 'file' && type !== 'color';
  }
  return !!el.isContentEditable;
}
function mapKeysActive() {
  const live = document.getElementById('live');
  const confirm = document.getElementById('confirm');
  return !!(live && live.classList.contains('show') && confirm && !confirm.classList.contains('open') &&
    !typingInField());
}
function flyCamera(dt) {
  if (!camera || !controls || !mapKeysActive()) return;
  const boost = held.ShiftLeft || held.ShiftRight;
  const speed = (boost ? 14 : 5.5) * dt;
  const forward = new THREE.Vector3();
  camera.getWorldDirection(forward);
  forward.y = 0;
  if (forward.lengthSq() < 1e-6) forward.set(0, 0, -1);
  else forward.normalize();
  const right = new THREE.Vector3().crossVectors(forward, camera.up).normalize();
  const delta = new THREE.Vector3();
  if (held.KeyW || held.ArrowUp) delta.add(forward);
  if (held.KeyS || held.ArrowDown) delta.sub(forward);
  if (held.KeyA || held.ArrowLeft) delta.sub(right);
  if (held.KeyD || held.ArrowRight) delta.add(right);
  if (held.KeyE) delta.y += 1;
  if (held.KeyQ) delta.y -= 1;
  if (delta.lengthSq() === 0) return;
  delta.normalize().multiplyScalar(speed);
  camera.position.add(delta);
  controls.target.add(delta);
}
function tick() {
  requestAnimationFrame(tick);
  flyCamera(Math.min(flyClock.getDelta(), 0.05));
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
  renderer.setClearColor(0x161514, 1);
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(60, 1, 0.05, 200);
  camera.position.set(2.2, 1.8, 2.2);
  controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  controls.enablePan = true;
  controls.screenSpacePanning = true;
  controls.panSpeed = 1.1;
  controls.minDistance = 0.12;
  controls.maxDistance = 80;
  controls.target.set(0, 0, 0);
  // G (rtabmap, z up) -> three (y up): G.x -> -Z, G.y -> -X, G.z -> +Y.
  world = new THREE.Group();
  world.matrixAutoUpdate = false;
  world.matrix.makeBasis(
    new THREE.Vector3(0, 0, -1),
    new THREE.Vector3(-1, 0, 0),
    new THREE.Vector3(0, 1, 0));
  scene.add(world);
  scene.add(new THREE.AmbientLight(0xdbdad9, 0.32));
  scene.add(new THREE.HemisphereLight(0xdbdad9, 0x1F1E1D, 0.62));
  const key = new THREE.DirectionalLight(0xdbdad9, 0.85);
  key.position.set(2.4, 4.2, 2.8);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xA19F9B, 0.18);
  fill.position.set(-2.2, 1.4, -1.6);
  scene.add(fill);
  // Start tag origin, drawn as a small square in the tag plane (G y-z plane).
  const origin = new THREE.Mesh(new THREE.SphereGeometry(0.04, 12, 10), new THREE.MeshBasicMaterial({ color: 0xA19F9B }));
  world.add(origin);
  const tagPlane = new THREE.Mesh(
    new THREE.PlaneGeometry(TAG_SIZE_M, TAG_SIZE_M),
    new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, transparent: true, opacity: 0.55 }));
  tagPlane.rotation.y = Math.PI / 2;
  world.add(tagPlane);
  window.addEventListener('resize', resizeViewer);
  if (window.ResizeObserver) {
    new ResizeObserver(resizeViewer).observe(document.getElementById('map-wrap'));
  }
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
  if (!initViewer()) return;
  resizeViewer();
  if (historyView) {
    setLiveLayersVisible(false);
    setHistoryBanner('Archive  ' + recName(historyView));
    return;
  }
  setHistoryBanner('');
  updateUsers(demo);
  const nodes = demo.global_nodes || 0;
  const meshGen = demo.mesh_gen || 0;
  if (!meshReady) setMapMsg('Awaiting keyframes');
  if (demo.mesh_baked) {
    loadBake(demo.bake_gen || 0, demo.bake_max_node || 0, demo.bake_textured === true);
  }
  loadMesh(nodes, meshGen);
}
function applyDemo(demo) {
  if (!demo || demo.ok === false) return;
  lastDemo = demo;
  if (historyView) {
    showLive(demo);
    return;
  }
  if (shouldShowMap(demo)) showLive(demo);
  else showCalib(demo);
}
function resetRoom() {
  lastSidebarKey = '';
  lastMeshNodes = -1;
  lastMeshGen = -1;
  lastMeshAt = 0;
  lastBakeGen = -1;
  bakeMaxNode = 0;
  meshReady = false;
  meshFramed = false;
  if (scene) { disposeLiveMesh(); disposeBakedMesh(); }
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
    if (lastDemo) renderDots(lastDemo);
  }).catch(function() {});
}
document.getElementById('dots').addEventListener('click', function(e) {
  const rec = e.target.closest('[data-video]');
  if (rec && this.contains(rec)) {
    openPlayer(rec.getAttribute('data-video'));
    return;
  }
  const model = e.target.closest('[data-model]');
  if (model && this.contains(model)) {
    openHistoryModel(model.getAttribute('data-model'));
    return;
  }
  const row = e.target.closest('[data-toggle]');
  if (!row || !this.contains(row)) return;
  const path = row.getAttribute('data-toggle');
  const next = !row.parentElement.classList.contains('open');
  treeOpen[path] = next;
  row.parentElement.classList.toggle('open', next);
  row.classList.toggle('open', next);
});
document.getElementById('reset-btn').addEventListener('click', function() { setConfirm(true); });
document.getElementById('confirm-no').addEventListener('click', function() { setConfirm(false); });
document.getElementById('confirm-go').addEventListener('click', function() { setConfirm(false); resetRoom(); });
document.getElementById('confirm').addEventListener('click', function(e) {
  if (e.target === this) setConfirm(false);
});
document.getElementById('opt-btn').addEventListener('click', optimizeNow);
document.getElementById('fit-btn').addEventListener('click', refit);
document.getElementById('live-btn').addEventListener('click', closeHistoryModel);
window.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') {
    if (document.getElementById('player') && document.getElementById('player').classList.contains('open')) {
      closePlayer();
      return;
    }
    if (historyView) {
      closeHistoryModel();
      return;
    }
    setConfirm(false);
  }
  if (typingInField()) return;
  if (e.key === 'f' || e.key === 'F') refit();
  held[e.code] = true;
  if (mapKeysActive() && (e.code === 'KeyW' || e.code === 'KeyA' || e.code === 'KeyS' ||
      e.code === 'KeyD' || e.code === 'KeyQ' || e.code === 'KeyE' ||
      e.code === 'ArrowUp' || e.code === 'ArrowDown' || e.code === 'ArrowLeft' || e.code === 'ArrowRight')) {
    e.preventDefault();
  }
});
window.addEventListener('keyup', function(e) { held[e.code] = false; });
window.addEventListener('blur', function() {
  Object.keys(held).forEach(function(k) { held[k] = false; });
});
tickClock();
setInterval(tickClock, 1000);
pollVideos();
pollModels();
pollRuns();
setInterval(pollVideos, 5000);
setInterval(pollModels, 5000);
setInterval(pollRuns, 5000);
initScanMap();
document.getElementById('player-close').addEventListener('click', closePlayer);
document.getElementById('player').addEventListener('click', function(e) {
  if (e.target === this && !this.classList.contains('docked')) closePlayer();
});
document.getElementById('player-summarize').addEventListener('click', function() {
  if (playerName) loadAnalysis(playerName, true);
});
document.getElementById('player-tasks').addEventListener('click', function(e) {
  const row = e.target.closest('[data-task]');
  const video = document.getElementById('player-video');
  if (!row || !video) return;
  const task = playerTasks[Number(row.getAttribute('data-task'))];
  if (!task) return;
  video.currentTime = Number(task.start_s) || 0;
  video.play().catch(function() {});
  highlightPlayerTask(video.currentTime);
});
document.getElementById('player-video').addEventListener('timeupdate', function() {
  if (playerTasks.length) highlightPlayerTask(this.currentTime || 0);
});
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
