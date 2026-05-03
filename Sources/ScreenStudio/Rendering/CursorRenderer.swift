import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// Renders a stylized cursor and click ripples on top of a CIImage.
///
/// ScreenCaptureKit can capture the OS cursor, but it gets blurry once we zoom 1.6×.
/// We disable cursor capture in the recorder and re-render a crisp vector cursor at
/// the recorded mouse position so it stays sharp at any zoom level.
final class CursorRenderer {
    struct Click: Sendable {
        let time: Double
        let x: Double
        let y: Double
    }

    let clicks: [Click]
    /// Per-frame mouse positions (one per video frame, source pixels).
    let mousePositions: [CGPoint]
    let frameRate: Int
    let videoSize: CGSize

    /// Cached cursor rendered at scale=1.0; we transform per-frame.
    private let cursorBaseImage: CIImage?
    /// Cached ripple — single white circle, scaled per-frame.
    private let rippleBaseImage: CIImage?

    init(clicks: [Click], mousePositions: [CGPoint], frameRate: Int, videoSize: CGSize) {
        self.clicks = clicks
        self.mousePositions = mousePositions
        self.frameRate = frameRate
        self.videoSize = videoSize
        self.cursorBaseImage = Self.renderCursorImage()
        self.rippleBaseImage = Self.renderRippleImage()
    }

    /// Build mouse-position samples + click impulses from a recording.
    static func make(events: [MouseEvent], frameRate: Int, videoSize: CGSize, duration: Double) -> CursorRenderer {
        let dt = 1.0 / Double(max(frameRate, 1))
        let frameCount = max(1, Int((duration / dt).rounded()))
        var positions = [CGPoint](repeating: CGPoint(x: videoSize.width / 2, y: videoSize.height / 2),
                                  count: frameCount)
        let sorted = events.sorted { $0.time < $1.time }
        var idx = 0
        var last = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        for f in 0..<frameCount {
            let t = Double(f) * dt
            while idx < sorted.count && sorted[idx].time <= t {
                last = CGPoint(x: sorted[idx].x, y: sorted[idx].y)
                idx += 1
            }
            positions[f] = last
        }

        let clicks = sorted.compactMap { evt -> Click? in
            guard evt.kind == .leftDown || evt.kind == .rightDown else { return nil }
            return Click(time: evt.time, x: evt.x, y: evt.y)
        }

        return CursorRenderer(clicks: clicks, mousePositions: positions,
                              frameRate: frameRate, videoSize: videoSize)
    }

    /// Composite cursor + ripple onto `base`. (focusX,focusY) is the camera focus,
    /// `zoom` is the current zoom factor. Coordinates we receive are in *source* pixels.
    /// We map them into output (after-zoom) pixel space and draw cursors there for crispness.
    func compose(onto base: CIImage, time: Double, focus: CGPoint, zoom: Double) -> CIImage {
        let frameIndex = min(mousePositions.count - 1, max(0, Int((time * Double(frameRate)).rounded())))
        let mouseSrc = mousePositions[frameIndex]

        let outX = (mouseSrc.x - focus.x) * zoom + videoSize.width / 2
        let outY = (mouseSrc.y - focus.y) * zoom + videoSize.height / 2
        // CoreImage origin is bottom-left.
        let ciY = videoSize.height - outY

        var result = base

        // Click ripple — any click within the last 0.55s.
        let rippleDuration = 0.55
        if let rippleBase = rippleBaseImage {
            for click in clicks where time >= click.time && time - click.time <= rippleDuration {
                let age = time - click.time
                let progress = age / rippleDuration
                let targetRadius = (18.0 + 70.0 * progress) * zoom
                let alpha = max(0, 1.0 - progress)

                let cx = (click.x - focus.x) * zoom + videoSize.width / 2
                let cy = videoSize.height - ((click.y - focus.y) * zoom + videoSize.height / 2)

                let baseExtent = rippleBase.extent
                let scaleX = (targetRadius * 2) / baseExtent.width
                let scaleY = (targetRadius * 2) / baseExtent.height
                let scaled = rippleBase
                    .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                let alphaMatrix = CIFilter(name: "CIColorMatrix", parameters: [
                    "inputImage": scaled,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])?.outputImage ?? scaled
                let positioned = alphaMatrix.transformed(
                    by: CGAffineTransform(translationX: cx - targetRadius, y: cy - targetRadius)
                )
                result = positioned.composited(over: result)
            }
        }

        // Cursor.
        if let base = cursorBaseImage {
            let cursorScale = max(1.0, zoom * 0.9)
            let scaled = base.transformed(by: CGAffineTransform(scaleX: cursorScale, y: cursorScale))
            // Anchor the cursor "hot spot" (tip) at (outX, ciY-0).
            let height = scaled.extent.height
            let positioned = scaled.transformed(
                by: CGAffineTransform(translationX: outX, y: ciY - height)
            )
            result = positioned.composited(over: result)
        }

        return result
    }

    // MARK: - Cached image construction

    private static func renderCursorImage() -> CIImage? {
        let size = CGSize(width: 22, height: 30)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                     color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        // Bitmap origin is bottom-left, but we want the standard arrow with tip top-left.
        // Flip Y so we can describe the cursor in normal "y-down" coordinates.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 1, y: 26))
        path.addLine(to: CGPoint(x: 8, y: 20))
        path.addLine(to: CGPoint(x: 12, y: 28))
        path.addLine(to: CGPoint(x: 15, y: 26))
        path.addLine(to: CGPoint(x: 11, y: 18))
        path.addLine(to: CGPoint(x: 19, y: 17))
        path.closeSubpath()
        cg.addPath(path)
        cg.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        cg.fillPath()
        cg.addPath(path)
        cg.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        cg.setLineWidth(1.2)
        cg.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg2 = rep.cgImage else { return nil }
        return CIImage(cgImage: cg2)
    }

    private static func renderRippleImage() -> CIImage? {
        let size = CGSize(width: 200, height: 200)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        let inset: CGFloat = 8
        let rect = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        cg.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        cg.setLineWidth(8)
        cg.strokeEllipse(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg2 = rep.cgImage else { return nil }
        return CIImage(cgImage: cg2)
    }
}
