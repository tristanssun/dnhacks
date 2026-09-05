import Foundation
import MultipeerConnectivity
import simd

/// Exact LocAR estimator from Miller et al., "Multi-User Augmented Reality with
/// Infrastructure-free Collaborative Localization" (arXiv:2111.00174), §4.
///
/// Joint state is factorized as P(D) Π_i P(V_i | D) (Rao-Blackwellization).
/// D is the display pose in its own VIO world. Each V_i is a peer in that same
/// world, plus a yaw offset θ from the peer's VIO frame. Hardware is on-device
/// ARKit VIO and Nearby Interaction ranges. The measurement model is range-only,
/// as in the paper. NI direction is not used.
final class LocAREngine {
    struct Estimate {
        var distance: Float
        var direction: simd_float3
        var heading: Float
        var worldPosition: SIMD3<Float>
    }

    private struct TargetParticle {
        var x: Float
        var y: Float
        var z: Float
        var theta: Float
        var weight: Float
    }

    private struct TargetCloud {
        var particles: [TargetParticle]
    }

    private struct Hypothesis {
        var x: Float
        var y: Float
        var z: Float
        var weight: Float
        var targets: [MCPeerID: TargetCloud]
    }

    private static let displayCount = 64
    private static let targetCount = 120
    private let sigmaXYZ: Float = 0.015
    private let sigmaTheta: Float = 0.008
    private let sigmaRange: Float = 0.18
    private let nlosProbability: Float = 0.2

    private var hypotheses: [Hypothesis]
    private var lastLocalPosition: SIMD3<Float>?
    private var lastLocalTime: Date?
    private var lastRemotePose: [MCPeerID: (position: SIMD3<Float>, yaw: Float)] = [:]
    private var lastCalibration: [MCPeerID: Date] = [:]
    private var lastRange: [MCPeerID: Float] = [:]
    private(set) var localYaw: Float = 0
    private var cameraTransform = matrix_identity_float4x4
    private var hasLocal = false
    private let calibrationInterval: TimeInterval = 2

    init() {
        let count = Self.displayCount
        let weight = 1 / Float(count)
        hypotheses = (0..<count).map { _ in
            Hypothesis(x: 0, y: 0, z: 0, weight: weight, targets: [:])
        }
    }

    func forget(_ peerID: MCPeerID) {
        lastRemotePose[peerID] = nil
        lastCalibration[peerID] = nil
        lastRange[peerID] = nil
        for i in hypotheses.indices {
            hypotheses[i].targets[peerID] = nil
        }
    }

    /// Display VIO. Updates D with eqs. (4)–(6) without a yaw offset, since this
    /// motion is already in the display world.
    func setLocal(position: SIMD3<Float>, yaw: Float, transform: simd_float4x4) {
        cameraTransform = transform
        localYaw = yaw
        let now = Date()
        if let last = lastLocalPosition, let lastTime = lastLocalTime {
            let delta = position - last
            if simd_length(delta) > 2.5 {
                resetDisplay(around: position)
            } else {
                let dt = Float(now.timeIntervalSince(lastTime))
                let step = max(min(sqrt(dt / 0.1), 3), 0.2)
                for i in hypotheses.indices {
                    hypotheses[i].x += delta.x + gauss(sigmaXYZ * step)
                    hypotheses[i].y += delta.y + gauss(sigmaXYZ * step)
                    hypotheses[i].z += delta.z + gauss(sigmaXYZ * step)
                }
            }
        } else {
            resetDisplay(around: position)
        }
        lastLocalPosition = position
        lastLocalTime = now
        hasLocal = true
    }

    /// Peer VIO. Applies eqs. (4)–(7) to every V_i | D_j cloud.
    func ingestRemoteVIO(peerID: MCPeerID, position: SIMD3<Float>, yaw: Float) {
        ensureTargets(peerID, range: nil)
        if let last = lastRemotePose[peerID] {
            let dx = position.x - last.position.x
            let dy = position.y - last.position.y
            let dz = position.z - last.position.z
            for i in hypotheses.indices {
                guard var cloud = hypotheses[i].targets[peerID] else { continue }
                for k in cloud.particles.indices {
                    let theta = cloud.particles[k].theta
                    let cosine = cos(theta)
                    let sine = sin(theta)
                    cloud.particles[k].x += dx * cosine + dz * sine + gauss(sigmaXYZ)
                    cloud.particles[k].y += dy + gauss(sigmaXYZ)
                    cloud.particles[k].z += dz * cosine - dx * sine + gauss(sigmaXYZ)
                    cloud.particles[k].theta += gauss(sigmaTheta)
                }
                hypotheses[i].targets[peerID] = cloud
            }
        }
        lastRemotePose[peerID] = (position, yaw)
    }

    /// UWB range z. Uniform ±3σ_r band plus P_nlos, eq. (8). Parent weight is
    /// the marginal P(z | D_j) = Σ_k w_k P(z | V_k, D_j).
    func ingestUWB(peerID: MCPeerID, range: Float) {
        guard hasLocal, range > 0.05, range < 80 else { return }
        lastRange[peerID] = range
        ensureTargets(peerID, range: range)
        if shouldSnapToRange(peerID, range: range) {
            snapToRange(peerID, range: range, direction: nil)
        }
        let limit = 3 * sigmaRange

        for i in hypotheses.indices {
            let display = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            guard var cloud = hypotheses[i].targets[peerID] else { continue }
            var likelihood: Float = 0
            for k in cloud.particles.indices {
                let peer = SIMD3<Float>(cloud.particles[k].x, cloud.particles[k].y, cloud.particles[k].z)
                let error = abs(simd_length(peer - display) - range)
                let probability: Float = error > limit ? nlosProbability : (1 - nlosProbability)
                likelihood += cloud.particles[k].weight * probability
                cloud.particles[k].weight *= probability
            }
            normalizeTargets(&cloud.particles)
            if effectiveCount(cloud.particles) < Float(Self.targetCount) * 0.5 {
                resampleTargets(&cloud.particles)
                injectSphere(into: &cloud.particles, origin: display, range: range, fraction: 0.15)
            }
            hypotheses[i].targets[peerID] = cloud
            hypotheses[i].weight *= max(likelihood, 1e-8)
        }

        normalizeDisplay()
        if effectiveDisplayCount() < Float(Self.displayCount) * 0.5 {
            resampleDisplay()
        }
    }

    /// Recurring UWB lock-in. When Nearby Interaction has a fresh range, and
    /// direction if we are in LOS, collapse V onto that fix. Runs at most once
    /// per `calibrationInterval` per peer.
    @discardableResult
    func calibrateIfDue(peerID: MCPeerID, range: Float, direction: simd_float3?) -> Bool {
        guard hasLocal, range > 0.05, range < 25 else { return false }
        lastRange[peerID] = range
        let now = Date()
        let wait = range < 1.5 ? 0.25 : calibrationInterval
        if let last = lastCalibration[peerID], now.timeIntervalSince(last) < wait {
            return false
        }
        snapToRange(peerID, range: range, direction: direction)
        lastCalibration[peerID] = now
        return true
    }

    private func shouldSnapToRange(_ peerID: MCPeerID, range: Float) -> Bool {
        if range < 1.5 { return true }
        guard let current = planarDistance(peerID) else { return false }
        return range + 0.6 < current
    }

    private func snapToRange(_ peerID: MCPeerID, range: Float, direction: simd_float3?) {
        ensureTargets(peerID, range: range)
        let worldDirection = direction.flatMap { niDirectionInWorld($0) }
        let jitter: Float = range < 1.5 ? 0.05 : 0.1
        for i in hypotheses.indices {
            let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            guard var cloud = hypotheses[i].targets[peerID] else { continue }
            if let worldDirection {
                let target = origin + worldDirection * range
                for k in cloud.particles.indices {
                    cloud.particles[k].x = target.x + gauss(jitter)
                    cloud.particles[k].y = origin.y + gauss(jitter * 0.5)
                    cloud.particles[k].z = target.z + gauss(jitter)
                    cloud.particles[k].weight = 1 / Float(Self.targetCount)
                }
            } else {
                for k in cloud.particles.indices {
                    let peer = SIMD3<Float>(cloud.particles[k].x, cloud.particles[k].y, cloud.particles[k].z)
                    var radial = SIMD3<Float>(peer.x - origin.x, 0, peer.z - origin.z)
                    let length = simd_length(radial)
                    if length < 0.08 {
                        let angle = Float.random(in: 0..<(2 * .pi))
                        radial = SIMD3<Float>(sin(angle) * range, 0, cos(angle) * range)
                    } else {
                        radial = (radial / length) * range
                    }
                    cloud.particles[k].x = origin.x + radial.x + gauss(jitter)
                    cloud.particles[k].y = origin.y + gauss(jitter * 0.4)
                    cloud.particles[k].z = origin.z + radial.z + gauss(jitter)
                    cloud.particles[k].weight = 1 / Float(Self.targetCount)
                }
            }
            hypotheses[i].targets[peerID] = cloud
        }
    }

    private func planarDistance(_ peerID: MCPeerID) -> Float? {
        guard let estimate = estimateRelative(peerID) else { return nil }
        return hypot(estimate.x, estimate.z)
    }

    private func estimateRelative(_ peerID: MCPeerID) -> SIMD3<Float>? {
        var relative = SIMD3<Float>.zero
        var weightSum: Float = 0
        for hypothesis in hypotheses {
            guard let cloud = hypothesis.targets[peerID], let mean = meanPosition(cloud) else { continue }
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            relative += (mean - display) * hypothesis.weight
            weightSum += hypothesis.weight
        }
        guard weightSum > 0 else { return nil }
        return relative / weightSum
    }

    private func niDirectionInWorld(_ direction: simd_float3) -> simd_float3? {
        var local = direction
        if abs(local.z) < 0.18, hypot(local.x, local.y) > 0.4 {
            local = simd_float3(local.x, 0, -local.y)
        }
        let length = simd_length(local)
        guard length > 0.05 else { return nil }
        local /= length
        let rotated = cameraTransform * SIMD4<Float>(local.x, local.y, local.z, 0)
        let world = SIMD3<Float>(rotated.x, rotated.y, rotated.z)
        let worldLength = simd_length(world)
        guard worldLength > 0.05 else { return nil }
        return world / worldLength
    }

    func estimate(for peerID: MCPeerID) -> Estimate? {
        guard hasLocal else { return nil }
        var relative = SIMD3<Float>.zero
        var world = SIMD3<Float>.zero
        var weightSum: Float = 0
        var sinSum: Float = 0
        var cosSum: Float = 0
        for hypothesis in hypotheses {
            guard let cloud = hypothesis.targets[peerID] else { continue }
            guard let mean = meanPosition(cloud) else { continue }
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            relative += (mean - display) * hypothesis.weight
            world += mean * hypothesis.weight
            weightSum += hypothesis.weight
            for particle in cloud.particles {
                let weight = hypothesis.weight * particle.weight
                sinSum += sin(particle.theta) * weight
                cosSum += cos(particle.theta) * weight
            }
        }
        guard weightSum > 0 else { return nil }
        relative /= weightSum
        world /= weightSum
        let (right, forward) = bodyAxes(relative)
        let planar = hypot(right, forward)
        let direction: simd_float3
        if planar > 0.02 {
            direction = simd_float3(right / planar, forward / planar, 0)
        } else {
            direction = simd_float3(0, 1, 0)
        }
        let theta = atan2(sinSum, cosSum)
        let remoteYaw = lastRemotePose[peerID]?.yaw ?? 0
        let worldSin = sin(remoteYaw + theta)
        let worldCos = cos(remoteYaw + theta)
        let headingRight = worldSin * cos(localYaw) - worldCos * sin(localYaw)
        let headingForward = worldSin * sin(localYaw) + worldCos * cos(localYaw)
        let measured = lastRange[peerID]
        let horizontal = hypot(relative.x, relative.z)
        return Estimate(
            distance: measured ?? horizontal,
            direction: direction,
            heading: atan2(headingRight, headingForward),
            worldPosition: world
        )
    }

    private func resetDisplay(around position: SIMD3<Float>) {
        let weight = 1 / Float(Self.displayCount)
        for i in hypotheses.indices {
            hypotheses[i].x = position.x + gauss(0.03)
            hypotheses[i].y = position.y + gauss(0.03)
            hypotheses[i].z = position.z + gauss(0.03)
            hypotheses[i].weight = weight
        }
    }

    private func ensureTargets(_ peerID: MCPeerID, range: Float?) {
        let seedRange = range ?? 3
        for i in hypotheses.indices {
            if hypotheses[i].targets[peerID] == nil {
                let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                hypotheses[i].targets[peerID] = TargetCloud(particles: seedSphere(origin: origin, range: seedRange))
            }
        }
    }

    private func seedSphere(origin: SIMD3<Float>, range: Float) -> [TargetParticle] {
        let count = Self.targetCount
        let weight = 1 / Float(count)
        return (0..<count).map { _ in
            let lambda = Float.random(in: 0..<(2 * .pi))
            let phi = acos(Float.random(in: -1...1))
            let radius = max(range + gauss(sigmaRange), 0.2)
            let offset = SIMD3<Float>(
                sin(phi) * cos(lambda),
                cos(phi),
                sin(phi) * sin(lambda)
            ) * radius
            let point = origin + offset
            return TargetParticle(
                x: point.x,
                y: point.y,
                z: point.z,
                theta: Float.random(in: 0..<(2 * .pi)),
                weight: weight
            )
        }
    }

    private func injectSphere(into particles: inout [TargetParticle], origin: SIMD3<Float>, range: Float, fraction: Float) {
        let count = max(Int(Float(particles.count) * fraction), 1)
        let extras = seedSphere(origin: origin, range: range)
        for i in 0..<count {
            particles[i] = extras[i]
        }
        normalizeTargets(&particles)
    }

    private func meanPosition(_ cloud: TargetCloud) -> SIMD3<Float>? {
        var position = SIMD3<Float>.zero
        var weight: Float = 0
        for particle in cloud.particles {
            position += SIMD3(particle.x, particle.y, particle.z) * particle.weight
            weight += particle.weight
        }
        guard weight > 0 else { return nil }
        return position / weight
    }

    private func bodyAxes(_ relative: SIMD3<Float>) -> (Float, Float) {
        let cosine = cos(localYaw)
        let sine = sin(localYaw)
        let right = relative.x * cosine - relative.z * sine
        let forward = relative.x * sine + relative.z * cosine
        return (right, forward)
    }

    private func normalizeTargets(_ particles: inout [TargetParticle]) {
        let sum = particles.reduce(Float.zero) { $0 + $1.weight }
        let count = max(particles.count, 1)
        guard sum > 0 else {
            let equal = 1 / Float(count)
            for i in particles.indices {
                particles[i].weight = equal
            }
            return
        }
        for i in particles.indices {
            particles[i].weight /= sum
        }
    }

    private func normalizeDisplay() {
        let sum = hypotheses.reduce(Float.zero) { $0 + $1.weight }
        let count = max(hypotheses.count, 1)
        guard sum > 0 else {
            let equal = 1 / Float(count)
            for i in hypotheses.indices {
                hypotheses[i].weight = equal
            }
            return
        }
        for i in hypotheses.indices {
            hypotheses[i].weight /= sum
        }
    }

    private func effectiveCount(_ particles: [TargetParticle]) -> Float {
        let sumSquares = particles.reduce(Float.zero) { $0 + $1.weight * $1.weight }
        return sumSquares > 0 ? 1 / sumSquares : 0
    }

    private func effectiveDisplayCount() -> Float {
        let sumSquares = hypotheses.reduce(Float.zero) { $0 + $1.weight * $1.weight }
        return sumSquares > 0 ? 1 / sumSquares : 0
    }

    private func resampleTargets(_ particles: inout [TargetParticle]) {
        let count = particles.count
        guard count > 1 else { return }
        var cdf = [Float](repeating: 0, count: count)
        cdf[0] = particles[0].weight
        for i in 1..<count {
            cdf[i] = cdf[i - 1] + particles[i].weight
        }
        var next = particles
        var index = 0
        let start = Float.random(in: 0..<(1 / Float(count)))
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < count - 1, probe > cdf[index] {
                index += 1
            }
            next[step] = particles[index]
            next[step].weight = 1 / Float(count)
        }
        particles = next
    }

    private func resampleDisplay() {
        let count = hypotheses.count
        guard count > 1 else { return }
        var cdf = [Float](repeating: 0, count: count)
        cdf[0] = hypotheses[0].weight
        for i in 1..<count {
            cdf[i] = cdf[i - 1] + hypotheses[i].weight
        }
        var next = hypotheses
        var index = 0
        let start = Float.random(in: 0..<(1 / Float(count)))
        let weight = 1 / Float(count)
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < count - 1, probe > cdf[index] {
                index += 1
            }
            next[step] = hypotheses[index]
            next[step].weight = weight
        }
        hypotheses = next
    }

    private func gauss(_ sigma: Float) -> Float {
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        return sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
