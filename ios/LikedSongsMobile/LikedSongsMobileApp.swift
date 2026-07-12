import SwiftUI

@main
struct ResonanceApp: App {
    @StateObject private var library = MusicLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
        }
    }
}
