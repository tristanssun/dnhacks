#!/usr/bin/env python3
"""Charts for server/collab-run-proof.md in the navy-teal paper palette."""

from __future__ import annotations

import math
import os
import sqlite3
import struct
from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(__file__), "collab-run-proof")
DB = os.path.join(os.path.dirname(__file__), "..", "collab-data", "global.db")

# Sampled from the reference metabolite bars.
NAVY = "#1B1C48"
DEEP = "#085068"
MID = "#1C6D8F"
CYAN = "#2693B4"
LIGHT = "#55C0C8"
ICE = "#D6EEF2"
CYCLE = [NAVY, DEEP, MID, CYAN, LIGHT, ICE]
BG = "#FFFFFF"
TEXT = "#1B1C48"
TEXT2 = "#085068"
TEXT3 = "#5A6A72"
CHIP = "#F4FBFC"


def hex_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def font(size: int):
    for path in (
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/Arial.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


FONT_TITLE = font(28)
FONT = font(20)
FONT_S = font(18)
FONT_XS = font(16)


@dataclass
class Series:
    name: str
    data: list[float]
    color: str
    fill: bool = False


@dataclass
class RefLine:
    value: float
    label: str
    color: str = DEEP


@dataclass
class Chart:
    filename: str
    title: str
    x_label: str
    y_label: str
    categories: list[str]
    series: list[Series]
    kind: str = "line"
    y_min: float | None = 0
    y_max: float | None = None
    refs: list[RefLine] = field(default_factory=list)
    y_suffix: str = ""
    cycle_bars: bool = False


def nice_max(v: float) -> float:
    if v <= 0:
        return 1
    exp = 10 ** math.floor(math.log10(v))
    for m in (1, 2, 2.5, 5, 10):
        if v <= m * exp:
            return m * exp
    return 10 * exp


def ticks(lo: float, hi: float, n: int = 5) -> list[float]:
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / (n - 1)
    exp = 10 ** math.floor(math.log10(raw)) if raw > 0 else 1
    step = min((1, 2, 2.5, 5, 10), key=lambda m: abs(m * exp - raw)) * exp
    out = []
    x = lo
    for _ in range(n + 3):
        if x > hi + step * 0.01:
            break
        out.append(x)
        x += step
    if out[-1] < hi - step * 0.05:
        out.append(out[-1] + step)
    return out


def fmt(v: float, suffix: str = "") -> str:
    if abs(v) >= 1000:
        s = f"{v/1000:.0f}k" if v % 1000 == 0 or v >= 10000 else f"{v/1000:.1f}k"
    elif abs(v - round(v)) < 1e-6:
        s = str(int(round(v)))
    else:
        s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s + suffix


def render_png(c: Chart) -> None:
    W, H = 1520, 720 if c.kind == "bar" else 700
    L, T, R, B = 120, 118, 48, 90
    pw, ph = W - L - R, H - T - B
    all_vals = [v for s in c.series for v in s.data] + [r.value for r in c.refs]
    y0 = 0.0 if c.y_min is not None else min(all_vals)
    y1 = c.y_max if c.y_max is not None else nice_max(max(all_vals) * 1.08)
    if y1 <= y0:
        y1 = y0 + 1
    yticks = ticks(y0, y1)

    img = Image.new("RGB", (W, H), hex_rgb(BG))
    d = ImageDraw.Draw(img)

    d.text((L, 28), c.title, fill=hex_rgb(TEXT), font=FONT_TITLE)

    def x_at(i: int) -> float:
        n = max(len(c.categories) - 1, 1)
        return L + pw * (i / n)

    def y_at(v: float) -> float:
        return T + ph * (1 - (v - y0) / (y1 - y0))

    lx = L
    for s in c.series:
        d.rectangle((lx, 76, lx + 22, 80), fill=hex_rgb(s.color))
        d.text((lx + 30, 66), s.name, fill=hex_rgb(TEXT2), font=FONT_S)
        lx += 30 + int(d.textlength(s.name, font=FONT_S)) + 28

    for t in yticks:
        if t < y0 - 1e-9 or t > y1 + 1e-9:
            continue
        y = y_at(t)
        lab = fmt(t, c.y_suffix)
        tw = d.textlength(lab, font=FONT_XS)
        d.text((L - 14 - tw, y - 10), lab, fill=hex_rgb(TEXT3), font=FONT_XS)

    n = len(c.categories)
    step = 1 if n <= 14 else 2
    for i, lab in enumerate(c.categories):
        if i % step and i != n - 1:
            continue
        x = x_at(i) if c.kind == "line" else L + (i + 0.5) * (pw / n)
        tw = d.textlength(lab, font=FONT_XS)
        d.text((x - tw / 2, T + ph + 10), lab, fill=hex_rgb(TEXT3), font=FONT_XS)

    d.text((L + pw / 2 - d.textlength(c.x_label, font=FONT_S) / 2, H - 36), c.x_label, fill=hex_rgb(TEXT3), font=FONT_S)
    tmp = Image.new("RGBA", (400, 36), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((0, 0), c.y_label, fill=hex_rgb(TEXT3), font=FONT_S)
    rot = tmp.rotate(90, expand=True)
    img.paste(rot, (16, T + ph // 2 - rot.size[1] // 2), rot)

    for r in c.refs:
        y = y_at(r.value)
        x = L
        while x < L + pw:
            d.line((x, y, min(x + 8, L + pw), y), fill=hex_rgb(r.color), width=2)
            x += 14
        tw = d.textlength(r.label, font=FONT_XS) + 16
        d.rectangle((L + pw - tw, y - 12, L + pw, y + 12), fill=hex_rgb(CHIP), outline=hex_rgb(r.color), width=1)
        d.text((L + pw - tw + 8, y - 10), r.label, fill=hex_rgb(TEXT), font=FONT_XS)

    if c.kind == "line":
        for s in c.series:
            pts = [(x_at(i), y_at(v)) for i, v in enumerate(s.data)]
            if s.fill:
                poly = [(pts[0][0], y_at(y0))] + pts + [(pts[-1][0], y_at(y0))]
                overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
                od = ImageDraw.Draw(overlay)
                col = hex_rgb(s.color) + (36,)
                od.polygon(poly, fill=col)
                img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
                d = ImageDraw.Draw(img)
            d.line(pts, fill=hex_rgb(s.color), width=4, joint="curve")
            for x, y in pts:
                d.ellipse((x - 5, y - 5, x + 5, y + 5), fill=hex_rgb(BG), outline=hex_rgb(s.color), width=3)
    else:
        groups = 1 if c.cycle_bars else len(c.series)
        slot = pw / n
        bar_w = min(44.0, (slot * 0.72) / groups)
        gap = 4 if groups > 1 else 0
        total = groups * bar_w + (groups - 1) * gap
        for i in range(n):
            cx = L + (i + 0.5) * slot
            if c.cycle_bars:
                v = c.series[0].data[i]
                x = cx - bar_w / 2
                y = y_at(v)
                color = CYCLE[i % len(CYCLE)]
                d.rectangle((x, y, x + bar_w, y_at(y0)), fill=hex_rgb(color), outline=hex_rgb(NAVY) if color == ICE else hex_rgb(color))
            else:
                for gi, s in enumerate(c.series):
                    v = s.data[i]
                    x = cx - total / 2 + gi * (bar_w + gap)
                    y = y_at(v)
                    d.rectangle((x, y, x + bar_w, y_at(y0)), fill=hex_rgb(s.color))

    path = os.path.join(OUT, c.filename)
    img.save(path, "PNG")
    print("wrote", path)


def walk_png() -> None:
    con = sqlite3.connect(DB)
    cur = con.cursor()

    def parse_pose(blob):
        vals = struct.unpack("<" + "f" * (len(blob) // 4), blob)
        return vals[3], vals[7], vals[11]

    cur.execute("SELECT id, pose FROM Node ORDER BY id")
    poses = [(i, *parse_pose(b)) for i, b in cur.fetchall()]
    id_xy = {i: (x, y) for i, x, y, z in poses}
    cur.execute("SELECT from_id, to_id FROM Link WHERE type=4")
    seen, lcs = set(), []
    for a, b in cur.fetchall():
        k = tuple(sorted((a, b)))
        if k in seen or a not in id_xy or b not in id_xy:
            continue
        seen.add(k)
        lcs.append((id_xy[a], id_xy[b]))

    xs = [p[1] for p in poses]
    ys = [p[2] for p in poses]
    pad_m = 0.6
    xmin, xmax = min(xs) - pad_m, max(xs) + pad_m
    ymin, ymax = min(ys) - pad_m, max(ys) + pad_m

    W, H = 1520, 900
    L, T, R, B = 110, 120, 40, 80
    pw, ph = W - L - R, H - T - B

    def to_px(x, y):
        return L + (x - xmin) / (xmax - xmin) * pw, T + (ymax - y) / (ymax - ymin) * ph

    img = Image.new("RGB", (W, H), hex_rgb(BG))
    d = ImageDraw.Draw(img)
    d.text((L, 28), "Optimized camera path in the shared tag frame G", fill=hex_rgb(TEXT), font=FONT_TITLE)

    def legend(x, y, color, label, kind="line"):
        if kind == "dot":
            d.ellipse((x + 6, y - 6, x + 18, y + 6), fill=hex_rgb(color))
        else:
            d.line((x, y, x + 22, y), fill=hex_rgb(color), width=4)
        d.text((x + 30, y - 10), label, fill=hex_rgb(TEXT2), font=FONT_S)
        return x + 30 + int(d.textlength(label, font=FONT_S)) + 28

    lx = L
    lx = legend(lx, 82, NAVY, "Optimized keyframes")
    lx = legend(lx, 82, CYAN, "Local-time loop closures")
    legend(lx, 82, NAVY, "Start tag", "dot")

    def frange(a, b, step):
        x = math.ceil(a / step) * step
        while x <= b + 1e-9:
            yield round(x, 6)
            x += step

    for gx in frange(xmin, xmax, 2):
        x0, _ = to_px(gx, ymin)
        lab = f"{gx:.0f}"
        tw = d.textlength(lab, font=FONT_XS)
        d.text((x0 - tw / 2, T + ph + 12), lab, fill=hex_rgb(TEXT3), font=FONT_XS)
    for gy in frange(ymin, ymax, 2):
        _, y0 = to_px(xmin, gy)
        lab = f"{gy:.0f}"
        tw = d.textlength(lab, font=FONT_XS)
        d.text((L - 14 - tw, y0 - 10), lab, fill=hex_rgb(TEXT3), font=FONT_XS)

    d.text((L + pw / 2 - 30, H - 36), "X (m)", fill=hex_rgb(TEXT3), font=FONT)
    tmp = Image.new("RGBA", (200, 40), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((0, 0), "Y (m)", fill=hex_rgb(TEXT3), font=FONT)
    rot = tmp.rotate(90, expand=True)
    img.paste(rot, (18, T + ph // 2 - rot.size[1] // 2), rot)

    for (ax, ay), (bx, by) in lcs:
        d.line((*to_px(ax, ay), *to_px(bx, by)), fill=hex_rgb(CYAN), width=3)
    pts = [to_px(x, y) for _, x, y, _ in poses]
    d.line(pts, fill=hex_rgb(NAVY), width=3, joint="curve")
    sx, sy = to_px(poses[0][1], poses[0][2])
    ex, ey = to_px(poses[-1][1], poses[-1][2])
    d.ellipse((sx - 7, sy - 7, sx + 7, sy + 7), fill=hex_rgb(NAVY))
    d.ellipse((ex - 5, ey - 5, ex + 5, ey + 5), fill=hex_rgb(MID))

    path = os.path.join(OUT, "11-walk-path.png")
    img.save(path, "PNG")
    print("wrote", path)


CHARTS = [
    Chart(
        "01-nodes-lc.png",
        "Nodes and loop closures vs walk time",
        "Walk time (mm:ss)",
        "Count",
        ["0:00", "0:20", "0:40", "1:00", "1:20", "1:40", "2:00", "2:20", "2:40", "3:00", "3:20", "3:40"],
        [
            Series("Global nodes", [1, 20, 41, 60, 79, 100, 118, 136, 157, 172, 195, 211], NAVY, True),
            Series("Loop closures (rtabmap memory)", [0, 5, 7, 11, 14, 16, 18, 25, 29, 30, 31, 35], CYAN),
        ],
    ),
    Chart(
        "02-sync-latency.png",
        "POST /sync wall time vs map size",
        "Global node count",
        "Latency (s)",
        ["1", "20", "40", "60", "80", "100", "120", "140", "160", "180", "200", "211"],
        [Series("Sync wall time (s)", [1.72, 1.78, 1.83, 1.71, 1.92, 2.24, 1.99, 2.25, 4.77, 4.29, 7.81, 1.8], MID)],
        y_max=9,
        refs=[RefLine(1.92, "p50 1.92 s", DEEP)],
        y_suffix=" s",
    ),
    Chart(
        "03-mesh-rebuild.png",
        "Live mesh rebuild time",
        "Global node count",
        "Rebuild (ms)",
        ["20", "40", "60", "80", "100", "118", "124", "140", "160", "180", "211"],
        [Series("Rebuild (ms)", [40, 30, 30, 50, 70, 50, 510, 30, 50, 60, 20], MID)],
        refs=[RefLine(40, "p50 40 ms", DEEP)],
        y_suffix=" ms",
    ),
    Chart(
        "04-mesh-faces.png",
        "Live mesh face count (adaptive decimation)",
        "Global node count",
        "Faces",
        ["20", "40", "60", "80", "100", "118", "124", "140", "160", "180", "211"],
        [Series("Faces", [64662, 113338, 185053, 258244, 342736, 402604, 97023, 101661, 118620, 131502, 155540], DEEP, True)],
        y_max=500000,
        refs=[RefLine(500000, "500k budget", NAVY)],
    ),
    Chart(
        "05-room15-merge.png",
        "Room 15: interleaved uploads, 360 nodes, 130 closures",
        "Clock time (5 Sep)",
        "Count",
        ["19:58", "19:58.4", "19:58.6", "19:59.2", "19:59.6", "19:59.8", "20:00.1", "20:00.4", "20:00.8", "20:01.8", "20:03"],
        [
            Series("Phone A nodes (map 0)", [2, 7, 19, 33, 55, 70, 84, 98, 113, 192, 251], NAVY, True),
            Series("Phone B nodes (map 1)", [0, 7, 19, 25, 50, 68, 82, 97, 109, 109, 109], MID, True),
            Series("Loop closures", [0, 0, 2, 13, 13, 15, 18, 29, 93, 118, 130], CYAN),
        ],
    ),
    Chart(
        "06-room21-join.png",
        "Room 21: second phone joins, inter-map link stays at 1",
        "Clock time (6 Sep 00:xx)",
        "Count",
        ["19:19", "19:47", "20:00", "20:20", "20:40", "21:00", "21:21", "23:59"],
        [
            Series("Phone B nodes (map 0)", [2, 4, 5, 5, 5, 5, 5, 48], DEEP, True),
            Series("Phone A nodes (map 1)", [0, 1, 12, 32, 54, 72, 92, 92], CYAN, True),
            Series("Inter-map loop closures", [0, 1, 1, 1, 1, 1, 1, 1], NAVY),
        ],
    ),
    Chart(
        "07-rooms-nodes-lc.png",
        "Peak nodes and loop closures per room",
        "Room index",
        "Count",
        ["15", "19", "21", "22", "23", "26", "27", "28"],
        [
            Series("Peak nodes", [360, 272, 140, 415, 202, 170, 160, 211], NAVY),
            Series("Peak loop closures", [130, 22, 6, 18, 6, 15, 18, 35], CYAN),
        ],
        kind="bar",
    ),
    Chart(
        "08-rooms-sync-p50.png",
        "POST /sync p50 by room",
        "Room",
        "Latency (s)",
        ["15 2p", "19", "21 2p", "22", "23", "26", "27", "28"],
        [Series("POST /sync p50 (s)", [4.52, 2.01, 1.85, 1.99, 2.25, 2.85, 1.88, 1.92], MID)],
        kind="bar",
        cycle_bars=True,
        refs=[RefLine(2, "2 s", DEEP)],
        y_suffix=" s",
    ),
    Chart(
        "09-bake-time.png",
        "Assembled-surface bake time vs coverage",
        "Room / max node",
        "Bake time (s)",
        ["19/272", "21/140", "22/178", "22/400", "23/202", "26/170", "27/160", "28/211"],
        [Series("Bake time (s)", [97, 31.8, 55.8, 142.6, 54.3, 46.9, 39.0, 27.5], MID)],
        kind="bar",
        cycle_bars=True,
        y_suffix=" s",
    ),
    Chart(
        "10-texture.png",
        "Texture coverage on the assembled mesh",
        "Bake",
        "Faces textured (%)",
        ["Occlusion on", "R27/160", "R26/170", "R28/172", "R28/211"],
        [Series("Faces textured (%)", [44, 69.1, 72.6, 84.3, 84.4], MID)],
        kind="bar",
        cycle_bars=True,
        y_max=100,
        y_suffix="%",
    ),
]


def _lerp(a: str, b: str, t: float) -> tuple[int, int, int]:
    ar, ag, ab = hex_rgb(a)
    br, bg, bb = hex_rgb(b)
    t = max(0.0, min(1.0, t))
    return (
        int(ar + (br - ar) * t),
        int(ag + (bg - ag) * t),
        int(ab + (bb - ab) * t),
    )


def _ramp(t: float) -> tuple[int, int, int]:
    """Navy -> deep -> mid -> cyan -> light, matching the paper palette."""
    stops = [NAVY, DEEP, MID, CYAN, LIGHT]
    if t <= 0:
        return hex_rgb(stops[0])
    if t >= 1:
        return hex_rgb(stops[-1])
    x = t * (len(stops) - 1)
    i = int(x)
    return _lerp(stops[i], stops[min(i + 1, len(stops) - 1)], x - i)


FIG_W, FIG_H = 2200, 1980
FIG_GAP_X, FIG_GAP_Y = 48, 40
FIG_ML, FIG_MT, FIG_MR, FIG_MB = 36, 24, 36, 64


def figure_layout() -> tuple[int, int, dict[str, tuple[int, int]]]:
    pw = (FIG_W - FIG_ML - FIG_MR - FIG_GAP_X) // 2
    ph = (FIG_H - FIG_MT - FIG_MB - FIG_GAP_Y) // 2
    return pw, ph, {
        "A": (FIG_ML, FIG_MT),
        "B": (FIG_ML + pw + FIG_GAP_X, FIG_MT),
        "C": (FIG_ML, FIG_MT + ph + FIG_GAP_Y),
        "D": (FIG_ML + pw + FIG_GAP_X, FIG_MT + ph + FIG_GAP_Y),
    }


def finish_figure(img: Image.Image, filename: str, footer: str) -> None:
    d = ImageDraw.Draw(img)
    d.text((FIG_ML, FIG_H - 40), footer, fill=hex_rgb(TEXT3), font=font(18))
    path = os.path.join(OUT, filename)
    img.save(path, "PNG")
    print("wrote", path)


def draw_chart_panel(img: Image.Image, x0: int, y0: int, pw: int, ph: int, letter: str, c: Chart) -> Image.Image:
    """Draw one Chart into a 2x2 cell. Returns img (may replace after fill composite)."""
    d = ImageDraw.Draw(img)
    f_letter = font(36)
    f_claim = font(24)
    f_tick = font(15)
    f_leg = font(16)
    f_ax = font(16)
    x1, y1 = x0 + pw, y0 + ph
    d.text((x0 + 6, y0 + 4), letter, fill=hex_rgb(NAVY), font=f_letter)
    d.text((x0 + 46, y0 + 12), c.title, fill=hex_rgb(TEXT), font=f_claim)
    lx = x0 + 46
    for s in c.series:
        d.rectangle((lx, y0 + 50, lx + 18, y0 + 56), fill=hex_rgb(s.color))
        d.text((lx + 24, y0 + 42), s.name, fill=hex_rgb(TEXT2), font=f_leg)
        lx += 24 + int(d.textlength(s.name, font=f_leg)) + 18

    px0, py0, px1, py1 = x0 + 78, y0 + 78, x1 - 18, y1 - 44
    plot_w, plot_h = px1 - px0, py1 - py0
    all_vals = [v for s in c.series for v in s.data] + [r.value for r in c.refs]
    ylo = 0.0 if c.y_min is not None else min(all_vals)
    yhi = c.y_max if c.y_max is not None else nice_max(max(all_vals) * 1.08)
    if yhi <= ylo:
        yhi = ylo + 1
    yticks = ticks(ylo, yhi)

    def x_at(i: int) -> float:
        n = max(len(c.categories) - 1, 1)
        return px0 + plot_w * (i / n)

    def y_at(v: float) -> float:
        return py0 + plot_h * (1 - (v - ylo) / (yhi - ylo))

    for t in yticks:
        if t < ylo - 1e-9 or t > yhi + 1e-9:
            continue
        y = y_at(t)
        lab = fmt(t, c.y_suffix)
        tw = d.textlength(lab, font=f_tick)
        d.text((px0 - 8 - tw, y - 8), lab, fill=hex_rgb(TEXT3), font=f_tick)

    n = len(c.categories)
    step = 1 if n <= 10 else 2
    for i, lab in enumerate(c.categories):
        if i % step and i != n - 1:
            continue
        x = x_at(i) if c.kind == "line" else px0 + (i + 0.5) * (plot_w / n)
        tw = d.textlength(lab, font=f_tick)
        d.text((x - tw / 2, py1 + 6), lab, fill=hex_rgb(TEXT3), font=f_tick)
    d.text((px0 + plot_w / 2 - d.textlength(c.x_label, font=f_ax) / 2, y1 - 20), c.x_label, fill=hex_rgb(TEXT3), font=f_ax)

    for r in c.refs:
        y = y_at(r.value)
        x = px0
        while x < px1:
            d.line((x, y, min(x + 7, px1), y), fill=hex_rgb(r.color), width=2)
            x += 12
        tw = d.textlength(r.label, font=f_tick) + 12
        d.rectangle((px1 - tw, y - 11, px1, y + 11), fill=hex_rgb(CHIP), outline=hex_rgb(r.color), width=1)
        d.text((px1 - tw + 6, y - 9), r.label, fill=hex_rgb(TEXT), font=f_tick)

    if c.kind == "line":
        for s in c.series:
            pts = [(x_at(i), y_at(v)) for i, v in enumerate(s.data)]
            if s.fill and pts:
                poly = [(pts[0][0], y_at(ylo))] + pts + [(pts[-1][0], y_at(ylo))]
                overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
                ImageDraw.Draw(overlay).polygon(poly, fill=hex_rgb(s.color) + (40,))
                img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
                d = ImageDraw.Draw(img)
            d.line(pts, fill=hex_rgb(s.color), width=3, joint="curve")
            for x, y in pts:
                d.ellipse((x - 4, y - 4, x + 4, y + 4), fill=hex_rgb(BG), outline=hex_rgb(s.color), width=2)
    else:
        groups = 1 if c.cycle_bars else len(c.series)
        slot = plot_w / n
        bar_w = min(36.0, (slot * 0.7) / groups)
        gap = 3 if groups > 1 else 0
        total = groups * bar_w + (groups - 1) * gap
        for i in range(n):
            cx = px0 + (i + 0.5) * slot
            if c.cycle_bars:
                v = c.series[0].data[i]
                x = cx - bar_w / 2
                color = CYCLE[i % len(CYCLE)]
                d.rectangle((x, y_at(v), x + bar_w, y_at(ylo)), fill=hex_rgb(color), outline=hex_rgb(NAVY) if color == ICE else hex_rgb(color))
            else:
                for gi, s in enumerate(c.series):
                    v = s.data[i]
                    x = cx - total / 2 + gi * (bar_w + gap)
                    d.rectangle((x, y_at(v), x + bar_w, y_at(ylo)), fill=hex_rgb(s.color))
    return img


def typed_figures() -> None:
    """Three 2x2s: lines, bars, two-phone overlays. One panel on each is the odd one."""
    pw, ph, boxes = figure_layout()

    line_panels = [
        ("A", Chart(
            "", "Nodes grow with the walk", "Walk time", "Count",
            ["0:00", "0:40", "1:20", "2:00", "2:40", "3:20", "3:40"],
            [Series("Nodes", [1, 41, 79, 118, 157, 195, 211], NAVY, True)],
        )),
        ("B", Chart(
            "", "Closures rise on revisits", "Walk time", "Count",
            ["0:00", "0:40", "1:20", "2:00", "2:40", "3:20", "3:40"],
            [Series("Loop closures", [0, 7, 14, 18, 29, 31, 35], CYAN)],
        )),
        ("C", Chart(
            "", "Sync stays near two seconds", "Nodes", "s",
            ["1", "40", "80", "120", "160", "200", "211"],
            [Series("Sync (s)", [1.72, 1.83, 1.92, 1.99, 4.77, 7.81, 1.8], MID)],
            y_max=9,
            refs=[RefLine(1.92, "p50 1.92 s", DEEP)],
            y_suffix=" s",
        )),
        ("D", Chart(
            "", "Nodes and closures together", "Walk time", "Count",
            ["0:00", "0:40", "1:20", "2:00", "2:40", "3:20", "3:40"],
            [
                Series("Nodes", [1, 41, 79, 118, 157, 195, 211], NAVY, True),
                Series("Closures", [0, 7, 14, 18, 29, 31, 35], CYAN),
            ],
        )),
    ]
    img = Image.new("RGB", (FIG_W, FIG_H), hex_rgb(BG))
    for letter, ch in line_panels:
        x0, y0 = boxes[letter]
        img = draw_chart_panel(img, x0, y0, pw, ph, letter, ch)
    finish_figure(img, "00-fig-lines.png", "Line charts  ·  room 28  ·  panel D varies: two series on one axis  ·  6 Sep 02:20–02:24")

    bar_panels = [
        ("A", Chart(
            "", "Peak nodes by room", "Room", "Nodes",
            ["15", "19", "21", "22", "23", "26", "27", "28"],
            [Series("Peak nodes", [360, 272, 140, 415, 202, 170, 160, 211], NAVY)],
            kind="bar",
            cycle_bars=True,
        )),
        ("B", Chart(
            "", "Sync p50 by room", "Room", "s",
            ["15 2p", "19", "21 2p", "22", "23", "26", "27", "28"],
            [Series("p50 (s)", [4.52, 2.01, 1.85, 1.99, 2.25, 2.85, 1.88, 1.92], MID)],
            kind="bar",
            cycle_bars=True,
            refs=[RefLine(2, "2 s", DEEP)],
            y_suffix=" s",
        )),
        ("C", Chart(
            "", "Bake time by room", "Room / nodes", "s",
            ["19", "21", "22a", "22b", "23", "26", "27", "28"],
            [Series("Bake (s)", [97, 31.8, 55.8, 142.6, 54.3, 46.9, 39.0, 27.5], MID)],
            kind="bar",
            cycle_bars=True,
            y_suffix=" s",
        )),
        ("D", Chart(
            "", "Nodes and closures by room", "Room", "Count",
            ["15", "19", "21", "22", "23", "26", "27", "28"],
            [
                Series("Nodes", [360, 272, 140, 415, 202, 170, 160, 211], NAVY),
                Series("Closures", [130, 22, 6, 18, 6, 15, 18, 35], CYAN),
            ],
            kind="bar",
        )),
    ]
    img = Image.new("RGB", (FIG_W, FIG_H), hex_rgb(BG))
    for letter, ch in bar_panels:
        x0, y0 = boxes[letter]
        img = draw_chart_panel(img, x0, y0, pw, ph, letter, ch)
    finish_figure(img, "00-fig-bars.png", "Bar charts  ·  eight rooms  ·  panel D varies: grouped bars  ·  5 Sep–6 Sep")

    merge_panels = [
        ("A", Chart(
            "", "Room 15, phone A", "Clock (5 Sep)", "Nodes",
            ["19:58", "19:59", "20:00", "20:01", "20:03"],
            [Series("Phone A", [2, 33, 84, 192, 251], NAVY, True)],
        )),
        ("B", Chart(
            "", "Room 15, phone B", "Clock (5 Sep)", "Nodes",
            ["19:58", "19:59", "20:00", "20:01", "20:03"],
            [Series("Phone B", [0, 25, 82, 109, 109], MID, True)],
        )),
        ("C", Chart(
            "", "Room 15 closures jump", "Clock (5 Sep)", "Count",
            ["19:58", "19:59", "20:00", "20:01", "20:03"],
            [Series("Loop closures", [0, 13, 18, 118, 130], CYAN)],
        )),
        ("D", Chart(
            "", "Both phones plus closures", "Clock (5 Sep)", "Count",
            ["19:58", "19:59", "20:00", "20:01", "20:03"],
            [
                Series("Phone A", [2, 33, 84, 192, 251], NAVY, True),
                Series("Phone B", [0, 25, 82, 109, 109], MID, True),
                Series("Closures", [0, 13, 18, 118, 130], CYAN),
            ],
        )),
    ]
    img = Image.new("RGB", (FIG_W, FIG_H), hex_rgb(BG))
    for letter, ch in merge_panels:
        x0, y0 = boxes[letter]
        img = draw_chart_panel(img, x0, y0, pw, ph, letter, ch)
    finish_figure(img, "00-fig-merge.png", "Two-phone overlays  ·  room 15  ·  panel D varies: three series  ·  5 Sep 19:58–20:03")


def panel_figure() -> None:
    """One 2x2 of traced paths. Panel D varies: height instead of a single stroke."""
    con = sqlite3.connect(DB)
    cur = con.cursor()

    def parse_pose(blob):
        vals = struct.unpack("<" + "f" * (len(blob) // 4), blob)
        return vals[3], vals[7], vals[11]

    cur.execute("SELECT id, pose FROM Node ORDER BY id")
    poses = [(i, *parse_pose(b)) for i, b in cur.fetchall()]
    id_xy = {i: (x, y) for i, x, y, z in poses}
    cur.execute("SELECT from_id, to_id FROM Link WHERE type=4")
    seen, lcs = set(), []
    for a, b in cur.fetchall():
        k = tuple(sorted((a, b)))
        if k in seen or a not in id_xy or b not in id_xy:
            continue
        seen.add(k)
        lcs.append((a, b, id_xy[a], id_xy[b]))

    xs = [p[1] for p in poses]
    ys = [p[2] for p in poses]
    zs = [p[3] for p in poses]
    pad_m = 0.7
    xmin, xmax = min(xs) - pad_m, max(xs) + pad_m
    ymin, ymax = min(ys) - pad_m, max(ys) + pad_m
    zmin, zmax = min(zs), max(zs)
    peak_i = max(range(len(poses)), key=lambda i: poses[i][1])
    pw, ph, box_xy = figure_layout()
    img = Image.new("RGB", (FIG_W, FIG_H), hex_rgb(BG))
    d = ImageDraw.Draw(img)
    f_letter = font(36)
    f_claim = font(26)
    f_ax = font(18)
    f_tick = font(16)
    f_leg = font(17)

    claims = {
        "A": "One tag-locked walk, one frame",
        "B": "Out and back through the same space",
        "C": "Closures stitch the revisits",
        "D": "Height along the walk",
    }

    def header(letter: str, x0: int, y0: int, items: list[tuple[str, str, str]]) -> None:
        d.text((x0 + 6, y0 + 4), letter, fill=hex_rgb(NAVY), font=f_letter)
        d.text((x0 + 46, y0 + 12), claims[letter], fill=hex_rgb(TEXT), font=f_claim)
        lx = x0 + 46
        for kind, color, label in items:
            if kind == "line":
                d.line((lx, y0 + 52, lx + 20, y0 + 52), fill=hex_rgb(color), width=4)
                d.text((lx + 26, y0 + 42), label, fill=hex_rgb(TEXT2), font=f_leg)
                lx += 26 + int(d.textlength(label, font=f_leg)) + 22
            elif kind == "dot":
                d.ellipse((lx + 4, y0 + 46, lx + 16, y0 + 58), fill=hex_rgb(color))
                d.text((lx + 22, y0 + 42), label, fill=hex_rgb(TEXT2), font=f_leg)
                lx += 22 + int(d.textlength(label, font=f_leg)) + 22

    def axes(px0, py0, px1, py1, y1_box):
        def to_px(x, y):
            return (
                px0 + (x - xmin) / (xmax - xmin) * (px1 - px0),
                py1 - (y - ymin) / (ymax - ymin) * (py1 - py0),
            )

        for gx in (0, 4, 8, 12):
            xx, _ = to_px(gx, ymin)
            if px0 - 2 <= xx <= px1 + 2:
                tw = d.textlength(str(gx), font=f_tick)
                d.text((xx - tw / 2, py1 + 6), str(gx), fill=hex_rgb(TEXT3), font=f_tick)
        for gy in (-2, 0, 4, 8):
            _, yy = to_px(xmin, gy)
            if py0 - 2 <= yy <= py1 + 2:
                tw = d.textlength(str(gy), font=f_tick)
                d.text((px0 - 10 - tw, yy - 8), str(gy), fill=hex_rgb(TEXT3), font=f_tick)
        d.text((px0 + (px1 - px0) / 2 - 18, y1_box - 20), "X (m)", fill=hex_rgb(TEXT3), font=f_ax)
        return to_px

    def draw_poly(pts, color, width=3):
        if len(pts) > 1:
            fill = color if isinstance(color, tuple) else hex_rgb(color)
            d.line(pts, fill=fill, width=width, joint="curve")

    def panel_plot(x0, y0):
        x1, y1 = x0 + pw, y0 + ph
        px0, py0, px1, py1 = x0 + 72, y0 + 78, x1 - 16, y1 - 44
        return x1, y1, px0, py0, px1, py1

    def color_bar(x1, py0, py1, lo: str, hi: str) -> None:
        bx0, by0 = x1 - 28, py0
        bh = py1 - py0
        for i in range(int(bh)):
            t = 1 - i / max(bh - 1, 1)
            d.line((bx0, by0 + i, bx0 + 10, by0 + i), fill=_ramp(t), width=1)
        d.text((bx0 - 8, by0 - 16), hi, fill=hex_rgb(TEXT3), font=f_tick)
        d.text((bx0 - 8, py1 + 2), lo, fill=hex_rgb(TEXT3), font=f_tick)

    def start_dot(to_px):
        sx, sy = to_px(poses[0][1], poses[0][2])
        d.ellipse((sx - 6, sy - 6, sx + 6, sy + 6), fill=hex_rgb(NAVY))

    x0, y0 = box_xy["A"]
    x1, y1, px0, py0, px1, py1 = panel_plot(x0, y0)
    to_px = axes(px0, py0, px1, py1, y1)
    header("A", x0, y0, [("line", NAVY, "Optimized keyframes"), ("dot", NAVY, "Start tag")])
    draw_poly([to_px(x, y) for _, x, y, _ in poses], NAVY, 3)
    start_dot(to_px)

    x0, y0 = box_xy["B"]
    x1, y1, px0, py0, px1, py1 = panel_plot(x0, y0)
    to_px = axes(px0, py0, px1, py1, y1)
    header("B", x0, y0, [("line", NAVY, "Out (to node 103)"), ("line", CYAN, "Back")])
    draw_poly([to_px(x, y) for _, x, y, _ in poses[: peak_i + 1]], NAVY, 3)
    draw_poly([to_px(x, y) for _, x, y, _ in poses[peak_i:]], CYAN, 3)
    start_dot(to_px)
    tx, ty = to_px(poses[peak_i][1], poses[peak_i][2])
    d.ellipse((tx - 5, ty - 5, tx + 5, ty + 5), fill=hex_rgb(CYAN))

    x0, y0 = box_xy["C"]
    x1, y1, px0, py0, px1, py1 = panel_plot(x0, y0)
    to_px = axes(px0, py0, px1, py1, y1)
    draw_poly([to_px(x, y) for _, x, y, _ in poses], MID, 2)
    header("C", x0, y0, [("line", ICE, "Path"), ("line", CYAN, "Local-time closures")])
    for _, _, (ax, ay), (bx, by) in lcs:
        d.line((*to_px(ax, ay), *to_px(bx, by)), fill=hex_rgb(CYAN), width=4)
        p1, p2 = to_px(ax, ay), to_px(bx, by)
        d.ellipse((p1[0] - 4, p1[1] - 4, p1[0] + 4, p1[1] + 4), fill=hex_rgb(CYAN))
        d.ellipse((p2[0] - 4, p2[1] - 4, p2[0] + 4, p2[1] + 4), fill=hex_rgb(CYAN))
    start_dot(to_px)

    x0, y0 = box_xy["D"]
    x1, y1, px0, py0, px1, py1 = panel_plot(x0, y0)
    to_px = axes(px0, py0, px1, py1, y1)
    header("D", x0, y0, [("line", NAVY, "Low (z)"), ("line", LIGHT, "High (z)")])
    zspan = max(zmax - zmin, 1e-6)
    for i in range(len(poses) - 1):
        _, xa, ya, za = poses[i]
        _, xb, yb, zb = poses[i + 1]
        t = ((za + zb) / 2 - zmin) / zspan
        d.line((*to_px(xa, ya), *to_px(xb, yb)), fill=_ramp(t), width=4)
    color_bar(x1, py0, py1, f"{zmin:.1f} m", f"{zmax:.1f} m")
    start_dot(to_px)

    finish_figure(
        img,
        "00-fig-paths.png",
        "Path traces  ·  room 28  ·  panel D varies: height  ·  6 Sep 02:20–02:24",
    )
    img.save(os.path.join(OUT, "00-panel.png"), "PNG")
    print("wrote", os.path.join(OUT, "00-panel.png"))

def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        if old.endswith(".svg") or old.startswith("00-panel-"):
            os.remove(os.path.join(OUT, old))
    for c in CHARTS:
        render_png(c)
    walk_png()
    panel_figure()
    typed_figures()


if __name__ == "__main__":
    main()
