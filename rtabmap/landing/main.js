import { initMap } from "./map.js?v=18";
import { initParticleText } from "./particles.js?v=5";

history.scrollRestoration = "manual";
window.scrollTo(0, 0);

const lenis = new Lenis({
  autoRaf: true,
  anchors: true,
  prevent: (node) =>
    !!node.closest("#player") ||
    (document.body.classList.contains("is-map-full") && !!node.closest("#map-wrap")),
});

const scrollHint = document.querySelector(".scroll-hint");
const phone = document.querySelector(".phone");
const hero = document.querySelector(".hero");
const feature = document.querySelector(".feature");
const laptop = document.querySelector(".laptop");
const command = document.querySelector(".command");
const commandCopy = document.querySelector(".command-copy");
const intoMap = document.querySelector(".into-map");
const zoomStartEl = document.getElementById("zoom-start");
const mapWrap = document.getElementById("map-wrap");
const commandScene = document.querySelector(".command-scene");
const phoneVideo = document.querySelector(".phone-bezel video");

phoneVideo?.play().catch(() => {});

const cmcs = document.querySelector(".cmcs");
const laptopScreen = document.querySelector(".laptop-screen");
const map = initMap();
const sessionStart = Date.now();

function pad2(n) {
  return n < 10 ? `0${n}` : String(n);
}

function tickClock() {
  const el = document.getElementById("clock");
  if (!el) {
    return;
  }
  const s = Math.max(0, Math.floor((Date.now() - sessionStart) / 1000));
  el.textContent = `${pad2(Math.floor(s / 3600))}:${pad2(Math.floor((s % 3600) / 60))}:${pad2(s % 60)}`;
}

function scaleCmcs() {
  if (!cmcs || !laptopScreen) {
    return;
  }
  const scale = laptopScreen.clientWidth / 1280;
  cmcs.style.transform = `scale(${scale})`;
  if (!document.body.classList.contains("is-zooming")) {
    map?.resize();
    map?.fit();
  }
}

function clamp01(n) {
  return Math.min(1, Math.max(0, n));
}

function pageTop(el, scroll = window.scrollY || 0) {
  return el.getBoundingClientRect().top + scroll;
}

function zoomProgress(scroll) {
  if (!intoMap || !zoomStartEl) {
    return 0;
  }
  const start = pageTop(zoomStartEl, scroll);
  const end = start + intoMap.offsetHeight * 0.88;
  return clamp01((scroll - start) / Math.max(end - start, 1));
}

const player = document.getElementById("player");
const playerVideo = document.getElementById("player-video");
const playerTitle = document.getElementById("player-title");

function closePlayer() {
  player?.classList.remove("open");
  document.querySelectorAll(".cmcs .tree-row.rec.on").forEach((row) => {
    row.classList.remove("on");
  });
  if (playerVideo) {
    playerVideo.pause();
    playerVideo.removeAttribute("src");
    playerVideo.load();
  }
}

function openPlayer(row) {
  const src = row.getAttribute("data-video");
  if (!player || !playerVideo || !src) {
    return;
  }
  document.querySelectorAll(".cmcs .tree-row.rec.on").forEach((item) => {
    item.classList.remove("on");
  });
  row.classList.add("on");
  if (playerTitle) {
    playerTitle.textContent = row.getAttribute("title") || row.querySelector(".tree-name")?.textContent || "Recording";
  }
  playerVideo.src = src;
  player.classList.add("open");
  playerVideo.play().catch(() => {});
}

document.querySelector(".cmcs .tree")?.addEventListener("click", (event) => {
  const rec = event.target.closest("[data-video]");
  if (rec) {
    openPlayer(rec);
    return;
  }
  const row = event.target.closest("[data-toggle]");
  if (!row) {
    return;
  }
  const node = row.closest(".tree-node");
  const open = !node?.classList.contains("open");
  node?.classList.toggle("open", open);
  row.classList.toggle("open", open);
});

document.getElementById("player-close")?.addEventListener("click", closePlayer);
player?.addEventListener("click", (event) => {
  if (event.target === player) {
    closePlayer();
  }
});
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && player?.classList.contains("open")) {
    closePlayer();
  }
});

const confirm = document.getElementById("confirm");
document.getElementById("reset-btn")?.addEventListener("click", () => {
  confirm?.classList.add("open");
});
document.getElementById("confirm-no")?.addEventListener("click", () => {
  confirm?.classList.remove("open");
});
document.getElementById("confirm-go")?.addEventListener("click", () => {
  confirm?.classList.remove("open");
});

tickClock();
setInterval(tickClock, 1000);
scaleCmcs();

function phoneShift(scroll) {
  if (!phone || !hero) {
    return 0;
  }

  const heroH = hero.offsetHeight;
  const travel = heroH - phone.offsetHeight / 2;
  const progress = Math.min(1, Math.max(0, scroll / heroH));
  return progress * travel;
}

function scrollProgress(scroll) {
  if (!hero) {
    return 0;
  }

  return Math.min(1, Math.max(0, scroll / hero.offsetHeight));
}

function syncPhone(scroll) {
  if (!phone) {
    return;
  }

  phone.style.transform = `translate3d(0, ${phoneShift(scroll)}px, 0)`;
}

function syncFeature(scroll) {
  if (!feature) {
    return;
  }

  const fade = Math.min(1, Math.max(0, (scrollProgress(scroll) - 0.55) / 0.45));
  feature.style.opacity = String(fade);
}

function syncLaptop(scroll) {
  if (!laptop || !command) {
    return;
  }

  if (zoomProgress(scroll) > 0) {
    laptop.style.opacity = "1";
    if (commandCopy) {
      commandCopy.style.opacity = "1";
    }
    return;
  }
  const start = (zoomStartEl ? pageTop(zoomStartEl, scroll) : command.offsetTop) - window.innerHeight * 0.55;
  const fade = clamp01((scroll - start) / (window.innerHeight * 0.4));
  laptop.style.opacity = String(fade);
  if (commandCopy) {
    commandCopy.style.opacity = String(fade);
  }
}

let mapOrigin = null;

function captureMapOrigin() {
  if (!mapWrap || !commandScene) {
    return null;
  }
  commandScene.style.transform = "";
  const wrap = mapWrap.getBoundingClientRect();
  const host = commandScene.getBoundingClientRect();
  if (wrap.width < 8 || wrap.height < 8) {
    return null;
  }
  mapOrigin = {
    left: wrap.left,
    top: wrap.top,
    width: wrap.width,
    height: wrap.height,
    ox: wrap.left + wrap.width / 2 - host.left,
    oy: wrap.top + wrap.height / 2 - host.top,
  };
  return mapOrigin;
}

function syncZoom(scroll) {
  if (!mapWrap || !commandScene) {
    return;
  }

  const raw = zoomProgress(scroll);
  const t = raw * raw * (3 - 2 * raw);
  document.documentElement.style.setProperty("--zoom", String(t));
  const leftMap = !!zoomStartEl && !!intoMap && scroll >= pageTop(zoomStartEl, scroll) + intoMap.offsetHeight - 8;
  const mapFull = raw >= 0.995 && !leftMap;
  document.body.classList.toggle("is-zooming", raw > 0.001);
  document.body.classList.toggle("is-map-full", mapFull);
  document.getElementById("map-notes")?.setAttribute("aria-hidden", mapFull ? "false" : "true");

  if (raw <= 0.001) {
    commandScene.style.transform = "";
    commandScene.style.transformOrigin = "";
    captureMapOrigin();
    return;
  }

  const from = mapOrigin || captureMapOrigin();
  if (!from) {
    return;
  }

  const scale = Math.max(window.innerWidth / from.width, window.innerHeight / from.height);
  const fromX = from.left + from.width / 2;
  const fromY = from.top + from.height / 2;
  const x = (window.innerWidth / 2 - fromX) * t;
  const y = (window.innerHeight / 2 - fromY) * t;
  const s = 1 + (scale - 1) * t;
  commandScene.style.transformOrigin = `${from.ox}px ${from.oy}px`;
  commandScene.style.transform = `translate3d(${x}px, ${y}px, 0) scale(${s})`;
}

lenis.scrollTo(0, { immediate: true });

function applyScroll(scroll) {
  scrollHint?.classList.toggle("is-hidden", scroll > 8);
  syncPhone(scroll);
  syncFeature(scroll);
  syncLaptop(scroll);
  syncZoom(scroll);
}

applyScroll(0);
requestAnimationFrame(function tickScroll() {
  applyScroll(lenis.scroll);
  requestAnimationFrame(tickScroll);
});

window.addEventListener("resize", () => {
  mapOrigin = null;
  syncPhone(lenis.scroll);
  syncFeature(lenis.scroll);
  syncLaptop(lenis.scroll);
  scaleCmcs();
  syncZoom(lenis.scroll);
});

scrollHint?.addEventListener("click", (event) => {
  event.preventDefault();
  scrollHint.classList.add("is-hidden");
  lenis.scrollTo("#next");
});

document.querySelector(".map-next")?.addEventListener("click", (event) => {
  event.preventDefault();
  lenis.scrollTo("#footer");
});

initParticleText(document.getElementById("name-particles"), {
  text: "MiniMap",
  fontFamily: '"Helvetica Neue", Helvetica, Arial, sans-serif',
  fontWeight: 700,
  color: "#f4f1ea",
  highlightColor: "#dbdad9",
  density: 13,
  particleSize: 2.1,
  glow: false,
  idleDrift: 1.6,
});
