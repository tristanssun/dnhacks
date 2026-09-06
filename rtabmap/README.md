# RTAB-Map iOS

iOS app for [RTAB-Map](https://github.com/introlab/rtabmap) (iPhone/iPad with LiDAR).

Open `app/ios/RTABMapApp.xcodeproj` in Xcode.

## Layout

- `app/ios`: Swift UI, Xcode project, and `install_deps.sh`
- `app/android/jni`: shared C++ mapping/rendering code compiled by the iOS target
- `corelib`, `utilite`, `cmake_modules`: RTAB-Map libraries built for iOS by `install_deps.sh`

## Build

1. Install CMake and Xcode.
2. Build third-party libraries and the RTAB-Map iOS static libs:

   ```bash
   cd app/ios/RTABMapApp
   ./install_deps.sh
   ```

   This writes headers and `.a` files into `app/ios/RTABMapApp/Libraries/`.
3. Open `app/ios/RTABMapApp.xcodeproj`, select a LiDAR device, and run.

The App Store listing is [RTAB-Map 3D LiDAR Scanner](https://apps.apple.com/ca/app/rtab-map-3d-lidar-scanner/id1564774365).

## Collaborative mapping

A headless C++ server (`rtabmap-collab-server`) can ingest node deltas from multiple iOS clients into one global rtabmap database, run inter-session loop closure, and export `map.db` / `map.ply`. The phones keep their local maps; the server does not push the merged map back.

See [server/README.md](server/README.md) for build, run, and LAN setup. Each Xcode build writes this Mac's LAN IPv4 into `CollabServerConfig.defaultURL` (fallback `http://192.168.1.159:8080`).
