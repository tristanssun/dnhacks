import Foundation
import simd

/// Sliding-window least squares on each peer's ARKit frame relative to ours.
///
/// The particle filter tracks where a peer *is*. This estimates something
/// nearly constant instead: the rigid transform between the two ARKit worlds.
/// Both are gravity-aligned, so it is four numbers — a translation t and a yaw
/// θ — and a point p in the peer's frame sits at R(θ)·p + t in ours, with
///
///     R(θ)·p = (p.x cosθ + p.z sinθ,  p.y,  p.z cosθ − p.x sinθ)
///
/// matching `LocAREngine.ingestRemoteVIO`. Every range, every bearing either
/// side has taken, and every range between two other peers is a residual on
/// those four numbers, evaluated against the two VIO trajectories at the
/// instant it was measured. A window of them is solved by robust
/// Levenberg–Marquardt, with a grid of θ starts so a wrong basin cannot hold
/// on, and the curvature at the answer is the confidence: a near-singular
/// Hessian in θ says the geometry never observed it, which is the honest
/// version of the cloud-consensus number that read 1.0 while θ was 49° out.
///
/// The solver is pure and runs off the main actor on a snapshot of the store,
/// hence `nonisolated`: the project defaults every type to the main actor.
nonisolated struct FrameSolver {
    // MARK: Samples

    struct PoseSample: Sendable {
        var time: TimeInterval
        var position: SIMD3<Float>
        /// That device's own ARKit yaw, `VIOTracker.yaw` convention.
        var yaw: Float = 0
    }

    /// The peer's camera seen directly in our frame, from an ARKit
    /// collaborative session's participant anchor. Position and yaw are both
    /// in our world, so paired with the peer's own pose at the same instant
    /// they fix the whole transform at once.
    struct VisualFix: Sendable {
        var time: TimeInterval
        var position: SIMD3<Float>
        var yaw: Float
    }

    struct ScalarSample: Sendable {
        var time: TimeInterval
        var value: Float
    }

    struct PairRange: Sendable {
        var time: TimeInterval
        var a: Int
        var b: Int
        var range: Float
    }

    struct PeerWindow: Sendable {
        var poses: [PoseSample] = []
        var ranges: [ScalarSample] = []
        /// ψ_us: world azimuth of us→peer in our frame.
        var ourBearings: [ScalarSample] = []
        /// ψ_them: world azimuth of peer→us in the peer's frame.
        var peerBearings: [ScalarSample] = []
        var visualFixes: [VisualFix] = []
        /// Coarse θ from the two compasses. A weak prior only.
        var compassTheta: Float?

        var isEmpty: Bool {
            ranges.isEmpty && ourBearings.isEmpty && peerBearings.isEmpty
        }
    }

    /// Everything the solver reads, as plain value types so a snapshot is one
    /// copy. Peers are keyed by a small integer the owner assigns; `MCPeerID`
    /// is neither `Sendable` nor cheap to hash.
    struct Store: Sendable {
        /// Long enough that ~10 s of walking is always inside it, short enough
        /// that ARKit yaw drift (about 2°/min per device) stays under the
        /// bearing noise across the window.
        static let window: TimeInterval = 40
        /// Samples closer than this in one channel are the same measurement
        /// again as far as the solver is concerned.
        static let minSpacing: TimeInterval = 0.12
        static let poseSpacing: TimeInterval = 0.04
        /// Participant anchors update every frame; a fix every 200 ms is
        /// already far more than the rest of the window carries.
        static let fixSpacing: TimeInterval = 0.2

        var localPoses: [PoseSample] = []
        var peers: [Int: PeerWindow] = [:]
        var pairRanges: [PairRange] = []

        mutating func recordLocalPose(_ position: SIMD3<Float>, yaw: Float = 0, at time: TimeInterval) {
            if let last = localPoses.last, time <= last.time + Self.poseSpacing { return }
            localPoses.append(PoseSample(time: time, position: position, yaw: yaw))
        }

        mutating func recordPeerPose(_ id: Int, _ position: SIMD3<Float>, yaw: Float = 0, at time: TimeInterval) {
            var window = peers[id] ?? PeerWindow()
            if let last = window.poses.last, time <= last.time + Self.poseSpacing { return }
            window.poses.append(PoseSample(time: time, position: position, yaw: yaw))
            peers[id] = window
        }

        mutating func recordVisualFix(_ id: Int, position: SIMD3<Float>, yaw: Float, at time: TimeInterval) {
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite, yaw.isFinite else { return }
            var window = peers[id] ?? PeerWindow()
            if let last = window.visualFixes.last, time <= last.time + Self.fixSpacing { return }
            window.visualFixes.append(VisualFix(time: time, position: position, yaw: yaw))
            peers[id] = window
        }

        mutating func recordRange(_ id: Int, _ range: Float, at time: TimeInterval) {
            guard range.isFinite, range > 0.05 else { return }
            var window = peers[id] ?? PeerWindow()
            Self.append(ScalarSample(time: time, value: range), to: &window.ranges)
            peers[id] = window
        }

        mutating func recordOurBearing(_ id: Int, azimuth: Float, at time: TimeInterval) {
            guard azimuth.isFinite else { return }
            var window = peers[id] ?? PeerWindow()
            Self.append(ScalarSample(time: time, value: azimuth), to: &window.ourBearings)
            peers[id] = window
        }

        mutating func recordPeerBearing(_ id: Int, azimuth: Float, at time: TimeInterval) {
            guard azimuth.isFinite else { return }
            var window = peers[id] ?? PeerWindow()
            Self.append(ScalarSample(time: time, value: azimuth), to: &window.peerBearings)
            peers[id] = window
        }

        mutating func recordPairRange(_ a: Int, _ b: Int, _ range: Float, at time: TimeInterval) {
            guard a != b, range.isFinite, range > 0.05 else { return }
            let (lo, hi) = a < b ? (a, b) : (b, a)
            // Bounded look-back for the last sample of this pair.
            for sample in pairRanges.suffix(64).reversed() where sample.a == lo && sample.b == hi {
                if time <= sample.time + Self.minSpacing { return }
                break
            }
            pairRanges.append(PairRange(time: time, a: lo, b: hi, range: range))
        }

        mutating func setCompassTheta(_ id: Int, _ theta: Float?) {
            var window = peers[id] ?? PeerWindow()
            window.compassTheta = theta
            peers[id] = window
        }

        /// The peer's ARKit frame changed (reset or re-origin), or the peer is
        /// gone. Nothing measured before is comparable to anything after.
        mutating func clearPeer(_ id: Int) {
            peers[id] = nil
            pairRanges.removeAll { $0.a == id || $0.b == id }
        }

        /// Our own ARKit frame changed. Every transform is now different.
        mutating func reset() {
            localPoses.removeAll(keepingCapacity: true)
            for id in peers.keys {
                peers[id] = PeerWindow(compassTheta: peers[id]?.compassTheta)
            }
            pairRanges.removeAll(keepingCapacity: true)
        }

        mutating func prune(before time: TimeInterval) {
            Self.drop(&localPoses, before: time)
            for id in peers.keys {
                guard var window = peers[id] else { continue }
                Self.drop(&window.poses, before: time)
                Self.drop(&window.ranges, before: time)
                Self.drop(&window.ourBearings, before: time)
                Self.drop(&window.peerBearings, before: time)
                Self.drop(&window.visualFixes, before: time)
                peers[id] = window
            }
            if let first = pairRanges.first, first.time < time {
                pairRanges.removeAll { $0.time < time }
            }
        }

        private static func append(_ sample: ScalarSample, to samples: inout [ScalarSample]) {
            guard sample.value.isFinite else { return }
            if let last = samples.last, sample.time <= last.time + minSpacing { return }
            samples.append(sample)
        }

        private static func drop(_ samples: inout [PoseSample], before time: TimeInterval) {
            let count = samples.firstIndex { $0.time >= time } ?? samples.count
            if count > 0 { samples.removeFirst(count) }
        }

        private static func drop(_ samples: inout [ScalarSample], before time: TimeInterval) {
            let count = samples.firstIndex { $0.time >= time } ?? samples.count
            if count > 0 { samples.removeFirst(count) }
        }

        private static func drop(_ samples: inout [VisualFix], before time: TimeInterval) {
            let count = samples.firstIndex { $0.time >= time } ?? samples.count
            if count > 0 { samples.removeFirst(count) }
        }

        /// Linear interpolation, or the nearest end within `slack`. Nil across
        /// a gap longer than `maxGap`, which is a VIO dropout rather than motion.
        static func interpolate(_ samples: [PoseSample], at time: TimeInterval) -> SIMD3<Float>? {
            guard let (a, b, fraction) = bracket(samples, at: time) else { return nil }
            return a.position + (b.position - a.position) * fraction
        }

        /// Yaw at `time`, interpolated on the circle.
        static func interpolateYaw(_ samples: [PoseSample], at time: TimeInterval) -> Float? {
            guard let (a, b, fraction) = bracket(samples, at: time) else { return nil }
            let x = cos(a.yaw) + (cos(b.yaw) - cos(a.yaw)) * fraction
            let y = sin(a.yaw) + (sin(b.yaw) - sin(a.yaw)) * fraction
            guard hypot(x, y) > 1e-3 else { return a.yaw }
            return atan2(y, x)
        }

        private static func bracket(_ samples: [PoseSample], at time: TimeInterval) -> (PoseSample, PoseSample, Float)? {
            let slack = 0.4
            let maxGap = 1.0
            guard let first = samples.first, let last = samples.last else { return nil }
            if time <= first.time { return time >= first.time - slack ? (first, first, 0) : nil }
            if time >= last.time { return time <= last.time + slack ? (last, last, 0) : nil }
            var lo = 0
            var hi = samples.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if samples[mid].time <= time { lo = mid } else { hi = mid }
            }
            let a = samples[lo]
            let b = samples[hi]
            let gap = b.time - a.time
            guard gap <= maxGap else { return nil }
            let fraction = gap > 0 ? Float((time - a.time) / gap) : 0
            return (a, b, fraction)
        }
    }

    // MARK: Solution

    struct Solution: Sendable {
        var theta: Float
        var translation: SIMD3<Float>
        /// Parameter order tx, ty, tz, θ.
        var covariance: simd_double4x4
        var sigmaTheta: Float
        /// Robust cost per residual. Around 0.5 when the noise model fits.
        var cost: Float
        var residualCount: Int
        var rangeCount: Int
        var bearingCount: Int
        var fixCount: Int
        /// Another basin explains the window nearly as well. Position and θ
        /// are then a coin toss between two answers, and the covariance,
        /// which only describes the chosen basin, does not know it.
        var ambiguous: Bool
        var solvedAt: TimeInterval

        /// A peer-frame point in our frame.
        func map(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let s = sin(theta)
            let c = cos(theta)
            return SIMD3<Float>(p.x * c + p.z * s, p.y, p.z * c - p.x * s) + translation
        }

        /// World azimuth of us→peer for the peer at peer-frame `p` and us at
        /// `q`, with its 1σ from the transform covariance. Nil when the peer is
        /// under `minPlanar` away horizontally, where azimuth means nothing.
        func azimuth(peer p: SIMD3<Float>, from q: SIMD3<Float>, minPlanar: Float = 0.3) -> (azimuth: Float, sigma: Float)? {
            let s = Double(sin(theta))
            let c = Double(cos(theta))
            let pd = SIMD3<Double>(p)
            let d = SIMD3<Double>(map(p) - q)
            let rho2 = d.x * d.x + d.z * d.z
            guard rho2 > Double(minPlanar * minPlanar) else { return nil }
            let dRp = SIMD3<Double>(-pd.x * s + pd.z * c, 0, -pd.z * s - pd.x * c)
            let dazdd = SIMD3<Double>(d.z / rho2, 0, -d.x / rho2)
            let g = SIMD4<Double>(dazdd.x, dazdd.y, dazdd.z, simd_dot(dazdd, dRp))
            let variance = simd_dot(g, covariance * g)
            guard variance.isFinite, variance >= 0 else { return nil }
            return (Float(atan2(d.x, d.z)), Float(sqrt(variance)))
        }
    }

    // MARK: Noise model

    /// Nearby Interaction range in line of sight, m.
    static let sigmaRange: Double = 0.10
    /// Camera-assisted `horizontalAngle`, rad.
    static let sigmaBearing: Double = 0.12
    /// Both sessions started at hand height, so the frames agree on up to
    /// within a few tens of centimetres.
    static let sigmaHeight: Double = 0.5
    /// Indoor compass bias is tens of degrees. This is a floor on how bad θ can
    /// be reported when nothing else observed it, not a source of precision.
    static let sigmaCompass: Double = 0.6
    /// Participant anchor position in our frame, m. ARKit's own relocalization
    /// error plus the merge, not the centimetres of the tracking itself.
    static let sigmaVisual: Double = 0.15
    /// θ from a participant anchor's yaw against the peer's reported yaw, rad.
    static let sigmaVisualYaw: Double = 0.05
    /// Cauchy scale in σ units. Non-line-of-sight ranges read long by a metre
    /// or more; the kernel takes their weight away instead of letting them
    /// drag the answer.
    static let cauchy: Double = 2.5
    /// θ starts for the global search, 15° apart.
    static let thetaStarts = 24
    /// A second basin within this much robust cost of the best is a tie.
    static let ambiguityMargin: Double = 4
    /// Robust cost per residual above which a warm start is treated as lost.
    static let poorFitCost: Double = 1.5
    static let minRanges = 6

    // MARK: Solve

    /// Solve every peer that has enough data. `warm` seeds each peer from its
    /// previous answer; with `fullSearch` the θ grid runs as well, which is
    /// what lets a wrong basin be left. The joint pass at the end adds the
    /// peer↔peer ranges, which need every transform at once.
    static func solve(
        _ store: Store,
        warm: [Int: Solution],
        now: TimeInterval,
        fullSearch: Bool
    ) -> [Int: Solution] {
        let ids = store.peers.keys.sorted()
        var order: [Int] = []
        var blocks: [[Term]] = []
        var counts: [(ranges: Int, bearings: Int, fixes: Int)] = []
        for id in ids {
            guard let window = store.peers[id] else { continue }
            let terms = assemble(window, local: store.localPoses, block: 0)
            let ranges = terms.filter { if case .range = $0 { return true } else { return false } }.count
            // A few participant fixes determine the transform on their own.
            guard ranges >= minRanges || window.visualFixes.count >= 3 else { continue }
            let bearings = terms.filter {
                switch $0 {
                case .ourBearing, .peerBearing: return true
                default: return false
                }
            }.count
            order.append(id)
            blocks.append(terms)
            counts.append((ranges, bearings, window.visualFixes.count))
        }
        guard !order.isEmpty else { return [:] }

        // Independent solves, each in its own single-block problem.
        var params: [[Double]] = []
        var ambiguous: [Bool] = []
        for (index, id) in order.enumerated() {
            let window = store.peers[id]!
            let problem = Problem(terms: blocks[index], blockCount: 1)
            var results: [(x: [Double], cost: Double)] = []
            var searched = fullSearch
            var starts: [[Double]] = []
            if let previous = warm[id] {
                starts.append([Double(previous.translation.x), Double(previous.translation.y),
                               Double(previous.translation.z), Double(previous.theta)])
            }
            // A participant anchor is the answer up to noise; always start there.
            if let visual = visualStart(window) {
                starts.append(visual)
            }
            for start in starts {
                let result = optimize(problem, from: start, iterations: 25)
                results.append((result.x, result.cost))
            }
            // A start that does not explain the window is in the wrong basin.
            // The noise model puts a good fit near 0.5 per residual and the
            // Cauchy kernel caps a bad one only slowly, so this is a clean
            // separation; run the grid now rather than wait for the scheduled one.
            if let best = results.min(by: { $0.cost < $1.cost }) {
                if best.cost > poorFitCost * Double(max(blocks[index].count, 1)) {
                    searched = true
                }
            } else {
                searched = true
            }
            if searched {
                for start in initialGuesses(window, local: store.localPoses) {
                    let result = optimize(problem, from: start, iterations: 25)
                    results.append((result.x, result.cost))
                }
            }
            guard let best = results.min(by: { $0.cost < $1.cost }) else { continue }
            let tie = results.contains { other in
                other.cost < best.cost + ambiguityMargin && distinct(other.x, best.x)
            }
            params.append(best.x)
            ambiguous.append(tie)
        }
        guard params.count == order.count else { return [:] }

        // Joint refinement with the peer↔peer ranges.
        var terms: [Term] = []
        for (index, block) in blocks.enumerated() {
            terms.append(contentsOf: block.map { $0.rebased(to: index) })
        }
        let blockOf = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var pairCount = 0
        for pair in store.pairRanges {
            guard let a = blockOf[pair.a], let b = blockOf[pair.b],
                  let pa = Store.interpolate(store.peers[pair.a]!.poses, at: pair.time),
                  let pb = Store.interpolate(store.peers[pair.b]!.poses, at: pair.time) else { continue }
            terms.append(.pair(a: a, b: b, pa: SIMD3<Double>(pa), pb: SIMD3<Double>(pb), r: Double(pair.range)))
            pairCount += 1
        }
        let joint = Problem(terms: terms, blockCount: order.count)
        let start = params.flatMap { $0 }
        let result = pairCount > 0 ? optimize(joint, from: start, iterations: 15) : optimize(joint, from: start, iterations: 3)

        // Covariance from the curvature at the answer, inflated when the
        // residuals are larger than the noise model claims.
        let n = 4 * order.count
        let dof = max(result.residuals - n, 1)
        let scale = max(1, result.weightedSquares / Double(dof))
        let inverse = invert(result.hessian, n: n)

        var solutions: [Int: Solution] = [:]
        for (index, id) in order.enumerated() {
            let base = 4 * index
            let x = result.x
            var covariance = simd_double4x4(0)
            var sigmaTheta = Double.infinity
            if let inverse {
                for row in 0..<4 {
                    for column in 0..<4 {
                        covariance[column][row] = inverse[(base + row) * n + base + column] * scale
                    }
                }
                let variance = covariance[3][3]
                sigmaTheta = variance.isFinite && variance >= 0 ? sqrt(variance) : .infinity
            }
            let count = counts[index]
            solutions[id] = Solution(
                theta: Float(wrap(x[base + 3])),
                translation: SIMD3<Float>(Float(x[base]), Float(x[base + 1]), Float(x[base + 2])),
                covariance: covariance,
                sigmaTheta: Float(sigmaTheta),
                cost: Float(result.cost / Double(max(result.residuals, 1))),
                residualCount: result.residuals,
                rangeCount: count.ranges,
                bearingCount: count.bearings,
                fixCount: count.fixes,
                ambiguous: ambiguous[index],
                solvedAt: now
            )
        }
        return solutions
    }

    // MARK: Terms

    /// One residual. `block` indexes the 4-parameter group it touches.
    private enum Term {
        case range(block: Int, q: SIMD3<Double>, p: SIMD3<Double>, r: Double)
        case ourBearing(block: Int, q: SIMD3<Double>, p: SIMD3<Double>, psi: Double)
        case peerBearing(block: Int, q: SIMD3<Double>, p: SIMD3<Double>, psi: Double)
        case pair(a: Int, b: Int, pa: SIMD3<Double>, pb: SIMD3<Double>, r: Double)
        /// One axis of R(θ)·p + t − target, a participant anchor seen in our frame.
        case pointFix(block: Int, p: SIMD3<Double>, target: SIMD3<Double>, axis: Int)
        case heightPrior(block: Int)
        case thetaPrior(block: Int, theta: Double, sigma: Double)

        func rebased(to block: Int) -> Term {
            switch self {
            case let .range(_, q, p, r): return .range(block: block, q: q, p: p, r: r)
            case let .ourBearing(_, q, p, psi): return .ourBearing(block: block, q: q, p: p, psi: psi)
            case let .peerBearing(_, q, p, psi): return .peerBearing(block: block, q: q, p: p, psi: psi)
            case .pair: return self
            case let .pointFix(_, p, target, axis): return .pointFix(block: block, p: p, target: target, axis: axis)
            case .heightPrior: return .heightPrior(block: block)
            case let .thetaPrior(_, theta, sigma): return .thetaPrior(block: block, theta: theta, sigma: sigma)
            }
        }
    }

    private static func assemble(_ window: PeerWindow, local: [PoseSample], block: Int) -> [Term] {
        var terms: [Term] = []
        for sample in window.ranges {
            guard let q = Store.interpolate(local, at: sample.time),
                  let p = Store.interpolate(window.poses, at: sample.time) else { continue }
            terms.append(.range(block: block, q: SIMD3<Double>(q), p: SIMD3<Double>(p), r: Double(sample.value)))
        }
        for sample in window.ourBearings {
            guard let q = Store.interpolate(local, at: sample.time),
                  let p = Store.interpolate(window.poses, at: sample.time) else { continue }
            terms.append(.ourBearing(block: block, q: SIMD3<Double>(q), p: SIMD3<Double>(p), psi: Double(sample.value)))
        }
        for sample in window.peerBearings {
            guard let q = Store.interpolate(local, at: sample.time),
                  let p = Store.interpolate(window.poses, at: sample.time) else { continue }
            terms.append(.peerBearing(block: block, q: SIMD3<Double>(q), p: SIMD3<Double>(p), psi: Double(sample.value)))
        }
        for fix in window.visualFixes {
            guard let p = Store.interpolate(window.poses, at: fix.time),
                  let yaw = Store.interpolateYaw(window.poses, at: fix.time) else { continue }
            for axis in 0..<3 {
                terms.append(.pointFix(block: block, p: SIMD3<Double>(p), target: SIMD3<Double>(fix.position), axis: axis))
            }
            terms.append(.thetaPrior(block: block, theta: Double(fix.yaw - yaw), sigma: sigmaVisualYaw))
        }
        terms.append(.heightPrior(block: block))
        if let compass = window.compassTheta, compass.isFinite {
            terms.append(.thetaPrior(block: block, theta: Double(compass), sigma: sigmaCompass))
        }
        return terms
    }

    // MARK: Problem

    private struct Problem {
        let terms: [Term]
        let blockCount: Int
        var n: Int { 4 * blockCount }

        struct Linearization {
            var cost: Double
            var weightedSquares: Double
            var residuals: Int
            var hessian: [Double]
            var gradient: [Double]
        }

        /// Accumulates JᵀWJ and JᵀWr directly; each term touches at most eight
        /// parameters, so there is no reason to build J.
        func linearize(_ x: [Double]) -> Linearization {
            let n = self.n
            var hessian = [Double](repeating: 0, count: n * n)
            var gradient = [Double](repeating: 0, count: n)
            var cost = 0.0
            var weightedSquares = 0.0
            var residuals = 0
            var columns = [Int](repeating: 0, count: 8)
            var values = [Double](repeating: 0, count: 8)

            for term in terms {
                var count = 0
                var residual = 0.0
                guard evaluate(term, x, &residual, &columns, &values, &count) else { continue }
                let ratio = residual / FrameSolver.cauchy
                let weight = 1 / (1 + ratio * ratio)
                cost += 0.5 * FrameSolver.cauchy * FrameSolver.cauchy * log1p(ratio * ratio)
                weightedSquares += weight * residual * residual
                residuals += 1
                for i in 0..<count {
                    let gi = values[i]
                    gradient[columns[i]] += weight * gi * residual
                    for j in 0..<count {
                        hessian[columns[i] * n + columns[j]] += weight * gi * values[j]
                    }
                }
            }
            return Linearization(cost: cost, weightedSquares: weightedSquares, residuals: residuals,
                                 hessian: hessian, gradient: gradient)
        }

        /// Residual and sparse gradient of one term, both divided by σ.
        private func evaluate(
            _ term: Term, _ x: [Double],
            _ residual: inout Double, _ columns: inout [Int], _ values: inout [Double], _ count: inout Int
        ) -> Bool {
            switch term {
            case let .range(block, q, p, r):
                let base = 4 * block
                let theta = x[base + 3]
                let (rp, dRp) = rotate(p, theta)
                let d = rp + SIMD3<Double>(x[base], x[base + 1], x[base + 2]) - q
                let norm = simd_length(d)
                guard norm > 1e-3 else { return false }
                let unit = d / norm
                let sigma = FrameSolver.sigmaRange
                residual = (norm - r) / sigma
                set(&columns, &values, &count, base, unit / sigma, simd_dot(unit, dRp) / sigma)
                return true

            case let .ourBearing(block, q, p, psi):
                let base = 4 * block
                let theta = x[base + 3]
                let (rp, dRp) = rotate(p, theta)
                let d = rp + SIMD3<Double>(x[base], x[base + 1], x[base + 2]) - q
                let rho2 = d.x * d.x + d.z * d.z
                guard rho2 > 0.09 else { return false }
                let sigma = FrameSolver.sigmaBearing
                let dazdd = SIMD3<Double>(d.z / rho2, 0, -d.x / rho2)
                residual = wrap(atan2(d.x, d.z) - psi) / sigma
                set(&columns, &values, &count, base, dazdd / sigma, simd_dot(dazdd, dRp) / sigma)
                return true

            case let .peerBearing(block, q, p, psi):
                let base = 4 * block
                let theta = x[base + 3]
                let s = sin(theta)
                let c = cos(theta)
                let u = q - SIMD3<Double>(x[base], x[base + 1], x[base + 2])
                // R(−θ)·u − p: us in the peer's frame, relative to the peer.
                let d = SIMD3<Double>(u.x * c - u.z * s, u.y, u.z * c + u.x * s) - p
                let rho2 = d.x * d.x + d.z * d.z
                guard rho2 > 0.09 else { return false }
                let sigma = FrameSolver.sigmaBearing
                let ax = d.z / rho2
                let az = -d.x / rho2
                // ∂d/∂t = −R(−θ); ∂d/∂θ = (−u.x s − u.z c, 0, −u.z s + u.x c).
                let dt = SIMD3<Double>(ax * -c + az * -s, 0, ax * s + az * -c)
                let dtheta = ax * (-u.x * s - u.z * c) + az * (-u.z * s + u.x * c)
                residual = wrap(atan2(d.x, d.z) - psi) / sigma
                set(&columns, &values, &count, base, dt / sigma, dtheta / sigma)
                return true

            case let .pair(a, b, pa, pb, r):
                let baseA = 4 * a
                let baseB = 4 * b
                let (rpa, dRpa) = rotate(pa, x[baseA + 3])
                let (rpb, dRpb) = rotate(pb, x[baseB + 3])
                let d = (rpa + SIMD3<Double>(x[baseA], x[baseA + 1], x[baseA + 2]))
                    - (rpb + SIMD3<Double>(x[baseB], x[baseB + 1], x[baseB + 2]))
                let norm = simd_length(d)
                guard norm > 1e-3 else { return false }
                let unit = d / norm
                let sigma = FrameSolver.sigmaRange
                residual = (norm - r) / sigma
                set(&columns, &values, &count, baseA, unit / sigma, simd_dot(unit, dRpa) / sigma)
                set(&columns, &values, &count, baseB, -unit / sigma, -simd_dot(unit, dRpb) / sigma)
                return true

            case let .heightPrior(block):
                let base = 4 * block
                let sigma = FrameSolver.sigmaHeight
                residual = x[base + 1] / sigma
                columns[0] = base + 1
                values[0] = 1 / sigma
                count = 1
                return true

            case let .pointFix(block, p, target, axis):
                let base = 4 * block
                let (rp, dRp) = rotate(p, x[base + 3])
                let d = rp + SIMD3<Double>(x[base], x[base + 1], x[base + 2]) - target
                let sigma = FrameSolver.sigmaVisual
                residual = d[axis] / sigma
                columns[0] = base + axis
                values[0] = 1 / sigma
                columns[1] = base + 3
                values[1] = dRp[axis] / sigma
                count = 2
                return true

            case let .thetaPrior(block, theta, sigma):
                let base = 4 * block
                residual = wrap(x[base + 3] - theta) / sigma
                columns[0] = base + 3
                values[0] = 1 / sigma
                count = 1
                return true
            }
        }

        private func set(
            _ columns: inout [Int], _ values: inout [Double], _ count: inout Int,
            _ base: Int, _ dt: SIMD3<Double>, _ dtheta: Double
        ) {
            columns[count] = base
            values[count] = dt.x
            columns[count + 1] = base + 1
            values[count + 1] = dt.y
            columns[count + 2] = base + 2
            values[count + 2] = dt.z
            columns[count + 3] = base + 3
            values[count + 3] = dtheta
            count += 4
        }
    }

    /// R(θ)·p and its derivative in θ.
    private static func rotate(_ p: SIMD3<Double>, _ theta: Double) -> (SIMD3<Double>, SIMD3<Double>) {
        let s = sin(theta)
        let c = cos(theta)
        return (
            SIMD3<Double>(p.x * c + p.z * s, p.y, p.z * c - p.x * s),
            SIMD3<Double>(-p.x * s + p.z * c, 0, -p.z * s - p.x * c)
        )
    }

    private struct Result {
        var x: [Double]
        var cost: Double
        var weightedSquares: Double
        var residuals: Int
        var hessian: [Double]
    }

    /// Levenberg–Marquardt with the robust weights recomputed every step.
    private static func optimize(_ problem: Problem, from start: [Double], iterations: Int) -> Result {
        let n = problem.n
        var x = start
        var current = problem.linearize(x)
        var lambda = 1e-3
        for _ in 0..<iterations {
            var damped = current.hessian
            for i in 0..<n {
                damped[i * n + i] *= 1 + lambda
                damped[i * n + i] += 1e-9
            }
            guard let step = solve(damped, rhs: current.gradient.map { -$0 }, n: n) else {
                lambda *= 10
                if lambda > 1e8 { break }
                continue
            }
            var candidate = x
            for i in 0..<n {
                candidate[i] += step[i]
                if i % 4 == 3 { candidate[i] = wrap(candidate[i]) }
            }
            let next = problem.linearize(candidate)
            if next.cost < current.cost {
                x = candidate
                current = next
                lambda = max(lambda / 3, 1e-6)
                if step.map(abs).max() ?? 0 < 1e-4 { break }
            } else {
                lambda *= 10
                if lambda > 1e8 { break }
            }
        }
        return Result(x: x, cost: current.cost, weightedSquares: current.weightedSquares,
                      residuals: current.residuals, hessian: current.hessian)
    }

    // MARK: Initial guesses

    /// The transform implied by the latest participant anchor alone:
    /// θ from the yaws, t from the positions.
    private static func visualStart(_ window: PeerWindow) -> [Double]? {
        guard let fix = window.visualFixes.last,
              let p = Store.interpolate(window.poses, at: fix.time),
              let yaw = Store.interpolateYaw(window.poses, at: fix.time) else { return nil }
        let theta = wrap(Double(fix.yaw - yaw))
        let (rp, _) = rotate(SIMD3<Double>(p), theta)
        let t = SIMD3<Double>(fix.position) - rp
        return [t.x, t.y, t.z, theta]
    }

    /// One or more starts per θ on the grid. Translation for a fixed θ is a
    /// trilateration of t from the anchors q_k − R(θ)p_k, which is linear after
    /// differencing; when a bearing exists it gives a second start that does
    /// not depend on either trajectory having moved.
    private static func initialGuesses(_ window: PeerWindow, local: [PoseSample]) -> [[Double]] {
        // Raw (q, p, r) triples, so each θ can rotate p itself.
        var pairs: [(q: SIMD3<Double>, p: SIMD3<Double>, r: Double)] = []
        var latestRange: (time: TimeInterval, r: Double)?
        for sample in window.ranges {
            guard let q = Store.interpolate(local, at: sample.time),
                  let p = Store.interpolate(window.poses, at: sample.time) else { continue }
            pairs.append((SIMD3<Double>(q), SIMD3<Double>(p), Double(sample.value)))
            latestRange = (sample.time, Double(sample.value))
        }
        guard let latest = latestRange, !pairs.isEmpty else { return [] }

        func nearestBearing(_ samples: [ScalarSample]) -> (q: SIMD3<Double>, p: SIMD3<Double>, r: Double, psi: Double)? {
            guard let sample = samples.min(by: { abs($0.time - latest.time) < abs($1.time - latest.time) }),
                  abs(sample.time - latest.time) < 1.0,
                  let q = Store.interpolate(local, at: sample.time),
                  let p = Store.interpolate(window.poses, at: sample.time) else { return nil }
            return (SIMD3<Double>(q), SIMD3<Double>(p), latest.r, Double(sample.value))
        }
        let ours = nearestBearing(window.ourBearings)
        let theirs = nearestBearing(window.peerBearings)

        var starts: [[Double]] = []
        for step in 0..<thetaStarts {
            let theta = -Double.pi + (Double(step) + 0.5) * 2 * .pi / Double(thetaStarts)
            if let t = trilaterate(pairs, theta: theta) {
                starts.append([t.x, t.y, t.z, theta])
            }
            if let ours {
                let (rp, _) = rotate(ours.p, theta)
                let peer = ours.q + ours.r * SIMD3<Double>(sin(ours.psi), 0, cos(ours.psi))
                let t = peer - rp
                starts.append([t.x, t.y, t.z, theta])
            }
            if let theirs {
                let (rp, _) = rotate(theirs.p, theta)
                // Their azimuth peer→us, rotated into our frame, points from the peer at us.
                let az = theirs.psi + theta
                let peer = theirs.q - theirs.r * SIMD3<Double>(sin(az), 0, cos(az))
                let t = peer - rp
                starts.append([t.x, t.y, t.z, theta])
            }
        }
        return starts
    }

    /// Least-squares t for a fixed θ from ‖t − a_k‖ = r_k with a_k = q_k − R(θ)p_k,
    /// differenced against the mean equation so it is linear in t. A weak pull
    /// of t.y toward 0 and a ridge keep a static pair from blowing up.
    private static func trilaterate(_ pairs: [(q: SIMD3<Double>, p: SIMD3<Double>, r: Double)], theta: Double) -> SIMD3<Double>? {
        var anchors: [SIMD3<Double>] = []
        anchors.reserveCapacity(pairs.count)
        for pair in pairs {
            let (rp, _) = rotate(pair.p, theta)
            anchors.append(pair.q - rp)
        }
        let count = Double(anchors.count)
        let meanAnchor = anchors.reduce(SIMD3<Double>.zero, +) / count
        let meanSquare = anchors.reduce(0.0) { $0 + simd_length_squared($1) } / count
        let meanRange2 = pairs.reduce(0.0) { $0 + $1.r * $1.r } / count
        var a = [Double](repeating: 0, count: 9)
        var b = [Double](repeating: 0, count: 3)
        for (anchor, pair) in zip(anchors, pairs) {
            let row = 2 * (anchor - meanAnchor)
            let rhs = simd_length_squared(anchor) - meanSquare - pair.r * pair.r + meanRange2
            for i in 0..<3 {
                b[i] += row[i] * rhs
                for j in 0..<3 {
                    a[i * 3 + j] += row[i] * row[j]
                }
            }
        }
        // Height pull and ridge, in the same units as the rows above.
        a[4] += 4
        for i in 0..<3 {
            a[i * 3 + i] += 1e-3
        }
        guard let t = solve(a, rhs: b, n: 3) else { return nil }
        // A rank-deficient system leaves t at the mean anchor, which is a fine
        // start; a wild one is not.
        guard t.allSatisfy(\.isFinite), simd_length(SIMD3<Double>(t[0], t[1], t[2]) - meanAnchor) < 200 else { return nil }
        return SIMD3<Double>(t[0], t[1], t[2])
    }

    // MARK: Linear algebra

    /// Gaussian elimination with partial pivoting on a row-major n×n matrix.
    private static func solve(_ matrix: [Double], rhs: [Double], n: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            var best = abs(a[column * n + column])
            for row in (column + 1)..<n where abs(a[row * n + column]) > best {
                best = abs(a[row * n + column])
                pivot = row
            }
            guard best > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<n {
                    a.swapAt(column * n + k, pivot * n + k)
                }
                b.swapAt(column, pivot)
            }
            let diagonal = a[column * n + column]
            for row in (column + 1)..<n {
                let factor = a[row * n + column] / diagonal
                guard factor != 0 else { continue }
                for k in column..<n {
                    a[row * n + k] -= factor * a[column * n + k]
                }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row * n + k] * x[k]
            }
            x[row] = sum / a[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    private static func invert(_ matrix: [Double], n: Int) -> [Double]? {
        var inverse = [Double](repeating: 0, count: n * n)
        for column in 0..<n {
            var e = [Double](repeating: 0, count: n)
            e[column] = 1
            guard let x = solve(matrix, rhs: e, n: n) else { return nil }
            for row in 0..<n {
                inverse[row * n + column] = x[row]
            }
        }
        return inverse
    }

    /// Two basins that differ only in height are the same answer for every
    /// purpose here: height is weakly observed by design and never drawn.
    private static func distinct(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count >= 4, b.count >= 4 else { return false }
        let horizontal = hypot(a[0] - b[0], a[2] - b[2])
        return abs(wrap(a[3] - b[3])) > 0.35 || horizontal > 1.0
    }

    static func wrap(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }
}
