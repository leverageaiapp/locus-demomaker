import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// The hero "press to record" panel at the top of the window.
/// Big circular button, refined typography, soft frosted card.
struct RecordingHeroView: View {
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var library: RecordingsLibrary

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var hideCameraPreviewWhileStarting = false
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
                cameraToggle
                if session.includeCamera && !hideCameraPreviewWhileStarting {
                    cameraPositioner
                }
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

    private var cameraToggle: some View {
        Toggle(isOn: $session.includeCamera) {
            Label("Face Camera", systemImage: "camera.fill")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var cameraPositioner: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bubbleSize = min(78, max(58, size.width * 0.22))
            let radius = bubbleSize / 2
            let maxX = size.width - radius - 10
            let maxY = size.height - radius - 10
            let center = CGPoint(x: maxX, y: maxY)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    }

                CameraPreview()
                    .frame(width: bubbleSize, height: bubbleSize)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                    }
                    .position(center)
            }
        }
        .frame(width: 340, height: 190)
        .padding(.top, 2)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
        hideCameraPreviewWhileStarting = true
        Task {
            await session.startRecording()
            if session.isRecording {
                startTimer()
            } else {
                hideCameraPreviewWhileStarting = false
            }
        }
    }

    private func stop() {
        Task {
            stopTimer()
            _ = await session.stopRecording()
            hideCameraPreviewWhileStarting = false
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

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.start()
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.start()
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) {
        nsView.stop()
    }
}

private final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.screenstudio.camera.preview", qos: .userInitiated)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    self?.startAuthorized()
                }
            }
        default:
            break
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func startAuthorized() {
        if !configured {
            configure()
        }
        queue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .medium

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        wantsLayer = true
        self.layer?.addSublayer(layer)
        previewLayer = layer
    }
}
