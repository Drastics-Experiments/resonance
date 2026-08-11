import SwiftUI

@main
struct ResonanceApp: App {
    @StateObject private var library = MusicLibrary()
    @StateObject private var themeStore = ResonanceThemeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(themeStore)
                .environment(\.resonancePalette, themeStore.palette)
                .tint(themeStore.palette.foregroundAccent)
                .preferredColorScheme(.dark)
                .task { await library.runAutomaticPlaylistSync() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await library.syncPlaylistsAutomatically() }
                }
        }
    }
}
