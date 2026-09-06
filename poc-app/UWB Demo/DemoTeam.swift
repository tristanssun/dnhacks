#if targetEnvironment(simulator)
import Combine
import Foundation
import simd

/// A scripted team for the simulator, where there is no UWB radio to range and
/// no peers to range against.
///
/// The script is a ten-second loop told from ALPHA's point of view. BRAVO and
/// CHARLIE are already on the map when it starts; DELTA joins the network part
/// way through and is only ever reachable second-hand; and CHARLIE's own UWB
/// drops mid-loop so the team carries it on relay until ranging comes back.
/// Between them those three cover every source the map can draw — live,
/// aging, relayed — and the handoffs between them.
///
/// Every path closes on itself at the ten-second mark and every scripted state
/// change sits strictly inside the loop, so the whole thing repeats seamlessly.
@MainActor
final class DemoTeam: ObservableObject {
    @Published private(set) var snapshots: [PeerSnapshot] = []
    @Published private(set) var yaw: Float = 0
    @Published private(set) var heading: Float = 1.2
    @Published private(set) var trackingState = "normal"
    @Published private(set) var frameEpoch = 0

    let perf = PerfMonitor()

    /// Length of the scripted loop, seconds.
    static let loop: Double = 10

    /// DELTA appears in the roster, connected but with no fix yet.
    private static let deltaJoins: Double = 3.4
    /// Its link reaches the stage where BRAVO's ranging can be forwarded to us.
    private static let deltaHalfLinked: Double = 3.9
    /// First relayed fix: DELTA reaches the map.
    private static let deltaFix: Double = 4.4

    /// Our own ranging to CHARLIE drops out.
    private static let charlieDrops: Double = 5.7
    /// BRAVO's ranging to CHARLIE reaches us, and the track recovers on relay.
    private static let charlieRelays: Double = 6.2
    /// Our own ranging to CHARLIE comes back.
    private static let charlieRecovers: Double = 8.7

    private var timer: Timer?
    private var startedAt = Date().timeIntervalSinceReferenceDate

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date().timeIntervalSinceReferenceDate
        perf.start()
        publish()

        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        perf.stop()
    }

    private func publish() {
        let now = Date().timeIntervalSinceReferenceDate
        let phase = (now - startedAt).truncatingRemainder(dividingBy: Self.loop)
        let angle = Float(2 * Double.pi * phase / Self.loop)

        // We turn on the spot as the team moves, so the forward-up map is
        // rotating under the markers rather than only translating.
        yaw = 0.32 * sin(angle)
        heading = 1.2 - yaw

        var team = [bravo(at: angle), charlie(at: phase, angle: angle)]
        if let delta = delta(at: phase) {
            team.append(delta)
        }
        snapshots = team
    }

    // MARK: - The team

    /// Our strongest link, and the one relaying for everyone else: direct UWB
    /// the whole loop, camera assisted, full four-stage pairing.
    private func bravo(at angle: Float) -> PeerSnapshot {
        let track = circle(at: angle, centre: SIMD2<Float>(3.0, 2.2), radius: 2.6)
        return snapshot(
            id: "BRAVO",
            mapPosition: track.position,
            mapFacing: mapAzimuth(of: track.tangent),
            source: .live,
            bearingNoise: 4 * .pi / 180,
            rangeNoise: 0.12,
            linkStage: 4,
            cameraAssisted: true,
            latencyMs: Int.random(in: 42...74),
            link: "mc tok ni run cam clk θ12/0.94"
        )
    }

    /// Live, then dropped, then relayed through BRAVO, then live again: the
    /// fallback chain the map exists to make readable.
    private func charlie(at phase: Double, angle: Float) -> PeerSnapshot {
        let track = figureEight(at: angle, centre: SIMD2<Float>(-3.4, 0.6), width: 1.9, height: 3.0)

        let source: PeerSnapshot.Source
        let linkStage: Int
        let latency: Int
        let link: String
        switch phase {
        case ..<Self.charlieDrops, Self.charlieRecovers...:
            source = .live
            linkStage = 4
            latency = Int.random(in: 58...96)
            link = "mc tok ni run clk θ-8/0.83"
        case ..<Self.charlieRelays:
            source = .aging
            linkStage = 3
            latency = 104
            link = "mc tok ni run✗ clk θ-8/0.74"
        default:
            source = .relayed
            linkStage = 3
            latency = Int.random(in: 118...146)
            link = "mc tok ni✗ run✗ clk θ-8/0.69"
        }

        return snapshot(
            id: "CHARLIE",
            mapPosition: track.position,
            mapFacing: mapAzimuth(of: track.tangent),
            source: source,
            // A relayed bearing is BRAVO's fix rotated into our frame, so it
            // carries BRAVO's θ error on top of its own.
            bearingNoise: source == .relayed ? 9 * .pi / 180 : 5 * .pi / 180,
            rangeNoise: source == .relayed ? 0.35 : 0.14,
            linkStage: linkStage,
            cameraAssisted: false,
            latencyMs: latency,
            link: link
        )
    }

    /// Joins part way through the loop, out past our own radio the whole time:
    /// it is on the map only because BRAVO can range it and tell us.
    private func delta(at phase: Double) -> PeerSnapshot? {
        guard phase >= Self.deltaJoins else { return nil }
        let track = approach(at: phase)

        // Connected over MultipeerConnectivity, pairing still climbing: in the
        // roster but not yet on the map.
        guard phase >= Self.deltaFix else {
            return PeerSnapshot(
                id: "DELTA",
                name: "DELTA",
                distance: nil,
                source: .none,
                bodyDirection: nil,
                facing: nil,
                hint: nil,
                linkStage: phase < Self.deltaHalfLinked ? 1 : 2,
                cameraAssisted: false,
                latencyMs: nil,
                link: phase < Self.deltaHalfLinked
                    ? "mc tok✗ ni✗ run✗"
                    : "mc tok ni✗ run✗ clk"
            )
        }

        return snapshot(
            id: "DELTA",
            mapPosition: track.position,
            mapFacing: mapAzimuth(of: track.tangent),
            source: .relayed,
            bearingNoise: 11 * .pi / 180,
            rangeNoise: 0.4,
            linkStage: 2,
            cameraAssisted: false,
            latencyMs: Int.random(in: 128...168),
            link: "mc tok ni✗ run✗ clk θ174/0.52"
        )
    }

    // MARK: - Paths

    private typealias Path = (position: SIMD2<Float>, tangent: SIMD2<Float>)

    /// A closed patrol circle, one lap per loop.
    private func circle(at angle: Float, centre: SIMD2<Float>, radius: Float) -> Path {
        (
            centre + SIMD2<Float>(radius * sin(angle), radius * cos(angle)),
            SIMD2<Float>(cos(angle), -sin(angle))
        )
    }

    /// A closed figure eight, one lap per loop.
    private func figureEight(at angle: Float, centre: SIMD2<Float>, width: Float, height: Float) -> Path {
        (
            centre + SIMD2<Float>(width * sin(2 * angle), height * sin(angle)),
            simd_normalize(SIMD2<Float>(2 * width * cos(2 * angle), height * cos(angle)))
        )
    }

    /// DELTA's walk in from behind our right shoulder. Not closed: it only
    /// exists from the moment DELTA joins to the end of the loop.
    private func approach(at phase: Double) -> Path {
        let span = Float((phase - Self.deltaJoins) / (Self.loop - Self.deltaJoins))
        let weave = 2 * Float.pi * span
        return (
            SIMD2<Float>(6.4 - 2.6 * span, -5.8 + 3.4 * span + 0.4 * sin(weave)),
            simd_normalize(SIMD2<Float>(-2.6, 3.4 + 0.4 * 2 * .pi * cos(weave)))
        )
    }

    // MARK: - Measurement

    /// Turns a ground truth map position into what the radio would have
    /// reported: a range and a bearing in our body frame, each with the noise
    /// its source earns.
    private func snapshot(
        id: String,
        mapPosition: SIMD2<Float>,
        mapFacing: Float,
        source: PeerSnapshot.Source,
        bearingNoise: Float,
        rangeNoise: Float,
        linkStage: Int,
        cameraAssisted: Bool,
        latencyMs: Int?,
        link: String?
    ) -> PeerSnapshot {
        let body = TacticalMapModel.mapToBody(mapPosition, yaw: yaw)
        let bearing = atan2(body.right, body.forward) + gaussian(standardDeviation: bearingNoise)
        let distance = max(simd_length(mapPosition) + gaussian(standardDeviation: rangeNoise), 0.2)
        return PeerSnapshot(
            id: id,
            name: id,
            distance: distance,
            source: source,
            bodyDirection: SIMD2<Float>(sin(bearing), cos(bearing)),
            facing: yaw - mapFacing,
            hint: nil,
            linkStage: linkStage,
            cameraAssisted: cameraAssisted,
            latencyMs: latencyMs,
            link: link
        )
    }

    private func mapAzimuth(of vector: SIMD2<Float>) -> Float {
        atan2(vector.x, vector.y)
    }

    private func gaussian(standardDeviation: Float) -> Float {
        let first = Float.random(in: 0.0001...1)
        let second = Float.random(in: 0...1)
        return standardDeviation * sqrt(-2 * log(first)) * cos(2 * .pi * second)
    }
}
#endif
