import Foundation
import MultipeerConnectivity
import QuartzCore
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
        /// Circular mean of the yaw offset between this peer's ARKit frame and
        /// ours, radians.
        var theta: Float
        /// Mean resultant length of that distribution, 0...1. Near 0 the clouds
        /// disagree about θ entirely, which is where the bearing error that
        /// grows with distance comes from.
        var thetaConfidence: Float
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

    /// Restored to 64 x 120 after 32 x 96 measurably degraded accuracy on
    /// device. The filter needs this much representational capacity; recover
    /// the CPU by making the per-particle work cheaper, not by removing
    /// particles.
    private static let displayCount = 64
    private static let targetCount = 120
    /// Position noise after 0.1 m of VIO travel.
    private let sigmaXYZ: Float = 0.015
    /// Small residual ARKit drift while stationary, metres per sqrt(second).
    private let staticSigmaXYZ: Float = 0.001
    /// θ is the offset between two ARKit frames, so its real process noise is
    /// ARKit yaw drift — about 2°/min per device, ~0.049 rad/min relative. At
    /// the 10 Hz remote VIO rate a random walk accumulates as σ·√600, so σ per
    /// message is 0.049/24.5. The previous 0.008 injected four times the drift
    /// the hardware has: ~11°/min of self-inflicted spread, 1.7 m of lateral
    /// error at 9 m.
    private let sigmaTheta: Float = 0.002
    /// Half-width of the compass agreement band, radians. Wide because indoor
    /// magnetic bias is tens of degrees; this is a floor on how bad θ can get,
    /// not a source of precision.
    private let thetaAnchorBand: Float = 0.7
    private let sigmaRange: Float = 0.18
    /// Camera-assisted `horizontalAngle` accuracy once converged, radians.
    private let sigmaBearing: Float = 0.12
    private let nlosProbability: Float = 0.2
    private let jumpLimit: Float = 2.5
    /// Anchor samples drawn per hypothesis when applying a peer-to-peer range.
    private static let anchorSamples = 16

    private var hypotheses: [Hypothesis]
    private var lastLocalPosition: SIMD3<Float>?
    /// ARKit frame timestamp of the last accepted local pose.
    private var lastLocalTime: TimeInterval?
    private var lastRemotePose: [MCPeerID: (position: SIMD3<Float>, yaw: Float)] = [:]
    private(set) var localYaw: Float = 0
    private var cameraTransform = matrix_identity_float4x4
    private(set) var hasLocal = false
    /// Coarse θ per peer from the two compasses, set by `PeerManager`. Used only
    /// to seed: `seedSphere` otherwise drew θ uniformly over the full circle, so
    /// a cold cloud started with no idea of the peer's frame orientation at all.
    private var thetaPrior: [MCPeerID: Float] = [:]
    /// Indoor magnetometers are far too biased to measure θ — that is why the
    /// filter does not treat this as an observation — but ±30° of prior beats a
    /// uniform circle, and it costs nothing.
    private let thetaPriorSigma: Float = 0.52

    init() {
        let count = Self.displayCount
        let weight = 1 / Float(count)
        hypotheses = (0..<count).map { _ in
            Hypothesis(x: 0, y: 0, z: 0, weight: weight, targets: [:])
        }
    }

    /// Radians, or nil to fall back to a uniform draw.
    func setThetaPrior(_ radians: Float?, for peerID: MCPeerID) {
        thetaPrior[peerID] = radians
    }

    func forget(_ peerID: MCPeerID) {
        lastRemotePose[peerID] = nil
        thetaPrior[peerID] = nil
        for i in hypotheses.indices {
            hypotheses[i].targets[peerID] = nil
        }
    }

    func hasTargets(_ peerID: MCPeerID) -> Bool {
        hypotheses.first?.targets[peerID] != nil
    }

    // MARK: Motion

    /// Display VIO. Propagates D with eqs. (4)–(6), no yaw offset, since this
    /// motion is already in the display world. Process variance grows with VIO
    /// distance travelled, plus a small time floor for genuine static drift.
    /// A re-origin (ARKit reset or a jump) shifts everything so relative vectors
    /// are preserved.
    func setLocal(_ pose: VIOTracker.Pose) {
        guard pose.isReliable else { return }
        cameraTransform = pose.transform
        localYaw = pose.yaw
        defer {
            lastLocalPosition = pose.position
            lastLocalTime = pose.timestamp
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
        // Capture-time dt: the small static floor follows actual frame time, not
        // how late the main thread got around to this frame. Independent motion
        // and static drift variances add in quadrature.
        let dt = Float(max(pose.timestamp - lastTime, 0))
        let distance = simd_length(delta)
        let motionSigma = sigmaXYZ * sqrt(distance / 0.1)
        let staticSigma = staticSigmaXYZ * sqrt(dt)
        let processSigma = hypot(motionSigma, staticSigma)
        for i in hypotheses.indices {
            hypotheses[i].x += delta.x + gauss(processSigma)
            hypotheses[i].y += delta.y + gauss(processSigma)
            hypotheses[i].z += delta.z + gauss(processSigma)
        }
        recenterDisplay(on: pose.position)
    }

    /// Peer VIO. Applies eqs. (4)–(7) to every V_i | D_j cloud. A peer reset or
    /// jump is not motion and is skipped.
    func ingestRemoteVIO(peerID: MCPeerID, position: SIMD3<Float>, yaw: Float, isReset: Bool) {
        defer { lastRemotePose[peerID] = (position, yaw) }
        guard !isReset, let last = lastRemotePose[peerID], hasTargets(peerID) else { return }
        let dx = position.x - last.position.x
        let dy = position.y - last.position.y
        let dz = position.z - last.position.z
        let distance = simd_length(SIMD3(dx, dy, dz))
        guard distance <= jumpLimit else { return }
        let translated = distance >= 0.02
        for i in hypotheses.indices {
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            for k in particles.indices {
                let theta = particles[k].theta
                let cosine = cos(theta)
                let sine = sin(theta)
                particles[k].x += dx * cosine + dz * sine + gauss(sigmaXYZ)
                particles[k].y += dy + gauss(sigmaXYZ)
                particles[k].z += dz * cosine - dx * sine + gauss(sigmaXYZ)
                // Eq. (7) is observable only through translated VIO. A stationary
                // peer therefore neither learns nor diffuses its frame yaw offset.
                particles[k].theta = Self.wrap(theta + (translated ? gauss(sigmaTheta) : 0))
            }
            hypotheses[i].targets[peerID] = particles
        }
    }

    /// Weak absolute anchor on θ from the two compasses, applied only once the
    /// cloud has already lost θ.
    ///
    /// Indoor magnetic bias is tens of degrees, so applying this continuously
    /// would make the filter confidently wrong at whatever the local bias is —
    /// the bias is systematic, and repeated application compounds it rather
    /// than averaging it out. But θ has no other restoring force: its only
    /// observation scales with peer displacement, so a peer that stays still
    /// lets θ random-walk anywhere on the circle with nothing to stop it.
    ///
    /// Applying it only on degeneracy makes it a recovery path rather than a
    /// continuous force: it bounds how bad θ can get without capping how good
    /// θ can become when real observations are available.
    func ingestThetaAnchor(peerID: MCPeerID, theta: Float) {
        guard hasTargets(peerID), theta.isFinite else { return }
        let inlierProbability = 1 - nlosProbability
        for i in hypotheses.indices {
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            for k in particles.indices {
                let error = abs(Self.wrap(particles[k].theta - theta))
                particles[k].weight *= error <= thetaAnchorBand ? inlierProbability : nlosProbability
            }
            normalize(&particles)
            hypotheses[i].targets[peerID] = particles
        }
    }

    // MARK: Range

    /// UWB range z. Uniform ±3σ_r band plus P_nlos, eq. (8). Parent weight is
    /// the marginal P(z | D_j) = Σ_k w_k P(z | V_k, D_j). If almost no particle
    /// is inside the band, the cloud is lost and fresh sphere samples are injected;
    /// routine low ESS only resamples and roughens the surviving cloud.
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
            }
            hypotheses[i].targets[peerID] = particles
            hypotheses[i].weight *= max(likelihood, 1e-8)
        }

        normalizeDisplay()
        if effectiveDisplayCount() < Float(Self.displayCount) * 0.5 {
            resampleDisplay()
        }
        recenterDisplayOnLocalPose()
    }

    /// Azimuth to the peer in the body frame (0 = forward, positive = right),
    /// from camera-assisted `horizontalAngle` or a projected NI direction.
    /// Same uniform-plus-P_nlos form as the range model, applied to bearing.
    func ingestBearing(peerID: MCPeerID, bodyAngle: Float) {
        guard hasLocal, hasTargets(peerID), bodyAngle.isFinite else { return }
        let world = worldBearing(bodyAngle: bodyAngle)
        let worldAngle = atan2(world.x, world.y)
        let limit = 3 * sigmaBearing
        let inlierProbability = 1 - nlosProbability

        for i in hypotheses.indices {
            let display = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            guard var particles = hypotheses[i].targets[peerID] else { continue }
            var likelihood: Float = 0
            var inliers: Float = 0
            var rangeSum: Float = 0
            for k in particles.indices {
                let relative = SIMD3<Float>(particles[k].x, particles[k].y, particles[k].z) - display
                let planar = hypot(relative.x, relative.z)
                rangeSum += simd_length(relative) * particles[k].weight
                let inside: Bool
                if planar < 0.1 {
                    inside = false
                } else {
                    let error = Self.wrap(atan2(relative.x, relative.z) - worldAngle)
                    inside = abs(error) <= limit
                }
                let probability = inside ? inlierProbability : nlosProbability
                if inside {
                    inliers += particles[k].weight
                }
                likelihood += particles[k].weight * probability
                particles[k].weight *= probability
            }
            normalize(&particles)
            if inliers < 0.15 {
                injectRay(into: &particles, origin: display, bearing: world, range: max(rangeSum, 0.3), fraction: 0.3)
            } else if effectiveCount(particles) < Float(Self.targetCount) * 0.5 {
                resample(&particles)
            }
            hypotheses[i].targets[peerID] = particles
            hypotheses[i].weight *= max(likelihood, 1e-8)
        }

        normalizeDisplay()
        if effectiveDisplayCount() < Float(Self.displayCount) * 0.5 {
            resampleDisplay()
        }
        recenterDisplayOnLocalPose()
    }

    /// Range between two other peers, z_ab, shared over the network. Each side
    /// is weighted against samples drawn from the other side's cloud, so two
    /// unresolved rings still learn the angle between them (triangle rigidity),
    /// and a peer we can't range ourselves is placed relative to one we can.
    func ingestPeerRange(_ a: MCPeerID, _ b: MCPeerID, range: Float) {
        guard hasLocal, a != b, range > 0.05, range < 80 else { return }
        guard hasTargets(a) || hasTargets(b) else { return }
        constrain(a, by: b, range: range)
        constrain(b, by: a, range: range)
    }

    private func constrain(_ target: MCPeerID, by anchor: MCPeerID, range: Float) {
        let limit = 3 * sigmaRange
        let inlierProbability = 1 - nlosProbability
        for i in hypotheses.indices {
            guard let anchorCloud = hypotheses[i].targets[anchor] else { continue }
            let anchors = sample(anchorCloud, count: Self.anchorSamples)
            guard !anchors.isEmpty else { continue }
            guard var particles = hypotheses[i].targets[target] else {
                // First sight of this peer via a third party: seed around the anchor.
                let origin = anchors[Int.random(in: 0..<anchors.count)]
                hypotheses[i].targets[target] = seedSphere(origin: origin, range: range)
                continue
            }
            var inliers: Float = 0
            for k in particles.indices {
                let point = SIMD3<Float>(particles[k].x, particles[k].y, particles[k].z)
                var hits = 0
                for anchorPoint in anchors where abs(simd_length(point - anchorPoint) - range) <= limit {
                    hits += 1
                }
                let fraction = Float(hits) / Float(anchors.count)
                let probability = nlosProbability + (inlierProbability - nlosProbability) * fraction
                if hits > 0 {
                    inliers += particles[k].weight
                }
                particles[k].weight *= probability
            }
            normalize(&particles)
            if inliers < 0.15 {
                let origin = anchors[Int.random(in: 0..<anchors.count)]
                injectSphere(into: &particles, origin: origin, range: range, fraction: 0.3)
            } else if effectiveCount(particles) < Float(Self.targetCount) * 0.5 {
                resample(&particles)
            }
            hypotheses[i].targets[target] = particles
        }
    }

    /// A peer's estimate of target − anchor (§8), expressed in the anchor's
    /// ARKit frame. Sampling both anchor position and θ preserves their joint
    /// uncertainty: θ is the transform that rotates the shared vector into this
    /// display's frame before it can constrain the target cloud.
    func ingestRelativeEstimate(target: MCPeerID, anchor: MCPeerID, vector: SIMD3<Float>, confidence: Float) {
        guard hasLocal, target != anchor, hasTargets(anchor),
              vector.x.isFinite, vector.y.isFinite, vector.z.isFinite,
              confidence.isFinite else { return }
        let boundedConfidence = min(max(confidence, 0), 1)
        // Linear interpolation gives a camera-resolved estimate a roughly 0.5 m
        // acceptance ball while an unresolved estimate remains a useful but soft
        // 3 m constraint. Clamping above keeps the radius finite and positive.
        let limit: Float = 3.0 - 2.5 * boundedConfidence
        guard limit.isFinite, limit > 0 else { return }
        let inlierProbability = 1 - nlosProbability

        for i in hypotheses.indices {
            guard let anchorCloud = hypotheses[i].targets[anchor] else { continue }
            let anchors = samplePoses(anchorCloud, count: Self.anchorSamples)
            guard !anchors.isEmpty else { continue }
            let implied = anchors.map { sample -> SIMD3<Float> in
                let cosine = cos(sample.theta)
                let sine = sin(sample.theta)
                let rotated = SIMD3<Float>(
                    vector.x * cosine + vector.z * sine,
                    vector.y,
                    vector.z * cosine - vector.x * sine
                )
                return sample.position + rotated
            }
            guard implied.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { continue }

            // Summarise the anchor's uncertainty as a mean and a spread instead
            // of testing every particle against every implied point. That inner
            // loop was 120 x 16 per hypothesis, 122,880 per ingest — 16x the
            // cost of `ingestUWB` — and at several ingests per second it
            // saturated the main thread, which starves the Multipeer transport
            // and NI session setup rather than failing visibly here.
            //
            // Folding the sample spread into the acceptance radius keeps the
            // constraint honest: an anchor we are unsure of widens the ball
            // rather than pretending its mean is exact.
            var mean = SIMD3<Float>.zero
            for point in implied {
                mean += point
            }
            mean /= Float(implied.count)
            var variance: Float = 0
            for point in implied {
                variance += simd_length_squared(point - mean)
            }
            variance /= Float(implied.count)
            let spread = sqrt(max(variance, 0))
            guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite, spread.isFinite else { continue }
            let acceptance = limit + spread

            guard var particles = hypotheses[i].targets[target] else {
                // First sight through a third party must start near its implied
                // position; half the acceptance radius keeps seeds inside the
                // shared estimate without pretending it is an exact point fix.
                hypotheses[i].targets[target] = seedSphere(origin: mean, range: acceptance * 0.5)
                continue
            }
            var inliers: Float = 0
            for k in particles.indices {
                let point = SIMD3<Float>(particles[k].x, particles[k].y, particles[k].z)
                // Same uniform-plus-P_nlos form as eq. (8), one test per particle.
                let inside = simd_length(point - mean) <= acceptance
                if inside {
                    inliers += particles[k].weight
                }
                particles[k].weight *= inside ? inlierProbability : nlosProbability
            }
            normalize(&particles)
            if inliers < 0.15 {
                injectSphere(into: &particles, origin: mean, range: acceptance * 0.5, fraction: 0.3)
            } else if effectiveCount(particles) < Float(Self.targetCount) * 0.5 {
                resample(&particles)
            }
            hypotheses[i].targets[target] = particles
        }
    }

    /// Recurring UWB lock-in. With a fresh Nearby Interaction direction the peer
    /// cloud is collapsed onto that 3D fix. Without direction, the cloud is only
    /// pulled onto the range sphere if it disagrees with the range by > 0.5 m.
    /// Returns true if anything was changed.
    ///
    /// Particle weights are deliberately preserved rather than flattened. A
    /// direction fix observes position, not θ, and θ's only credibility lives in
    /// the weights — each particle carries its own θ, and which ones are right
    /// is encoded purely in how much weight they hold. Resetting to uniform
    /// every two seconds erased that, so θ could never converge and instead
    /// random-walked around whatever `seedSphere` drew. That is the state
    /// variable behind bearing error that grows with range.
    func calibrate(peerID: MCPeerID, range: Float, direction: simd_float3?) -> Bool {
        guard hasLocal, range > 0.05, range < 25 else { return false }
        ensureTargets(peerID, range: range)

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
                }
                normalize(&particles)
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
            }
            normalize(&particles)
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
        // Mean resultant length of the θ distribution. Free here, since the
        // sums are already computed, and it is the only window onto the state
        // variable that drives the range-dependent bearing error: a θ error ε
        // misplaces a peer by about r·sin(ε), invisible at 1 m and metres at 9.
        let thetaConfidence = min(hypot(sinSum, cosSum) / total, 1)
        let remoteYaw = lastRemotePose[peerID]?.yaw ?? 0
        let facing = SIMD3<Float>(sin(remoteYaw + theta), 0, cos(remoteYaw + theta))
        let (facingRight, facingForward) = bodyAxes(facing)
        return Estimate(
            distance: rangeSum / total,
            direction: direction,
            heading: atan2(facingRight, facingForward),
            bearingConfidence: confidence,
            worldPosition: world / total,
            theta: theta,
            thetaConfidence: thetaConfidence
        )
    }

    /// E[V − D] in this device's full 3D ARKit frame. `Estimate.direction`
    /// deliberately drops height, so it cannot carry the §8 shared constraint.
    func relativeVector(for peerID: MCPeerID) -> (vector: SIMD3<Float>, confidence: Float)? {
        guard hasLocal, hasTargets(peerID) else { return nil }
        var relativeMean = SIMD3<Float>.zero
        var bearingMean = SIMD2<Float>.zero
        var total: Float = 0
        for hypothesis in hypotheses {
            guard let particles = hypothesis.targets[peerID] else { continue }
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            for particle in particles {
                let relative = SIMD3<Float>(particle.x, particle.y, particle.z) - display
                let weight = hypothesis.weight * particle.weight
                guard weight.isFinite, relative.x.isFinite, relative.y.isFinite, relative.z.isFinite else { continue }
                relativeMean += relative * weight
                let planar = hypot(relative.x, relative.z)
                if planar.isFinite, planar > 0.02 {
                    bearingMean += SIMD2<Float>(relative.x, relative.z) / planar * weight
                }
                total += weight
            }
        }
        guard total.isFinite, total > 0 else { return nil }
        relativeMean /= total
        bearingMean /= total
        let confidence = simd_length(bearingMean)
        guard relativeMean.x.isFinite, relativeMean.y.isFinite, relativeMean.z.isFinite,
              confidence.isFinite else { return nil }
        return (relativeMean, min(max(confidence, 0), 1))
    }

    /// Body azimuth (0 = forward, positive = right) for an NI direction vector.
    func bodyAngle(fromNI direction: simd_float3) -> Float? {
        guard let body = bodyDirection(fromNI: direction) else { return nil }
        return atan2(body.x, body.y)
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
        recenterDisplay(on: position)
    }

    /// ARKit changed its origin. Move every hypothesis to the new position and
    /// carry its targets along so relative estimates survive.
    private func reorigin(to position: SIMD3<Float>) {
        for i in hypotheses.indices {
            let old = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            let moved = SIMD3<Float>(
                position.x + gauss(0.02),
                position.y + gauss(0.02),
                position.z + gauss(0.02)
            )
            let shift = moved - old
            hypotheses[i].x = moved.x
            hypotheses[i].y = moved.y
            hypotheses[i].z = moved.z
            for (peer, var particles) in hypotheses[i].targets {
                for k in particles.indices {
                    particles[k].x += shift.x
                    particles[k].y += shift.y
                    particles[k].z += shift.z
                }
                hypotheses[i].targets[peer] = particles
            }
        }
        recenterDisplay(on: position)
    }

    /// Translation is a gauge freedom of P(D) Π_i P(V_i | D). Pin its weighted
    /// mean to ARKit after propagation or weighting, applying the same shift to
    /// every V_i so each relative vector V_i − D is preserved exactly.
    private func recenterDisplayOnLocalPose() {
        guard let position = lastLocalPosition else { return }
        recenterDisplay(on: position)
    }

    private func recenterDisplay(on position: SIMD3<Float>) {
        let started = CACurrentMediaTime()
        defer { perfCounters.recordRecenter(CACurrentMediaTime() - started) }

        var mean = SIMD3<Float>.zero
        var total: Float = 0
        for hypothesis in hypotheses {
            mean += SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z) * hypothesis.weight
            total += hypothesis.weight
        }
        guard total.isFinite, total > 0 else { return }
        let shift = position - mean / total
        guard shift.x.isFinite, shift.y.isFinite, shift.z.isFinite else { return }

        for i in hypotheses.indices {
            hypotheses[i].x += shift.x
            hypotheses[i].y += shift.y
            hypotheses[i].z += shift.z
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
            hypotheses[i].targets[peerID] = seedSphere(origin: origin, range: range, theta: thetaPrior[peerID])
        }
    }

    private func seedSphere(origin: SIMD3<Float>, range: Float, theta prior: Float? = nil) -> [TargetParticle] {
        let count = Self.targetCount
        let weight = 1 / Float(count)
        return (0..<count).map { _ in
            let radius = max(range + gauss(sigmaRange), 0.2)
            let point = origin + randomUnitVector() * radius
            // Spread around the compass prior when there is one, so the cloud
            // starts within roughly a quadrant of the truth instead of anywhere
            // on the circle. θ is only observable through translated peer VIO,
            // so a cold uniform draw can persist for as long as nobody walks.
            let theta = prior.map { Self.wrap($0 + gauss(thetaPriorSigma)) }
                ?? Float.random(in: 0..<(2 * .pi))
            return TargetParticle(
                x: point.x,
                y: point.y,
                z: point.z,
                theta: theta,
                weight: weight
            )
        }
    }

    /// World horizontal unit vector (x, z) for a body azimuth, using the display yaw.
    private func worldBearing(bodyAngle: Float) -> SIMD2<Float> {
        let forward = SIMD2<Float>(sin(localYaw), cos(localYaw))
        let right = SIMD2<Float>(-cos(localYaw), sin(localYaw))
        return forward * cos(bodyAngle) + right * sin(bodyAngle)
    }

    private func injectRay(into particles: inout [TargetParticle], origin: SIMD3<Float>, bearing: SIMD2<Float>, range: Float, fraction: Float) {
        let count = max(Int(Float(particles.count) * fraction), 1)
        let uniform = 1 / Float(particles.count)
        for i in 0..<count {
            let radius = max(range + gauss(0.4), 0.2)
            let angle = gauss(sigmaBearing)
            let cosine = cos(angle)
            let sine = sin(angle)
            let rotated = SIMD2<Float>(bearing.x * cosine + bearing.y * sine, -bearing.x * sine + bearing.y * cosine)
            particles[i] = TargetParticle(
                x: origin.x + rotated.x * radius,
                y: origin.y + gauss(0.2),
                z: origin.z + rotated.y * radius,
                theta: Float.random(in: 0..<(2 * .pi)),
                weight: uniform
            )
        }
        normalize(&particles)
    }

    /// Systematic sample of `count` positions from a cloud, by weight.
    private func sample(_ particles: [TargetParticle], count: Int) -> [SIMD3<Float>] {
        guard !particles.isEmpty else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        var cumulative: Float = 0
        var index = 0
        let start = Float.random(in: 0..<(1 / Float(count)))
        cumulative = particles[0].weight
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < particles.count - 1, probe > cumulative {
                index += 1
                cumulative += particles[index].weight
            }
            result.append(SIMD3<Float>(particles[index].x, particles[index].y, particles[index].z))
        }
        return result
    }

    /// Systematic sample retaining the frame transform needed by §8 vectors.
    private func samplePoses(_ particles: [TargetParticle], count: Int) -> [(position: SIMD3<Float>, theta: Float)] {
        guard !particles.isEmpty, count > 0 else { return [] }
        var result: [(position: SIMD3<Float>, theta: Float)] = []
        result.reserveCapacity(count)
        var index = 0
        let denominator = Float(count)
        guard denominator.isFinite, denominator > 0 else { return [] }
        let start = Float.random(in: 0..<(1 / denominator))
        var cumulative = particles[0].weight
        for step in 0..<count {
            let probe = start + Float(step) / denominator
            while index < particles.count - 1, probe > cumulative {
                index += 1
                cumulative += particles[index].weight
            }
            let particle = particles[index]
            result.append((SIMD3<Float>(particle.x, particle.y, particle.z), particle.theta))
        }
        return result
    }

    private static func wrap(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value <= -.pi { value += 2 * .pi }
        return value
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

    /// E[|V − D|] over the whole cloud. Cheap enough to call per VIO frame.
    func expectedRange(_ peerID: MCPeerID) -> Float? {
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

    /// Systematic resampling followed by Gordon roughening. The jitter follows
    /// this cloud's own per-axis spread and N^(-1/3), so it restores distinct
    /// descendants without imposing an absolute position-noise floor.
    private func resample(_ particles: inout [TargetParticle]) {
        let count = particles.count
        guard count > 1 else { return }
        let standardDeviation = spatialStandardDeviation(particles)
        let roughening = 0.2 * pow(Float(count), -1 / Float(3))
        let sigma = standardDeviation * roughening
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
            next[step].x += gauss(sigma.x)
            next[step].y += gauss(sigma.y)
            next[step].z += gauss(sigma.z)
            next[step].weight = 1 / Float(count)
        }
        particles = next
    }

    /// Display-particle counterpart of `resample`, using the display cloud's
    /// adaptive spatial spread rather than a fixed process sigma.
    private func resampleDisplay() {
        let count = hypotheses.count
        guard count > 1 else { return }
        let standardDeviation = displayStandardDeviation()
        let roughening = 0.2 * pow(Float(count), -1 / Float(3))
        let sigma = standardDeviation * roughening
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
            next[step].x += gauss(sigma.x)
            next[step].y += gauss(sigma.y)
            next[step].z += gauss(sigma.z)
            next[step].weight = weight
        }
        hypotheses = next
    }

    private func spatialStandardDeviation(_ particles: [TargetParticle]) -> SIMD3<Float> {
        var mean = SIMD3<Float>.zero
        var total: Float = 0
        for particle in particles {
            mean += SIMD3<Float>(particle.x, particle.y, particle.z) * particle.weight
            total += particle.weight
        }
        guard total.isFinite, total > 0 else { return .zero }
        mean /= total
        guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite else { return .zero }

        var variance = SIMD3<Float>.zero
        for particle in particles {
            let delta = SIMD3<Float>(particle.x, particle.y, particle.z) - mean
            variance += delta * delta * particle.weight
        }
        variance /= total
        return finiteStandardDeviation(from: variance)
    }

    private func displayStandardDeviation() -> SIMD3<Float> {
        var mean = SIMD3<Float>.zero
        var total: Float = 0
        for hypothesis in hypotheses {
            mean += SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z) * hypothesis.weight
            total += hypothesis.weight
        }
        guard total.isFinite, total > 0 else { return .zero }
        mean /= total
        guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite else { return .zero }

        var variance = SIMD3<Float>.zero
        for hypothesis in hypotheses {
            let delta = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z) - mean
            variance += delta * delta * hypothesis.weight
        }
        variance /= total
        return finiteStandardDeviation(from: variance)
    }

    private func finiteStandardDeviation(from variance: SIMD3<Float>) -> SIMD3<Float> {
        guard variance.x.isFinite, variance.y.isFinite, variance.z.isFinite else { return .zero }
        return SIMD3<Float>(
            sqrt(max(variance.x, 0)),
            sqrt(max(variance.y, 0)),
            sqrt(max(variance.z, 0))
        )
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
