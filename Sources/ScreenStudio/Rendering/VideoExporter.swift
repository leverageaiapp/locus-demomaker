import Foundation
import AVFoundation
import CoreGraphics
import OSLog

/// High-level driver that takes a recording directory (source.mp4 + metadata.json)
/// and produces a final mp4 with auto-zoom + crisp cursor applied.
@MainActor
final class VideoExporter: ObservableObject {
    private let logger = Logger(subsystem: "com.screenstudio.app", category: "VideoExporter")

    enum Phase: Equatable {
        case idle
        case loading
        case exporting(progress: Double)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var progressTimer: Timer?

    /// `recordingDir` is what `RecordingSession.stopRecording()` returned.
    func export(recordingDir: URL, outputURL: URL,
                config: ZoomKeyframeEngine.Config = .init()) async {
        phase = .loading
        let videoURL = recordingDir.appendingPathComponent("source.mp4")
        let metaURL = recordingDir.appendingPathComponent("metadata.json")

        guard FileManager.default.fileExists(atPath: videoURL.path),
              FileManager.default.fileExists(atPath: metaURL.path) else {
            phase = .failed("Recording files missing")
            return
        }

        let metadata: RecordingMetadata
        do {
            let data = try Data(contentsOf: metaURL)
            metadata = try JSONDecoder().decode(RecordingMetadata.self, from: data)
        } catch {
            phase = .failed("Failed to read metadata: \(error.localizedDescription)")
            return
        }

            let asset = AVURLAsset(url: videoURL)
            let cameraURL = metadata.cameraVideoFileName.map { recordingDir.appendingPathComponent($0) }
            let cameraAsset: AVURLAsset?
            if let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) {
                cameraAsset = AVURLAsset(url: cameraURL)
            } else {
                cameraAsset = nil
            }

            do {
                let duration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first else {
                phase = .failed("No video track in source")
                return
            }
            let durationSeconds = CMTimeGetSeconds(duration)
            let videoSize = metadata.pixelSize

            // Build keyframes.
            let engine = ZoomKeyframeEngine(config: config)
            let keyframes = engine.generate(
                events: metadata.mouseEvents,
                duration: durationSeconds,
                frameRate: metadata.frameRate,
                videoSize: videoSize
            )

            // Build cursor renderer (shared with compositor through static var).
            let cursor = CursorRenderer.make(
                events: metadata.mouseEvents,
                frameRate: metadata.frameRate,
                videoSize: videoSize,
                duration: durationSeconds
            )
            AutoZoomCompositor.sharedCursorRenderer = cursor

            // Build composition.
            let composition = AVMutableComposition()
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                phase = .failed("Failed to add composition track")
                return
            }
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack, at: .zero
            )
            if let audioTrack = audioTracks.first,
               let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try compAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: .zero
                )
            }

            var cameraTrackID: CMPersistentTrackID?
            if let cameraAsset {
                let cameraTracks = try await cameraAsset.loadTracks(withMediaType: .video)
                if let cameraSourceTrack = cameraTracks.first,
                   let cameraCompTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                    let cameraDuration = try await cameraAsset.load(.duration)
                    let insertDuration = CMTimeCompare(cameraDuration, duration) < 0 ? cameraDuration : duration
                    try cameraCompTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: insertDuration),
                        of: cameraSourceTrack,
                        at: .zero
                    )
                    cameraTrackID = cameraCompTrack.trackID
                }
            }
            let sourceTrackIDs = [compTrack.trackID] + (cameraTrackID.map { [$0] } ?? [])

            let videoComposition = AVMutableVideoComposition()
            videoComposition.customVideoCompositorClass = AutoZoomCompositor.self
            videoComposition.renderSize = videoSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(metadata.frameRate))

            let instruction = AutoZoomCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: duration),
                sourceTrackIDs: sourceTrackIDs,
                screenTrackID: compTrack.trackID,
                cameraTrackID: cameraTrackID,
                keyframes: keyframes,
                videoSize: videoSize,
                frameRate: metadata.frameRate,
                cameraOverlayPosition: metadata.cameraOverlayPosition ?? .bottomRight,
                cameraOverlaySizeRatio: metadata.cameraOverlaySizeRatio ?? 0.18,
                cameraOverlayCenter: nil
            )
            videoComposition.instructions = [instruction]

            // Export.
            guard let exporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality
            ) else {
                phase = .failed("Failed to create export session")
                return
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.videoComposition = videoComposition
            exporter.shouldOptimizeForNetworkUse = true

            phase = .exporting(progress: 0)
            startProgressPolling(exporter)

            await exporter.export()
            stopProgressPolling()

            switch exporter.status {
            case .completed:
                phase = .finished(outputURL)
                // Drop a marker next to source.mp4 so the row's action buttons
                // can switch from "Export" to "Show in Finder" — and stay
                // switched across app restarts.
                let info = RecordingsLibrary.ExportInfo(
                    path: outputURL.path, exportedAt: Date()
                )
                let infoURL = recordingDir.appendingPathComponent("export.json")
                if let data = try? JSONEncoder().encode(info) {
                    try? data.write(to: infoURL)
                }
                logger.info("Export complete: \(outputURL.path)")
            case .cancelled:
                phase = .failed("Export cancelled")
            case .failed:
                phase = .failed(exporter.error?.localizedDescription ?? "Unknown export error")
            default:
                phase = .failed("Export ended in unexpected state \(exporter.status.rawValue)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }

        AutoZoomCompositor.sharedCursorRenderer = nil
    }

    private func startProgressPolling(_ exporter: AVAssetExportSession) {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if case .exporting = self.phase {
                    self.phase = .exporting(progress: Double(exporter.progress))
                }
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
