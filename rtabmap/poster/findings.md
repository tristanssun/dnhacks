# MiniMap — Key Findings (poster copy)

## Tagline
Ordinary phones, walked through a building, become a live team-tracking and
3D-mapping system — with nothing installed in the building beforehand.

## The problem (one paragraph)
Indoors, GPS is nearly useless: its error is measured in meters, and walls make
it worse. First responders entering a burning, collapsed, or unfamiliar
building can't see where their teammates are, and their commanders can't see
the building at all. Deaths and injuries happen because people get lost,
separated, or can't be found.

---

## Finding 1 — Phones can locate each other to within a hand's width, with no infrastructure

- Every recent iPhone contains an **ultra-wideband (UWB) radio** that measures
  the distance to another phone with roughly **centimeter-to-10 cm accuracy** —
  10 to 100 times better than GPS — and it works **through walls**.
- UWB alone is accurate but jumpy; the phone's **camera + motion sensors
  (visual-inertial odometry)** are smooth but slowly drift. Fusing them gives
  the best of both: **smooth, drift-corrected positions in real time**.
- When two teammates lose direct radio contact, an intermediate teammate's
  phone **relays** the measurement, so the network stays connected as the team
  spreads out.
- No anchors, no GPS, no pre-installed beacons — just the phones the team
  carries in.

## Finding 2 — A team of phones can build a live 3D model of a building in minutes

Measured across **10 real rooms** mapped overnight with two iPhones and one
laptop:

- **~2 seconds from phone to command screen.** A scan taken by a phone appears
  in the shared 3D map with a median delay of **1.9–2.1 s** (457 timed
  uploads).
- **The live 3D model redraws in under 1/10 of a second** (median **40 ms**,
  typically 20–60 ms) even as the map grows past 150,000 surface triangles.
- **The map corrects itself as people walk.** When a mapper revisits a spot,
  the system recognizes it ("loop closure") and pulls the accumulated drift
  out: 35 corrections in one 3 min 40 s walk covering 87.6 m of path in an
  11.6 × 10.6 m room.
- **Two phones, one map.** Both phones scan independently and the server fuses
  them into a single model. In one run, corrections jumped from 29 to 93 the
  moment the two phones' paths overlapped, ending at 360 keyframes and 130
  corrections in a shared map.
- **A printed tag is the only "setup."** Each phone glances at one paper
  marker at the door to join the shared coordinate frame: 14 successful locks,
  **0 rejected alignments** across the night. A second phone joining an
  in-progress map aligned within seconds.
- **The finished model is photo-textured**: 84% of the surface receives real
  camera imagery, baked in ~28 seconds.

## Finding 3 — Together, they answer the two questions that matter in a crisis

*Where is everyone?* (positioning) and *What does the space look like?*
(mapping). The same commodity phones feed both, so a commander watches
teammates move, in real time, through a 3D model of a building nobody had a
map of five minutes earlier — for roughly **$500 of off-the-shelf hardware**.

---

## Numbers box (for a sidebar)

| What | Measured |
|---|---|
| UWB ranging vs GPS accuracy | cm-level vs meters (10–100×) |
| Scan-to-command-screen delay (median) | 1.9 s |
| Live 3D model refresh (median) | 40 ms |
| Drift corrections, one 3:40 walk | 35 |
| Two-phone merged map | 360 keyframes, 130 corrections |
| Shared-frame tag locks / rejections | 14 / 0 |
| Surface photo-textured | 84% |
| Rooms mapped in one night | 10 |
| Hardware cost | ~$500, no installed infrastructure |

## How it works (three steps, for a diagram)

1. **Carry** — each responder carries an ordinary smartphone; UWB radios and
   cameras measure distances and motion continuously.
2. **Share** — phones stream small map updates and positions over Wi-Fi to a
   laptop at the command post, aligned by a single paper tag at the entrance.
3. **See** — command watches a live, self-correcting 3D model with every
   teammate's position in it; responders see each other through walls.

## Why it matters (closing line)
Any team that already carries phones — firefighters, search-and-rescue, police,
industrial crews — can walk into an unmapped building and walk out with
situational awareness that today requires pre-installed infrastructure that
burning and collapsed buildings never have.
