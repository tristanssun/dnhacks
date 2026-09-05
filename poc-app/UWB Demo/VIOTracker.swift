import ARKit
import simd

final class VIOTracker: NSObject, ARSessionDelegate {
    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float
        var transform: simd_float4x4
        /// False while ARKit is initializing, relocalizing, or has no tracking.
        var isReliable: Bool
        /// True on the first reliable frame after tracking was lost. The world
        /// origin may have changed, so the delta from the previous pose is not motion.
        var didResume: Bool
    }

    let session = ARSession()
    private(set) var pose: Pose?
    var onPose: ((Pose) -> Void)?
    private var lastYaw: Float = 0
    private var wasReliable = false
    private var hasEverTracked = false

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        session.delegate = self
        session.run(Self.configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        pose = nil
        wasReliable = false
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
        let transform = frame.camera.transform
        let reliable: Bool
        switch frame.camera.trackingState {
        case .normal:
            reliable = true
        case .limited(let reason):
            switch reason {
            case .initializing, .relocalizing:
                reliable = false
            default:
                reliable = true
            }
        case .notAvailable:
            reliable = false
        }
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        Task { @MainActor in
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
                isReliable: reliable,
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
