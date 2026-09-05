import ARKit
import simd

final class VIOTracker: NSObject, ARSessionDelegate {
    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float
        var transform: simd_float4x4
    }

    let session = ARSession()
    private(set) var pose: Pose?
    var onPose: ((Pose) -> Void)?

    var isRunning: Bool { pose != nil }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        session.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        pose = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = SIMD3<Float>(-transform.columns.2.x, 0, -transform.columns.2.z)
        let yaw = atan2(forward.x, forward.z)
        let next = Pose(position: position, yaw: yaw, transform: transform)
        Task { @MainActor in
            self.pose = next
            self.onPose?(next)
        }
    }
}
