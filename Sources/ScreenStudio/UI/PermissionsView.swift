import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var permissions: PermissionsManager

    var body: some View {
        VStack(spacing: 24) {
            Image("LocusLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)

            VStack(spacing: 6) {
                Text("Welcome to Locus DemoMaker")
                    .font(.title.weight(.semibold))
                Text("Capture your screen with smooth auto-zoom. We need a couple of macOS permissions first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            VStack(spacing: 10) {
                permissionCard(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    subtitle: "Capture pixels from your display.",
                    granted: permissions.screenRecordingGranted,
                    action: {
                        Task {
                            _ = await PermissionsManager.checkScreenRecording()
                            await permissions.refresh()
                            if !permissions.screenRecordingGranted {
                                permissions.openSystemSettingsScreenRecording()
                            }
                        }
                    }
                )
                permissionCard(
                    icon: "cursorarrow.motionlines",
                    title: "Accessibility",
                    subtitle: "Track the cursor anywhere on screen.",
                    granted: permissions.accessibilityGranted,
                    action: {
                        permissions.requestAccessibility()
                        if !permissions.accessibilityGranted {
                            permissions.openSystemSettingsAccessibility()
                        }
                    }
                )
            }
            .frame(maxWidth: 440)

            Button {
                Task { await permissions.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: permissions.screenRecordingGranted)
        .animation(.snappy, value: permissions.accessibilityGranted)
    }

    private func permissionCard(icon: String, title: String, subtitle: String,
                                 granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.tint.opacity(granted ? 0.12 : 0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}
