import Combine
import Foundation
import simd

/// A view-independent description of one peer at one instant.
struct PeerSnapshot: Identifiable {
    let id: String
    let name: String
    let distance: Float?
    let source: Source
    let bodyDirection: SIMD2<Float>?
    let facing: Float?
    let hint: String?
    let linkStage: Int
    let cameraAssisted: Bool
    let latencyMs: Int?
    let link: String?

    enum Source {
        case live
        case aging
        case relayed
        case inferred
        case none
    }
}

extension PeerSnapshot.Source {
    /// True once our own UWB ranging to this peer has dropped out — either the
    /// last sample has aged past `RangeTrack.liveWindow`, or there was never a
    /// measurement behind the distance at all.
    ///
    /// `relayed` is deliberately excluded. That is another device's *live* UWB
    /// reaching us second-hand, which is the normal and expected state for a
    /// peer beyond our own range, not a fault worth alarming about.
    var hasLostUWB: Bool {
        switch self {
        case .live, .relayed: return false
        case .aging, .inferred, .none: return true
        }
    }
}

extension PeerSnapshot {
    init(peer: PeerManager.Peer, localHeading: Float, at date: Date) {
        let display = peer.displayDistance(at: date)
        let direction = peer.locarDirection.map { SIMD2<Float>($0.x, $0.y) }
        let tokens = Set((peer.link ?? "").split(separator: " ").map(String.init))

        id = peer.displayName
        name = peer.displayName
        distance = display?.meters
        switch display?.source {
        case .live: source = .live
        case .aging: source = .aging
        case .relayed: source = .relayed
        case .inferred: source = .inferred
        case nil: source = .none
        }
        bodyDirection = direction
        facing = peer.heading.map { $0 - localHeading }
        hint = peer.hint
        linkStage = ["mc", "tok", "ni", "run"].reduce(into: 0) { count, token in
            if tokens.contains(token) { count += 1 }
        }
        cameraAssisted = tokens.contains("cam")
        latencyMs = peer.uwbLatencyMs ?? peer.bluetoothLatencyMs
        link = peer.link
    }
}

@MainActor
final class TacticalMapModel: ObservableObject {
    struct Track: Identifiable {
        let id: String
        var name: String
        var glideFrom: SIMD2<Float>
        var glideTo: SIMD2<Float>
        var glideStart: TimeInterval
        var distance: Float
        var hasBearing: Bool
        var source: PeerSnapshot.Source
        var linkStage: Int
        var cameraAssisted: Bool
        var hint: String?
        var latencyMs: Int?
        var link: String?
        var facingFrom: Float?
        var facingTo: Float?
        var facingStart: TimeInterval
        var lastSeen: TimeInterval
        var bornAt: TimeInterval
        var fadingSince: TimeInterval?

        /// Interpolated map position at `time`. Linear over `positionInterval`.
        func mapPosition(at time: TimeInterval) -> SIMD2<Float> {
            let fraction = Float(min(max((time - glideStart) / TacticalMapModel.positionInterval, 0), 1))
            return glideFrom + (glideTo - glideFrom) * fraction
        }

        /// Eased facing along the shortest arc, with cubic ease-out.
        func facing(at time: TimeInterval) -> Float? {
            guard let destination = facingTo else { return facingFrom }
            guard let origin = facingFrom else { return destination }
            let fraction = Float(min(max((time - facingStart) / TacticalMapModel.facingTurnDuration, 0), 1))
            let eased = 1 - pow(1 - fraction, 3)
            return Self.wrapped(origin + Self.wrapped(destination - origin) * eased)
        }

        /// Fade in over 400 ms and fade out over 600 ms.
        func opacity(at time: TimeInterval) -> Double {
            let fadeIn = min(max((time - bornAt) / 0.4, 0), 1)
            let fadeOut: Double
            if let fadingSince {
                fadeOut = 1 - min(max((time - fadingSince) / 0.6, 0), 1)
            } else {
                fadeOut = 1
            }
            return min(fadeIn, fadeOut)
        }

        private static func wrapped(_ angle: Float) -> Float {
            atan2(sin(angle), cos(angle))
        }
    }

    static let positionInterval: TimeInterval = 1.0 / 3
    static let facingEveryNTicks = 3
    static let facingTurnDuration: TimeInterval = 0.35
    static let ladderFeet: [Float] = [10, 16, 25, 40, 65, 100, 160]

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var halfWidthMeters: Float
    @Published private(set) var scaleAnimStart: TimeInterval
    @Published private(set) var previousHalfWidthMeters: Float

    private struct VectorOneEuro {
        var x = SIMD2<Float>.zero
        var dx = SIMD2<Float>.zero
        var lastTime: TimeInterval?
        var pendingJump: SIMD2<Float>?

        var hasValue: Bool { lastTime != nil }

        /// τ ≈ 1.3 s at rest; harness: 0.08 m max wobble on σ 0.3 m input.
        static let minCutoff: Float = 0.12
        /// Cutoff rises 0.5 Hz per m/s: ~1.5 Hz (τ 0.1 s) at a jog.
        static let beta: Float = 0.5
        static let derivativeCutoff: Float = 1.0

        mutating func filter(_ sample: SIMD2<Float>, at time: TimeInterval) {
            guard let lastTime else {
                x = sample
                dx = .zero
                self.lastTime = time
                pendingJump = nil
                return
            }

            if simd_length(sample - x) > 2.5 {
                if let pendingJump {
                    if simd_length(sample - pendingJump) <= 1.0 {
                        x = sample
                        dx = .zero
                        self.lastTime = time
                    }
                    self.pendingJump = nil
                } else {
                    pendingJump = sample
                }
                return
            }

            pendingJump = nil
            let dt = Float(max(time - lastTime, 1.0 / 60.0))
            // Speed comes from the filtered output's own velocity, not from
            // raw sample differences: with ~0.3 m of bearing jitter per sample
            // at 15 Hz a raw derivative reads several m/s while standing still,
            // which lifts the cutoff and defeats the smoothing. The output
            // velocity is near zero at rest and converges to the true speed
            // within a few hundred ms once the peer actually moves.
            let cutoff = Self.minCutoff + Self.beta * simd_length(dx)
            let valueAlpha = Self.alpha(cutoff: cutoff, dt: dt)
            let next = valueAlpha * sample + (1 - valueAlpha) * x
            let derivativeAlpha = Self.alpha(cutoff: Self.derivativeCutoff, dt: dt)
            dx = derivativeAlpha * ((next - x) / dt) + (1 - derivativeAlpha) * dx
            x = next
            self.lastTime = time
        }

        mutating func rotate(from oldYaw: Float, to newYaw: Float) {
            guard hasValue else { return }
            x = TacticalMapModel.reframe(x, from: oldYaw, to: newYaw)
            dx = TacticalMapModel.reframe(dx, from: oldYaw, to: newYaw)
            if let pendingJump {
                self.pendingJump = TacticalMapModel.reframe(pendingJump, from: oldYaw, to: newYaw)
            }
        }

        private static func alpha(cutoff: Float, dt: Float) -> Float {
            1 / (1 + (1 / (2 * .pi * cutoff)) / dt)
        }
    }

    private struct ScalarOneEuro {
        var x: Float = 0
        var dx: Float = 0
        var lastTime: TimeInterval?

        var hasValue: Bool { lastTime != nil }

        mutating func filter(_ sample: Float, at time: TimeInterval) {
            guard let lastTime else {
                x = sample
                dx = 0
                self.lastTime = time
                return
            }
            let dt = Float(max(time - lastTime, 1.0 / 60.0))
            let derivativeAlpha = Self.alpha(cutoff: 1.0, dt: dt)
            let rawDerivative = (sample - x) / dt
            dx = derivativeAlpha * rawDerivative + (1 - derivativeAlpha) * dx
            let valueAlpha = Self.alpha(cutoff: 0.5 + 0.5 * abs(dx), dt: dt)
            x = valueAlpha * sample + (1 - valueAlpha) * x
            self.lastTime = time
        }

        private static func alpha(cutoff: Float, dt: Float) -> Float {
            1 / (1 + (1 / (2 * .pi * cutoff)) / dt)
        }
    }

    private struct Latest {
        var name: String
        var source: PeerSnapshot.Source
        var linkStage: Int
        var cameraAssisted: Bool
        var hint: String?
        var latencyMs: Int?
        var link: String?
    }

    private struct State {
        var position = VectorOneEuro()
        var distance = ScalarOneEuro()
        var track: Track?
        var latest: Latest
        var lastSeen: TimeInterval
        var lastBearingSeen: TimeInterval?
        var bearingSeenSinceCommit = false
        var facingSin: Float = 0
        var facingCos: Float = 0
        var facingCount = 0
    }

    private var states: [String: State] = [:]
    private var timer: Timer?
    private var tickCount = 0
    private var aspect: Float = 2.0
    private var currentYaw: Float = 0
    private var lastYaw: Float?
    private var lastEpoch: Int?
    private var scaleDownSince: TimeInterval?

    init() {
        let initial = Float(25) * 0.3048
        halfWidthMeters = initial
        previousHalfWidthMeters = initial
        scaleAnimStart = Date().timeIntervalSinceReferenceDate

        let timer = Timer(timeInterval: Self.positionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commit(at: Date().timeIntervalSinceReferenceDate)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    func setAspect(_ newAspect: CGFloat) {
        aspect = max(Float(newAspect), 0.01)
    }

    func ingest(_ snapshots: [PeerSnapshot], yaw: Float, frameEpoch: Int, at time: TimeInterval) {
        if let lastEpoch, let lastYaw, frameEpoch != lastEpoch {
            reframeAll(from: lastYaw, to: yaw)
            tracks = states.values.compactMap(\.track).sorted { $0.id < $1.id }
        }
        self.lastEpoch = frameEpoch
        self.lastYaw = yaw
        currentYaw = yaw

        for snapshot in snapshots {
            guard let measuredDistance = snapshot.distance else { continue }
            let latest = Latest(
                name: snapshot.name,
                source: snapshot.source,
                linkStage: snapshot.linkStage,
                cameraAssisted: snapshot.cameraAssisted,
                hint: snapshot.hint,
                latencyMs: snapshot.latencyMs,
                link: snapshot.link
            )
            var state = states[snapshot.id] ?? State(
                latest: latest,
                lastSeen: time
            )

            if let direction = snapshot.bodyDirection {
                let right = direction.x * measuredDistance
                let forward = direction.y * measuredDistance
                state.position.filter(Self.bodyToMap(right: right, forward: forward, yaw: yaw), at: time)
                state.lastBearingSeen = time
                state.bearingSeenSinceCommit = true
            }
            state.distance.filter(measuredDistance, at: time)

            if let facing = snapshot.facing {
                let mapAzimuth = yaw - facing
                state.facingSin += sin(mapAzimuth)
                state.facingCos += cos(mapAzimuth)
                state.facingCount += 1
            }

            state.latest = latest
            state.lastSeen = time
            if state.track?.fadingSince != nil {
                state.track?.fadingSince = nil
            }
            states[snapshot.id] = state
        }
    }

    private func commit(at now: TimeInterval) {
        tickCount += 1
        let commitsFacing = tickCount.isMultiple(of: Self.facingEveryNTicks)
        // Averaging the whole 1 s period meant a turn took two commits to
        // settle; keeping only the last two thirds of it settles in one.
        let clearsFacingWindow = tickCount % Self.facingEveryNTicks == Self.facingEveryNTicks / 2
        var idsToRemove: [String] = []

        for id in states.keys.sorted() {
            guard var state = states[id], state.distance.hasValue else { continue }
            let hasRecentBearing = state.bearingSeenSinceCommit
                || state.lastBearingSeen.map { now - $0 <= 1.5 } == true
            let position: SIMD2<Float>
            if state.position.hasValue {
                // Lead the glide by one interval of output velocity once the
                // peer is clearly moving. The glide otherwise always arrives one
                // commit late, ~0.9 m behind a jogger; at rest the ramp is 0 so
                // no velocity noise leaks in.
                let speed = simd_length(state.position.dx)
                let ramp = min(max((speed - 0.4) / 0.8, 0), 1)
                position = state.position.x + state.position.dx * Float(Self.positionInterval) * ramp
            } else {
                position = .zero
            }

            if var track = state.track {
                track.glideFrom = track.mapPosition(at: now)
                track.glideTo = position
                track.glideStart = now
                track.distance = state.distance.x
                track.hasBearing = hasRecentBearing
                apply(state.latest, to: &track)
                track.lastSeen = state.lastSeen

                if state.facingCount > 0, commitsFacing || track.facingTo == nil {
                    let destination = atan2(state.facingSin, state.facingCos)
                    track.facingFrom = track.facing(at: now) ?? destination
                    track.facingTo = destination
                    track.facingStart = now
                }

                if now - state.lastSeen > 1.0, track.fadingSince == nil {
                    track.fadingSince = now
                }
                if let fadingSince = track.fadingSince, now - fadingSince > 0.6 {
                    idsToRemove.append(id)
                } else {
                    state.track = track
                }
            } else {
                var track = Track(
                    id: id,
                    name: state.latest.name,
                    glideFrom: position,
                    glideTo: position,
                    glideStart: now,
                    distance: state.distance.x,
                    hasBearing: hasRecentBearing,
                    source: state.latest.source,
                    linkStage: state.latest.linkStage,
                    cameraAssisted: state.latest.cameraAssisted,
                    hint: state.latest.hint,
                    latencyMs: state.latest.latencyMs,
                    link: state.latest.link,
                    facingFrom: nil,
                    facingTo: nil,
                    facingStart: now,
                    lastSeen: state.lastSeen,
                    bornAt: now,
                    fadingSince: nil
                )
                if state.facingCount > 0 {
                    let destination = atan2(state.facingSin, state.facingCos)
                    track.facingFrom = destination
                    track.facingTo = destination
                    track.facingStart = now
                }
                state.track = track
            }

            state.bearingSeenSinceCommit = false
            if commitsFacing || clearsFacingWindow || state.track?.facingTo != nil && state.track?.facingStart == now {
                state.facingSin = 0
                state.facingCos = 0
                state.facingCount = 0
            }
            states[id] = state
        }

        for id in idsToRemove {
            states.removeValue(forKey: id)
        }

        updateScale(at: now)
        tracks = states.values.compactMap(\.track).sorted { $0.id < $1.id }
    }

    private func updateScale(at now: TimeInterval) {
        let visible = states.values.compactMap(\.track).filter { $0.fadingSince == nil }
        guard !visible.isEmpty else {
            scaleDownSince = nil
            return
        }

        let extent = visible.reduce(Float.zero) { current, track in
            if !track.hasBearing {
                // A range ring reaches `distance` straight ahead; keep its label on screen.
                return max(current, track.distance / aspect)
            }
            let body = Self.mapToBody(track.glideTo, yaw: currentYaw)
            return max(current, max(abs(body.right), abs(body.forward) / aspect))
        }
        let normalized = extent / halfWidthMeters

        if normalized > 0.85 {
            let required = extent / 0.70
            let currentFeet = halfWidthMeters / 0.3048
            let rung = Self.ladderFeet.first { $0 >= currentFeet && $0 * 0.3048 >= required }
                ?? Self.ladderFeet.last ?? currentFeet
            changeScale(to: rung * 0.3048, at: now)
            return
        }

        guard normalized < 0.38 else {
            scaleDownSince = nil
            return
        }
        if scaleDownSince == nil {
            scaleDownSince = now
            return
        }
        guard let scaleDownSince, now - scaleDownSince >= 4 else { return }

        let currentIndex = Self.ladderFeet.enumerated().min {
            abs($0.element * 0.3048 - halfWidthMeters) < abs($1.element * 0.3048 - halfWidthMeters)
        }?.offset ?? 0
        guard currentIndex > 0 else {
            self.scaleDownSince = nil
            return
        }
        let lower = Self.ladderFeet[currentIndex - 1] * 0.3048
        if extent / lower <= 0.70 {
            changeScale(to: lower, at: now)
        } else {
            self.scaleDownSince = nil
        }
    }

    private func changeScale(to newValue: Float, at now: TimeInterval) {
        guard newValue != halfWidthMeters else {
            scaleDownSince = nil
            return
        }
        previousHalfWidthMeters = halfWidthMeters
        halfWidthMeters = newValue
        scaleAnimStart = now
        scaleDownSince = nil
    }

    private func reframeAll(from oldYaw: Float, to newYaw: Float) {
        let delta = newYaw - oldYaw
        let cosine = cos(delta)
        let sine = sin(delta)
        for id in Array(states.keys) {
            guard var state = states[id] else { continue }
            state.position.rotate(from: oldYaw, to: newYaw)
            let oldFacingSin = state.facingSin
            let oldFacingCos = state.facingCos
            state.facingSin = oldFacingSin * cosine + oldFacingCos * sine
            state.facingCos = oldFacingCos * cosine - oldFacingSin * sine
            if var track = state.track {
                track.glideFrom = Self.reframe(track.glideFrom, from: oldYaw, to: newYaw)
                track.glideTo = Self.reframe(track.glideTo, from: oldYaw, to: newYaw)
                track.facingFrom = track.facingFrom.map { Self.wrapped($0 + delta) }
                track.facingTo = track.facingTo.map { Self.wrapped($0 + delta) }
                state.track = track
            }
            states[id] = state
        }
    }

    private func apply(_ latest: Latest, to track: inout Track) {
        track.name = latest.name
        track.source = latest.source
        track.linkStage = latest.linkStage
        track.cameraAssisted = latest.cameraAssisted
        track.hint = latest.hint
        track.latencyMs = latest.latencyMs
        track.link = latest.link
    }

    static func mapToBody(_ map: SIMD2<Float>, yaw: Float) -> (right: Float, forward: Float) {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let right = -map.x * cosine + map.y * sine
        let forward = map.x * sine + map.y * cosine
        return (right, forward)
    }

    static func bodyToMap(right: Float, forward: Float, yaw: Float) -> SIMD2<Float> {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return SIMD2<Float>(
            forward * sine - right * cosine,
            forward * cosine + right * sine
        )
    }

    private static func reframe(_ map: SIMD2<Float>, from oldYaw: Float, to newYaw: Float) -> SIMD2<Float> {
        let body = mapToBody(map, yaw: oldYaw)
        return bodyToMap(right: body.right, forward: body.forward, yaw: newYaw)
    }

    private static func wrapped(_ angle: Float) -> Float {
        atan2(sin(angle), cos(angle))
    }
}
