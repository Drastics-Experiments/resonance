import SwiftUI

@main
struct ResonanceApp: App {
    @StateObject private var library = MusicLibrary()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .task { await library.runAutomaticPlaylistSync() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await library.syncPlaylistsAutomatically() }
                }
        }
    }
}
