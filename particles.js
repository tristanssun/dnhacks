export function initParticleText(canvas, options = {}) {
  if (!canvas) {
    return null;
  }

  const text = options.text ?? "MiniMap";
  const particleSize = options.particleSize ?? 2.1;
  const density = options.density ?? 13;
  const color = options.color ?? "#111111";
  const highlightColor = options.highlightColor ?? "#5c5a56";
  const scatter = options.scatter ?? 190;
  const gatherDuration = options.gatherDuration ?? 1600;
  const stagger = options.stagger ?? 420;
  const pointerRepel = options.pointerRepel ?? 42;
  const repelRadius = options.repelRadius ?? 120;
  const idleDrift = options.idleDrift ?? 1.6;
  const glow = options.glow ?? false;
  const fontFamily = options.fontFamily ?? '"Helvetica Neue", Helvetica, Arial, sans-serif';
  const fontWeight = options.fontWeight ?? 700;

  const ctx = canvas.getContext("2d", { alpha: true });
  const pointer = { x: 0, y: 0, on: false };
  let particles = [];
  let width = 0;
  let height = 0;
  let started = false;
  let startAt = 0;
  let raf = 0;
  let dotSize = particleSize;

  function hexToRgb(hex) {
    const n = hex.replace("#", "");
    const v = n.length === 3 ? n.split("").map((c) => c + c).join("") : n;
    return {
      r: parseInt(v.slice(0, 2), 16),
      g: parseInt(v.slice(2, 4), 16),
      b: parseInt(v.slice(4, 6), 16),
    };
  }

  const rgbA = hexToRgb(color);
  const rgbB = hexToRgb(highlightColor);

  function mix(t) {
    return {
      r: Math.round(rgbA.r + (rgbB.r - rgbA.r) * t),
      g: Math.round(rgbA.g + (rgbB.g - rgbA.g) * t),
      b: Math.round(rgbA.b + (rgbB.b - rgbA.b) * t),
    };
  }

  function easeOut(t) {
    const x = Math.min(1, Math.max(0, t));
    return 1 - (1 - x) ** 3;
  }

  function sample() {
    const nextW = Math.max(1, Math.round(canvas.clientWidth));
    const nextH = Math.max(1, Math.round(canvas.clientHeight));
    if (nextW < 8 || nextH < 8) {
      requestAnimationFrame(sample);
      return;
    }

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const narrow = nextW < 500;
    width = nextW;
    height = nextH;
    canvas.width = Math.floor(nextW * dpr);
    canvas.height = Math.floor(nextH * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const off = document.createElement("canvas");
    off.width = nextW;
    off.height = nextH;
    const octx = off.getContext("2d", { willReadFrequently: true });
    let size = narrow
      ? Math.min(nextH * 0.22, nextW * 0.24)
      : Math.min(nextH * 0.42, nextW * 0.18);
    octx.font = `${fontWeight} ${size}px ${fontFamily}`;
    const measured = octx.measureText(text).width;
    const maxWidth = nextW * (narrow ? 0.86 : 0.88);
    if (measured > maxWidth) {
      size *= maxWidth / Math.max(measured, 1);
      octx.font = `${fontWeight} ${size}px ${fontFamily}`;
    }
    octx.fillStyle = "#000";
    octx.textAlign = "center";
    octx.textBaseline = "middle";
    octx.fillText(text, nextW / 2, nextH / 2);

    const data = octx.getImageData(0, 0, off.width, off.height).data;
    const next = [];
    const step = narrow
      ? Math.max(3, Math.round(size / 20))
      : Math.max(2, density);
    const skip = narrow ? 0.04 : 0.16;
    const jitter = step * (narrow ? 0.28 : 0.7);
    dotSize = narrow ? Math.max(particleSize, step * 0.52) : particleSize;
    for (let y = 0; y < off.height; y += step) {
      for (let x = 0; x < off.width; x += step) {
        if (data[(y * off.width + x) * 4 + 3] < 90) {
          continue;
        }
        if (Math.random() < skip) {
          continue;
        }
        const angle = Math.random() * Math.PI * 2;
        const dist = Math.random() * scatter;
        const tx = x + (Math.random() - 0.5) * jitter;
        const ty = y + (Math.random() - 0.5) * jitter;
        next.push({
          tx,
          ty,
          sx: tx + Math.cos(angle) * dist,
          sy: ty + Math.sin(angle) * dist,
          x: tx + Math.cos(angle) * dist,
          y: ty + Math.sin(angle) * dist,
          delay: Math.random() * stagger,
          tint: Math.random(),
          phase: Math.random() * Math.PI * 2,
          size: 0.65 + Math.random() * 0.7,
        });
      }
    }
    particles = next;
    if (started) {
      startAt = performance.now();
    }
  }

  function replay() {
    particles.forEach((p) => {
      const angle = Math.random() * Math.PI * 2;
      const dist = Math.random() * scatter;
      p.sx = p.tx + Math.cos(angle) * dist;
      p.sy = p.ty + Math.sin(angle) * dist;
      p.delay = Math.random() * stagger;
    });
    startAt = performance.now();
    started = true;
  }

  function start() {
    if (!particles.length) {
      sample();
    }
    replay();
  }

  function draw(now) {
    raf = requestAnimationFrame(draw);
    ctx.clearRect(0, 0, width, height);
    if (!particles.length) {
      return;
    }
    const t0 = started ? startAt : now;
    particles.forEach((p) => {
      const gather = easeOut((now - t0 - p.delay) / gatherDuration);
      let x = p.sx + (p.tx - p.sx) * gather;
      let y = p.sy + (p.ty - p.sy) * gather;
      if (gather > 0.98) {
        x += Math.sin(now * 0.0012 + p.phase) * idleDrift;
        y += Math.cos(now * 0.001 + p.phase) * idleDrift;
      }
      if (pointer.on) {
        const dx = x - pointer.x;
        const dy = y - pointer.y;
        const d2 = dx * dx + dy * dy;
        const r2 = repelRadius * repelRadius;
        if (d2 < r2 && d2 > 0.01) {
          const d = Math.sqrt(d2);
          const force = (1 - d / repelRadius) * pointerRepel;
          x += (dx / d) * force;
          y += (dy / d) * force;
        }
      }
      p.x = x;
      p.y = y;
      const rgb = mix(p.tint * 0.55);
      if (glow) {
        ctx.fillStyle = `rgba(${rgb.r},${rgb.g},${rgb.b},0.16)`;
        ctx.beginPath();
        ctx.arc(x, y, dotSize * 2.4, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.fillStyle = `rgb(${rgb.r},${rgb.g},${rgb.b})`;
      ctx.beginPath();
      ctx.arc(x, y, dotSize * p.size, 0, Math.PI * 2);
      ctx.fill();
    });
  }

  function onPointer(event) {
    const rect = canvas.getBoundingClientRect();
    pointer.x = event.clientX - rect.left;
    pointer.y = event.clientY - rect.top;
    pointer.on = true;
  }

  const pointerRoot = options.pointerRoot ?? canvas;
  pointerRoot.addEventListener("pointermove", onPointer);
  pointerRoot.addEventListener("pointerenter", onPointer);
  pointerRoot.addEventListener("pointerleave", () => {
    pointer.on = false;
  });

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting && !started) {
          start();
        }
      });
    },
    { threshold: 0.28 },
  );
  io.observe(canvas);

  const ready = document.fonts?.ready ?? Promise.resolve();
  ready.then(() => {
    sample();
    raf = requestAnimationFrame(draw);
  });

  window.addEventListener("resize", () => {
    sample();
  });

  return { start, replay };
}
