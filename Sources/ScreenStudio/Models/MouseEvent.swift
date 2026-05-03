import Foundation
import CoreGraphics

/// A single mouse event captured during recording.
/// Timestamps are seconds relative to the start of the recording.
struct MouseEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case move
        case leftDown
        case leftUp
        case rightDown
        case rightUp
        case scroll
        case dragged
    }

    let time: Double
    let kind: Kind
    /// Position in screen pixel coordinates (origin top-left), already multiplied by display scale.
    let x: Double
    let y: Double
    /// Scroll delta (only meaningful for `.scroll`).
    let scrollDX: Double
    let scrollDY: Double

    init(time: Double, kind: Kind, x: Double, y: Double, scrollDX: Double = 0, scrollDY: Double = 0) {
        self.time = time
        self.kind = kind
        self.x = x
        self.y = y
        self.scrollDX = scrollDX
        self.scrollDY = scrollDY
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
    var isClick: Bool { kind == .leftDown || kind == .rightDown }
}
