import Foundation
import AppKit
import AVFoundation
import OSLog

/// Scans `~/Movies/ScreenStudio/` for recording directories, exposes them as a
/// sorted list, and supports moving an entry to the Trash.
@MainActor
final class RecordingsLibrary: ObservableObject {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "RecordingsLibrary")

    @Published private(set) var items: [RecordingItem] = []

    var rootDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return movies.appendingPathComponent("ScreenStudio", isDirectory: true)
    }

    func refresh() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else {
            self.items = []
            return
        }

        let urls = (try? fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let recordingDirs = urls.filter { url in
            guard url.lastPathComponent.hasPrefix("Recording-") else { return false }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir
        }

        var collected: [RecordingItem] = []
        for dir in recordingDirs {
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else {
                continue  // skip incomplete / broken recordings
            }

            // Optional: pick up the last-exported file pointer. We only set it
            // if the file still exists — if the user moved/deleted the export,
            // the row will fall back to showing "Export" again.
            var lastExport: URL?
            let exportInfoURL = dir.appendingPathComponent("export.json")
            if let data = try? Data(contentsOf: exportInfoURL),
               let info = try? JSONDecoder().decode(ExportInfo.self, from: data) {
                let url = URL(fileURLWithPath: info.path)
                if FileManager.default.fileExists(atPath: url.path) {
                    lastExport = url
                }
            }

            collected.append(RecordingItem(
                id: meta.id,
                directory: dir,
                createdAt: meta.createdAt,
                pixelWidth: meta.pixelWidth,
                pixelHeight: meta.pixelHeight,
                frameRate: meta.frameRate,
                mouseEventCount: meta.mouseEvents.count,
                duration: nil,
                lastExportURL: lastExport
            ))
        }
        // Newest first.
        collected.sort { $0.createdAt > $1.createdAt }
        self.items = collected

        await loadDurations()
    }

    /// Probe each video's duration in the background and update items in place.
    private func loadDurations() async {
        for currentItem in items where currentItem.duration == nil {
            let asset = AVURLAsset(url: currentItem.sourceVideoURL)
            let dur: Double
            do {
                let cm = try await asset.load(.duration)
                dur = CMTimeGetSeconds(cm)
            } catch {
                continue
            }
            // Items may have changed (refresh / delete) — locate by id, not index.
            if let idx = items.firstIndex(where: { $0.id == currentItem.id }) {
                items[idx].duration = dur
            }
        }
    }

    /// Persisted alongside source.mp4 so the post-export action buttons survive
    /// app restarts. See `VideoExporter` (writer) and `refresh()` (reader).
    struct ExportInfo: Codable {
        let path: String
        let exportedAt: Date
    }

    /// Move the recording to the Trash. Safe — recoverable from Finder.
    func delete(_ item: RecordingItem) {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: item.directory, resultingItemURL: &resultingURL)
            items.removeAll { $0.id == item.id }
        } catch {
            logger.error("Failed to trash \(item.directory.path): \(error.localizedDescription)")
        }
    }
}
