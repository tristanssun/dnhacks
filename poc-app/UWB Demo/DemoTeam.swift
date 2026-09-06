#if targetEnvironment(simulator)
import Combine
import Foundation
import simd

@MainActor
final class DemoTeam: ObservableObject {
    @Published private(set) var snapshots: [PeerSnapshot] = []
    @Published private(set) var yaw: Float = 0
    @Published private(set) var heading: Float = 1.2
    @Published private(set) var trackingState = "normal"
    @Published private(set) var frameEpoch = 0

    let perf = PerfMonitor()

    private var timer: Timer?
    private var startedAt = Date().timeIntervalSinceReferenceDate
    private var tickCount = 0
    private let charliePoints: [SIMD2<Float>]
    private let charlieDistances: [Float]
    private let charlieLength: Float

    init() {
        let sampleCount = 2_048
        var points: [SIMD2<Float>] = []
        var distances: [Float] = [0]
        points.reserveCapacity(sampleCount + 1)
        distances.reserveCapacity(sampleCount + 1)

        for index in 0...sampleCount {
            let angle = Float(index) / Float(sampleCount) * 2 * .pi
            let point = SIMD2<Float>(3 * sin(angle), 6.5 + 2 * sin(2 * angle))
            if let previous = points.last {
                distances.append((distances.last ?? 0) + simd_length(point - previous))
            }
            points.append(point)
        }
        charliePoints = points
        charlieDistances = distances
        charlieLength = distances.last ?? 1
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date().timeIntervalSinceReferenceDate
        tickCount = 0
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
        let elapsed = now - startedAt
        tickCount += 1
        yaw = 0.5 * sin(Float(2 * Double.pi * elapsed / 20))
        heading = 1.2 - yaw

        let bravoTruth = roundedRectangle(distance: Float(elapsed) * 2.8)
        var bravoPosition = bravoTruth.position
        if tickCount > 1, tickCount.isMultiple(of: 90) {
            let glitchAngle = Float.random(in: 0..<(2 * .pi))
            bravoPosition += SIMD2<Float>(sin(glitchAngle), cos(glitchAngle)) * 1.8
        }
        let bravo = noisySnapshot(
            id: "BRAVO",
            mapPosition: bravoPosition,
            mapFacing: mapAzimuth(of: bravoTruth.tangent),
            source: .live,
            hint: nil,
            linkStage: 4,
            cameraAssisted: true,
            latencyMs: Int.random(in: 40...80),
            link: "mc tok ni run cam θ12/0.94"
        )

        let charlieSample = charlie(distance: Float(elapsed) * 1.2)
        let charliePhase = elapsed.truncatingRemainder(dividingBy: 12)
        let charlieHasBearing = charliePhase < 8
        let charlie = snapshot(
            id: "CHARLIE",
            mapPosition: charlieSample.position,
            mapFacing: mapAzimuth(of: charlieSample.tangent),
            source: charlieHasBearing ? .live : .aging,
            hasBearing: charlieHasBearing,
            hint: "Sweep phone left/right",
            linkStage: 3,
            cameraAssisted: false,
            latencyMs: 92,
            link: "mc tok ni run✗ θ-8/0.71"
        )

        let delta = snapshot(
            id: "DELTA",
            mapPosition: SIMD2<Float>(3, -7),
            mapFacing: .pi,
            source: .relayed,
            hasBearing: true,
            hint: nil,
            linkStage: 2,
            cameraAssisted: false,
            latencyMs: 138,
            link: "mc tok ni✗ run✗ θ180/0.52"
        )

        var next = [bravo, charlie, delta]
        if elapsed >= 20, elapsed < 35 {
            next.append(snapshot(
                id: "ECHO",
                mapPosition: SIMD2<Float>(0, 20),
                mapFacing: 0,
                source: .inferred,
                hasBearing: true,
                hint: nil,
                linkStage: 1,
                cameraAssisted: false,
                latencyMs: 224,
                link: "mc tok✗ ni✗ run✗ θ0/0.33"
            ))
        }
        snapshots = next
    }

    private func noisySnapshot(
        id: String,
        mapPosition: SIMD2<Float>,
        mapFacing: Float,
        source: PeerSnapshot.Source,
        hint: String?,
        linkStage: Int,
        cameraAssisted: Bool,
        latencyMs: Int?,
        link: String?
    ) -> PeerSnapshot {
        let body = TacticalMapModel.mapToBody(mapPosition, yaw: yaw)
        let angle = atan2(body.right, body.forward) + gaussian(standardDeviation: 4 * .pi / 180)
        let distance = max(simd_length(mapPosition) + gaussian(standardDeviation: 0.15), 0.2)
        return PeerSnapshot(
            id: id,
            name: id,
            distance: distance,
            source: source,
            bodyDirection: SIMD2<Float>(sin(angle), cos(angle)),
            facing: yaw - mapFacing,
            hint: hint,
            linkStage: linkStage,
            cameraAssisted: cameraAssisted,
            latencyMs: latencyMs,
            link: link
        )
    }

    private func snapshot(
        id: String,
        mapPosition: SIMD2<Float>,
        mapFacing: Float,
        source: PeerSnapshot.Source,
        hasBearing: Bool,
        hint: String?,
        linkStage: Int,
        cameraAssisted: Bool,
        latencyMs: Int?,
        link: String?
    ) -> PeerSnapshot {
        let body = TacticalMapModel.mapToBody(mapPosition, yaw: yaw)
        let distance = simd_length(mapPosition)
        let direction = distance > 0
            ? SIMD2<Float>(body.right / distance, body.forward / distance)
            : nil
        return PeerSnapshot(
            id: id,
            name: id,
            distance: distance,
            source: source,
            bodyDirection: hasBearing ? direction : nil,
            facing: yaw - mapFacing,
            hint: hint,
            linkStage: linkStage,
            cameraAssisted: cameraAssisted,
            latencyMs: latencyMs,
            link: link
        )
    }

    private func roundedRectangle(distance: Float) -> (position: SIMD2<Float>, tangent: SIMD2<Float>) {
        let cornerLength = Float.pi / 2
        let perimeter = 24 + 2 * Float.pi
        var cursor = distance.truncatingRemainder(dividingBy: perimeter)

        if cursor < 8 {
            return (SIMD2<Float>(-4 + cursor, 3), SIMD2<Float>(1, 0))
        }
        cursor -= 8
        if cursor < cornerLength {
            return (
                SIMD2<Float>(4 + sin(cursor), 2 + cos(cursor)),
                SIMD2<Float>(cos(cursor), -sin(cursor))
            )
        }
        cursor -= cornerLength
        if cursor < 4 {
            return (SIMD2<Float>(5, 2 - cursor), SIMD2<Float>(0, -1))
        }
        cursor -= 4
        if cursor < cornerLength {
            return (
                SIMD2<Float>(4 + cos(cursor), -2 - sin(cursor)),
                SIMD2<Float>(-sin(cursor), -cos(cursor))
            )
        }
        cursor -= cornerLength
        if cursor < 8 {
            return (SIMD2<Float>(4 - cursor, -3), SIMD2<Float>(-1, 0))
        }
        cursor -= 8
        if cursor < cornerLength {
            return (
                SIMD2<Float>(-4 - sin(cursor), -2 - cos(cursor)),
                SIMD2<Float>(-cos(cursor), sin(cursor))
            )
        }
        cursor -= cornerLength
        if cursor < 4 {
            return (SIMD2<Float>(-5, -2 + cursor), SIMD2<Float>(0, 1))
        }
        cursor -= 4
        return (
            SIMD2<Float>(-4 - cos(cursor), 2 + sin(cursor)),
            SIMD2<Float>(sin(cursor), cos(cursor))
        )
    }

    private func charlie(distance: Float) -> (position: SIMD2<Float>, tangent: SIMD2<Float>) {
        let target = distance.truncatingRemainder(dividingBy: charlieLength)
        var lower = 0
        var upper = charlieDistances.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if charlieDistances[middle] <= target {
                lower = middle
            } else {
                upper = middle
            }
        }
        let span = max(charlieDistances[upper] - charlieDistances[lower], 0.0001)
        let fraction = (target - charlieDistances[lower]) / span
        let position = charliePoints[lower] + (charliePoints[upper] - charliePoints[lower]) * fraction
        let tangent = simd_normalize(charliePoints[upper] - charliePoints[lower])
        return (position, tangent)
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
