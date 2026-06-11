import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecordingsListView: View {
    @EnvironmentObject var library: RecordingsLibrary
    @EnvironmentObject var exporter: VideoExporter
    @EnvironmentObject var loc: Localization

    @State private var showAll = false
    @State private var exportingItemID: UUID?
    @State private var pendingDelete: RecordingItem?
    @State private var showDeleteAlert = false
    @AppStorage("exportVisualMode") private var exportVisualModeRaw = ExportVisualMode.autoZoom.rawValue
    @AppStorage("cameraBackdropHex") private var cameraBackdropHex = ""

    private let defaultLimit = 5
    private var exportVisualMode: ExportVisualMode {
        get { ExportVisualMode(rawValue: exportVisualModeRaw) ?? .autoZoom }
        nonmutating set { exportVisualModeRaw = newValue.rawValue }
    }

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
                            exportVisualMode: Binding(
                                get: { exportVisualMode },
                                set: { exportVisualMode = $0 }
                            ),
                            onExport: { runExport(item, visualMode: exportVisualMode) },
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
        .alert(loc.t("Delete this recording?"), isPresented: $showDeleteAlert, presenting: pendingDelete) { item in
            Button(loc.t("Move to Trash"), role: .destructive) {
                library.delete(item)
                pendingDelete = nil
            }
            Button(loc.t("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text(String(format: loc.t("%@ and its source video will be moved to the Trash."),
                        item.directory.lastPathComponent))
        }
    }

    // MARK: - Empty / Show all

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text(loc.t("No recordings yet"))
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(loc.t("Press the record button above to capture your first one."))
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
                Text(showAll ? loc.t("Show fewer") : "\(loc.t("Show all")) (\(library.items.count))")
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

    private func runExport(_ item: RecordingItem, visualMode: ExportVisualMode) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "Locus Demo \(stamp).mp4"
        panel.title = loc.t("Export final video")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let outURL = panel.url else { return }
            Task {
                exportingItemID = item.id
                await exporter.export(
                    recordingDir: item.directory,
                    outputURL: outURL,
                    options: .init(visualMode: visualMode,
                                   cameraBackdropHex: cameraBackdropHex)
                )
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
    @Binding var exportVisualMode: ExportVisualMode
    let onExport: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var exporter: VideoExporter
    @EnvironmentObject var loc: Localization
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
        VideoThumbnail(url: item.sourceVideoURL)
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .opacity(hovering ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .onTapGesture {
                NSWorkspace.shared.open(item.sourceVideoURL)
            }
            .help(loc.t("Play original recording"))
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
                Text(loc.t("Loading…")).font(.caption).foregroundStyle(.secondary)
            }
        case .finished:
            Label(loc.t("Exported"), systemImage: "checkmark.circle.fill")
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
            modePill

            Button(action: onExport) {
                Label(loc.t("Export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            secondaryMenu {
                Picker(loc.t("Video Mode"), selection: $exportVisualMode) {
                    ForEach(ExportVisualMode.allCases) { mode in
                        Label(loc.t(mode.displayName), systemImage: mode.systemImage).tag(mode)
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.sourceVideoURL])
                } label: {
                    Label(loc.t("Show original recording in Finder"), systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(item.sourceVideoURL)
                } label: {
                    Label(loc.t("Open original source.mp4"), systemImage: "play.rectangle")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(loc.t("Move recording to Trash"), systemImage: "trash")
                }
            }
        }
    }

    private func postExportActions(exported: URL) -> some View {
        HStack(spacing: 6) {
            modePill

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } label: {
                Label(loc.t("Show in Finder"), systemImage: "folder")
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
                        Label(loc.t("Show exported file in Finder"), systemImage: "folder")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.sourceVideoURL])
                    } label: {
                        Label(loc.t("Show original recording in Finder"), systemImage: "folder.badge.gearshape")
                    }
                }
                Section {
                    Button {
                        NSWorkspace.shared.open(exported)
                    } label: {
                        Label(loc.t("Open exported file"), systemImage: "play.rectangle.on.rectangle")
                    }
                    Button {
                        NSWorkspace.shared.open(item.sourceVideoURL)
                    } label: {
                        Label(loc.t("Open original source.mp4"), systemImage: "play.rectangle")
                    }
                }
                Section {
                    Picker(loc.t("Video Mode"), selection: $exportVisualMode) {
                        ForEach(ExportVisualMode.allCases) { mode in
                            Label(loc.t(mode.displayName), systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    Button(action: onExport) {
                        Label(loc.t("Re-export…"), systemImage: "square.and.arrow.up.on.square")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(loc.t("Move recording to Trash"), systemImage: "trash")
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

    private var modePill: some View {
        Label(loc.t(exportVisualMode.displayName), systemImage: exportVisualMode.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
    }

    private func formatDuration(_ d: Double) -> String {
        let total = Int(d.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
