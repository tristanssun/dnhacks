import Accelerate
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

    /// Weighted histogram of horizontal bearings, used to report the cloud's
    /// dominant mode instead of its mean.
    ///
    /// The mean resultant length this replaced measures how tightly the cloud
    /// agrees with *itself*, which is a different question from whether it is
    /// right, and it cannot see multimodality at all. Three devices make that
    /// concrete: with a bearing to one peer and range only to another, the
    /// second peer has two solutions mirrored across the line joining the first
    /// two, and range can never break the tie — a lateral move changes range by
    /// d²/2r. The cloud correctly settles on both, and the weighted mean then
    /// lands between them, at a spot the peer is not, reported confidently
    /// because each lobe is individually tight.
    private struct BearingHistogram {
        static let binCount = 36
        /// Bins within this many of the peak count as the same mode: ±2 bins is
        /// ±20°, comfortably wider than a converged cloud (`sigmaBearing` is
        /// about 7°) and narrower than any ambiguity worth hiding an arrow for.
        static let modeHalfWidth = 2

        var weights = [Float](repeating: 0, count: binCount)
        var vectors = [SIMD2<Float>](repeating: .zero, count: binCount)

        /// `unit` is a world-frame horizontal (x, z) unit vector. Binning in the
        /// world frame rather than the body frame keeps the bins still while the
        /// phone turns.
        mutating func add(_ unit: SIMD2<Float>, weight: Float) {
            let angle = atan2(unit.x, unit.y)
            let bin = Int((angle + .pi) / (2 * .pi) * Float(Self.binCount))
            let index = min(max(bin, 0), Self.binCount - 1)
            weights[index] += weight
            vectors[index] += unit * weight
        }

        /// Direction of the heaviest mode, and the share of the cloud's total
        /// weight lying inside it. Two equal lobes report about 0.5 and so fail
        /// the caller's gate, which is the point.
        func dominant(total: Float) -> (direction: SIMD2<Float>, confidence: Float)? {
            guard total > 0 else { return nil }
            var bestBin = 0
            var bestWeight: Float = -1
            for bin in 0..<Self.binCount {
                var sum: Float = 0
                for offset in -Self.modeHalfWidth...Self.modeHalfWidth {
                    sum += weights[(bin + offset + Self.binCount) % Self.binCount]
                }
                if sum > bestWeight {
                    bestWeight = sum
                    bestBin = bin
                }
            }
            var direction = SIMD2<Float>.zero
            for offset in -Self.modeHalfWidth...Self.modeHalfWidth {
                direction += vectors[(bestBin + offset + Self.binCount) % Self.binCount]
            }
            let length = simd_length(direction)
            guard length > 1e-6 else { return nil }
            return (direction / length, min(max(bestWeight / total, 0), 1))
        }
    }

    private struct Hypothesis {
        var x: Float
        var y: Float
        var z: Float
        var weight: Float
    }

    /// One peer's conditional particles, stored hypothesis-major in flat
    /// structure-of-arrays buffers so a whole ingest walks contiguous memory.
    private struct Cloud {
        var x: [Float]
        var y: [Float]
        var z: [Float]
        var theta: [Float]
        var weight: [Float]
        var sineScratch: [Float]
        var cosineScratch: [Float]

        init(count: Int) {
            x = [Float](repeating: 0, count: count)
            y = [Float](repeating: 0, count: count)
            z = [Float](repeating: 0, count: count)
            theta = [Float](repeating: 0, count: count)
            weight = [Float](repeating: 0, count: count)
            sineScratch = [Float](repeating: 0, count: count)
            cosineScratch = [Float](repeating: 0, count: count)
        }

        mutating func withMutableBuffers<R>(
            _ body: (
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>,
                UnsafeMutableBufferPointer<Float>
            ) -> R
        ) -> R {
            x.withUnsafeMutableBufferPointer { x in
                y.withUnsafeMutableBufferPointer { y in
                    z.withUnsafeMutableBufferPointer { z in
                        theta.withUnsafeMutableBufferPointer { theta in
                            weight.withUnsafeMutableBufferPointer { weight in
                                sineScratch.withUnsafeMutableBufferPointer { sine in
                                    cosineScratch.withUnsafeMutableBufferPointer { cosine in
                                        body(x, y, z, theta, weight, sine, cosine)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
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
    /// Two independent bearings, each at `sigmaBearing`, combine in quadrature.
    private let sigmaThetaObservation: Float = 0.17
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
    private var clouds: [Cloud?] = []
    private var slots: [MCPeerID: Int] = [:]
    private var freeSlots: [Int] = []
    /// Every draw the filter makes comes from here rather than from
    /// `Float.random`. See `FastRandom`.
    private var random = FastRandom(seed: UInt64.random(in: UInt64.min...UInt64.max))
    /// Box-Muller's second output, held for the next `gauss` call.
    private var spareGauss: Float?
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
            Hypothesis(x: 0, y: 0, z: 0, weight: weight)
        }
    }

    /// Radians, or nil to fall back to a uniform draw.
    func setThetaPrior(_ radians: Float?, for peerID: MCPeerID) {
        thetaPrior[peerID] = radians
    }

    func forget(_ peerID: MCPeerID) {
        lastRemotePose[peerID] = nil
        thetaPrior[peerID] = nil
        if let slot = slots.removeValue(forKey: peerID) {
            clouds[slot] = nil
            freeSlots.append(slot)
        }
    }

    func hasTargets(_ peerID: MCPeerID) -> Bool {
        slots[peerID] != nil
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
        guard !isReset, let last = lastRemotePose[peerID], let slot = slots[peerID] else { return }
        let dx = position.x - last.position.x
        let dy = position.y - last.position.y
        let dz = position.z - last.position.z
        let distance = simd_length(SIMD3(dx, dy, dz))
        guard distance <= jumpLimit else { return }
        let translated = distance >= 0.02
        withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, _, sine, cosine in
                var count = Int32(theta.count)
                vvsincosf(sine.baseAddress!, cosine.baseAddress!, theta.baseAddress!, &count)
                for k in theta.indices {
                    let oldTheta = theta[k]
                    x[k] += dx * cosine[k] + dz * sine[k] + gauss(sigmaXYZ)
                    y[k] += dy + gauss(sigmaXYZ)
                    z[k] += dz * cosine[k] - dx * sine[k] + gauss(sigmaXYZ)
                    // Eq. (7) is observable only through translated VIO. A
                    // stationary peer therefore neither learns nor diffuses its
                    // frame yaw offset.
                    theta[k] = Self.wrap(oldTheta + (translated ? gauss(sigmaTheta) : 0))
                }
            }
        }
    }

    /// θ measured directly, from a bearing taken on each side of the link.
    ///
    /// Both devices are gravity-aligned, so their frames differ by yaw alone —
    /// that is θ, and it is the only unknown in their relative orientation. If
    /// ψ_us is the azimuth of us→peer in our frame and ψ_them is the azimuth of
    /// peer→us in theirs, both describe one physical line pointing opposite
    /// ways, so rotating their frame into ours must reconcile them:
    ///
    ///     ψ_them + θ = ψ_us + π   ⟹   θ = ψ_us − ψ_them + π
    ///
    /// One equation, one unknown, solved outright. No motion and no range
    /// needed, which is what separates this from every other θ information
    /// source here: the rotation term in `ingestRemoteVIO` only discriminates
    /// in proportion to peer displacement, so a peer standing still teaches
    /// nothing, and `ingestRelativeEstimate` rotates an incoming vector *by* θ
    /// and therefore consumes it rather than measuring it.
    ///
    /// Independent exchanges average as σ/√N, so ~10° from one becomes ~3° from
    /// ten — against a compass floor of tens of degrees.
    func ingestThetaObservation(peerID: MCPeerID, theta: Float) {
        guard let slot = slots[peerID], theta.isFinite else { return }
        let limit = 3 * sigmaThetaObservation
        let inlierProbability = 1 - nlosProbability
        withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, angles, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    var inliers: Float = 0
                    for k in slice {
                        let error = abs(Self.wrap(angles[k] - theta))
                        let inside = error <= limit
                        if inside {
                            inliers += weight[k]
                        }
                        weight[k] *= inside ? inlierProbability : nlosProbability
                    }
                    normalize(weight, in: slice)
                    // A measured θ the cloud cannot represent means the cloud is wrong
                    // about θ, not that the measurement is. Re-seed the angle around it
                    // while leaving positions alone — θ and position are separate state
                    // and a bad θ should not throw away a good fix.
                    if inliers < 0.15 {
                        for k in slice where random.unit() < 0.3 {
                            angles[k] = Self.wrap(theta + gauss(sigmaThetaObservation))
                        }
                        normalize(weight, in: slice)
                    } else if effectiveCount(weight, in: slice) < Float(Self.targetCount) * 0.5 {
                        resample(x: x, y: y, z: z, theta: angles, weight: weight, in: slice)
                    }
                }
            }
        }
    }

    /// This device's world-frame azimuth for a body-frame bearing, which is the
    /// ψ that goes on the wire for `ingestThetaObservation`.
    func worldAzimuth(bodyAngle: Float) -> Float? {
        guard hasLocal, bodyAngle.isFinite else { return nil }
        let world = worldBearing(bodyAngle: bodyAngle)
        guard world.x.isFinite, world.y.isFinite, simd_length(world) > 0.05 else { return nil }
        return atan2(world.x, world.y)
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
        guard let slot = slots[peerID], theta.isFinite else { return }
        let inlierProbability = 1 - nlosProbability
        withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { _, _, _, angles, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    for k in slice {
                        let error = abs(Self.wrap(angles[k] - theta))
                        weight[k] *= error <= thetaAnchorBand ? inlierProbability : nlosProbability
                    }
                    normalize(weight, in: slice)
                }
            }
        }
    }

    // MARK: Range

    /// UWB range z. Uniform ±3σ_r band plus P_nlos, eq. (8). Parent weight is
    /// the marginal P(z | D_j) = Σ_k w_k P(z | V_k, D_j). If almost no particle
    /// is inside the band, the cloud is lost and fresh sphere samples are injected;
    /// routine low ESS only resamples and roughens the surviving cloud.
    func ingestUWB(peerID: MCPeerID, range: Float) {
        guard hasLocal, range > 0.05, range < 80 else { return }
        let (slot, isNew) = targetSlot(for: peerID)
        let prior = isNew ? thetaPrior[peerID] : nil
        let limit = 3 * sigmaRange
        let inlierProbability = 1 - nlosProbability

        withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    let display = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                    if isNew {
                        seedSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                   in: slice, origin: display, range: range, theta: prior)
                    }
                    var likelihood: Float = 0
                    var inliers: Float = 0
                    for k in slice {
                        let peer = SIMD3<Float>(x[k], y[k], z[k])
                        let error = abs(simd_length(peer - display) - range)
                        let inside = error <= limit
                        let probability = inside ? inlierProbability : nlosProbability
                        if inside {
                            inliers += weight[k]
                        }
                        likelihood += weight[k] * probability
                        weight[k] *= probability
                    }
                    normalize(weight, in: slice)
                    if inliers < 0.15 {
                        injectSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                     in: slice, origin: display, range: range, fraction: 0.3)
                    } else if effectiveCount(weight, in: slice) < Float(Self.targetCount) * 0.5 {
                        resample(x: x, y: y, z: z, theta: theta, weight: weight, in: slice)
                    }
                    hypotheses[i].weight *= max(likelihood, 1e-8)
                }
            }
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
        guard hasLocal, let slot = slots[peerID], bodyAngle.isFinite else { return }
        let world = worldBearing(bodyAngle: bodyAngle)
        let worldAngle = atan2(world.x, world.y)
        let limit = 3 * sigmaBearing
        let inlierProbability = 1 - nlosProbability

        withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    let display = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                    var likelihood: Float = 0
                    var inliers: Float = 0
                    var rangeSum: Float = 0
                    for k in slice {
                        let relative = SIMD3<Float>(x[k], y[k], z[k]) - display
                        let planar = hypot(relative.x, relative.z)
                        rangeSum += simd_length(relative) * weight[k]
                        let inside: Bool
                        if planar < 0.1 {
                            inside = false
                        } else {
                            let error = Self.wrap(atan2(relative.x, relative.z) - worldAngle)
                            inside = abs(error) <= limit
                        }
                        let probability = inside ? inlierProbability : nlosProbability
                        if inside {
                            inliers += weight[k]
                        }
                        likelihood += weight[k] * probability
                        weight[k] *= probability
                    }
                    normalize(weight, in: slice)
                    if inliers < 0.15 {
                        injectRay(x: x, y: y, z: z, theta: theta, weight: weight,
                                  in: slice, origin: display, bearing: world,
                                  range: max(rangeSum, 0.3), fraction: 0.3)
                    } else if effectiveCount(weight, in: slice) < Float(Self.targetCount) * 0.5 {
                        resample(x: x, y: y, z: z, theta: theta, weight: weight, in: slice)
                    }
                    hypotheses[i].weight *= max(likelihood, 1e-8)
                }
            }
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
        var aSlot = slots[a]
        var bSlot = slots[b]
        guard aSlot != nil || bSlot != nil else { return }
        if let anchorSlot = bSlot {
            let (targetSlot, isNew) = aSlot.map { ($0, false) } ?? self.targetSlot(for: a)
            aSlot = targetSlot
            constrain(targetSlot, isNew: isNew, by: anchorSlot, range: range)
        }
        if let anchorSlot = aSlot {
            let (targetSlot, isNew) = bSlot.map { ($0, false) } ?? self.targetSlot(for: b)
            bSlot = targetSlot
            constrain(targetSlot, isNew: isNew, by: anchorSlot, range: range)
        }
    }

    private func constrain(_ targetSlot: Int, isNew: Bool, by anchorSlot: Int, range: Float) {
        let limit = 3 * sigmaRange
        let inlierProbability = 1 - nlosProbability
        guard let anchorCloud = clouds[anchorSlot] else { return }
        withCloud(at: targetSlot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    let anchors = sample(anchorCloud, in: slice, count: Self.anchorSamples)
                    guard !anchors.isEmpty else { continue }
                    if isNew {
                        // First sight of this peer via a third party: seed around the anchor.
                        let origin = anchors[random.below(anchors.count)]
                        seedSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                   in: slice, origin: origin, range: range)
                        continue
                    }
                    var inliers: Float = 0
                    for k in slice {
                        let point = SIMD3<Float>(x[k], y[k], z[k])
                        var hits = 0
                        for anchorPoint in anchors where abs(simd_length(point - anchorPoint) - range) <= limit {
                            hits += 1
                        }
                        let fraction = Float(hits) / Float(anchors.count)
                        let probability = nlosProbability + (inlierProbability - nlosProbability) * fraction
                        if hits > 0 {
                            inliers += weight[k]
                        }
                        weight[k] *= probability
                    }
                    normalize(weight, in: slice)
                    if inliers < 0.15 {
                        let origin = anchors[random.below(anchors.count)]
                        injectSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                     in: slice, origin: origin, range: range, fraction: 0.3)
                    } else if effectiveCount(weight, in: slice) < Float(Self.targetCount) * 0.5 {
                        resample(x: x, y: y, z: z, theta: theta, weight: weight, in: slice)
                    }
                }
            }
        }
    }

    /// A peer's estimate of target − anchor (§8), expressed in the anchor's
    /// ARKit frame. Sampling both anchor position and θ preserves their joint
    /// uncertainty: θ is the transform that rotates the shared vector into this
    /// display's frame before it can constrain the target cloud.
    func ingestRelativeEstimate(target: MCPeerID, anchor: MCPeerID, vector: SIMD3<Float>, confidence: Float) {
        guard hasLocal, target != anchor, let anchorSlot = slots[anchor],
              vector.x.isFinite, vector.y.isFinite, vector.z.isFinite,
              confidence.isFinite else { return }
        let existingTargetSlot = slots[target]
        let (targetSlot, isNew) = existingTargetSlot.map { ($0, false) } ?? self.targetSlot(for: target)
        let boundedConfidence = min(max(confidence, 0), 1)
        // Linear interpolation gives a camera-resolved estimate a roughly 0.5 m
        // acceptance ball while an unresolved estimate remains a useful but soft
        // 3 m constraint. Clamping above keeps the radius finite and positive.
        let limit: Float = 3.0 - 2.5 * boundedConfidence
        guard limit.isFinite, limit > 0 else { return }
        let inlierProbability = 1 - nlosProbability

        guard let anchorCloud = clouds[anchorSlot] else { return }
        withCloud(at: targetSlot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, weight, _, _ in
                for i in hypotheses.indices {
                    let slice = targetSlice(i)
                    let anchors = samplePoses(anchorCloud, in: slice, count: Self.anchorSamples)
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

                    if isNew {
                        // First sight through a third party must start near its implied
                        // position; half the acceptance radius keeps seeds inside the
                        // shared estimate without pretending it is an exact point fix.
                        seedSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                   in: slice, origin: mean, range: acceptance * 0.5)
                        continue
                    }
                    var inliers: Float = 0
                    for k in slice {
                        let point = SIMD3<Float>(x[k], y[k], z[k])
                        // Same uniform-plus-P_nlos form as eq. (8), one test per particle.
                        let inside = simd_length(point - mean) <= acceptance
                        if inside {
                            inliers += weight[k]
                        }
                        weight[k] *= inside ? inlierProbability : nlosProbability
                    }
                    normalize(weight, in: slice)
                    if inliers < 0.15 {
                        injectSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                     in: slice, origin: mean, range: acceptance * 0.5, fraction: 0.3)
                    } else if effectiveCount(weight, in: slice) < Float(Self.targetCount) * 0.5 {
                        resample(x: x, y: y, z: z, theta: theta, weight: weight, in: slice)
                    }
                }
            }
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
        let (slot, isNew) = targetSlot(for: peerID)
        let prior = isNew ? thetaPrior[peerID] : nil
        let worldDirection = direction.flatMap(niDirectionInWorld)

        return withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, theta, weight, _, _ in
                if isNew {
                    for i in hypotheses.indices {
                        let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                        seedSphere(x: x, y: y, z: z, theta: theta, weight: weight,
                                   in: targetSlice(i), origin: origin, range: range, theta: prior)
                    }
                }

                if let world = worldDirection {
                    for i in hypotheses.indices {
                        let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                        let target = origin + world * range
                        let slice = targetSlice(i)
                        for k in slice where random.unit() < 0.85 {
                            x[k] = target.x + gauss(0.08)
                            y[k] = target.y + gauss(0.05)
                            z[k] = target.z + gauss(0.08)
                        }
                        normalize(weight, in: slice)
                    }
                    return true
                }

                guard let expected = expectedRange(x: x, y: y, z: z, weight: weight),
                      abs(expected - range) > 0.5 else { return false }
                for i in hypotheses.indices {
                    let origin = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
                    let slice = targetSlice(i)
                    for k in slice {
                        let peer = SIMD3<Float>(x[k], y[k], z[k])
                        var radial = peer - origin
                        let length = simd_length(radial)
                        if length < 0.08 {
                            radial = randomUnitVector() * range
                        } else {
                            radial *= range / length
                        }
                        x[k] = origin.x + radial.x + gauss(0.08)
                        y[k] = origin.y + radial.y + gauss(0.08)
                        z[k] = origin.z + radial.z + gauss(0.08)
                    }
                    normalize(weight, in: slice)
                }
                return true
            }
        }
    }

    // MARK: Output

    func estimate(for peerID: MCPeerID) -> Estimate? {
        guard hasLocal, let slot = slots[peerID] else { return nil }
        return withCloud(at: slot) { cloud in
            cloud.withMutableBuffers { x, y, z, thetaValues, weights, sine, cosine in
                var count = Int32(thetaValues.count)
                vvsincosf(sine.baseAddress!, cosine.baseAddress!, thetaValues.baseAddress!, &count)
                var rangeSum: Float = 0
                var histogram = BearingHistogram()
                var world = SIMD3<Float>.zero
                var total: Float = 0
                var sinSum: Float = 0
                var cosSum: Float = 0
                for i in hypotheses.indices {
                    let hypothesis = hypotheses[i]
                    let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
                    for k in targetSlice(i) {
                        let point = SIMD3<Float>(x[k], y[k], z[k])
                        let relative = point - display
                        let weight = hypothesis.weight * weights[k]
                        rangeSum += simd_length(relative) * weight
                        let planar = hypot(relative.x, relative.z)
                        if planar > 0.02 {
                            histogram.add(SIMD2<Float>(relative.x, relative.z) / planar, weight: weight)
                        }
                        world += point * weight
                        total += weight
                        sinSum += sine[k] * weight
                        cosSum += cosine[k] * weight
                    }
                }
                guard total > 0 else { return nil }
                // The mode rather than the mean, and the weight behind it rather
                // than how tightly the cloud agrees with itself.
                let mode = histogram.dominant(total: total)
                let confidence = mode?.confidence ?? 0
                var direction = simd_float3(0, 1, 0)
                if let mode {
                    let (right, forward) = bodyAxes(SIMD3<Float>(mode.direction.x, 0, mode.direction.y))
                    let planar = hypot(right, forward)
                    if planar > 1e-4 {
                        direction = simd_float3(right / planar, forward / planar, 0)
                    }
                }
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
        }
    }

    /// E[V − D] in this device's full 3D ARKit frame. `Estimate.direction`
    /// deliberately drops height, so it cannot carry the §8 shared constraint.
    func relativeVector(for peerID: MCPeerID) -> (vector: SIMD3<Float>, confidence: Float)? {
        guard hasLocal, let slot = slots[peerID], let cloud = clouds[slot] else { return nil }
        var relativeMean = SIMD3<Float>.zero
        var histogram = BearingHistogram()
        var total: Float = 0
        for i in hypotheses.indices {
            let hypothesis = hypotheses[i]
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            for k in targetSlice(i) {
                let relative = SIMD3<Float>(cloud.x[k], cloud.y[k], cloud.z[k]) - display
                let weight = hypothesis.weight * cloud.weight[k]
                guard weight.isFinite, relative.x.isFinite, relative.y.isFinite, relative.z.isFinite else { continue }
                relativeMean += relative * weight
                let planar = hypot(relative.x, relative.z)
                if planar.isFinite, planar > 0.02 {
                    histogram.add(SIMD2<Float>(relative.x, relative.z) / planar, weight: weight)
                }
                total += weight
            }
        }
        guard total.isFinite, total > 0 else { return nil }
        relativeMean /= total
        // Same mode-based measure as `estimate`. It gates `broadcastRelativeEstimates`,
        // so an unresolved two-lobed cloud now stays off the wire instead of being
        // shared at high confidence and reseeding someone else's cloud onto it.
        let confidence = histogram.dominant(total: total)?.confidence ?? 0
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
        var shifts = [SIMD3<Float>](repeating: .zero, count: hypotheses.count)
        for i in hypotheses.indices {
            let old = SIMD3<Float>(hypotheses[i].x, hypotheses[i].y, hypotheses[i].z)
            let moved = SIMD3<Float>(
                position.x + gauss(0.02),
                position.y + gauss(0.02),
                position.z + gauss(0.02)
            )
            let shift = moved - old
            shifts[i] = shift
            hypotheses[i].x = moved.x
            hypotheses[i].y = moved.y
            hypotheses[i].z = moved.z
        }
        for slot in clouds.indices where clouds[slot] != nil {
            withCloud(at: slot) { cloud in
                cloud.withMutableBuffers { x, y, z, _, _, _, _ in
                    for i in hypotheses.indices {
                        let shift = shifts[i]
                        for k in targetSlice(i) {
                            x[k] += shift.x
                            y[k] += shift.y
                            z[k] += shift.z
                        }
                    }
                }
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
        }
        for slot in clouds.indices where clouds[slot] != nil {
            withCloud(at: slot) { cloud in
                cloud.withMutableBuffers { x, y, z, _, _, _, _ in
                    for k in x.indices {
                        x[k] += shift.x
                        y[k] += shift.y
                        z[k] += shift.z
                    }
                }
            }
        }
    }

    private func targetSlice(_ hypothesis: Int) -> Range<Int> {
        let start = hypothesis * Self.targetCount
        return start..<(start + Self.targetCount)
    }

    private func targetSlot(for peerID: MCPeerID) -> (slot: Int, isNew: Bool) {
        if let slot = slots[peerID] {
            return (slot, false)
        }
        let slot: Int
        let count = Self.displayCount * Self.targetCount
        if let recycled = freeSlots.popLast() {
            slot = recycled
            clouds[slot] = Cloud(count: count)
        } else {
            slot = clouds.count
            clouds.append(Cloud(count: count))
        }
        slots[peerID] = slot
        return (slot, true)
    }

    private func withCloud<R>(at slot: Int, _ body: (inout Cloud) -> R) -> R {
        guard var cloud = clouds[slot] else { preconditionFailure("missing particle cloud") }
        clouds[slot] = nil
        let result = body(&cloud)
        clouds[slot] = cloud
        return result
    }

    private func seedSphere(
        x: UnsafeMutableBufferPointer<Float>,
        y: UnsafeMutableBufferPointer<Float>,
        z: UnsafeMutableBufferPointer<Float>,
        theta: UnsafeMutableBufferPointer<Float>,
        weight: UnsafeMutableBufferPointer<Float>,
        in slice: Range<Int>,
        origin: SIMD3<Float>,
        range: Float,
        theta prior: Float? = nil
    ) {
        let uniform = 1 / Float(slice.count)
        for k in slice {
            let radius = max(range + gauss(sigmaRange), 0.2)
            let point = origin + randomUnitVector() * radius
            // Spread around the compass prior when there is one, so the cloud
            // starts within roughly a quadrant of the truth instead of anywhere
            // on the circle. θ is only observable through translated peer VIO,
            // so a cold uniform draw can persist for as long as nobody walks.
            let angle = prior.map { Self.wrap($0 + gauss(thetaPriorSigma)) }
                ?? random.upTo(2 * .pi)
            x[k] = point.x
            y[k] = point.y
            z[k] = point.z
            theta[k] = angle
            weight[k] = uniform
        }
    }

    /// World horizontal unit vector (x, z) for a body azimuth, using the display yaw.
    private func worldBearing(bodyAngle: Float) -> SIMD2<Float> {
        let forward = SIMD2<Float>(sin(localYaw), cos(localYaw))
        let right = SIMD2<Float>(-cos(localYaw), sin(localYaw))
        return forward * cos(bodyAngle) + right * sin(bodyAngle)
    }

    private func injectRay(
        x: UnsafeMutableBufferPointer<Float>,
        y: UnsafeMutableBufferPointer<Float>,
        z: UnsafeMutableBufferPointer<Float>,
        theta: UnsafeMutableBufferPointer<Float>,
        weight: UnsafeMutableBufferPointer<Float>,
        in slice: Range<Int>,
        origin: SIMD3<Float>,
        bearing: SIMD2<Float>,
        range: Float,
        fraction: Float
    ) {
        let count = max(Int(Float(slice.count) * fraction), 1)
        let uniform = 1 / Float(slice.count)
        for k in slice.lowerBound..<(slice.lowerBound + count) {
            let radius = max(range + gauss(0.4), 0.2)
            let angle = gauss(sigmaBearing)
            let cosine = cos(angle)
            let sine = sin(angle)
            let rotated = SIMD2<Float>(bearing.x * cosine + bearing.y * sine, -bearing.x * sine + bearing.y * cosine)
            x[k] = origin.x + rotated.x * radius
            y[k] = origin.y + gauss(0.2)
            z[k] = origin.z + rotated.y * radius
            theta[k] = random.upTo(2 * .pi)
            weight[k] = uniform
        }
        normalize(weight, in: slice)
    }

    /// Systematic sample of `count` positions from a cloud, by weight.
    private func sample(_ cloud: Cloud, in slice: Range<Int>, count: Int) -> [SIMD3<Float>] {
        guard !slice.isEmpty, count > 0 else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        var index = slice.lowerBound
        let start = random.upTo(1 / Float(count))
        var cumulative = cloud.weight[index]
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < slice.upperBound - 1, probe > cumulative {
                index += 1
                cumulative += cloud.weight[index]
            }
            result.append(SIMD3<Float>(cloud.x[index], cloud.y[index], cloud.z[index]))
        }
        return result
    }

    /// Systematic sample retaining the frame transform needed by §8 vectors.
    private func samplePoses(_ cloud: Cloud, in slice: Range<Int>, count: Int) -> [(position: SIMD3<Float>, theta: Float)] {
        guard !slice.isEmpty, count > 0 else { return [] }
        var result: [(position: SIMD3<Float>, theta: Float)] = []
        result.reserveCapacity(count)
        var index = slice.lowerBound
        let denominator = Float(count)
        guard denominator.isFinite, denominator > 0 else { return [] }
        let start = random.upTo(1 / denominator)
        var cumulative = cloud.weight[index]
        for step in 0..<count {
            let probe = start + Float(step) / denominator
            while index < slice.upperBound - 1, probe > cumulative {
                index += 1
                cumulative += cloud.weight[index]
            }
            result.append((SIMD3<Float>(cloud.x[index], cloud.y[index], cloud.z[index]), cloud.theta[index]))
        }
        return result
    }

    /// Wrapping is needed by callers solving θ before it reaches the filter.
    static func wrapAngle(_ angle: Float) -> Float { wrap(angle) }

    private static func wrap(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value <= -.pi { value += 2 * .pi }
        return value
    }

    private func injectSphere(
        x: UnsafeMutableBufferPointer<Float>,
        y: UnsafeMutableBufferPointer<Float>,
        z: UnsafeMutableBufferPointer<Float>,
        theta: UnsafeMutableBufferPointer<Float>,
        weight: UnsafeMutableBufferPointer<Float>,
        in slice: Range<Int>,
        origin: SIMD3<Float>,
        range: Float,
        fraction: Float
    ) {
        let count = max(Int(Float(slice.count) * fraction), 1)
        let end = slice.lowerBound + count
        let uniform = 1 / Float(slice.count)
        for k in slice {
            let radius = max(range + gauss(sigmaRange), 0.2)
            let point = origin + randomUnitVector() * radius
            let angle = random.upTo(2 * .pi)
            if k < end {
                x[k] = point.x
                y[k] = point.y
                z[k] = point.z
                theta[k] = angle
                weight[k] = uniform
            }
        }
        normalize(weight, in: slice)
    }

    /// E[|V − D|] over the whole cloud. Cheap enough to call per VIO frame.
    func expectedRange(_ peerID: MCPeerID) -> Float? {
        guard let slot = slots[peerID], let cloud = clouds[slot] else { return nil }
        return expectedRange(x: cloud.x, y: cloud.y, z: cloud.z, weight: cloud.weight)
    }

    private func expectedRange<C: RandomAccessCollection>(
        x: C, y: C, z: C, weight: C
    ) -> Float? where C.Index == Int, C.Element == Float {
        var sum: Float = 0
        var total: Float = 0
        for i in hypotheses.indices {
            let hypothesis = hypotheses[i]
            let display = SIMD3<Float>(hypothesis.x, hypothesis.y, hypothesis.z)
            for k in targetSlice(i) {
                let particleWeight = hypothesis.weight * weight[k]
                sum += simd_length(SIMD3(x[k], y[k], z[k]) - display) * particleWeight
                total += particleWeight
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

    private func normalize(_ weight: UnsafeMutableBufferPointer<Float>, in slice: Range<Int>) {
        var sum: Float = 0
        for k in slice {
            sum += weight[k]
        }
        let count = max(slice.count, 1)
        guard sum > 0 else {
            let equal = 1 / Float(count)
            for k in slice {
                weight[k] = equal
            }
            return
        }
        for k in slice {
            weight[k] /= sum
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

    private func effectiveCount(_ weight: UnsafeMutableBufferPointer<Float>, in slice: Range<Int>) -> Float {
        var sumSquares: Float = 0
        for k in slice {
            sumSquares += weight[k] * weight[k]
        }
        return sumSquares > 0 ? 1 / sumSquares : 0
    }

    private func effectiveDisplayCount() -> Float {
        let sumSquares = hypotheses.reduce(Float.zero) { $0 + $1.weight * $1.weight }
        return sumSquares > 0 ? 1 / sumSquares : 0
    }

    /// Systematic resampling followed by Gordon roughening. The jitter follows
    /// this cloud's own per-axis spread and N^(-1/3), so it restores distinct
    /// descendants without imposing an absolute position-noise floor.
    private func resample(
        x: UnsafeMutableBufferPointer<Float>,
        y: UnsafeMutableBufferPointer<Float>,
        z: UnsafeMutableBufferPointer<Float>,
        theta: UnsafeMutableBufferPointer<Float>,
        weight: UnsafeMutableBufferPointer<Float>,
        in slice: Range<Int>
    ) {
        let count = slice.count
        guard count > 1 else { return }
        let standardDeviation = spatialStandardDeviation(x: x, y: y, z: z, weight: weight, in: slice)
        let roughening = 0.2 * pow(Float(count), -1 / Float(3))
        let sigma = standardDeviation * roughening
        var cdf = [Float](repeating: 0, count: count)
        cdf[0] = weight[slice.lowerBound]
        for i in 1..<count {
            cdf[i] = cdf[i - 1] + weight[slice.lowerBound + i]
        }
        var nextX = [Float](repeating: 0, count: count)
        var nextY = [Float](repeating: 0, count: count)
        var nextZ = [Float](repeating: 0, count: count)
        var nextTheta = [Float](repeating: 0, count: count)
        var index = 0
        let start = random.upTo(1 / Float(count))
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < count - 1, probe > cdf[index] {
                index += 1
            }
            let source = slice.lowerBound + index
            nextX[step] = x[source] + gauss(sigma.x)
            nextY[step] = y[source] + gauss(sigma.y)
            nextZ[step] = z[source] + gauss(sigma.z)
            nextTheta[step] = theta[source]
        }
        let uniform = 1 / Float(count)
        for step in 0..<count {
            let destination = slice.lowerBound + step
            x[destination] = nextX[step]
            y[destination] = nextY[step]
            z[destination] = nextZ[step]
            theta[destination] = nextTheta[step]
            weight[destination] = uniform
        }
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
        var ancestors = [Int](repeating: 0, count: count)
        var index = 0
        let start = random.upTo(1 / Float(count))
        let weight = 1 / Float(count)
        for step in 0..<count {
            let probe = start + Float(step) / Float(count)
            while index < count - 1, probe > cdf[index] {
                index += 1
            }
            ancestors[step] = index
            next[step] = hypotheses[index]
            next[step].x += gauss(sigma.x)
            next[step].y += gauss(sigma.y)
            next[step].z += gauss(sigma.z)
            next[step].weight = weight
        }
        hypotheses = next
        for slot in clouds.indices where clouds[slot] != nil {
            withCloud(at: slot) { cloud in
                let nextCloud = cloud.withMutableBuffers { x, y, z, theta, targetWeight, _, _ in
                    var nextX = [Float](repeating: 0, count: x.count)
                    var nextY = [Float](repeating: 0, count: y.count)
                    var nextZ = [Float](repeating: 0, count: z.count)
                    var nextTheta = [Float](repeating: 0, count: theta.count)
                    var nextWeight = [Float](repeating: 0, count: targetWeight.count)
                    for destinationHypothesis in ancestors.indices {
                        let source = targetSlice(ancestors[destinationHypothesis])
                        let destination = targetSlice(destinationHypothesis)
                        for offset in 0..<Self.targetCount {
                            let from = source.lowerBound + offset
                            let to = destination.lowerBound + offset
                            nextX[to] = x[from]
                            nextY[to] = y[from]
                            nextZ[to] = z[from]
                            nextTheta[to] = theta[from]
                            nextWeight[to] = targetWeight[from]
                        }
                    }
                    return (nextX, nextY, nextZ, nextTheta, nextWeight)
                }
                cloud.x = nextCloud.0
                cloud.y = nextCloud.1
                cloud.z = nextCloud.2
                cloud.theta = nextCloud.3
                cloud.weight = nextCloud.4
            }
        }
    }

    private func spatialStandardDeviation(
        x: UnsafeMutableBufferPointer<Float>,
        y: UnsafeMutableBufferPointer<Float>,
        z: UnsafeMutableBufferPointer<Float>,
        weight: UnsafeMutableBufferPointer<Float>,
        in slice: Range<Int>
    ) -> SIMD3<Float> {
        var mean = SIMD3<Float>.zero
        var total: Float = 0
        for k in slice {
            mean += SIMD3<Float>(x[k], y[k], z[k]) * weight[k]
            total += weight[k]
        }
        guard total.isFinite, total > 0 else { return .zero }
        mean /= total
        guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite else { return .zero }

        var variance = SIMD3<Float>.zero
        for k in slice {
            let delta = SIMD3<Float>(x[k], y[k], z[k]) - mean
            variance += delta * delta * weight[k]
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
        let lambda = random.upTo(2 * .pi)
        let phi = acos(random.signedUnit())
        return SIMD3<Float>(sin(phi) * cos(lambda), cos(phi), sin(phi) * sin(lambda))
    }

    /// Box-Muller, keeping both outputs.
    ///
    /// The sine half used to be discarded, so every single sample paid a `log`,
    /// a `sqrt` and a transcendental. Caching it halves all three for free. The
    /// spare is standardized, so a later call at a different sigma is still
    /// correct: N(0,1) scaled by sigma is N(0,sigma).
    private func gauss(_ sigma: Float) -> Float {
        if let spare = spareGauss {
            spareGauss = nil
            return sigma * spare
        }
        // Same floor as before, which truncates the tail at about 4.3 sigma.
        let u1 = max(random.unit(), 0.0001)
        let u2 = random.unit()
        let radius = sqrt(-2 * log(u1))
        let angle = 2 * Float.pi * u2
        spareGauss = radius * sin(angle)
        return sigma * radius * cos(angle)
    }
}

/// xoshiro128+, the filter's source of randomness.
///
/// `Float.random(in:)` draws from `SystemRandomNumberGenerator`, which is
/// backed by `arc4random_buf` — a locked ChaCha stream reached through a call
/// out of the module. `ingestRemoteVIO` alone asks for four Gaussians per
/// particle, so at 64 x 120 particles and 10 Hz per peer the filter was making
/// well over a million CSPRNG draws a second for process noise. A particle
/// filter has no use for cryptographic randomness, and this is a few integer
/// ops with no lock.
private struct FastRandom {
    private var s: (UInt32, UInt32, UInt32, UInt32)

    /// SplitMix64 expands the seed, so a poorly spread one still fills the state.
    init(seed: UInt64) {
        var z = seed
        func mix() -> UInt64 {
            z = z &+ 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        let a = mix()
        let b = mix()
        s = (
            UInt32(truncatingIfNeeded: a),
            UInt32(truncatingIfNeeded: a >> 32),
            UInt32(truncatingIfNeeded: b),
            UInt32(truncatingIfNeeded: b >> 32)
        )
        // xoshiro is undefined on an all-zero state.
        if s == (0, 0, 0, 0) {
            s = (0x9E37_79B9, 0x243F_6A88, 0xB7E1_5162, 0x8AED_2A6B)
        }
    }

    private mutating func next() -> UInt32 {
        let result = s.0 &+ s.3
        let t = s.1 << 9
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = (s.3 << 11) | (s.3 >> 21)
        return result
    }

    /// Uniform in [0, 1). The low bits of xoshiro128+ are the weak ones, so this
    /// takes the top 24 — which is a Float's mantissa width anyway.
    mutating func unit() -> Float {
        Float(next() >> 8) * 0x1p-24
    }

    /// Uniform in [0, limit).
    mutating func upTo(_ limit: Float) -> Float {
        limit * unit()
    }

    /// Uniform in [-1, 1).
    mutating func signedUnit() -> Float {
        2 * unit() - 1
    }

    /// Uniform in 0..<count. Biased by at most 2^-24, which is far below
    /// anything a 120-particle cloud can resolve.
    mutating func below(_ count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(Int(unit() * Float(count)), count - 1)
    }
}
