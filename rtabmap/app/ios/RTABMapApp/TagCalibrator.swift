//
//  TagCalibrator.swift
//  RTABMapApp
//
//  Detect the shared start tag (ArUco 4x4_50 id 0) from the AR camera.
//  Does not touch live odometry / Rtabmap::process.
//

import ARKit
import CoreVideo
import Foundation
import simd
import UIKit

enum DemoTag {
    static let id = 0
    static let sizeMeters: Float = 0.20
    static let family = "4x4_50"
}

struct TagPose {
    var tagId: Int
    var tx: Float
    var ty: Float
    var tz: Float
    var qx: Float
    var qy: Float
    var qz: Float
    var qw: Float
    var detected: Bool

    func jsonBody() -> [String: Any] {
        return [
            "tag_id": tagId,
            "detected": detected,
            "tx": tx,
            "ty": ty,
            "tz": tz,
            "qx": qx,
            "qy": qy,
            "qz": qz,
            "qw": qw
        ]
    }
}

class TagCalibrator {
    private var lastArucoAt = Date.distantPast

    func detect(from frame: ARFrame) -> TagPose? {
        let now = Date()
        if now.timeIntervalSince(lastArucoAt) < 0.25 {
            return nil
        }
        lastArucoAt = now
        var arucoFound = 0
        var arucoTag = -1
        var arucoSeen = -1
        var arucoError = 0
        if let pose = detectAruco(frame: frame, found: &arucoFound, tagId: &arucoTag, seenId: &arucoSeen, error: &arucoError) {
            NSLog("TagCalibrator: detect found=%d tag_id=%d seen_id=%d error=%d", arucoFound, arucoTag, arucoSeen, arucoError)
            return pose
        }
        return nil
    }

    private func detectAruco(
        frame: ARFrame,
        found: inout Int,
        tagId: inout Int,
        seenId: inout Int,
        error: inout Int
    ) -> TagPose? {
        let buffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            found = 0
            tagId = -1
            seenId = -1
            error = 1
            return nil
        }
        let width = Int32(CVPixelBufferGetWidthOfPlane(buffer, 0))
        let height = Int32(CVPixelBufferGetHeightOfPlane(buffer, 0))
        let stride = Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        let k = frame.camera.intrinsics
        let fx = k.columns.0.x * Float(width) / Float(CVPixelBufferGetWidth(buffer))
        let fy = k.columns.1.y * Float(height) / Float(CVPixelBufferGetHeight(buffer))
        let cx = k.columns.2.x * Float(width) / Float(CVPixelBufferGetWidth(buffer))
        let cy = k.columns.2.y * Float(height) / Float(CVPixelBufferGetHeight(buffer))
        let cam = detectStartTagNative(
            yBase,
            width,
            height,
            stride,
            fx,
            fy,
            cx,
            cy,
            DemoTag.sizeMeters)
        found = Int(cam.found)
        tagId = Int(cam.tag_id)
        seenId = Int(cam.seen_id)
        error = Int(cam.error)
        if cam.found == 0 || cam.tag_id != Int32(DemoTag.id) {
            return nil
        }
        return composeOdomFromTag(
            frame: frame,
            camTx: cam.tx, camTy: cam.ty, camTz: cam.tz,
            camQx: cam.qx, camQy: cam.qy, camQz: cam.qz, camQw: cam.qw)
    }

    // rtabmap's MarkerDetector returns the tag in the camera *base_link* frame
    // (x forward, y left, z up). ARKit's camera frame is x right, y up, z back.
    // This fixed rotation maps base_link axes into ARKit camera axes; without
    // it the tag pose is wrong by an amount that depends on how the phone was
    // held, so two phones never agree on the shared frame.
    private static let T_arkitCam_from_base: simd_float4x4 = simd_float4x4(columns: (
        simd_float4(0, 0, -1, 0),
        simd_float4(-1, 0, 0, 0),
        simd_float4(0, 1, 0, 0),
        simd_float4(0, 0, 0, 1)))

    private func composeOdomFromTag(
        frame: ARFrame,
        camTx: Float, camTy: Float, camTz: Float,
        camQx: Float, camQy: Float, camQz: Float, camQw: Float
    ) -> TagPose {
        let T_world_from_cam = frame.camera.transform
        let T_base_from_tag = matrix(tx: camTx, ty: camTy, tz: camTz, qx: camQx, qy: camQy, qz: camQz, qw: camQw)
        let T_world_from_tag = T_world_from_cam * TagCalibrator.T_arkitCam_from_base * T_base_from_tag
        let t = T_world_from_tag.columns.3
        let q = quat(from: T_world_from_tag)
        return TagPose(tagId: DemoTag.id, tx: t.x, ty: t.y, tz: t.z, qx: q.0, qy: q.1, qz: q.2, qw: q.3, detected: true)
    }

    private func matrix(tx: Float, ty: Float, tz: Float, qx: Float, qy: Float, qz: Float, qw: Float) -> simd_float4x4 {
        let n = max(1e-6, sqrt(qx * qx + qy * qy + qz * qz + qw * qw))
        let x = qx / n
        let y = qy / n
        let z = qz / n
        let w = qw / n
        let xx = x * x
        let yy = y * y
        let zz = z * z
        let xy = x * y
        let xz = x * z
        let yz = y * z
        let wx = w * x
        let wy = w * y
        let wz = w * z
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0)
        m.columns.1 = simd_float4(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0)
        m.columns.2 = simd_float4(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0)
        m.columns.3 = simd_float4(tx, ty, tz, 1)
        return m
    }

    // Full rotation-matrix to quaternion conversion (all four branches). The
    // previous version returned identity whenever trace <= 0, which silently
    // dropped any tag orientation more than ~90 degrees from the world axes.
    private func quat(from m: simd_float4x4) -> (Float, Float, Float, Float) {
        // m[col][row]: r(i,j) = m.columns.j[i]
        let r00 = m.columns.0.x, r01 = m.columns.1.x, r02 = m.columns.2.x
        let r10 = m.columns.0.y, r11 = m.columns.1.y, r12 = m.columns.2.y
        let r20 = m.columns.0.z, r21 = m.columns.1.z, r22 = m.columns.2.z
        let trace = r00 + r11 + r22
        var x: Float, y: Float, z: Float, w: Float
        if trace > 0 {
            let s = sqrt(trace + 1.0) * 2
            w = 0.25 * s
            x = (r21 - r12) / s
            y = (r02 - r20) / s
            z = (r10 - r01) / s
        } else if r00 > r11 && r00 > r22 {
            let s = sqrt(1.0 + r00 - r11 - r22) * 2
            w = (r21 - r12) / s
            x = 0.25 * s
            y = (r01 + r10) / s
            z = (r02 + r20) / s
        } else if r11 > r22 {
            let s = sqrt(1.0 + r11 - r00 - r22) * 2
            w = (r02 - r20) / s
            x = (r01 + r10) / s
            y = 0.25 * s
            z = (r12 + r21) / s
        } else {
            let s = sqrt(1.0 + r22 - r00 - r11) * 2
            w = (r10 - r01) / s
            x = (r02 + r20) / s
            y = (r12 + r21) / s
            z = 0.25 * s
        }
        let n = sqrt(x * x + y * y + z * z + w * w)
        if n < 1e-6 || !n.isFinite {
            return (0, 0, 0, 1)
        }
        return (x / n, y / n, z / n, w / n)
    }
}
