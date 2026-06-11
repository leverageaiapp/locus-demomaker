import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import OSLog

/// Wraps SCStream + AVAssetWriter to record a single SCDisplay to an .mp4 file.
/// Designed for post-processing: we record at native resolution and a fixed framerate,
/// then the renderer applies auto-zoom on top of the recorded file.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "ScreenRecorder")

    private var stream: SCStream?
    private let audioCaptureSession = AVCaptureSession()
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let videoQueue = DispatchQueue(label: "com.screenstudio.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.screenstudio.audio", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "com.screenstudio.writer", qos: .userInteractive)
    /// start/stopRunning block until in-flight delegate callbacks finish, so
    /// they must not share `audioQueue` with the delegate or they can stall.
    private let sessionControlQueue = DispatchQueue(label: "com.screenstudio.audio.control", qos: .userInitiated)

    private var sessionStarted = false
    private var firstSampleTime: CMTime?
    private(set) var outputURL: URL?
    private(set) var pixelSize: CGSize = .zero
    private(set) var displayScale: CGFloat = 1.0
    private(set) var displayOrigin: CGPoint = .zero
    private(set) var displayPointSize: CGSize = .zero
    private(set) var frameRate: Int = 60

    /// What we're recording.
    enum Target {
        case fullDisplay(SCDisplay)
        case region(SCDisplay, rectInDisplayPoints: CGRect)
        case window(SCWindow, on: SCDisplay)
    }

    private(set) var captureMode: CaptureMode = .fullDisplay
    private(set) var capturedWindowTitle: String?

    /// Begin capture against `target`, writing into `url`.
    func start(target: Target, url: URL, frameRate: Int = 60,
               quality: RecordingQuality = .high) async throws {
        self.outputURL = url
        self.frameRate = frameRate

        let filter: SCContentFilter
        let surfaceOriginGlobalPoints: CGPoint
        let surfacePointSize: CGSize
        let scale: CGFloat
        let cfg = SCStreamConfiguration()

        switch target {
        case .fullDisplay(let display):
            self.captureMode = .fullDisplay
            self.capturedWindowTitle = nil
            scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1.0
            surfacePointSize = display.frame.size
            surfaceOriginGlobalPoints = display.frame.origin
            self.pixelSize = CGSize(width: display.width, height: display.height)
            filter = SCContentFilter(display: display, excludingWindows: [])

        case .region(let display, let rectInDisplay):
            self.captureMode = .region
            self.capturedWindowTitle = nil
            scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1.0
            surfacePointSize = rectInDisplay.size
            surfaceOriginGlobalPoints = CGPoint(
                x: display.frame.origin.x + rectInDisplay.origin.x,
                y: display.frame.origin.y + rectInDisplay.origin.y
            )
            self.pixelSize = CGSize(
                width:  ceil(rectInDisplay.width  * scale),
                height: ceil(rectInDisplay.height * scale)
            )
            // sourceRect is in display-local point coordinates, top-left origin.
            cfg.sourceRect = rectInDisplay
            filter = SCContentFilter(display: display, excludingWindows: [])

        case .window(let window, let display):
            self.captureMode = .window
            self.capturedWindowTitle = window.title ?? window.owningApplication?.applicationName
            scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1.0
            surfacePointSize = window.frame.size
            surfaceOriginGlobalPoints = window.frame.origin
            self.pixelSize = CGSize(
                width:  ceil(window.frame.width  * scale),
                height: ceil(window.frame.height * scale)
            )
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        self.displayPointSize = surfacePointSize
        self.displayOrigin = surfaceOriginGlobalPoints
        self.displayScale = scale

        // Configure AVAssetWriter
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.screenBitrate(pixelSize: pixelSize, frameRate: frameRate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else {
            throw NSError(domain: "ScreenRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected video input"])
        }
        writer.add(input)
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        } else {
            logger.warning("AVAssetWriter rejected audio input; continuing without microphone audio")
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ScreenRecorder", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
        }

        self.assetWriter = writer
        self.videoInput = input
        self.audioInput = writer.inputs.contains(audioInput) ? audioInput : nil
        self.pixelBufferAdaptor = adaptor
        self.sessionStarted = false
        self.firstSampleTime = nil

        // Configure SCStream — `filter` and `cfg.sourceRect` were set per-mode above.
        cfg.width = Int(pixelSize.width)
        cfg.height = Int(pixelSize.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try configureMicrophoneCapture()
        sessionControlQueue.async { [weak self] in
            self?.audioCaptureSession.startRunning()
        }
        try await stream.startCapture()
        self.stream = stream
        logger.info("Recording started → \(url.path)")
    }

    /// Stop capture and finalize the .mp4 file. Returns the output URL.
    func stop() async throws -> URL {
        guard let stream = stream, let writer = assetWriter, let input = videoInput, let url = outputURL else {
            throw NSError(domain: "ScreenRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Recorder not running"])
        }
        let stopStart = Date()
        try? await stream.stopCapture()
        logger.info("stopCapture took \(Int(-stopStart.timeIntervalSinceNow * 1000)) ms")
        self.stream = nil
        sessionControlQueue.async { [weak self] in
            self?.audioCaptureSession.stopRunning()
        }

        let finishStart = Date()
        let result: URL = await withCheckedContinuation { (cont: CheckedContinuation<URL, Never>) in
            writerQueue.async {
                // finishWriting only invokes its handler from the .writing
                // state — resuming directly otherwise keeps stop() from
                // hanging forever after a mid-recording writer failure.
                guard writer.status == .writing else {
                    self.logger.error("Writer not in .writing state at stop (status \(writer.status.rawValue)): \(writer.error?.localizedDescription ?? "no error")")
                    cont.resume(returning: url)
                    return
                }
                input.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    cont.resume(returning: url)
                }
            }
        }
        logger.info("finishWriting took \(Int(-finishStart.timeIntervalSinceNow * 1000)) ms")
        return result
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusValue = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete else {
            return
        }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let pts = sampleBuffer.presentationTimeStamp

        writerQueue.async { [weak self] in
            guard let self = self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor else { return }
            if !self.sessionStarted {
                writer.startSession(atSourceTime: pts)
                self.firstSampleTime = pts
                self.sessionStarted = true
            }
            if input.isReadyForMoreMediaData {
                if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                    self.logger.error("Pixel buffer append failed: \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    // MARK: - Microphone

    private func configureMicrophoneCapture() throws {
        audioCaptureSession.beginConfiguration()
        defer { audioCaptureSession.commitConfiguration() }

        audioCaptureSession.inputs.forEach { audioCaptureSession.removeInput($0) }
        audioCaptureSession.outputs.forEach { audioCaptureSession.removeOutput($0) }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            logger.warning("No microphone available; continuing without audio")
            return
        }
        let micInput = try AVCaptureDeviceInput(device: device)
        guard audioCaptureSession.canAddInput(micInput) else {
            logger.warning("Microphone input unavailable; continuing without audio")
            return
        }
        audioCaptureSession.addInput(micInput)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard audioCaptureSession.canAddOutput(output) else {
            logger.warning("Microphone output unavailable; continuing without audio")
            return
        }
        audioCaptureSession.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        let pts = sampleBuffer.presentationTimeStamp

        writerQueue.async { [weak self] in
            guard let self,
                  self.sessionStarted,
                  let firstSampleTime = self.firstSampleTime,
                  pts >= firstSampleTime,
                  let input = self.audioInput,
                  input.isReadyForMoreMediaData else { return }

            if !input.append(sampleBuffer) {
                self.logger.error("Audio sample append failed: \(self.assetWriter?.error?.localizedDescription ?? "unknown")")
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
    }
}
