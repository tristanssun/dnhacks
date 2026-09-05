import Foundation
import MultipeerConnectivity
import simd

/// LocAR estimator (Miller et al., arXiv:2111.00174, §4) on iPhone hardware.
///
/// Joint state is factorized as P(D) Π_i P(V_i | D) (Rao-Blackwellization).
/// D is the display pose in its own ARKit world. Each V_i is a peer in that same
/// world plus a yaw offset θ from the peer's ARKit frame. Motion comes from
/// ARKit VIO on both phones, eqs. (4)–(7). Range comes from Nearby Interaction,
/// eq. (8). Nearby Interaction direction is used only by `calibrate`.
final class LocAREngine {
    struct Estimate {
        /// Expected range E[|V − D|]. Stays correct even while the bearing is
        /// still ambiguous (the cloud is a ring around the display).
        var distance: Float
        var direction: simd_float3
        var heading: Float
        /// Mean resultant length of the horizontal bearing distribution, 0...1.
        /// Near 1 the cloud agrees on a bearing; near 0 it is a uniform ring.
        var bearingConfidence: Float
        var worldPosition: SIMD3<Float>
    }

    private struct TargetParticle {
        var x: Float
        var y: Float
        var z: Float
        var theta: Float
        var weight: Float
    }

    private struct Hypothesis {
        var x: Float
        var y: Float
        var z: Float
        var weight: Float
        var targets: [MCPeerID: [TargetParticle]]
    }

    private static let displayCount = 64
    private static let targetCount = 120
    private let sigmaXYZ: Float = 0.015
    private let sigmaTheta: Float = 0.008
    private let sigmaRange: Float = 0.18
    private let nlosProbability: Float = 0.2
    private let jumpLimit: Float = 2.5

    private var hypotheses: [Hypothesis]
    private var lastLocalPosition: SIMD3<Float>?
    private var lastLocalTime: Date?
    private var lastRemotePose: [MCPeerID: (position: SIMD3<Float>, yaw: Float)] = [:]
    private(set) var localYaw: Float = 0
    private var cameraTransform = matrix_identity_float4x4
    private(set) var hasLocal = false

    init() {
        let count = Self.displayCount
        let weight = 1 / Float(count)
        hypotheses = (0..<count).map { _ in
            Hypothesis(x: 0, y: 0, z: 0, weight: weight, targets: [:])
        }
    }

    func forget(_ peerID: MCPeerID) {
        lastRemotePose[peerID] = nil
        for i in hypotheses.indices {
            hypotheses[i].targets[peerID] = nil
        }
    }

    func hasTargets(_ peerID: MCPeerID) -> Bool {
        hypotheses.first?.targets[peerID] != nil
    }

    // MARK: Motion

    /// Display VIO. Propagates D with eqs. (4)–(6), no yaw offset, since this
    /// motion is already in the display world. A re-origin (ARKit reset or a
    /// jump) shifts everything so relative vectors are preserved.
    func setLocal(_ pose: VIOTracker.Pose) {
        guard pose.isReliable else { return }
        cameraTransform = pose.transform
        localYaw = pose.yaw
        let now = Date()
        defer {
            lastLocalPosition = pose.position
            lastLocalTime = now
            hasLocal = true
        }
        guard let last = lastLocalPosition, let lastTime = lastLocalTime else {
            resetDisplay(around: pose.position)
            return
        }
        let delta = pose.position - last
        if pose.didResume || simd_length(delta) > jumpLimit {
            reorigin(to: pose.position)
            return
        }
        let dt = Float(now.timeIntervalSince(lastTime))
        let step = max(min(sqrt(dt / 0.1), 3), 0.2)
        for i in hypotheses.indices {
            hypotheses[i].x += delta.x + gauss(sigmaXYZ * step)
            hypotheses[i].y += delta.y + gauss(sigmaXYZ * step)
            hypotheses[i].z += delta.z + gauss(sigmaXYZ * step)
        }
    }

    /// Peer VIO. Applies eqs. (4)–(7) to every V_i | D_j cloud. A peer reset or
    /// jump is not motion and is skipped.
    func ingestRemoteVIO(peerID: MCPeerID, position: SIMD3<Float>, yaw: Float, isReset: Bool) {
        defer { lastRemotePose[peerID] = (position, yaw) }
        guard !isReset, let last = lastRemotePose[peerID], hasTargets(peerID) else { return }
        let dx = position.x - last.position.x
        let dy = position.y - last.position.y
        let dz = position.z - last.position.z
        guard simd_length(SIMD3(dx, dy, dz)) <= jumpLimit else { return }
        for i in hypotheses.indices {
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            for k in particles.indices {
                let theta = particles[k].theta
                let cosine = cos(theta)
                let sine = sin(theta)
                particles[k].x += dx * cosine + dz * sine + gauss(sigmaXYZ)
                particles[k].y += dy + gauss(sigmaXYZ)
                particles[k].z += dz * cosine - dx * sine + gauss(sigmaXYZ)
                particles[k].theta += gauss(sigmaTheta)
            }
            hypotheses[i].targets[peerID] = particles
        }
    }

    // MARK: Range

    /// UWB range z. Uniform ±3σ_r band plus P_nlos, eq. (8). Parent weight is
    /// the marginal P(z | D_j) = Σ_k w_k P(z | V_k, D_j). If almost no particle
    /// is inside the band, the cloud is lost and fresh sphere samples are injected.
    func ingestUWB(peerID: MCPeerID, range: Float) {
        guard hasLocal, range > 0.05, range < 80 else { return }
        ensureTargets(peerID, range: range)
        let limit = 3 * sigmaRange
        let inlierProbability = 1 - nlosProbability

        for i in hypotheses.indices {
            let display = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            var likelihood: Float = 0
            var inliers: Float = 0
            for k in particles.indices {
                let peer = SIMD3<Float>(particles[k].x, particles[k].y, particles[k].z)
                let error = abs(simd_length(peer - display) - range)
                let inside = error <= limit
                let probability = inside ? inlierProbability : nlosProbability
                if inside {
                    inliers += particles[k].weight
                }
                likelihood += particles[k].weight * probability
                particles[k].weight *= probability
            }
            normalize(&particles)
            if inliers < 0.15 {
                injectSphere(into: &particles, origin: display, range: range, fraction: 0.3)
            } else if effectiveCount(particles) < Float(Self.targetCount) * 0.5 {
                resample(&particles)
                injectSphere(into: &particles, origin: display, range: range, fraction: 0.1)
            }
            hypotheses[i].targets[peerID] = particles
            hypotheses[i].weight *= max(likelihood, 1e-8)
        }

        normalizeDisplay()
        if effectiveDisplayCount() < Float(Self.displayCount) * 0.5 {
            resampleDisplay()
        }
    }

    /// Recurring UWB lock-in. With a fresh Nearby Interaction direction the peer
    /// cloud is collapsed onto that 3D fix. Without direction, the cloud is only
    /// pulled onto the range sphere if it disagrees with the range by > 0.5 m.
    /// Returns true if anything was changed.
    func calibrate(peerID: MCPeerID, range: Float, direction: simd_float3?) -> Bool {
        guard hasLocal, range > 0.05, range < 25 else { return false }
        ensureTargets(peerID, range: range)
        let uniform = 1 / Float(Self.targetCount)

        if let direction, let world = niDirectionInWorld(direction) {
            for i in hypotheses.indices {
                let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                guard var particles = hypotheses[i].targets[peerID] else { continue }
                let target = origin + world * range
                for k in particles.indices {
                    if Float.random(in: 0...1) < 0.85 {
                        particles[k].x = target.x + gauss(0.08)
                        particles[k].y = target.y + gauss(0.05)
                        particles[k].z = target.z + gauss(0.08)
                    }
                    particles[k].weight = uniform
                }
                hypotheses[i].targets[peerID] = particles
            }
            return true
        }

        guard let expected = expectedRange(peerID) else { return false }
        guard abs(expected - range) > 0.5 else { return false }
        for i in hypotheses.indices {
            let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            for k in particles.indices {
                let peer = SIMD3<Float>(particles[k].x, particles[k].y, particles[k].z)
                var radial = peer - origin
                let length = simd_length(radial)
                if length < 0.08 {
                    radial = randomUnitVector() * range
                } else {
                    radial *= range / length
                }
                particles[k].x = origin.x + radial.x + gauss(0.08)
                particles[k].y = origin.y + radial.y + gauss(0.08)
                particles[k].z = origin.z + radial.z + gauss(0.08)
                particles[k].weight = uniform
            }
            hypotheses[i].targets[peerID] = particles
        }
        return true
    }

    // MARK: Output

    func estimate(for peerID: MCPeerID) -> Estimate? {
        guard hasLocal, hasTargets(peerID) else { return nil }
        var rangeSum: Float = 0
        var bearing = SIMD2<Float>.zero
        var world = SIMD3<Float>.zero
        var total: Float = 0
        var sinSum: Float = 0
        var cosSum: Float = 0
        for hypothesis in hypotheses {
            guard let particles = hypothesis.targets[peerID] else { continue }
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            for particle in particles {
                let point = SIMD3<Float>(particle.x, particle.y, particle.z)
                let relative = point - display
                let weight = hypothesis.weight * particle.weight
                rangeSum += simd_length(relative) * weight
                let planar = hypot(relative.x, relative.z)
                if planar > 0.02 {
                    bearing += SIMD2<Float>(relative.x, relative.z) / planar * weight
                }
                world += point * weight
                total += weight
                sinSum += sin(particle.theta) * weight
                cosSum += cos(particle.theta) * weight
            }
        }
        guard total > 0 else { return nil }
        bearing /= total
        let confidence = simd_length(bearing)
        let (right, forward) = bodyAxes(SIMD3<Float>(bearing.x, 0, bearing.y))
        let planar = hypot(right, forward)
        let direction = planar > 1e-4
            ? simd_float3(right / planar, forward / planar, 0)
            : simd_float3(0, 1, 0)
        let theta = atan2(sinSum, cosSum)
        let remoteYaw = lastRemotePose[peerID]?.yaw ?? 0
        let facing = SIMD3<Float>(sin(remoteYaw + theta), 0, cos(remoteYaw + theta))
        let (facingRight, facingForward) = bodyAxes(facing)
        return Estimate(
            distance: rangeSum / total,
            direction: direction,
            heading: atan2(facingRight, facingForward),
            bearingConfidence: confidence,
            worldPosition: world / total
        )
    }

    /// Nearby Interaction direction (device frame) converted to the radar's body
    /// frame: x right, y forward, projected onto the horizontal plane.
    func bodyDirection(fromNI direction: simd_float3) -> simd_float3? {
        guard hasLocal, let world = niDirectionInWorld(direction) else { return nil }
        let (right, forward) = bodyAxes(world)
        let planar = hypot(right, forward)
        guard planar > 0.05 else { return nil }
        return simd_float3(right / planar, forward / planar, 0)
    }

    // MARK: Internals

    private func resetDisplay(around position: SIMD3<Float>) {
        let weight = 1 / Float(Self.displayCount)
        for i in hypotheses.indices {
            hypotheses[i].x = position.x + gauss(0.03)
            hypotheses[i].y = position.y + gauss(0.03)
            hypotheses[i].z = position.z + gauss(0.03)
            hypotheses[i].weight = weight
        }
    }

    /// ARKit changed its origin. Move every hypothesis to the new position and
    /// carry its targets along so relative estimates survive.
    private func reorigin(to position: SIMD3<Float>) {
        for i in hypotheses.indices {
            let old = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            let shift = position - old
            hypotheses[i].x = position.x + gauss(0.02)
            hypotheses[i].y = position.y + gauss(0.02)
            hypotheses[i].z = position.z + gauss(0.02)
            for (peer, var particles) in hypotheses[i].targets {
                for k in particles.indices {
                    particles[k].x += shift.x
                    particles[k].y += shift.y
                    particles[k].z += shift.z
                }
                hypotheses[i].targets[peer] = particles
            }
        }
    }

    private func ensureTargets(_ peerID: MCPeerID, range: Float) {
        for i in hypotheses.indices where hypotheses[i].targets[peerID] == nil {
            let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            hypotheses[i].targets[peerID] = seedSphere(origin: origin, range: range)
        }
    }

    private func seedSphere(origin: SIMD3<Float>, range: Float) -> [TargetParticle] {
        let count = Self.targetCount
        let weight = 1 / Float(count)
        return (0..<count).map { _ in
            let radius = max(range + gauss(sigmaRange), 0.2)
            let point = origin + randomUnitVector() * radius
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
        let uniform = 1 / Float(particles.count)
        for i in 0..<count {
            particles[i] = extras[i]
            particles[i].weight = uniform
        }
        normalize(&particles)
    }

    private func expectedRange(_ peerID: MCPeerID) -> Float? {
        var sum: Float = 0
        var total: Float = 0
        for hypothesis in hypotheses {
            guard let particles = hypothesis.targets[peerID] else { continue }
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            for particle in particles {
                let weight = hypothesis.weight * particle.weight
                sum += simd_length(SIMD3(particle.x, particle.y, particle.z) - display) * weight
                total += weight
            }
        }
        guard total > 0 else { return nil }
        return sum / total
    }

    /// Nearby Interaction and ARKit share the device frame (+x right, +y up,
    /// +z toward the user), so the camera transform maps NI direction to world.
    private func niDirectionInWorld(_ direction: simd_float3) -> simd_float3? {
        let length = simd_length(direction)
        guard length > 0.05 else { return nil }
        let local = direction / length
        let rotated = cameraTransform * SIMD4<Float>(local.x, local.y, local.z, 0)
        let world = SIMD3<Float>(rotated.x, rotated.y, rotated.z)
        let worldLength = simd_length(world)
        guard worldLength > 0.05 else { return nil }
        return world / worldLength
    }

    /// Body frame from yaw ψ where forward = (sin ψ, cos ψ) in world (x, z).
    /// Right is (−cos ψ, sin ψ), matching ARKit's +x-right camera frame.
    private func bodyAxes(_ vector: SIMD3<Float>) -> (right: Float, forward: Float) {
        let cosine = cos(localYaw)
        let sine = sin(localYaw)
        let forward = vector.x * sine + vector.z * cosine
        let right = -vector.x * cosine + vector.z * sine
        return (right, forward)
    }

    private func normalize(_ particles: inout [TargetParticle]) {
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

    private func resample(_ particles: inout [TargetParticle]) {
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

    private func randomUnitVector() -> SIMD3<Float> {
        let lambda = Float.random(in: 0..<(2 * .pi))
        let phi = acos(Float.random(in: -1...1))
        return SIMD3<Float>(sin(phi) * cos(lambda), cos(phi), sin(phi) * sin(lambda))
    }

    private func gauss(_ sigma: Float) -> Float {
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        return sigma * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
