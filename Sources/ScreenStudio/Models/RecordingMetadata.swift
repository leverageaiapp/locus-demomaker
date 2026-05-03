import Foundation
import CoreGraphics

/// Persistent metadata describing a single recording session, written next to the raw video file.
struct RecordingMetadata: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    /// Recorded video pixel size (width, height).
    let pixelWidth: Int
    let pixelHeight: Int
    /// Display point→pixel scale factor (Retina = 2.0).
    let displayScale: CGFloat
    /// Display origin in global screen point space — used to convert global mouse coordinates
    /// into video pixel space.
    let displayOriginX: CGFloat
    let displayOriginY: CGFloat
    /// Display point size (width, height).
    let displayPointWidth: CGFloat
    let displayPointHeight: CGFloat
    let frameRate: Int
    let mouseEvents: [MouseEvent]

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}
