import AppKit
import SwiftUI

@main
struct LikedSongsFocusApp: App {
    @StateObject private var model: PlayerModel
    @StateObject private var localImportModel: MacLocalImportViewModel
    @StateObject private var updateManager = UpdateManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = PlayerModel(systemPlaybackController: MacSystemPlaybackController())
        _model = StateObject(wrappedValue: model)
        _localImportModel = StateObject(
            wrappedValue: MacLocalImportViewModel(model: model)
        )
    }

    var body: some Scene {
        WindowGroup("Resonance") {
            ContentView()
                .environmentObject(model)
                .environmentObject(localImportModel)
                .environmentObject(updateManager)
                .background(WindowConfigurator())
                .task {
                    await model.refreshClientConfigurationNow()
                    await model.runAutomaticPlaylistSync()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await model.refreshClientConfigurationNow()
                            await model.syncPlaylistsAutomatically()
                        }
                    } else {
                        model.flushPersistence()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandMenu("Music") {
                Button("Search Music") {
                    NotificationCenter.default.post(name: .focusMusicSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Add Music…") { model.importLocalFiles() }
                    .keyboardShortcut("o", modifiers: [.command])

                Button("New Playlist…") {
                    NotificationCenter.default.post(name: .newMusicPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                Button("Previous Track") { model.previous() }
                Button("Next Track") { model.next() }
            }
        }

        Settings {
            MusicSettingsView()
                .environmentObject(model)
                .environmentObject(updateManager)
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.027, green: 0.063, blue: 0.110, alpha: 1)
        window.minSize = NSSize(width: 860, height: 620)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}
