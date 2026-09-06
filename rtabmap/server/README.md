# Collaborative mapping server

Headless `rtabmap-collab-server` process. iOS clients POST native rtabmap `.db` node deltas to one host. The server merges those nodes into a single global database with the official `DBReader` + `Rtabmap::process` path, runs inter-session loop closure, and serves the merged map (`GET /map.db`, `GET /map.mesh`, `GET /pull`).

Phones keep their own ARKit/rtabmap session for capture and odometry. Other users' nodes come back through `GET /pull` (in the shared frame G, see below) and are drawn as an overlay; the final save/export downloads `GET /map.db`.

## Build

Host dependencies (macOS):

```bash
brew install cmake opencv pcl
```

From the repository root:

```bash
mkdir -p build && cd build
cmake -DBUILD_COLLAB_SERVER=ON -DBUILD_APP=OFF -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DWITH_QT=OFF ..
cmake --build . --target rtabmap-collab-server
```

The binary is `build/bin/rtabmap-collab-server`.

## Run

```bash
./bin/rtabmap-collab-server --port 8080 --data ./collab-data
```

The process binds `0.0.0.0:8080` (override with `--port`). Working files go under `--data` (default `./collab-data`): `global.db`, `clients.json`, `map.ply`.

The iOS app uses this Mac's LAN IPv4 at Xcode build time (`CollabServerConfig.defaultURL`, fallback `http://192.168.1.159:8080`). No auth. Same LAN.

Endpoints:

- `POST /sync` with `X-Client-Id` (persistent phone UUID) and `X-Since-Id` (last accepted local node id, `0` on first upload). Body is `application/octet-stream`: a small rtabmap `.db` of new nodes only.
- `GET /status` JSON: global node count, per-client last id / node count / last seen, pose count, loop-closure count.
- `GET /map.db` current global rtabmap database.
- `GET /map.ply` merged colored cloud in the optimized frame (voxelized at about 2 cm).
- `GET /map.mesh` live colored mesh: per-node `cloudRGBFromSensorData` + `organizedFastMesh` at each keyframe pose in G (same as the iOS live view). Vertex RGB. `GET /map.mesh?bake=1` is the unused Poisson file.
- `POST /join` with `X-Client-Id`: `mode: new` when nobody is active (the room is reset), `mode: join` otherwise. `must_download` is always false: a joiner starts a blank local session and receives other users' nodes through `/pull`; loading the room map locally would place it in the wrong frame. `must_wait_for_lock` tells the phone to point at the tag first.
- `POST /calibrate` JSON `tag_id detected tx ty tz qx qy qz qw` (tag pose in the phone's ARKit world). Rejected unless `detected` is true and `tag_id` is 0.
- `POST /pose` small JSON `tx ty tz qx qy qz qw`: the raw ARKit camera transform. Admin markers move at about 3 Hz without waiting for a node export. The same fields are accepted on `POST /heartbeat`.
- `POST /reset` clears the session lock and calibration (map kept).
- `POST /optimize` runs the optimize/export pass now (tag constraint, `detectMoreLoopClosures`, poses, live mesh) and returns `/status`. The same pass runs in the background after every ingest.
- `GET /demo` poll at 250 ms: `locked show_tag aligned calibrated[] clients[]`; clients carry `x y z qx qy qz qw yaw` in G plus a ground-plane trail.
- `GET /` or `/admin` the demo page: start tag until two phones lock, then the live 3D map with phone markers.
- `GET /tag.png` the ArUco marker as rendered by OpenCV.

## Start-tag lock and the shared frame G

Mapping is gated on a start tag. The admin page (`GET /` or `/admin`) shows an OpenCV ArUco `4x4_50` id 0 marker (`GET /tag.png`, assumed width 0.20 m). A phone posts `POST /calibrate` only when rtabmap's `MarkerDetector` actually found id 0 in the camera frame; the body carries `detected: true` and the tag pose in the phone's ARKit world. Anything without a real detection is rejected with 400. The room locks when two distinct phones have real detections; `GET /demo` then reports `locked: true, show_tag: false`, the admin page hides the tag and shows the live 3D map, and `POST /join` stops asking phones to wait. Lock state is session-only: leftover `clients.json` state never locks a room, `POST /reset` (or the admin Reset button) clears it.

All server-side geometry lives in one frame G: the tag frame re-expressed in rtabmap convention (x forward, y left, z up), origin at the tag center, z along the tag's up edge. The phone stores node poses in its rtabmap world; the server derives `T_G_from_clientWorld` from the calibrate pose (see the frame constants at the top of `CollabMap.cpp`) and applies it to that client's nodes for the mesh, `/demo`, and `/pull`. `GET /pull` sends the inverse as `X-Client-To-Global` so a phone can place other users' G-frame nodes in its own world. `POST /pose` carries the raw ARKit camera transform and is converted the same way. `collab_frame_test.cpp` checks this algebra with two simulated phones.

`aligned` (on `/status`, `/demo`, and `X-Aligned`) is true only when the room is tag-locked or the graph holds a real inter-`map_id` loop closure. Intra-session closures and the stored loop-closure count never set it.

## Cross-user merge

Each client session is one `map_id`; a later delta from the same client continues that map and is chained to its previous last node (a neighbor link, or the closure `Rtabmap::process` found itself). Ingest is the official `DBReader` + `Rtabmap::process` path; after it, `detectMoreLoopClosures` looks for more constraints and the graph is optimized with `RGBD/OptimizeFromGraphEnd=false`. Loop-closure counts and poses are never overwritten with zero by a later failed pass. Late join, drop, and reconnect are safe: `(clientId, localId) -> globalId` is persisted so a replay is not ingested twice.

Without a tag lock and without overlapping appearance, two sessions share no frame. With the lock, the server also writes the measured relative pose between the two sessions' first nodes into the graph as a `kUserClosure` link (`Rtabmap::addLink`, with the global max-error guard disabled for that one measured link and restored afterwards). From then on the sessions are one connected graph: the optimized poses saved in `global.db` (what a phone downloads at stop/save), the `/pull` poses, and the live mesh all share the root client's frame, and `detectMoreLoopClosures` can find visual cross-session closures between now-adjacent nodes. When any cross-map link exists, every node gets the root client's tag transform.

## Live mesh and latency

`GET /map.mesh` is rebuilt after every ingest: each node's `cloudRGBFromSensorData` (depth capped at 2.5 m like the phone) meshed with `organizedFastMesh` at its optimized pose in G, vertex RGB, binary PLY. Decimation adapts to the node count so every node stays under the 500k-face budget (newest scans are never dropped). Node meshes are built once and cached in memory; a refresh only reloads poses, so it takes tens of milliseconds regardless of map size. `scripts/render_admin_mesh.py <ply>` rasterizes a PLY to a PNG to eyeball it without a browser.

Ingest is kept short on purpose: `Rtabmap::process` over the delta, the start-tag constraint if the room is locked, pose save, then the live mesh. Measured at phone cadence (10-node deltas every 2 s, 240 nodes): `POST /sync` p50 1.6 s, max 2.1 s, and the mesh containing every node lands about 0.1 s after each upload. The wider `detectMoreLoopClosures` search and the downloadable cloud/PLY run in a maintenance thread that waits for a quiet moment (no upload for 3 s, at least 10 s since the last pass) and is forced at most once a minute during a continuous walk, so it never sits in front of an upload. `Memory::close` in corelib used to sleep a fixed 1.5 s per session (to keep database `time_enter` rows a second apart); it now only sleeps the remainder of that second, which is already exceeded by any real ingest.

## Tests

All run against temp servers and never touch the LaunchAgent room on `:8080` except read-only `GET /status`.

```bash
./build/bin/rtabmap-collab-frame-test                 # frame algebra, two simulated phones
python3 server/demo_e2e.py                             # tag lock, tag hide, reset, /pose, lag, 10x lock
python3 server/app_protocol_e2e.py                     # CollabSync HTTP protocol, two phones, /pull both ways
./build/bin/rtabmap-collab-merge-test \
  --source ./collab-data --work /tmp/merge-test \
  --server ./build/bin/rtabmap-collab-server           # merge mechanics on a real room snapshot (+ --skip-http)
```
