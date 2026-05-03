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

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// Effective mode — falls back to fullDisplay for legacy records.
    var effectiveMode: CaptureMode { captureMode ?? .fullDisplay }
}
