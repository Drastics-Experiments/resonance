import SwiftUI

@main
struct ResonanceApp: App {
    @StateObject private var library = MusicLibrary()
    @StateObject private var listenAlong = MobileListenAlongController()
    @StateObject private var themeStore = ResonanceThemeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(listenAlong)
                .environmentObject(themeStore)
                .environment(\.resonancePalette, themeStore.palette)
                .tint(themeStore.palette.foregroundAccent)
                .preferredColorScheme(.dark)
                .task {
                    listenAlong.bind(to: library)
                    await library.runAutomaticPlaylistSync()
                }
                .onOpenURL { url in
                    listenAlong.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        library.retryPendingRemoteSongMetadata()
                        await library.syncPlaylistsAutomatically()
                    }
                }
        }
    }
}
