import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecordingsListView: View {
    @EnvironmentObject var library: RecordingsLibrary
    @EnvironmentObject var exporter: VideoExporter

    @State private var showAll = false
    @State private var exportingItemID: UUID?
    @State private var pendingDelete: RecordingItem?
    @State private var showDeleteAlert = false

    private let defaultLimit = 5

    var body: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleItems) { item in
                        RecordingRow(
                            item: item,
                            isExporting: exportingItemID == item.id,
                            onExport: { runExport(item) },
                            onDelete: {
                                pendingDelete = item
                                showDeleteAlert = true
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if library.items.count > defaultLimit {
                        showAllButton
                    }
                }
                .animation(.snappy, value: library.items)
                .animation(.snappy, value: showAll)
            }
        }
        .alert("Delete this recording?", isPresented: $showDeleteAlert, presenting: pendingDelete) { item in
            Button("Move to Trash", role: .destructive) {
                library.delete(item)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("\(item.directory.lastPathComponent) and its source video will be moved to the Trash.")
        }
    }

    // MARK: - Empty / Show all

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("No recordings yet")
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Press the record button above to capture your first one.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.025))
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.tertiary)
        }
    }

    private var showAllButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showAll.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(showAll ? "Show fewer" : "Show all (\(library.items.count))")
                Image(systemName: showAll ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var visibleItems: [RecordingItem] {
        showAll ? library.items : Array(library.items.prefix(defaultLimit))
    }

    private func runExport(_ item: RecordingItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Locus-DemoMaker-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.title = "Export final video"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let outURL = panel.url else { return }
            Task {
                exportingItemID = item.id
                await exporter.export(recordingDir: item.directory, outputURL: outURL)
                // Refresh so the row picks up the new export.json marker and
                // can flip to the post-export action set.
                await library.refresh()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                exportingItemID = nil
            }
        }
    }
}

// MARK: - Row

private struct RecordingRow: View {
    let item: RecordingItem
    let isExporting: Bool
    let onExport: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var exporter: VideoExporter
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTimestamp)
                    .font(.system(size: 13, weight: .medium))
                metadataLine
            }

            Spacer(minLength: 8)

            if isExporting {
                exportStatus
                    .transition(.opacity)
            } else {
                actions
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.10 : 0.06), lineWidth: 0.5)
                }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isExporting)
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.85), Color.purple.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: 56, height: 36)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            if let d = item.duration {
                metaPill(systemImage: "clock", text: formatDuration(d))
            }
            metaPill(text: "\(item.pixelWidth) × \(item.pixelHeight)")
            metaPill(systemImage: "cursorarrow", text: "\(item.mouseEventCount)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metaPill(systemImage: String? = nil, text: String) -> some View {
        HStack(spacing: 3) {
            if let sym = systemImage {
                Image(systemName: sym).font(.caption2)
            }
            Text(text)
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch exporter.phase {
        case .exporting(let p):
            HStack(spacing: 8) {
                ProgressView(value: p)
                    .controlSize(.small)
                    .frame(width: 110)
                Text("\(Int(p * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case .finished:
            Label("Exported", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .font(.caption.weight(.medium))
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let exported = item.lastExportURL,
           FileManager.default.fileExists(atPath: exported.path) {
            postExportActions(exported: exported)
        } else {
            preExportActions
        }
    }

    private var preExportActions: some View {
        HStack(spacing: 6) {
            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            secondaryMenu {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.sourceVideoURL])
                } label: {
                    Label("Show original recording in Finder", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(item.sourceVideoURL)
                } label: {
                    Label("Open original source.mp4", systemImage: "play.rectangle")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Move recording to Trash", systemImage: "trash")
                }
            }
        }
    }

    private func postExportActions(exported: URL) -> some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(exported.lastPathComponent)

            secondaryMenu {
                // The two important actions, surfaced first.
                Section {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([exported])
                    } label: {
                        Label("Show exported file in Finder", systemImage: "folder")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.sourceVideoURL])
                    } label: {
                        Label("Show original recording in Finder", systemImage: "folder.badge.gearshape")
                    }
                }
                Section {
                    Button {
                        NSWorkspace.shared.open(exported)
                    } label: {
                        Label("Open exported file", systemImage: "play.rectangle.on.rectangle")
                    }
                    Button {
                        NSWorkspace.shared.open(item.sourceVideoURL)
                    } label: {
                        Label("Open original source.mp4", systemImage: "play.rectangle")
                    }
                }
                Section {
                    Button(action: onExport) {
                        Label("Re-export…", systemImage: "square.and.arrow.up.on.square")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Move recording to Trash", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Shared `…` menu trigger used by both pre- and post-export rows.
    private func secondaryMenu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func formatDuration(_ d: Double) -> String {
        let total = Int(d.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
