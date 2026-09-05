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
        let peers = Array(manager.peers.values).sorted { $0.displayName < $1.displayName }

        return ZStack(alignment: .topLeading) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 16))
                .offset(x: local.x - 8, y: local.y - 8)

            ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                let point = Self.clampedPoint(
                    for: peer,
                    index: index,
                    local: local,
                    scale: scale,
                    minX: minX,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY
                )
                let rotation = Self.rotation(for: peer, localHeading: manager.localHeading)
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 14))
                    .rotationEffect(.radians(Double(rotation)))
                    .offset(x: point.x - 7, y: point.y - 7)
                Text(Self.label(for: peer))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(width: 140)
                    .offset(x: point.x - 70, y: min(point.y + 14, maxY - 4))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private static func clampedPoint(
        for peer: PeerManager.Peer,
        index: Int,
        local: CGPoint,
        scale: CGFloat,
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGPoint {
        var x = local.x
        var y = local.y
        if let distance = peer.distance {
            let meters = CGFloat(distance)
            if let direction = peer.direction {
                x = local.x + CGFloat(direction.x) * meters * scale
                y = local.y + CGFloat(direction.z) * meters * scale
            } else {
                y = local.y - meters * scale
            }
        } else {
            x = local.x + CGFloat(index) * 48 - 24
            y = local.y - 40
        }
        if y < minY { y = minY }
        if y > maxY { y = maxY }
        if x < minX { x = minX }
        if x > maxX { x = maxX }
        return CGPoint(x: x, y: y)
    }

    private static func label(for peer: PeerManager.Peer) -> String {
        guard let distance = peer.distance else {
            return peer.displayName
        }
        let meters = String(format: "%.1f m", distance)
        if peer.direction == nil {
            return "\(peer.displayName) \(meters)?"
        }
        return "\(peer.displayName) \(meters)"
    }

    private static func rotation(for peer: PeerManager.Peer, localHeading: Float) -> Float {
        guard let heading = peer.heading else { return 0 }
        return heading - localHeading
    }
}
