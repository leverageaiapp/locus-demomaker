import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import OSLog

/// Wraps SCStream + AVAssetWriter to record a single SCDisplay to an .mp4 file.
/// Designed for post-processing: we record at native resolution and a fixed framerate,
/// then the renderer applies auto-zoom on top of the recorded file.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "ScreenRecorder")

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let videoQueue = DispatchQueue(label: "com.screenstudio.video", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "com.screenstudio.writer", qos: .userInteractive)

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
    func start(target: Target, url: URL, frameRate: Int = 60) async throws {
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
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
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
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ScreenRecorder", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
        }

        self.assetWriter = writer
        self.videoInput = input
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
        try? await stream.stopCapture()
        self.stream = nil

        return await withCheckedContinuation { (cont: CheckedContinuation<URL, Never>) in
            writerQueue.async {
                input.markAsFinished()
                writer.finishWriting {
                    cont.resume(returning: url)
                }
            }
        }
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

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
    }
}
