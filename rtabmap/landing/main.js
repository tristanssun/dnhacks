import { initMap } from "./map.js?v=5";

history.scrollRestoration = "manual";
window.scrollTo(0, 0);

const lenis = new Lenis({
  autoRaf: true,
  anchors: true,
  prevent: (node) => !!node.closest("#map-wrap"),
});

const scrollHint = document.querySelector(".scroll-hint");
const phone = document.querySelector(".phone");
const hero = document.querySelector(".hero");
const feature = document.querySelector(".feature");
const laptop = document.querySelector(".laptop");
const command = document.querySelector(".command");
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
  map?.resize();
  map?.fit();
}

document.querySelector(".cmcs .tree")?.addEventListener("click", (event) => {
  const row = event.target.closest("[data-toggle]");
  if (!row) {
    return;
  }
  const node = row.closest(".tree-node");
  const open = !node?.classList.contains("open");
  node?.classList.toggle("open", open);
  row.classList.toggle("open", open);
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

function buildLaptopKeyboard() {
  const kb = document.querySelector(".kb");
  if (!kb || kb.firstChild) {
    return;
  }

  const rows = [
    ["w15", "", "", "", "", "", "", "", "", "", "", "", "", "w15"],
    ["", "", "", "", "", "", "", "", "", "", "", "", "", "w16"],
    ["w15", "", "", "", "", "", "", "", "", "", "", "", "", "w15"],
    ["w17", "", "", "", "", "", "", "", "", "", "", "", "w17"],
    ["w22", "", "", "", "", "", "", "", "", "", "", "w22"],
    ["w11", "w11", "w13", "space", "w13", "w11", "w11"],
  ];

  rows.forEach((keys) => {
    const row = document.createElement("div");
    row.className = "kb-row";
    keys.forEach((mod) => {
      const key = document.createElement("i");
      if (mod) {
        key.className = mod;
      }
      row.append(key);
    });
    kb.append(row);
  });
}

buildLaptopKeyboard();
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

  const start = command.offsetTop - window.innerHeight * 0.55;
  const fade = Math.min(1, Math.max(0, (scroll - start) / (window.innerHeight * 0.4)));
  laptop.style.opacity = String(fade);
}

lenis.scrollTo(0, { immediate: true });
syncPhone(0);
syncFeature(0);
syncLaptop(0);

lenis.on("scroll", ({ scroll }) => {
  scrollHint?.classList.toggle("is-hidden", scroll > 8);
  syncPhone(scroll);
  syncFeature(scroll);
  syncLaptop(scroll);
});

window.addEventListener("resize", () => {
  syncPhone(lenis.scroll);
  syncFeature(lenis.scroll);
  syncLaptop(lenis.scroll);
  scaleCmcs();
});

scrollHint?.addEventListener("click", (event) => {
  event.preventDefault();
  scrollHint.classList.add("is-hidden");
  lenis.scrollTo("#next");
});
