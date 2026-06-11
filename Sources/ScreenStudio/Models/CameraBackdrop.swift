import Foundation
import CoreImage

/// A solid color painted behind the presenter in the camera bubble, applied
/// at export time via Vision person segmentation. Parsed from a "#RRGGBB"
/// hex string; an empty string means "keep the real background".
struct BackdropColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        red   = Double((value >> 16) & 0xFF) / 255.0
        green = Double((value >> 8) & 0xFF) / 255.0
        blue  = Double(value & 0xFF) / 255.0
    }

    var ciColor: CIColor {
        CIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    /// Curated presets shown as one-click swatches in the picker.
    static let presets: [(name: String, hex: String)] = [
        ("Studio Gray", "#2C2C2E"),
        ("White", "#F2F2F4"),
        ("Indigo", "#4B4ACF"),
        ("Forest", "#1E5E3F"),
        ("Sand", "#D9C7A7"),
    ]
}
