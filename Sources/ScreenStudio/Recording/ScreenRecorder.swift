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

    /// Begin capture of `display`, writing into `url`. Returns a `RecordingMetadata`-friendly
    /// snapshot of display geometry.
    func start(display: SCDisplay, url: URL, frameRate: Int = 60) async throws {
        self.outputURL = url
        self.frameRate = frameRate
        self.pixelSize = CGSize(width: display.width, height: display.height)
        self.displayPointSize = CGSize(width: display.frame.width, height: display.frame.height)
        self.displayOrigin = display.frame.origin
        self.displayScale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1.0

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

        // Configure SCStream
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
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
