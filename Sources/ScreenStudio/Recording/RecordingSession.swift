import Foundation
import AppKit
import ScreenCaptureKit
import OSLog

extension SCDisplay {
    /// Human-readable name like "Built-in Retina Display" or "Studio Display",
    /// resolved by matching `displayID` against `NSScreen.screens`.
    var localizedName: String {
        let id = self.displayID
        let match = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == id
        }
        return match?.localizedName ?? "Display"
    }
}

/// Coordinates ScreenRecorder + MouseTracker so that they start together,
/// share a common t=0, and produce a `RecordingMetadata` snapshot when stopped.
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

    @Published private(set) var state: State = .idle
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var lastRecordingDirectory: URL?

    private let recorder = ScreenRecorder()
    private let mouseTracker = MouseTracker()
    private var startedAt: Date?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func loadDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.availableDisplays = content.displays
            if selectedDisplayID == nil, let first = content.displays.first {
                selectedDisplayID = first.displayID
            }
        } catch {
            logger.error("loadDisplays failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    func startRecording() async {
        guard case .idle = state else { return }
        state = .preparing
        await loadDisplays()

        guard let display = availableDisplays.first(where: { $0.displayID == selectedDisplayID })
                ?? availableDisplays.first else {
            state = .error("No display available")
            return
        }

        let dir = Self.makeRecordingDirectory()
        let videoURL = dir.appendingPathComponent("source.mp4")
        do {
            try await recorder.start(display: display, url: videoURL, frameRate: 60)
            let displayOriginPoints = display.frame.origin
            let scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1.0
            guard mouseTracker.start(displayOrigin: displayOriginPoints, displayScale: scale) else {
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

    /// Stop and persist metadata. Returns the directory that contains source.mp4 and metadata.json.
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
                mouseEvents: events
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
