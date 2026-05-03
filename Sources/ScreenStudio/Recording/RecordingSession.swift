import Foundation
import AppKit
import ScreenCaptureKit
import OSLog

extension SCDisplay {
    /// Human-readable name like "Built-in Retina Display" or "Studio Display".
    var localizedName: String {
        let id = self.displayID
        let match = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == id
        }
        return match?.localizedName ?? "Display"
    }
}

/// Coordinates capture mode + ScreenRecorder + MouseTracker so they start together,
/// share a common t=0, and persist a `RecordingMetadata` snapshot on stop.
@MainActor
final class RecordingSession: ObservableObject {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "RecordingSession")

    enum State: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case stopping
        case error(String)
    }

    // MARK: Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var availableWindows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?

    @Published var captureMode: CaptureMode = .fullDisplay {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: Self.modeKey) }
    }
    @Published var preferredRegion: CaptureRegion = .defaultCentered(
        displayPointSize: CGSize(width: 1440, height: 900)
    ) {
        didSet { persistRegion() }
    }

    @Published private(set) var lastRecordingDirectory: URL?

    // MARK: Internals

    private let recorder = ScreenRecorder()
    private let mouseTracker = MouseTracker()
    private var startedAt: Date?

    private static let modeKey = "captureMode"
    private static let regionKey = "preferredRegion"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let mode = CaptureMode(rawValue: raw) {
            self.captureMode = mode
        }
        if let data = UserDefaults.standard.data(forKey: Self.regionKey),
           let region = try? JSONDecoder().decode(CaptureRegion.self, from: data) {
            self.preferredRegion = region
        }
    }

    private func persistRegion() {
        if let data = try? JSONEncoder().encode(preferredRegion) {
            UserDefaults.standard.set(data, forKey: Self.regionKey)
        }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var selectedDisplay: SCDisplay? {
        availableDisplays.first(where: { $0.displayID == selectedDisplayID })
            ?? availableDisplays.first
    }

    var selectedWindow: SCWindow? {
        availableWindows.first(where: { $0.windowID == selectedWindowID })
    }

    // MARK: Discovery

    func loadDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            self.availableDisplays = content.displays
            if selectedDisplayID == nil, let first = content.displays.first {
                selectedDisplayID = first.displayID
            }
            // Filter to capturable, non-system windows owned by other apps so the
            // user sees a sensible list to record.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            self.availableWindows = content.windows
                .filter { w in
                    guard let app = w.owningApplication else { return false }
                    if app.processID == ownPID { return false }
                    if !w.isOnScreen { return false }
                    if w.frame.width < 100 || w.frame.height < 100 { return false }
                    if (w.title ?? "").isEmpty && (app.applicationName).isEmpty { return false }
                    return true
                }
                .sorted { ($0.title ?? "") < ($1.title ?? "") }
            if let region = selectedDisplay.map({ self.preferredRegion.clamped(to: $0.frame.size) }) {
                self.preferredRegion = region
            }
        } catch {
            logger.error("loadDisplays failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Region picking

    func presentRegionPicker() {
        guard let display = selectedDisplay else { return }
        let initial = preferredRegion.clamped(to: display.frame.size).rectInPoints
        RegionSelector.present(on: display, initialRectInPoints: initial) { [weak self] picked in
            guard let self, let picked else { return }
            self.preferredRegion = CaptureRegion(rectInPoints: picked)
                .clamped(to: display.frame.size)
        }
    }

    // MARK: Start / stop

    func startRecording() async {
        guard case .idle = state else { return }
        state = .preparing
        await loadDisplays()

        guard let display = selectedDisplay else {
            state = .error("No display available")
            return
        }

        let target: ScreenRecorder.Target
        switch captureMode {
        case .fullDisplay:
            target = .fullDisplay(display)
        case .region:
            let region = preferredRegion.clamped(to: display.frame.size)
            target = .region(display, rectInDisplayPoints: region.rectInPoints)
        case .window:
            guard let window = selectedWindow else {
                state = .error("Pick a window to record first.")
                return
            }
            target = .window(window, on: display)
        }

        let dir = Self.makeRecordingDirectory()
        let videoURL = dir.appendingPathComponent("source.mp4")
        do {
            try await recorder.start(target: target, url: videoURL, frameRate: 60)
            // MouseTracker uses the captured surface origin (already global points)
            // and the surface scale — same logic for all 3 modes.
            guard mouseTracker.start(
                displayOrigin: recorder.displayOrigin,
                displayScale: recorder.displayScale
            ) else {
                _ = try? await recorder.stop()
                state = .error("Mouse tracker failed — accessibility permission needed.")
                return
            }
            self.lastRecordingDirectory = dir
            self.startedAt = Date()
            state = .recording(startedAt: Date())
        } catch {
            logger.error("startRecording failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    /// Stop and persist metadata.
    func stopRecording() async -> URL? {
        guard case .recording = state else { return nil }
        state = .stopping
        let events = mouseTracker.stop()
        do {
            let videoURL = try await recorder.stop()
            guard let dir = lastRecordingDirectory else { return nil }
            let metadata = RecordingMetadata(
                id: UUID(),
                createdAt: startedAt ?? Date(),
                pixelWidth: Int(recorder.pixelSize.width),
                pixelHeight: Int(recorder.pixelSize.height),
                displayScale: recorder.displayScale,
                displayOriginX: recorder.displayOrigin.x,
                displayOriginY: recorder.displayOrigin.y,
                displayPointWidth: recorder.displayPointSize.width,
                displayPointHeight: recorder.displayPointSize.height,
                frameRate: recorder.frameRate,
                mouseEvents: events,
                captureMode: recorder.captureMode,
                capturedWindowTitle: recorder.capturedWindowTitle
            )
            let metaURL = dir.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: metaURL)
            state = .idle
            logger.info("Stopped. Wrote \(events.count) mouse events. Source = \(videoURL.path)")
            return dir
        } catch {
            logger.error("stopRecording failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            return nil
        }
    }

    private static func makeRecordingDirectory() -> URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("ScreenStudio", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = folder.appendingPathComponent("Recording-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
