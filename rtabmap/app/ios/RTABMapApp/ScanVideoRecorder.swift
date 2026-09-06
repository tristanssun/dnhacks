import Foundation
import AVFoundation
import ARKit
import UIKit

// Records the camera feed of a scan to an .mp4 while ARKit owns the camera.
// A second AVCaptureSession is not possible next to an ARSession, so frames
// come from ARFrame.capturedImage (the sensor's 420f pixel buffer) and are
// handed to an AVAssetWriter. Frames are appended synchronously on the
// ARSession delegate queue (VideoToolbox retains the buffer), capped at
// `maxFPS`, HEVC when the device can encode it, H.264 otherwise.
final class ScanVideoRecorder {
    static let tempFileName = "rtabmap.scan.mp4"

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var lastAppended: TimeInterval = -1
    private var orientation: UIInterfaceOrientation = .portrait
    private(set) var outputURL: URL?
    private(set) var frameCount = 0
    private(set) var startedAt: Date?
    private(set) var isRecording = false

    var maxFPS: Double = 15
    var bitRate: Int = 5_000_000

    // Begin a recording; the writer itself is configured on the first frame,
    // when the pixel buffer size is known.
    func start(url: URL, orientation: UIInterfaceOrientation) {
        stopImmediately()
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        self.orientation = orientation
        frameCount = 0
        lastAppended = -1
        sessionStarted = false
        startedAt = Date()
        isRecording = true
        NSLog("ScanVideo: start %@ (orientation=%d)", url.lastPathComponent, orientation.rawValue)
    }

    func append(frame: ARFrame) {
        guard isRecording, let url = outputURL else { return }
        let t = frame.timestamp
        if lastAppended >= 0 && t - lastAppended < (1.0 / maxFPS) - 0.002 {
            return
        }
        let buffer = frame.capturedImage
        if writer == nil {
            if !setupWriter(url: url, buffer: buffer) {
                isRecording = false
                return
            }
        }
        guard let writer = writer, let input = input, let adaptor = adaptor else { return }
        let pts = CMTime(seconds: t, preferredTimescale: 600)
        if !sessionStarted {
            guard writer.startWriting() else {
                NSLog("ScanVideo: startWriting failed: %@", writer.error?.localizedDescription ?? "?")
                isRecording = false
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: pts) {
            frameCount += 1
            lastAppended = t
        } else if writer.status == .failed {
            NSLog("ScanVideo: append failed: %@", writer.error?.localizedDescription ?? "?")
            isRecording = false
        }
    }

    // Finish the file. `completion` runs on the main queue with the URL, the
    // duration in seconds and the file size, or nil when nothing was written.
    func stop(completion: @escaping (URL?, Double, Int64) -> Void) {
        guard isRecording || writer != nil else {
            DispatchQueue.main.async { completion(nil, 0, 0) }
            return
        }
        isRecording = false
        let url = outputURL
        let frames = frameCount
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let writer = writer, let input = input, sessionStarted, writer.status == .writing else {
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            if let url = url { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { completion(nil, 0, 0) }
            return
        }
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            let ok = writer.status == .completed
            if !ok {
                NSLog("ScanVideo: finishWriting status=%d error=%@", writer.status.rawValue, writer.error?.localizedDescription ?? "?")
            }
            var size: Int64 = 0
            if ok, let url = url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
            NSLog("ScanVideo: stop frames=%d duration=%.1fs bytes=%lld ok=%d", frames, duration, size, ok ? 1 : 0)
            DispatchQueue.main.async {
                self?.writer = nil
                self?.input = nil
                self?.adaptor = nil
                completion(ok ? url : nil, duration, size)
            }
        }
    }

    private func stopImmediately() {
        if let writer = writer, writer.status == .writing {
            writer.cancelWriting()
        }
        writer = nil
        input = nil
        adaptor = nil
        isRecording = false
        sessionStarted = false
    }

    private func setupWriter(url: URL, buffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return false }
        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            NSLog("ScanVideo: cannot create writer: %@", error.localizedDescription)
            return false
        }
        var codec = AVVideoCodecType.hevc
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(maxFPS),
                AVVideoMaxKeyFrameIntervalKey: Int(maxFPS) * 2
            ]
        ]
        if !newWriter.canApply(outputSettings: settings, forMediaType: .video) {
            codec = .h264
            settings[AVVideoCodecKey] = codec
            if !newWriter.canApply(outputSettings: settings, forMediaType: .video) {
                NSLog("ScanVideo: no usable video encoder settings")
                return false
            }
        }
        let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        newInput.expectsMediaDataInRealTime = true
        // capturedImage is sensor-landscape; tag the track so players show it
        // the way the phone was held.
        switch orientation {
        case .portrait:
            newInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown:
            newInput.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft:
            newInput.transform = CGAffineTransform(rotationAngle: .pi)
        default:
            newInput.transform = .identity
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(buffer),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: newInput, sourcePixelBufferAttributes: attrs)
        guard newWriter.canAdd(newInput) else {
            NSLog("ScanVideo: cannot add input")
            return false
        }
        newWriter.add(newInput)
        writer = newWriter
        input = newInput
        adaptor = newAdaptor
        NSLog("ScanVideo: writer %dx%d codec=%@ fps<=%.0f bitrate=%d", width, height, codec.rawValue, maxFPS, bitRate)
        return true
    }
}
