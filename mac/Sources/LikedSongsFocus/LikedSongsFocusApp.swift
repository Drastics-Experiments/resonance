import AppKit
import SwiftUI

@main
struct LikedSongsFocusApp: App {
    @StateObject private var model = PlayerModel()
    @StateObject private var updateManager = UpdateManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Resonance") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updateManager)
                .background(WindowConfigurator())
                .task { await model.runAutomaticPlaylistSync() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.syncPlaylistsAutomatically() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Playlist…") {
                    NotificationCenter.default.post(name: .newMusicPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Import Songs…") {
                    model.importLocalFiles()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Navigate") {
                Button("Search Music") {
                    NotificationCenter.default.post(name: .focusMusicSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Open Music Server") { model.selectSection(.server) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Updates") {
                Button("Check for Updates…") {
                    Task { await updateManager.checkForUpdates() }
                }
                .disabled(updateManager.isBusy)

                if updateManager.hasUpdate {
                    Button(updateManager.canInstall ? "Restart to Install Update" : "Update and Restart") {
                        if updateManager.canInstall {
                            updateManager.installAndRestart()
                        } else {
                            Task { await updateManager.downloadAndInstall() }
                        }
                    }
                    .disabled(updateManager.isBusy)
                }
            }

            CommandMenu("Library") {
                Button("Toggle Liked") {
                    if let track = model.currentTrack { model.toggleFavorite(track) }
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.currentTrack == nil)

                Button("Download Selected Server Songs", action: model.downloadSelectedServerSongs)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selectedRemoteSongIDs.isEmpty || model.isSyncingServer)
            }

            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") {
                    model.togglePlay()
                }

                Button("Previous Track") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Next Track") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
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
