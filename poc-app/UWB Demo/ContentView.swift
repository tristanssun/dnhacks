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
                radar(size: proxy.size, safeArea: proxy.safeAreaInsets)
            }
            .ignoresSafeArea()
        }
    }

    private func radar(size: CGSize, safeArea: EdgeInsets) -> some View {
        let pad: CGFloat = 24
        let local = CGPoint(x: size.width / 2, y: size.height - safeArea.bottom - pad)
        let minX = pad
        let maxX = size.width - pad
        let minY = max(safeArea.top, 54) + 56
        let maxY = local.y
        let usableHeight = max(maxY - minY, 1)
        let scale = usableHeight / 8
        let marks = Self.marks(from: Array(manager.peers.values).sorted { $0.displayName < $1.displayName })
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

            ForEach(placed) { item in
                let mark = item.mark
                let point = item.point
                let rotation = Self.rotation(for: mark)
                ArrowMark()
                    .frame(width: 14, height: 26)
                    .rotationEffect(.radians(Double(rotation)))
                    .offset(x: point.x - 7, y: point.y - 13)
                VStack(spacing: 1) {
                    Text(mark.peer.displayName)
                    Text(Self.distanceLabel(for: mark))
                    Text(Self.latency(mark.latencyMs))
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

    private struct Mark: Identifiable {
        let id: String
        let peer: PeerManager.Peer
        let distance: Float
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

    private static func marks(from peers: [PeerManager.Peer]) -> [Mark] {
        peers.compactMap { peer in
            guard let distance = peer.locarDistance ?? peer.distance ?? peer.bluetoothDistance else {
                return nil
            }
            return Mark(
                id: "\(peer.displayName)-\(peer.id.hashValue)",
                peer: peer,
                distance: distance,
                direction: peer.locarDirection ?? peer.direction,
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

    private static func rotation(for mark: Mark) -> Float {
        if let heading = mark.peer.locarHeading {
            return heading
        }
        return 0
    }

    private static func distanceLabel(for mark: Mark) -> String {
        let feet = Double(mark.distance) * 3.28084
        let text = String(format: "%.1f ft", feet)
        return mark.direction == nil ? "\(text)?" : text
    }

    private static func latency(_ ms: Int?) -> String {
        guard let ms else { return "- ms" }
        return "\(ms) ms"
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
