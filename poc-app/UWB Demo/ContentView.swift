import simd
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = PeerManager()

    var body: some View {
        if let message = manager.unsupportedMessage {
            Text(message)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                // Capped at 60. ProMotion was driving this at 120+, and the
                // radar carries no detail that a 120 Hz redraw resolves — it
                // just doubled layout work on the same thread the filter and
                // ARKit frame delivery share.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: manager.peers.isEmpty)) { context in
                    radar(size: proxy.size, safeArea: proxy.safeAreaInsets, date: context.date)
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                PerfHUD(perf: manager.perf)
            }
        }
    }

    private func radar(size: CGSize, safeArea: EdgeInsets, date: Date) -> some View {
        // One call per TimelineView tick, so this is the rate the user sees.
        perfCounters.recordUIFrame()
        let pad: CGFloat = 24
        let local = CGPoint(x: size.width / 2, y: size.height - safeArea.bottom - pad)
        let minX = pad
        let maxX = size.width - pad
        let minY = max(safeArea.top, 54) + 56
        let maxY = local.y
        let usableHeight = max(maxY - minY, 1)
        let marks = Self.marks(from: Array(manager.peers.values).sorted { $0.displayName < $1.displayName }, at: date)
        // Fixed 8 m full-scale pinned every peer to the screen edge at the
        // ranges actually being tested (6-9 m), so the drawn position stopped
        // tracking reality well before any estimation error did. Scale to the
        // farthest peer instead, with headroom so a peer walking out does not
        // sit on the boundary, and a floor so a close pair is not magnified
        // into jitter.
        let span = Self.radarSpan(for: marks)
        let scale = usableHeight / span
        let placed = Self.placedMarks(
            from: marks,
            local: local,
            scale: scale,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY
        )

        return ZStack(alignment: .topLeading) {
            ArrowMark()
                .frame(width: 16, height: 28)
                .offset(x: local.x - 8, y: local.y - 14)

            // The span moves with the farthest peer, so it has to be readable
            // or the radar silently rescales under you.
            Text(String(format: "%.0f ft", span * 3.28084))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .offset(x: minX, y: minY - 16)

            ForEach(placed) { item in
                let mark = item.mark
                let point = item.point
                let rotation = Self.rotation(for: mark, localHeading: manager.localHeading)
                ArrowMark()
                    .frame(width: 14, height: 26)
                    .rotationEffect(.radians(Double(rotation)))
                    .offset(x: point.x - 7, y: point.y - 13)
                VStack(spacing: 1) {
                    Text(mark.peer.displayName)
                    Text(Self.distanceLabel(for: mark))
                    Text(Self.latency(mark.latencyMs))
                    if mark.direction == nil {
                        // Nearby Interaction's own reason when it has one,
                        // otherwise the thing that resolves a bearing without
                        // it: parallax. Successive ranges taken from different
                        // vantage points triangulate the peer, so stepping
                        // sideways gives the filter everything and walking
                        // straight at them gives it nothing.
                        Text(mark.peer.hint ?? "Step side to side")
                            .foregroundStyle(.secondary)
                    }
                    if let link = mark.peer.link {
                        Text(link)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(width: 150)
                .offset(x: point.x - 75, y: min(point.y + 16, maxY - 4))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// Metres represented by the full height of the radar.
    private static func radarSpan(for marks: [Mark]) -> CGFloat {
        let farthest = marks.map { CGFloat($0.distance) }.max() ?? 0
        return min(max(farthest * 1.25, 4), 40)
    }

    private struct Mark: Identifiable {
        let id: String
        let peer: PeerManager.Peer
        let distance: Float
        let source: PeerManager.Peer.DistanceSource
        let direction: simd_float3?
        let latencyMs: Int?
    }

    private struct PlacedMark: Identifiable {
        var id: String { mark.id }
        let mark: Mark
        let point: CGPoint
    }

    private static func placedMarks(
        from marks: [Mark],
        local: CGPoint,
        scale: CGFloat,
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> [PlacedMark] {
        let raw = marks.map { mark in
            clampedPoint(
                distance: mark.distance,
                direction: mark.direction,
                local: local,
                scale: scale,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY
            )
        }
        let spread = spreadSideBySide(raw, minX: minX, maxX: maxX)
        return zip(marks, spread).map { PlacedMark(mark: $0, point: $1) }
    }

    private static func spreadSideBySide(
        _ points: [CGPoint],
        minX: CGFloat,
        maxX: CGFloat,
        clusterRadius: CGFloat = 96,
        spacing: CGFloat = 156
    ) -> [CGPoint] {
        let count = points.count
        guard count > 1 else { return points }

        var parent = Array(0..<count)
        func find(_ index: Int) -> Int {
            if parent[index] != index {
                parent[index] = find(parent[index])
            }
            return parent[index]
        }
        func union(_ a: Int, _ b: Int) {
            let pa = find(a)
            let pb = find(b)
            if pa != pb {
                parent[pa] = pb
            }
        }

        for i in 0..<count {
            for j in (i + 1)..<count {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                if (dx * dx) + (dy * dy) < clusterRadius * clusterRadius {
                    union(i, j)
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for index in 0..<count {
            groups[find(index), default: []].append(index)
        }

        var result = points
        for indices in groups.values where indices.count > 1 {
            let sorted = indices.sorted()
            let centerX = sorted.reduce(CGFloat.zero) { $0 + points[$1].x } / CGFloat(sorted.count)
            let centerY = sorted.reduce(CGFloat.zero) { $0 + points[$1].y } / CGFloat(sorted.count)
            let slots = CGFloat(sorted.count)
            var gap = spacing
            let usable = max(maxX - minX, 1)
            if (slots - 1) * gap > usable {
                gap = usable / max(slots - 1, 1)
            }
            let width = (slots - 1) * gap
            var start = centerX - width / 2
            if start < minX {
                start = minX
            }
            if start + width > maxX {
                start = maxX - width
            }
            for (slot, index) in sorted.enumerated() {
                result[index] = CGPoint(x: start + CGFloat(slot) * gap, y: centerY)
            }
        }
        return result
    }

    private static func marks(from peers: [PeerManager.Peer], at date: Date) -> [Mark] {
        peers.compactMap { peer in
            guard let display = peer.displayDistance(at: date) else {
                return nil
            }
            return Mark(
                id: "\(peer.displayName)-\(peer.id.hashValue)",
                peer: peer,
                distance: display.meters,
                source: display.source,
                direction: peer.locarDirection,
                latencyMs: peer.uwbLatencyMs ?? peer.bluetoothLatencyMs
            )
        }
    }

    private static func clampedPoint(
        distance: Float,
        direction: simd_float3?,
        local: CGPoint,
        scale: CGFloat,
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGPoint {
        let meters = CGFloat(distance)
        var x = local.x
        var y = local.y
        if let direction {
            x = local.x + CGFloat(direction.x) * meters * scale
            y = local.y - CGFloat(direction.y) * meters * scale
        } else {
            y = local.y - meters * scale
        }
        if y < minY { y = minY }
        if y > maxY { y = maxY }
        if x < minX { x = minX }
        if x > maxX { x = maxX }
        return CGPoint(x: x, y: y)
    }

    /// Peer arrow rotation from compass: their magnetic heading minus ours.
    private static func rotation(for mark: Mark, localHeading: Float) -> Float {
        guard let heading = mark.peer.heading else { return 0 }
        return heading - localHeading
    }

    /// "12.4 ft" live UWB. "~12.4 ft" VIO-propagated or stale. Trailing "?" means
    /// no usable bearing, so the arrow is drawn straight ahead.
    private static func distanceLabel(for mark: Mark) -> String {
        let feet = Double(mark.distance) * 3.28084
        var text = String(format: "%.1f ft", feet)
        switch mark.source {
        case .live:
            break
        case .relayed:
            // Not our measurement gone stale — someone else's, arriving
            // second-hand. That is the expected state past our own UWB range,
            // so it reads differently from a reading we let go cold.
            text = "!" + text
        case .aging, .inferred:
            text = "~" + text
        }
        return mark.direction == nil ? "\(text)?" : text
    }

    private static func latency(_ ms: Int?) -> String {
        guard let ms else { return "- ms" }
        return "\(ms) ms"
    }
}

/// A/B controls and live counters for the progressive-slowdown test.
/// Flip a toggle mid-run: the same session, map, and thermal state on both
/// sides of the switch is a far cleaner comparison than two separate runs.
private struct PerfHUD: View {
    @ObservedObject var perf: PerfMonitor

    var body: some View {
        let snapshot = perf.snapshot
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                metric("AR", snapshot.arHz, "%.0f", "Hz")
                metric("UI", snapshot.uiHz, "%.0f", "Hz")
                metric("pub", snapshot.publishHz, "%.0f", "Hz")
                metric("hop p95", snapshot.hopP95Ms, "%.1f", "ms")
                metric("recenter", snapshot.recenterMsPerSec, "%.0f", "ms/s")
                metric("mem", snapshot.memoryMB, "%.0f", "MB")
                VStack(spacing: 0) {
                    Text("thermal")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(PerfMonitor.thermalNames[min(snapshot.thermal, 3)])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(snapshot.thermal >= 2 ? .red : .primary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 2)
    }

    private func metric(_ label: String, _ value: Double, _ format: String, _ unit: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(String(format: format, value) + unit)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }
}

private struct ArrowMark: View {
    var body: some View {
        ArrowShape()
            .fill(Color.primary)
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let stem = width * 0.32
        let head = height * 0.42
        var path = Path()
        path.move(to: CGPoint(x: width / 2, y: 0))
        path.addLine(to: CGPoint(x: width, y: head))
        path.addLine(to: CGPoint(x: width / 2 + stem / 2, y: head))
        path.addLine(to: CGPoint(x: width / 2 + stem / 2, y: height))
        path.addLine(to: CGPoint(x: width / 2 - stem / 2, y: height))
        path.addLine(to: CGPoint(x: width / 2 - stem / 2, y: head))
        path.addLine(to: CGPoint(x: 0, y: head))
        path.closeSubpath()
        return path
    }
}
