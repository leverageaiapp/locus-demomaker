import SwiftUI
import ScreenCaptureKit

/// The hero "press to record" panel at the top of the window.
/// Big circular button, refined typography, soft frosted card.
struct RecordingHeroView: View {
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var library: RecordingsLibrary

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    /// Suppresses the auto-open behavior on the very first appearance, when the
    /// captureMode is just being restored from UserDefaults.
    @State private var didApplyInitialMode = false

    var body: some View {
        VStack(spacing: 18) {
            recordButton
            captionStack
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: session.isRecording)
        .onChange(of: session.captureMode) { _, newMode in
            // Skip the change SwiftUI emits when the @Published var first attaches.
            guard didApplyInitialMode else {
                didApplyInitialMode = true
                return
            }
            switch newMode {
            case .window:
                session.presentWindowPicker()
            case .region:
                session.presentRegionPickerWithSmartDefault()
            case .fullDisplay:
                break
            }
        }
        .onAppear { didApplyInitialMode = true }
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button(action: toggle) {
            ZStack {
                // outer halo
                Circle()
                    .fill(Color.red.opacity(session.isRecording ? 0.22 : 0.14))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder(Color.red.opacity(0.28), lineWidth: 1)
                    .frame(width: 96, height: 96)
                // inner shape — circle when idle, rounded square (stop) when recording
                Group {
                    if session.isRecording {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1, green: 0.35, blue: 0.35),
                                             Color(red: 0.95, green: 0.18, blue: 0.18)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: 38, height: 38)
                            .shadow(color: Color.red.opacity(0.4), radius: 8, y: 2)
                    }
                }
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(RecordButtonStyle())
        .disabled(isBusy)
        .opacity(isBusy ? 0.65 : 1)
    }

    // MARK: - Caption / picker

    @ViewBuilder
    private var captionStack: some View {
        if session.isRecording {
            VStack(spacing: 4) {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Click the button to stop")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                Text("Start Recording")
                    .font(.title2.weight(.semibold))
                Text("Auto-zoom follows your cursor while you work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                modeSegmented
                modeDetail
                if session.availableDisplays.count > 1 {
                    displayChooser
                }
                if case .error(let msg) = session.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Mode picker + per-mode detail row

    private var modeSegmented: some View {
        Picker("", selection: $session.captureMode) {
            ForEach(CaptureMode.allCases) { mode in
                Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private var modeDetail: some View {
        switch session.captureMode {
        case .fullDisplay:
            HStack(spacing: 6) {
                Image(systemName: "display").font(.caption)
                Text(session.selectedDisplay?.localizedName ?? "Display")
            }
            .font(.callout).foregroundStyle(.secondary)

        case .region:
            let r = session.preferredRegion.rectInPoints
            HStack(spacing: 8) {
                Label("\(Int(r.width)) × \(Int(r.height))", systemImage: "rectangle.dashed")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.primary)
                Button {
                    session.presentRegionPicker()
                } label: {
                    Label("Adjust", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .window:
            windowPicker
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        if let selected = session.selectedWindow {
            HStack(spacing: 8) {
                Label(windowDisplayName(selected), systemImage: "macwindow")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
                Button {
                    session.presentWindowPicker()
                } label: {
                    Label("Change", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Label("No window picked", systemImage: "macwindow.badge.plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    session.presentWindowPicker()
                } label: {
                    Label("Pick a window", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func windowDisplayName(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? ""
        let title = (w.title?.isEmpty == false) ? w.title! : ""
        if !app.isEmpty && !title.isEmpty { return "\(app) — \(title)" }
        if !app.isEmpty { return app }
        if !title.isEmpty { return title }
        return "Window"
    }

    /// Single display → static label. Multiple → menu picker with real names.
    @ViewBuilder
    private var displayChooser: some View {
        let displays = session.availableDisplays
        if displays.count <= 1 {
            if let only = displays.first {
                HStack(spacing: 6) {
                    Image(systemName: "display")
                        .font(.caption)
                    Text(only.localizedName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        } else {
            Picker("", selection: Binding(
                get: { session.selectedDisplayID ?? displays.first?.displayID ?? 0 },
                set: { session.selectedDisplayID = $0 }
            )) {
                ForEach(displays, id: \.displayID) { d in
                    Text(d.localizedName).tag(d.displayID)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.regular)
            .fixedSize()
        }
    }

    // MARK: - Behavior

    private var isBusy: Bool {
        if case .preparing = session.state { return true }
        if case .stopping = session.state { return true }
        return false
    }

    private func toggle() {
        if session.isRecording { stop() } else { start() }
    }

    private func start() {
        Task {
            await session.startRecording()
            startTimer()
        }
    }

    private func stop() {
        Task {
            stopTimer()
            _ = await session.stopRecording()
            await library.refresh()
        }
    }

    private func startTimer() {
        elapsed = 0
        timer?.invalidate()
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsed = Date().timeIntervalSince(start)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        let ms = Int((t - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}

/// Custom style so the press animation is driven by `configuration.isPressed`
/// (a SwiftUI-managed value) instead of an `onLongPressGesture` that would
/// race with the Button's own tap recognizer and swallow clicks. That race was
/// the cause of the "stop button needs many tries" bug.
private struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
