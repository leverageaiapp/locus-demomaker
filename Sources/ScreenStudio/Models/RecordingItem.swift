import Foundation
import CoreGraphics

/// One row in the recordings list. Built from a Recording-* directory on disk.
struct RecordingItem: Identifiable, Hashable {
    let id: UUID
    let directory: URL
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let frameRate: Int
    let mouseEventCount: Int
    /// Loaded asynchronously from the source video — `nil` until probed.
    var duration: Double?
    /// Path to the most recently exported mp4 — `nil` if never exported, or if the
    /// exported file no longer exists at the recorded path.
    var lastExportURL: URL?

    var sourceVideoURL: URL { directory.appendingPathComponent("source.mp4") }
    var metadataURL: URL { directory.appendingPathComponent("metadata.json") }
    var exportInfoURL: URL { directory.appendingPathComponent("export.json") }

    var displayTimestamp: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: createdAt)
    }
}
