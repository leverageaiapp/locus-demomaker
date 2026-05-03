import SwiftUI

struct ContentView: View {
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var session: RecordingSession
    @EnvironmentObject var library: RecordingsLibrary

    var body: some View {
        Group {
            if !permissions.screenRecordingGranted || !permissions.accessibilityGranted {
                PermissionsView()
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                if case .recording = session.state {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .symbolEffect(.pulse)
                            .foregroundStyle(.red)
                        Text("Recording")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
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

    private var recordingsSection: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Recordings")
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
                .help("Refresh")
            }
            RecordingsListView()
        }
    }
}
