import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// Per-frame instruction the compositor consults — produced by ZoomKeyframeEngine
/// and stored on `AutoZoomCompositionInstruction`.
struct ZoomInstruction: Sendable {
    let timeRange: CMTimeRange
    let keyframes: [ZoomKeyframe]
    let videoSize: CGSize
    let frameRate: Int
}

/// AVFoundation requires composition instructions to be Objective-C `AVVideoCompositionInstructionProtocol` objects.
final class AutoZoomCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let keyframes: [ZoomKeyframe]
    let videoSize: CGSize
    let frameRate: Int

    init(timeRange: CMTimeRange, sourceTrackIDs: [CMPersistentTrackID],
         keyframes: [ZoomKeyframe], videoSize: CGSize, frameRate: Int) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: Int($0)) }
        self.keyframes = keyframes
        self.videoSize = videoSize
        self.frameRate = frameRate
        super.init()
    }
}

/// Custom AVVideoCompositing that reads each source frame, applies the zoom transform
/// from the keyframe table, and overlays the cursor + click ripples.
final class AutoZoomCompositor: NSObject, AVVideoCompositing {
    /// Set externally before passing this compositor to AVAssetExportSession.
    static var sharedCursorRenderer: CursorRenderer?

    private let renderQueue = DispatchQueue(label: "com.screenstudio.compositor.render", qos: .userInitiated)
    private let ciContext: CIContext = {
        // GPU when available.
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferOpenGLCompatibilityKey as String: true,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferOpenGLCompatibilityKey as String: true,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let request = asyncVideoCompositionRequest
        renderQueue.async { [weak self] in
            guard let self = self else {
                request.finish(with: NSError(domain: "AutoZoomCompositor", code: -1))
                return
            }
            do {
                let buffer = try self.render(request: request)
                request.finish(withComposedVideoFrame: buffer)
            } catch {
                request.finish(with: error)
            }
        }
    }

    private func render(request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? AutoZoomCompositionInstruction else {
            throw NSError(domain: "AutoZoomCompositor", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Wrong instruction type"])
        }
        guard let sourceTrackIDValue = instruction.requiredSourceTrackIDs?.first as? NSNumber,
              let sourceBuffer = request.sourceFrame(byTrackID: sourceTrackIDValue.int32Value) else {
            throw NSError(domain: "AutoZoomCompositor", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Missing source frame"])
        }
        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "AutoZoomCompositor", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate pixel buffer"])
        }

        let timeSeconds = CMTimeGetSeconds(request.compositionTime)
        let kf = lookup(time: timeSeconds, keyframes: instruction.keyframes)

        var ci = CIImage(cvPixelBuffer: sourceBuffer)
        let videoSize = instruction.videoSize

        // Zoom transform — anchor at focus point so the focus stays put while zooming.
        // CoreImage origin is bottom-left, so flip Y when computing focus.
        let focusX = kf.focusX
        let focusYFromTop = kf.focusY
        let focusYFromBottom = videoSize.height - focusYFromTop
        let zoom = max(0.001, kf.zoom)

        let translateToOrigin = CGAffineTransform(translationX: -focusX, y: -focusYFromBottom)
        let scale = CGAffineTransform(scaleX: zoom, y: zoom)
        let translateBack = CGAffineTransform(translationX: videoSize.width / 2,
                                              y: videoSize.height / 2)
        let combined = translateToOrigin.concatenating(scale).concatenating(translateBack)
        ci = ci.transformed(by: combined)

        // The render-context pixel buffer comes from a pool and contains uninitialized
        // (garbage) pixels from a previously released frame. If the transformed source
        // does not fully cover the output rect — e.g. zoom ≈ 1.0 with an off-center
        // focus, which happens whenever the cursor is not exactly at screen center —
        // the uncovered strips would expose that garbage. Composite over an explicit
        // black background that matches the output rect so every pixel is defined.
        let outputRect = CGRect(origin: .zero, size: videoSize)
        let background = CIImage(color: CIColor.black).cropped(to: outputRect)
        ci = ci.cropped(to: outputRect).composited(over: background)

        // Overlay cursor + click ripples.
        if let cursor = AutoZoomCompositor.sharedCursorRenderer {
            ci = cursor.compose(onto: ci, time: timeSeconds,
                                focus: CGPoint(x: focusX, y: focusYFromTop), zoom: zoom)
            ci = ci.cropped(to: outputRect)
        }

        ciContext.render(ci, to: outputBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return outputBuffer
    }

    /// Binary search for the keyframe whose `.time` is closest to `time`.
    private func lookup(time: Double, keyframes: [ZoomKeyframe]) -> ZoomKeyframe {
        guard !keyframes.isEmpty else {
            return ZoomKeyframe(time: time, focusX: 0, focusY: 0, zoom: 1)
        }
        if time <= keyframes.first!.time { return keyframes.first! }
        if time >= keyframes.last!.time { return keyframes.last! }
        var lo = 0
        var hi = keyframes.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid }
        }
        // Linear interpolation between lo and hi for sub-frame precision.
        let a = keyframes[lo]
        let b = keyframes[hi]
        let span = b.time - a.time
        if span <= 0 { return a }
        let t = (time - a.time) / span
        return ZoomKeyframe(
            time: time,
            focusX: a.focusX + (b.focusX - a.focusX) * t,
            focusY: a.focusY + (b.focusY - a.focusY) * t,
            zoom: a.zoom + (b.zoom - a.zoom) * t
        )
    }
}
