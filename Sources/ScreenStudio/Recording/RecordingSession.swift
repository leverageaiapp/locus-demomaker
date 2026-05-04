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
            // excludingDesktopWindows: true → drop the wallpaper layer and
            // anything else SC classifies as desktop chrome.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            self.availableDisplays = content.displays
            if selectedDisplayID == nil, let first = content.displays.first {
                selectedDisplayID = first.displayID
            }
            // Filter to capturable, non-system windows owned by other apps. We
            // then sort front-to-back authoritatively via CGWindowListCopyWindowInfo
            // so the visual picker's "first frame containing the cursor wins"
            // logic actually picks the *topmost* window, not whatever the
            // underlying SC order happens to be on this macOS version.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let filtered = content.windows.filter { w in
                guard let app = w.owningApplication else { return false }
                if app.processID == ownPID { return false }
                if !w.isOnScreen { return false }
                // Layer 0 = normal user-facing windows. Higher layers are Dock,
                // menu bar, notification center, system overlays, floating panels.
                // None of those should ever be selectable in the picker.
                if w.windowLayer != 0 { return false }
                if w.frame.width < 100 || w.frame.height < 100 { return false }
                if (w.title ?? "").isEmpty && (app.applicationName).isEmpty { return false }
                return true
            }
            self.availableWindows = Self.sortFrontToBack(filtered)
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

    /// Used when the user just switched into Region mode — show the selector
    /// pre-populated with the topmost user-facing window's bounds, so the
    /// default selection is something they probably want to record.
    func presentRegionPickerWithSmartDefault() {
        guard let display = selectedDisplay else { return }
        Task { [weak self] in
            guard let self else { return }
            let initial = await self.smartDefaultRegion(on: display)
            RegionSelector.present(on: display, initialRectInPoints: initial) { picked in
                guard let picked else { return }
                self.preferredRegion = CaptureRegion(rectInPoints: picked)
                    .clamped(to: display.frame.size)
            }
        }
    }

    private func smartDefaultRegion(on display: SCDisplay) async -> CGRect {
        let fallback = preferredRegion.clamped(to: display.frame.size).rectInPoints
        guard let topmost = await topmostUserFacingWindow(on: display) else {
            return fallback
        }
        // SCDisplay.frame and SCWindow.frame share the same Quartz coordinate
        // space — converting to display-local is just origin subtraction.
        let local = CGRect(
            x: topmost.frame.minX - display.frame.minX,
            y: topmost.frame.minY - display.frame.minY,
            width: topmost.frame.width,
            height: topmost.frame.height
        )
        let clipped = local.intersection(CGRect(origin: .zero, size: display.frame.size))
        if clipped.width < 200 || clipped.height < 150 { return fallback }
        return clipped
    }

    private func topmostUserFacingWindow(on display: SCDisplay) async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let candidates = content.windows.filter { w in
                guard let app = w.owningApplication else { return false }
                if app.processID == ownPID { return false }
                if !w.isOnScreen { return false }
                if w.windowLayer != 0 { return false }
                if w.frame.width < 200 || w.frame.height < 150 { return false }
                return w.frame.intersects(display.frame)
            }
            return Self.sortFrontToBack(candidates).first
        } catch {
            return nil
        }
    }

    /// Front-to-back order for capturable windows.
    ///
    /// `CGWindowListCopyWindowInfo([.optionOnScreenOnly, ...])` is documented
    /// to return windows in front-to-back order — far more reliable than the
    /// undocumented order `SCShareableContent.windows` uses. We walk that list
    /// directly and pull out matching SCWindow entries; anything missing from
    /// the CG list falls to the back.
    ///
    /// We use `NSNumber.uint32Value` rather than `as? CGWindowID` because the
    /// latter cast goes through Obj-C bridging and silently returns nil if the
    /// underlying NSNumber storage type doesn't match exactly — which would
    /// leave the dictionary empty and the sort effectively a no-op.
    private static func sortFrontToBack(_ windows: [SCWindow]) -> [SCWindow] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let byID: [CGWindowID: SCWindow] = Dictionary(
            uniqueKeysWithValues: windows.map { ($0.windowID, $0) }
        )

        var ordered: [SCWindow] = []
        var seen = Set<CGWindowID>()
        for d in info {
            guard let n = d[kCGWindowNumber as String] as? NSNumber else { continue }
            let id = CGWindowID(n.uint32Value)
            if let w = byID[id], !seen.contains(id) {
                ordered.append(w)
                seen.insert(id)
            }
        }
        // Anything not found in the CG list (rare — private system surfaces)
        // gets appended in its original order at the back.
        for w in windows where !seen.contains(w.windowID) {
            ordered.append(w)
        }

        #if DEBUG
        let summary = ordered.prefix(5).map {
            "\($0.owningApplication?.applicationName ?? "?")[\($0.windowID)]"
        }.joined(separator: " > ")
        print("WindowPicker order (front-first): \(summary)")
        #endif

        return ordered
    }

    // MARK: Window picking

    func presentWindowPicker() {
        guard let display = selectedDisplay else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadDisplays()  // refresh window list — user might have closed/opened things
            WindowPicker.present(on: display, windows: self.availableWindows) { picked in
                if let picked {
                    self.selectedWindowID = picked.windowID
                }
            }
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
