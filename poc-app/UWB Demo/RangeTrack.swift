import Foundation

/// Tracked UWB range, in meters. It is a value type so the view can hold a
/// snapshot and call `value(at:)` every frame.
///
/// `.uwbFirst` (default): every local UWB sample is taken at face value. Between
/// samples the range advances with ARKit motion (`nudge`), or with the last
/// measured rate when the bearing isn't resolved. UWB is the truth; ARKit only
/// fills the 100–200 ms gaps and dropouts.
///
/// `.smoothed`: constant-velocity Kalman filter that also fuses the peer's
/// sample. Less jitter, a little more lag.
struct RangeTrack {
    enum Mode {
        case uwbFirst
        case smoothed
    }

    enum Source {
        case local
        case remote
    }

    let mode: Mode
    private(set) var range: Float
    private(set) var rate: Float
    /// Time of the last accepted measurement.
    private(set) var updatedAt: Date
    private var predictedAt: Date
    private var p00: Float
    private var p01: Float
    private var p11: Float
    private var outliers = 0
    /// Set by `nudge`; tells `.uwbFirst` that motion is already being applied so
    /// it must not also extrapolate with the measured rate.
    private var motionAssisted = false

    /// Human walking acceleration, m/s².
    static let accelerationSigma: Float = 1.5
    /// Nearby Interaction distance noise in line of sight, m.
    static let localSigma: Float = 0.08
    /// Peer's sample, arriving one network hop late, m.
    static let remoteSigma: Float = 0.15
    static let maxRate: Float = 3
    static let maxExtrapolation: TimeInterval = 0.35
    /// How recent a measurement has to be to render without the stale marker.
    ///
    /// 0.75 s was tighter than Nearby Interaction's own cadence near the edge of
    /// its range, where samples arrive sparsely and irregularly, so ordinary
    /// jitter at 8-9 m was being drawn as a failure. A 1.5 s old UWB reading is
    /// still a measurement; `staleWindow` at 5 s still covers genuinely gone.
    static let liveWindow: TimeInterval = 1.5
    static let staleWindow: TimeInterval = 5

    init(range: Float, at date: Date, mode: Mode = .uwbFirst) {
        self.mode = mode
        self.range = range
        rate = 0
        updatedAt = date
        predictedAt = date
        p00 = 0.05
        p01 = 0
        p11 = 1
    }

    // MARK: Inputs

    mutating func update(_ measurement: Float, from source: Source, at date: Date) {
        switch mode {
        case .uwbFirst:
            guard source == .local else { return }
            snap(measurement, at: date)
        case .smoothed:
            fuse(measurement, sigma: source == .local ? Self.localSigma : Self.remoteSigma, at: date)
        }
    }

    /// Take the UWB sample as-is. The only rejection is a physically impossible
    /// jump (faster than `maxRate`), and even that is accepted after 3 in a row.
    private mutating func snap(_ measurement: Float, at date: Date) {
        // Ranging returning after a dropout. The held value is dead-reckoned
        // rather than measured, so there is nothing to reconcile against, and
        // the jump gate below would reject the truth for three samples running
        // — longer in practice, since `outliers` resets on any accepted sample
        // and marginal-range readings interleave good with bad. Start clean.
        if isStale(at: date) {
            self = RangeTrack(range: measurement, at: date, mode: mode)
            return
        }
        let dt = Float(max(date.timeIntervalSince(updatedAt), 0.02))
        let previous = range
        let jump = measurement - value(at: date)
        if abs(jump) > 0.35 + Self.maxRate * dt {
            outliers += 1
            if outliers < 3 {
                return
            }
        }
        outliers = 0
        let instantRate = max(min((measurement - previous) / dt, Self.maxRate), -Self.maxRate)
        if motionAssisted {
            // ARKit is carrying the motion between samples; rate would double-count.
            rate = 0
        } else {
            rate = dt > 0.5 ? 0 : 0.5 * rate + 0.5 * instantRate
        }
        motionAssisted = false
        range = max(measurement, 0)
        updatedAt = date
        predictedAt = date
    }

    /// Kalman fuse of a range measurement taken at `date`. Late samples are
    /// shifted by the current rate so a 50 ms old value doesn't drag the estimate.
    private mutating func fuse(_ measurement: Float, sigma: Float, at date: Date) {
        // Same reasoning as `snap`, and it also avoids running `predict` across
        // a multi-second gap, where the q*dt^4 covariance term explodes.
        if isStale(at: date) {
            self = RangeTrack(range: measurement, at: date, mode: mode)
            return
        }
        predict(to: date)
        let lag = Float(max(predictedAt.timeIntervalSince(date), 0))
        let z = measurement + rate * min(lag, 0.25)
        let innovation = z - range
        let s = p00 + sigma * sigma
        let gate = max(3 * sqrt(s), 0.35)
        if abs(innovation) > gate {
            outliers += 1
            if outliers >= 3 {
                self = RangeTrack(range: measurement, at: date, mode: mode)
            }
            return
        }
        outliers = 0
        let k0 = p00 / s
        let k1 = p01 / s
        range += k0 * innovation
        rate = max(min(rate + k1 * innovation, Self.maxRate), -Self.maxRate)
        let n00 = (1 - k0) * p00
        let n01 = (1 - k0) * p01
        let n11 = p11 - k1 * p01
        p00 = n00
        p01 = n01
        p11 = n11
        updatedAt = max(updatedAt, date)
    }

    /// Range change implied by VIO motion since the last call. The filter's rate
    /// then only has to learn the residual.
    mutating func nudge(_ delta: Float, at date: Date) {
        predict(to: date)
        range = max(range + max(min(delta, 0.3), -0.3), 0)
        motionAssisted = true
    }

    // MARK: Output

    /// Range extrapolated to `date`, capped at `maxExtrapolation` past the last
    /// prediction so a dropout holds instead of running away.
    func value(at date: Date) -> Float {
        let dt = Float(min(max(date.timeIntervalSince(predictedAt), 0), Self.maxExtrapolation))
        return max(range + rate * dt, 0)
    }

    func age(at date: Date) -> TimeInterval {
        date.timeIntervalSince(updatedAt)
    }

    func isLive(at date: Date) -> Bool {
        age(at: date) < Self.liveWindow
    }

    func isStale(at date: Date) -> Bool {
        age(at: date) >= Self.staleWindow
    }

    // MARK: Internals

    private mutating func predict(to date: Date) {
        let dt = Float(date.timeIntervalSince(predictedAt))
        guard dt > 0 else { return }
        range = max(range + rate * dt, 0)
        let q = Self.accelerationSigma * Self.accelerationSigma
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        p00 += 2 * p01 * dt + p11 * dt2 + q * dt4 / 4
        p01 += p11 * dt + q * dt3 / 2
        p11 += q * dt2
        predictedAt = date
    }
}
