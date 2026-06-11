import SwiftUI

/// Swatch row for the presenter-bubble backdrop: keep the real background,
/// pick a curated preset, or choose any custom color. Persists as a hex
/// string ("" = real background) shared with the exporter via AppStorage.
struct CameraBackdropPicker: View {
    @AppStorage("cameraBackdropHex") private var backdropHex = ""
    @EnvironmentObject var loc: Localization

    var body: some View {
        HStack(spacing: 10) {
            Label(loc.t("Backdrop"), systemImage: "person.and.background.dotted")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Real background.
            swatchButton(hex: "", help: loc.t("Real background")) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07))
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(BackdropColor.presets, id: \.hex) { preset in
                swatchButton(hex: preset.hex, help: loc.t(preset.name)) {
                    Circle().fill(Color(hex: preset.hex) ?? .gray)
                }
            }

            ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .help(loc.t("Custom color"))
        }
    }

    private func swatchButton(hex: String, help: String,
                              @ViewBuilder content: () -> some View) -> some View {
        let isSelected = backdropHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            backdropHex = hex
        } label: {
            content()
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The color well doubles as the "custom" swatch: picking any color
    /// selects it, and it reflects the current choice when one is set.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: backdropHex) ?? .white },
            set: { backdropHex = $0.hexString }
        )
    }
}

// MARK: - Color ↔ hex helpers

extension Color {
    init?(hex: String) {
        guard let parsed = BackdropColor(hex: hex) else { return nil }
        self = Color(red: parsed.red, green: parsed.green, blue: parsed.blue)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
