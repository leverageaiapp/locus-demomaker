import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Vision

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
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let cameraOverlayPosition: CameraOverlayPosition
    let cameraOverlaySizeRatio: CGFloat
    let cameraOverlayCenter: CGPoint?
    /// When set, the presenter is segmented out of the camera frame and this
    /// solid color is painted behind them.
    let cameraBackdrop: BackdropColor?

    init(timeRange: CMTimeRange, sourceTrackIDs: [CMPersistentTrackID],
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID?,
         keyframes: [ZoomKeyframe], videoSize: CGSize, frameRate: Int,
         cameraOverlayPosition: CameraOverlayPosition = .bottomRight,
         cameraOverlaySizeRatio: CGFloat = 0.18,
         cameraOverlayCenter: CGPoint? = nil,
         cameraBackdrop: BackdropColor? = nil) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: Int($0)) }
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.keyframes = keyframes
        self.videoSize = videoSize
        self.frameRate = frameRate
        self.cameraOverlayPosition = cameraOverlayPosition
        self.cameraOverlaySizeRatio = cameraOverlaySizeRatio
        self.cameraOverlayCenter = cameraOverlayCenter
        self.cameraBackdrop = cameraBackdrop
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
        guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) else {
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

        if let cameraTrackID = instruction.cameraTrackID,
           let cameraBuffer = request.sourceFrame(byTrackID: cameraTrackID) {
            ci = composeCameraBubble(
                cameraBuffer: cameraBuffer,
                onto: ci,
                videoSize: videoSize,
                position: instruction.cameraOverlayPosition,
                sizeRatio: instruction.cameraOverlaySizeRatio,
                normalizedCenter: instruction.cameraOverlayCenter,
                backdrop: instruction.cameraBackdrop
            )
            ci = ci.cropped(to: outputRect)
        }

        ciContext.render(ci, to: outputBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return outputBuffer
    }

    /// Reused across frames — Vision request allocation is not free.
    private lazy var segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// Person-probability mask for a camera frame (white = person), or nil
    /// when segmentation fails — callers fall back to the real background.
    private func personMask(for buffer: CVPixelBuffer) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([segmentationRequest])) != nil,
              let mask = segmentationRequest.results?.first?.pixelBuffer else {
            return nil
        }
        return CIImage(cvPixelBuffer: mask)
    }

    private func composeCameraBubble(cameraBuffer: CVPixelBuffer,
                                     onto background: CIImage,
                                     videoSize: CGSize,
                                     position: CameraOverlayPosition,
                                     sizeRatio: CGFloat,
                                     normalizedCenter: CGPoint?,
                                     backdrop: BackdropColor?) -> CIImage {
        let diameter = max(96, min(videoSize.width * sizeRatio, videoSize.height * 0.32))
        let margin = max(24, diameter * 0.16)
        let rect: CGRect

        if let normalizedCenter {
            let centerX = min(1, max(0, normalizedCenter.x)) * videoSize.width
            let centerYFromTop = min(1, max(0, normalizedCenter.y)) * videoSize.height
            rect = CGRect(
                x: min(videoSize.width - diameter - margin,
                       max(margin, centerX - diameter / 2)),
                y: min(videoSize.height - diameter - margin,
                       max(margin, videoSize.height - centerYFromTop - diameter / 2)),
                width: diameter,
                height: diameter
            )
        } else {
            switch position {
            case .bottomRight:
                rect = CGRect(x: videoSize.width - diameter - margin,
                              y: margin,
                              width: diameter, height: diameter)
            case .bottomLeft:
                rect = CGRect(x: margin, y: margin, width: diameter, height: diameter)
            case .topRight:
                rect = CGRect(x: videoSize.width - diameter - margin,
                              y: videoSize.height - diameter - margin,
                              width: diameter, height: diameter)
            case .topLeft:
                rect = CGRect(x: margin,
                              y: videoSize.height - diameter - margin,
                              width: diameter, height: diameter)
            }
        }

        var camera = CIImage(cvPixelBuffer: cameraBuffer)
        let extent = camera.extent
        camera = camera.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        // Replace the real background with a solid backdrop, if requested.
        // Mask coordinates match the unmirrored buffer, so blend before the
        // mirror transform below.
        if let backdrop, let mask = personMask(for: cameraBuffer) {
            let frameRect = CGRect(origin: .zero, size: extent.size)
            let scaled = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / max(1, mask.extent.width),
                y: extent.height / max(1, mask.extent.height)
            ))
            // A ~1.5 px feather hides the segmentation's stair-step edge.
            let feathered = scaled
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
                .cropped(to: frameRect)
            let solid = CIImage(color: backdrop.ciColor).cropped(to: frameRect)
            camera = camera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: solid,
                kCIInputMaskImageKey: feathered
            ])
        }

        // Mirror the presenter bubble so it behaves like a front-camera preview.
        camera = camera.transformed(by:
            CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -extent.width, y: 0)
        )

        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let centeredOrigin = CGPoint(
            x: rect.midX - scaledSize.width / 2,
            y: rect.midY - scaledSize.height / 2
        )
        camera = camera
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: centeredOrigin.x, y: centeredOrigin.y))
            .cropped(to: rect)

        let shadowRect = rect.insetBy(dx: -diameter * 0.08, dy: -diameter * 0.08)
        let shadow = circleImage(in: shadowRect, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.24))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: diameter * 0.045])
            .cropped(to: shadowRect)

        let border = circleImage(in: rect.insetBy(dx: -3, dy: -3), color: CIColor.white)
        let mask = circleMask(in: rect)
        let maskedCamera = camera.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: mask
        ])

        return maskedCamera
            .composited(over: border)
            .composited(over: shadow)
            .composited(over: background)
    }

    private func circleImage(in rect: CGRect, color: CIColor) -> CIImage {
        let fill = CIImage(color: color).cropped(to: rect)
        return fill.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: circleMask(in: rect)
        ])
    }

    private func circleMask(in rect: CGRect) -> CIImage {
        let radius = rect.width / 2
        let center = CIVector(x: rect.midX, y: rect.midY)
        let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": radius - 1,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear
        ])
        return (filter?.outputImage ?? CIImage(color: .clear)).cropped(to: rect)
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
