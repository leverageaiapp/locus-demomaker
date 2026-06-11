import SwiftUI

struct ContentView: View {
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var library: RecordingsLibrary
    @EnvironmentObject var loc: Localization

    var body: some View {
        Group {
            if !permissions.screenRecordingGranted
                || !permissions.accessibilityGranted
                || !permissions.microphoneGranted {
                PermissionsView()
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .top) {
                    ambientBackdrop
                    ScrollView {
                        VStack(spacing: 28) {
                            RecordingHeroView()
                            recordingsSection
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if case .recording = session.state {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .symbolEffect(.pulse)
                            .foregroundStyle(.red)
                        Text(loc.t("Recording"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(loc.t("Language"), selection: $loc.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "globe")
                }
                .menuIndicator(.hidden)
                .help(loc.t("Language"))
            }
        }
        .task {
            await permissions.refresh()
            await session.loadDisplays()
            await library.refresh()
        }
        .animation(.snappy, value: permissions.screenRecordingGranted)
        .animation(.snappy, value: permissions.accessibilityGranted)
    }

    /// Soft color wash behind the content — indigo at rest, warms to red
    /// while a recording is in flight so the whole window signals state.
    private var ambientBackdrop: some View {
        LinearGradient(
            colors: [
                (session.isRecording ? Color.red : Color.indigo)
                    .opacity(session.isRecording ? 0.10 : 0.07),
                .clear
            ],
            startPoint: .top, endPoint: .center
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: session.isRecording)
    }

    private var recordingsSection: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.t("Recent Recordings"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await library.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(loc.t("Refresh"))
            }
            RecordingsListView()
        }
    }
}
