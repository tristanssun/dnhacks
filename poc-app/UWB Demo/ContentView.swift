import SwiftUI

struct ContentView: View {
    #if targetEnvironment(simulator)
    @StateObject private var demo = DemoTeam()
    #else
    @StateObject private var manager = PeerManager()
    #endif
    @StateObject private var model = TacticalMapModel()
    @State private var snapshots: [PeerSnapshot] = []
    @State private var showDiagnostics = false

    @ViewBuilder
    var body: some View {
        #if targetEnvironment(simulator)
        tacticalLayout(
            yaw: demo.yaw,
            heading: demo.heading,
            trackingState: demo.trackingState,
            peerCount: snapshots.count,
            perf: demo.perf
        )
        .onReceive(demo.$snapshots) { peers in
            snapshots = peers.sorted { $0.name < $1.name }
            model.ingest(
                peers,
                yaw: demo.yaw,
                frameEpoch: demo.frameEpoch,
                at: Date().timeIntervalSinceReferenceDate
            )
        }
        .onAppear { demo.start() }
        .onDisappear { demo.stop() }
        #else
        if let message = manager.unsupportedMessage {
            unsupported(message: message)
        } else {
            tacticalLayout(
                yaw: manager.localYaw,
                heading: manager.localHeading,
                trackingState: manager.trackingState,
                peerCount: manager.peers.count,
                perf: manager.perf
            )
            .onReceive(manager.$peers) { peers in
                let date = Date()
                let next = peers.values.map {
                    PeerSnapshot(peer: $0, localHeading: manager.localHeading, at: date)
                }
                snapshots = next.sorted { $0.name < $1.name }
                model.ingest(
                    next,
                    yaw: manager.localYaw,
                    frameEpoch: manager.frameEpoch,
                    at: date.timeIntervalSinceReferenceDate
                )
            }
        }
        #endif
    }

    private func tacticalLayout(
        yaw: Float,
        heading: Float,
        trackingState: String,
        peerCount: Int,
        perf: PerfMonitor
    ) -> some View {
        GeometryReader { proxy in
            let rosterHeight = rosterHeight(peerCount: snapshots.count, bottomInset: proxy.safeAreaInsets.bottom)

            ZStack {
                Theme.ground.ignoresSafeArea()

                VStack(spacing: 0) {
                    StatusBar(
                        peerCount: peerCount,
                        hasLiveTrack: model.tracks.contains { $0.source == .live },
                        trackingState: trackingState,
                        cameraAssisted: snapshots.contains { $0.cameraAssisted }
                    )
                    .padding(.top, proxy.safeAreaInsets.top)
                    .padding(.leading, proxy.safeAreaInsets.leading)
                    .padding(.trailing, proxy.safeAreaInsets.trailing)
                    .frame(height: 44 + proxy.safeAreaInsets.top)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.ease) {
                            showDiagnostics.toggle()
                        }
                    }

                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)

                    MapView(
                        model: model,
                        yaw: yaw,
                        heading: heading,
                        hasPeers: !model.tracks.isEmpty
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)

                    Roster(
                        snapshots: snapshots,
                        tracks: model.tracks,
                        safeArea: proxy.safeAreaInsets
                    )
                    .frame(height: rosterHeight)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if showDiagnostics {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        DiagnosticsSheet(
                            perf: perf,
                            snapshots: snapshots,
                            trackingState: trackingState,
                            horizontalInsets: EdgeInsets(
                                top: 0,
                                leading: proxy.safeAreaInsets.leading,
                                bottom: 0,
                                trailing: proxy.safeAreaInsets.trailing
                            )
                        )
                    }
                    .padding(.bottom, rosterHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .ignoresSafeArea()
        }
        .background(Theme.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func rosterHeight(peerCount: Int, bottomInset: CGFloat) -> CGFloat {
        let contentHeight: CGFloat = peerCount == 0 ? 36 : CGFloat(min(peerCount, 4)) * 56
        return contentHeight + bottomInset
    }

    private func unsupported(message: String) -> some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("UWB UNAVAILABLE")
                    .font(Theme.mono(12, .semibold))
                    .kerning(Theme.tracking(12))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct StatusBar: View {
    let peerCount: Int
    let hasLiveTrack: Bool
    let trackingState: String
    let cameraAssisted: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if hasLiveTrack {
                    Circle()
                        .fill(Theme.ember.opacity(0.7))
                        .frame(width: 6, height: 6)
                        .blur(radius: 6)
                }
                Circle()
                    .fill(hasLiveTrack ? Theme.ember : Theme.inkFaint)
                    .frame(width: 6, height: 6)
            }

            Text("LINK · \(peerCount)")
                .foregroundStyle(Theme.inkDim)

            Spacer(minLength: 10)

            Text("ARKIT \(trackingState.uppercased())")
                .foregroundStyle(trackingState == "normal" ? Theme.inkDim : Theme.inkFaint)

            if cameraAssisted {
                Text("CAM")
                    .foregroundStyle(Theme.inkDim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .overlay {
                        Rectangle().stroke(Theme.line, lineWidth: 1)
                    }
            }
        }
        .font(Theme.mono(10))
        .kerning(Theme.tracking(10))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

private struct Roster: View {
    let snapshots: [PeerSnapshot]
    let tracks: [TacticalMapModel.Track]
    let safeArea: EdgeInsets

    var body: some View {
        VStack(spacing: 0) {
            if snapshots.isEmpty {
                Text("SCANNING")
                    .font(Theme.mono(9))
                    .kerning(Theme.tracking(9))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshots) { snapshot in
                            RosterRow(
                                snapshot: snapshot,
                                track: tracks.first { $0.id == snapshot.id }
                            )
                        }
                    }
                }
            }

            Theme.ground
                .frame(height: safeArea.bottom)
        }
        .padding(.leading, safeArea.leading)
        .padding(.trailing, safeArea.trailing)
        .background(Theme.ground)
    }
}

private struct RosterRow: View {
    let snapshot: PeerSnapshot
    let track: TacticalMapModel.Track?

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.name.uppercased())
                    .font(Theme.mono(12, .semibold))
                    .kerning(Theme.tracking(12))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                rosterDistance
            }

            HStack(spacing: 7) {
                if track == nil {
                    Text("LINKING")
                        .font(Theme.mono(9, .medium))
                        .kerning(Theme.tracking(9))
                        .foregroundStyle(Theme.inkFaint)
                    LinkPips(stage: snapshot.linkStage)
                    Spacer(minLength: 4)
                } else if track?.hasBearing != true {
                    Text((track?.hint ?? snapshot.hint ?? "STEP SIDE TO SIDE").uppercased())
                        .font(Theme.mono(9, .medium))
                        .kerning(Theme.tracking(9))
                        .foregroundStyle(Theme.ember)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("NO FIX")
                        .font(Theme.mono(9))
                        .kerning(Theme.tracking(9))
                        .foregroundStyle(Theme.inkFaint)
                } else {
                    Text(statusLabel)
                        .font(Theme.mono(9, .medium))
                        .kerning(Theme.tracking(9))
                        .foregroundStyle(statusColor)

                    if let latency = track?.latencyMs ?? snapshot.latencyMs {
                        Text("· \(latency) MS")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.inkFaint)
                    }

                    LinkPips(stage: track?.linkStage ?? snapshot.linkStage)

                    Spacer(minLength: 4)
                }

                if track?.cameraAssisted == true || snapshot.cameraAssisted {
                    Text("CAM")
                        .font(Theme.mono(9))
                        .kerning(Theme.tracking(9))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var rosterDistance: some View {
        if let track {
            let lostUWB = track.source.hasLostUWB
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(lostUWB ? "~" + distanceNumber(track.distance) : distanceNumber(track.distance))
                    .font(Theme.mono(20, .medium))
                    .monospacedDigit()
                Text("FT")
                    .font(Theme.mono(10))
                    .kerning(Theme.tracking(10))
            }
            .foregroundStyle(lostUWB ? Theme.alarm : (track.source == .live ? Theme.ink : Theme.inkDim))
        } else {
            Text("NO RANGE")
                .font(Theme.mono(12, .medium))
                .kerning(Theme.tracking(12))
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private var statusLabel: String {
        switch track?.source ?? snapshot.source {
        case .live: return "LIVE"
        case .aging: return "NO UWB"
        case .relayed: return "RELAY"
        case .inferred: return "DR"
        case .none: return "NO FIX"
        }
    }

    private var statusColor: Color {
        switch track?.source ?? snapshot.source {
        case .live: return Theme.ember
        case .aging: return Theme.alarm
        case .relayed: return Theme.frost
        case .inferred, .none: return Theme.alarm.opacity(0.7)
        }
    }

    private func distanceNumber(_ metres: Float) -> String {
        let feet = metres / 0.3048
        return feet < 100
            ? String(format: "%.1f", Double(feet))
            : String(format: "%.0f", Double(feet))
    }
}

private struct LinkPips: View {
    let stage: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(index < stage ? Theme.inkDim : Theme.line)
                    .frame(width: 3, height: 8)
            }
        }
        .accessibilityLabel("LINK STAGE \(stage) OF 4")
    }
}

private struct DiagnosticsSheet: View {
    @ObservedObject var perf: PerfMonitor
    let snapshots: [PeerSnapshot]
    let trackingState: String
    let horizontalInsets: EdgeInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PerfHUD(perf: perf)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)

            Text("ARKIT \(trackingState.uppercased())")
                .font(Theme.mono(9))
                .kerning(Theme.tracking(9))
                .foregroundStyle(Theme.inkFaint)

            ForEach(snapshots) { snapshot in
                Text("\(snapshot.name.uppercased())  \(snapshot.link ?? "—")")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.leading, 14 + horizontalInsets.leading)
        .padding(.trailing, 14 + horizontalInsets.trailing)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
    }
}

private struct PerfHUD: View {
    @ObservedObject var perf: PerfMonitor

    var body: some View {
        let snapshot = perf.snapshot
        HStack(spacing: 10) {
            metric("AR", snapshot.arHz, "%.0f", "HZ")
            metric("UI", snapshot.uiHz, "%.0f", "HZ")
            metric("PUB", snapshot.publishHz, "%.0f", "HZ")
            metric("HOP P95", snapshot.hopP95Ms, "%.1f", "MS")
            metric("RECENTER", snapshot.recenterMsPerSec, "%.0f", "MS/S")
            metric("MEM", snapshot.memoryMB, "%.0f", "MB")

            VStack(alignment: .leading, spacing: 1) {
                Text("THERMAL")
                    .font(Theme.mono(8))
                    .kerning(Theme.tracking(8))
                    .foregroundStyle(Theme.inkFaint)
                Text(thermalValue(snapshot.thermal))
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(snapshot.thermal >= 2 ? Theme.ink : Theme.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, _ value: Double, _ format: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.mono(8))
                .kerning(Theme.tracking(8))
                .foregroundStyle(Theme.inkFaint)
            Text(String(format: format, value) + unit)
                .font(Theme.mono(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
    }

    private func thermalValue(_ level: Int) -> String {
        let name = PerfMonitor.thermalNames[min(max(level, 0), 3)].uppercased()
        return level >= 2 ? "!\(name)" : name
    }
}
