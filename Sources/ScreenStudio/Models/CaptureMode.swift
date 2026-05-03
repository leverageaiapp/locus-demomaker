import Foundation
import CoreGraphics

/// What the user wants to record.
enum CaptureMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Whole display.
    case fullDisplay
    /// A specific window — follows it if the user moves it.
    case window
    /// A fixed rectangle on a display, picked visually.
    case region

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullDisplay: return "Screen"
        case .window:      return "Window"
        case .region:      return "Region"
        }
    }

    var systemImage: String {
        switch self {
        case .fullDisplay: return "display"
        case .window:      return "macwindow"
        case .region:      return "rectangle.dashed"
        }
    }
}

/// A persisted region preference. The rectangle is in **display-local point**
/// coordinates (origin = top-left of the display).
struct CaptureRegion: Codable, Sendable, Equatable {
    var rectInPoints: CGRect

    /// A reasonable default — 1280×720 centered on the given display size.
    static func defaultCentered(displayPointSize: CGSize) -> CaptureRegion {
        let w: CGFloat = min(1280, displayPointSize.width)
        let h: CGFloat = min(720,  displayPointSize.height)
        let x = (displayPointSize.width - w) / 2
        let y = (displayPointSize.height - h) / 2
        return CaptureRegion(rectInPoints: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Clamp to the display so a previously-stored region from a different display
    /// doesn't end up off-screen.
    func clamped(to displayPointSize: CGSize) -> CaptureRegion {
        var r = rectInPoints
        r.size.width  = max(120, min(r.size.width,  displayPointSize.width))
        r.size.height = max(90,  min(r.size.height, displayPointSize.height))
        r.origin.x    = max(0,   min(r.origin.x,    displayPointSize.width  - r.size.width))
        r.origin.y    = max(0,   min(r.origin.y,    displayPointSize.height - r.size.height))
        return CaptureRegion(rectInPoints: r)
    }
}
