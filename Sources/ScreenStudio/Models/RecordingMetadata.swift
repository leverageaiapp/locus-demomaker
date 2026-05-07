import Foundation
import CoreGraphics

/// Persistent metadata describing a single recording session, written next to the raw video file.
///
/// All "display..." fields actually describe the **captured surface**, which may be the
/// whole display, a sub-region of it, or a single window's frame. Mouse events are stored
/// in pixel coordinates relative to that surface.
struct RecordingMetadata: Codable, Sendable {
    let id: UUID
    let createdAt: Date

    /// Output video pixel size — always equal to the captured surface in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Point→pixel scale (Retina = 2.0).
    let displayScale: CGFloat

    /// Captured surface origin in global screen-point coordinates.
    /// (Used to convert global mouse positions back to surface pixels.)
    let displayOriginX: CGFloat
    let displayOriginY: CGFloat
    /// Captured surface size in points.
    let displayPointWidth: CGFloat
    let displayPointHeight: CGFloat

    let frameRate: Int
    let mouseEvents: [MouseEvent]

    // MARK: New in v0.2 (optional for forward compatibility)

    /// What the user picked. `nil` for recordings made before v0.2 — assume `.fullDisplay`.
    let captureMode: CaptureMode?
    /// For `.window` mode: a label so the recording is recognizable in the list.
    let capturedWindowTitle: String?

    // MARK: New in v0.3

    /// Sidecar camera recording, if present. The exporter composites this after
    /// applying screen zoom so the circular camera bubble stays fixed.
    let cameraVideoFileName: String?
    let cameraOverlayPosition: CameraOverlayPosition?
    let cameraOverlaySizeRatio: CGFloat?
    /// Normalized center in final output coordinates: x is left→right, y is top→bottom.
    let cameraOverlayCenterX: CGFloat?
    let cameraOverlayCenterY: CGFloat?

    // MARK: New in v0.4

    /// Recording quality used for the raw screen/camera files. Optional so old
    /// recordings decode without migration.
    let recordingQuality: RecordingQuality?

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// Effective mode — falls back to fullDisplay for legacy records.
    var effectiveMode: CaptureMode { captureMode ?? .fullDisplay }

    var hasCameraOverlay: Bool {
        cameraVideoFileName?.isEmpty == false
    }
}

enum CameraOverlayPosition: String, Codable, Sendable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}

enum ExportVisualMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fullFrame
    case autoZoom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoZoom: return "Auto Zoom"
        case .fullFrame: return "Full Frame"
        }
    }

    var systemImage: String {
        switch self {
        case .autoZoom: return "scope"
        case .fullFrame: return "rectangle"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case high
    case ultra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }

    var screenBitratePer1080p60: Int {
        switch self {
        case .standard: return 12_000_000
        case .high: return 24_000_000
        case .ultra: return 45_000_000
        }
    }

    var cameraBitrate: Int {
        switch self {
        case .standard: return 2_500_000
        case .high: return 5_000_000
        case .ultra: return 8_000_000
        }
    }

    func screenBitrate(pixelSize: CGSize, frameRate: Int) -> Int {
        let referencePixels = 1920.0 * 1080.0
        let pixels = max(1.0, Double(pixelSize.width * pixelSize.height))
        let frameRateScale = Double(max(frameRate, 1)) / 60.0
        let scaled = Double(screenBitratePer1080p60) * pixels / referencePixels * frameRateScale
        return max(screenBitratePer1080p60, Int(scaled.rounded()))
    }
}
