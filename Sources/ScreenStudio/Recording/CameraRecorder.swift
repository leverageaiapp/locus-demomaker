import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import OSLog

/// Records the built-in front camera to a sidecar movie so the exporter can
/// composite it after screen zooming. Keeping it separate prevents the camera
/// bubble from being zoomed or cropped with the screen track.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "CameraRecorder")

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.screenstudio.camera.capture", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "com.screenstudio.camera.writer", qos: .userInteractive)
    /// start/stopRunning block until in-flight delegate callbacks finish, so
    /// they must not share `captureQueue` with the delegate or stop stalls.
    private let sessionControlQueue = DispatchQueue(label: "com.screenstudio.camera.control", qos: .userInitiated)

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    private(set) var outputURL: URL?

    func start(url: URL, quality: RecordingQuality = .high) async throws {
        self.outputURL = url
        self.sessionStarted = false

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.cameraBitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "CameraRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected camera input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "CameraRecorder", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to start camera writer"])
        }
        self.assetWriter = writer
        self.videoInput = input

        try configureSession()
        await withCheckedContinuation { cont in
            sessionControlQueue.async { [weak self] in
                self?.session.startRunning()
                cont.resume()
            }
        }
        logger.info("Camera recording started -> \(url.path)")
    }

    func stop() async -> URL? {
        let writer = assetWriter
        let input = videoInput
        let url = outputURL

        await withCheckedContinuation { cont in
            sessionControlQueue.async { [weak self] in
                self?.session.stopRunning()
                cont.resume()
            }
        }

        return await withCheckedContinuation { cont in
            writerQueue.async { [weak self] in
                // finishWriting only invokes its handler from the .writing
                // state; resuming directly otherwise avoids hanging the
                // continuation when stop() races a failed or unstarted writer.
                guard let writer, writer.status == .writing else {
                    self?.assetWriter = nil
                    self?.videoInput = nil
                    cont.resume(returning: nil)
                    return
                }
                input?.markAsFinished()
                writer.finishWriting {
                    self?.assetWriter = nil
                    self?.videoInput = nil
                    cont.resume(returning: url)
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "CameraRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else {
            throw NSError(domain: "CameraRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"])
        }
        session.addInput(deviceInput)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "CameraRecorder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Camera output unavailable"])
        }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        let pts = sampleBuffer.presentationTimeStamp

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  input.isReadyForMoreMediaData else { return }

            if !self.sessionStarted {
                writer.startSession(atSourceTime: pts)
                self.sessionStarted = true
            }

            if !input.append(sampleBuffer) {
                self.logger.error("Camera sample append failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
    }
}
