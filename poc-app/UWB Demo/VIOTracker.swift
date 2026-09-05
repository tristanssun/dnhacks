import ARKit
import QuartzCore
import simd

final class VIOTracker: NSObject, ARSessionDelegate {
    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float
        var transform: simd_float4x4
        /// ARKit capture time (system uptime clock). Use this for motion-model
        /// dt, not wall-clock at delivery, so scheduling delay isn't read as motion time.
        var timestamp: TimeInterval
        /// False while ARKit is initializing, relocalizing, or has no tracking.
        var isReliable: Bool
        /// True only for `.normal`. Camera assistance requires it, while the
        /// filter is content with `.limited` for reasons other than
        /// initializing or relocalizing — so `isReliable` being true says
        /// nothing about whether `horizontalAngle` can ever appear.
        var isNormal: Bool
        /// Short tracking-state label for display.
        var trackingLabel: String
        /// True on the first reliable frame after tracking was lost. The world
        /// origin may have changed, so the delta from the previous pose is not motion.
        var didResume: Bool
    }

    /// Forward every Nth frame to the main actor. 60 Hz camera → ~20 Hz poses,
    /// which is plenty for dead-reckoning between 5–10 Hz UWB samples.
    private static let frameStride = 3

    let session = ARSession()
    private(set) var pose: Pose?
    var onPose: ((Pose) -> Void)?
    private var lastYaw: Float = 0
    private var wasReliable = false
    private var hasEverTracked = false
    // Touched only on ARKit's delivery queue, which is serial.
    private nonisolated(unsafe) var frameCounter = 0
    private nonisolated(unsafe) var lastForwardedReliable: Bool?

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        session.delegate = self
        session.run(Self.configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        pose = nil
        wasReliable = false
        lastForwardedReliable = nil
    }

    private static var configuration: ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.isLightEstimationEnabled = false
        return config
    }

    /// Heading as the horizontal blend of camera forward (-Z) and device up (+Y).
    /// Upright phone: camera forward dominates. Flat phone: the Dynamic Island
    /// direction dominates. Both agree for a phone tilted toward the user.
    private static func yaw(from transform: simd_float4x4) -> Float? {
        let c = transform.columns
        let camForward = SIMD2<Float>(-c.2.x, -c.2.z)
        let deviceUp = SIMD2<Float>(c.1.x, c.1.z)
        let forward = camForward + deviceUp
        guard simd_length(forward) > 0.05 else { return nil }
        return atan2(forward.x, forward.y)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Counted before any thinning: this is ARKit's true delivery rate, and
        // a fall means ARKit is throttling us for holding on to frames.
        perfCounters.recordARFrame()
        let transform = frame.camera.transform
        let reliable: Bool
        let normal: Bool
        let label: String
        switch frame.camera.trackingState {
        case .normal:
            reliable = true
            normal = true
            label = "normal"
        case .limited(let reason):
            normal = false
            switch reason {
            case .initializing:
                reliable = false
                label = "init"
            case .relocalizing:
                reliable = false
                label = "reloc"
            case .excessiveMotion:
                reliable = true
                label = "motion"
            case .insufficientFeatures:
                reliable = true
                label = "features"
            @unknown default:
                reliable = true
                label = "limited"
            }
        case .notAvailable:
            reliable = false
            normal = false
            label = "none"
        }
        // Thin the stream before paying the actor hop, but never drop a frame
        // where reliability flipped: `didResume` depends on seeing the transition.
        frameCounter += 1
        let transition = lastForwardedReliable != reliable
        guard transition || frameCounter % Self.frameStride == 0 else { return }
        lastForwardedReliable = reliable
        let timestamp = frame.timestamp
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let hopStart = CACurrentMediaTime()
        Task { @MainActor in
            // Time from handing the pose off to the main actor actually running
            // it. Rises without bound once arrivals outpace the main thread.
            perfCounters.recordHop(CACurrentMediaTime() - hopStart)
            let yaw = Self.yaw(from: transform) ?? self.lastYaw
            self.lastYaw = yaw
            let resumed = reliable && !self.wasReliable && self.hasEverTracked
            if reliable {
                self.hasEverTracked = true
            }
            self.wasReliable = reliable
            let next = Pose(
                position: position,
                yaw: yaw,
                transform: transform,
                timestamp: timestamp,
                isReliable: reliable,
                isNormal: normal,
                trackingLabel: label,
                didResume: resumed
            )
            self.pose = next
            self.onPose?(next)
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // Relocalization can hang in .limited(.relocalizing) forever. Prefer a
        // clean reset; the engine treats the next reliable frame as a re-origin.
        false
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.wasReliable = false
            self.session.run(Self.configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }
}
