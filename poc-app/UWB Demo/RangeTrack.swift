import Foundation

/// Constant-velocity Kalman filter on a UWB range, in meters.
///
/// Smooths the ±10 cm jitter without moving-average lag, rejects outliers with
/// a 3σ gate, accepts VIO dead-reckoning between UWB frames, and extrapolates
/// to render time so the label shows where you are now rather than one UWB
/// interval ago. It is a value type so the view can hold a snapshot and call
/// `value(at:)` every frame.
struct RangeTrack {
    private(set) var range: Float
    private(set) var rate: Float
    /// Time of the last accepted measurement.
    private(set) var updatedAt: Date
    private var predictedAt: Date
    private var p00: Float
    private var p01: Float
    private var p11: Float
    private var outliers = 0

    /// Human walking acceleration, m/s².
    static let accelerationSigma: Float = 1.5
    /// Nearby Interaction distance noise in line of sight, m.
    static let localSigma: Float = 0.08
    /// Peer's sample, arriving one network hop late, m.
    static let remoteSigma: Float = 0.15
    static let maxRate: Float = 3
    static let maxExtrapolation: TimeInterval = 0.35
    static let liveWindow: TimeInterval = 0.75
    static let staleWindow: TimeInterval = 5

    init(range: Float, at date: Date) {
        self.range = range
        rate = 0
        updatedAt = date
        predictedAt = date
        p00 = 0.05
        p01 = 0
        p11 = 1
    }

    // MARK: Inputs

    /// Fuse a range measurement taken at `date`. Late samples are shifted by the
    /// current rate so a 50 ms old value doesn't drag the estimate behind.
    mutating func update(_ measurement: Float, sigma: Float, at date: Date) {
        predict(to: date)
        let lag = Float(max(predictedAt.timeIntervalSince(date), 0))
        let z = measurement + rate * min(lag, 0.25)
        let innovation = z - range
        let s = p00 + sigma * sigma
        let gate = max(3 * sqrt(s), 0.35)
        if abs(innovation) > gate {
            outliers += 1
            if outliers >= 3 {
                self = RangeTrack(range: measurement, at: date)
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
