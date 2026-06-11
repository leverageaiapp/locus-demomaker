import SwiftUI

@main
struct ScreenStudioApp: App {
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var session = RecordingSession()
    @StateObject private var exporter = VideoExporter()
    @StateObject private var library = RecordingsLibrary()
    @StateObject private var loc = Localization()

    var body: some Scene {
        WindowGroup("Locus DemoMaker") {
            ContentView()
                .environmentObject(permissions)
                .environmentObject(session)
                .environmentObject(exporter)
                .environmentObject(library)
                .environmentObject(loc)
                .frame(minWidth: 580, minHeight: 640)
                .background(WindowBackground().ignoresSafeArea())
        }
        .windowResizability(.contentSize)
        .commands {
            // Hide the default "New Window" command — there's only one window concept.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
