import AppKit
import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor(ResonanceAppDelegate.self) private var appDelegate
    @StateObject private var model: PlayerModel
    @StateObject private var localImportModel: MacLocalImportViewModel
    @StateObject private var updateManager: UpdateManager
    @StateObject private var desktopPreferences: MacDesktopPreferences
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let migration = LegacyAppMigration.run()
        let model = PlayerModel(
            systemPlaybackController: MacSystemPlaybackController(),
            legacyApplicationSupportMigration: migration
        )
        _model = StateObject(wrappedValue: model)
        _localImportModel = StateObject(
            wrappedValue: MacLocalImportViewModel(model: model)
        )
        _updateManager = StateObject(wrappedValue: UpdateManager())
        _desktopPreferences = StateObject(wrappedValue: MacDesktopPreferences())
    }

    var body: some Scene {
        WindowGroup("Resonance") {
            ContentView()
                .environmentObject(model)
                .environmentObject(localImportModel)
                .environmentObject(updateManager)
                .environmentObject(desktopPreferences)
                .background(WindowConfigurator())
                .task {
                    desktopPreferences.bind(to: model)
                    await model.refreshAccountSessionIfNeeded()
                    await model.refreshClientConfigurationNow()
                    await model.runAutomaticPlaylistSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    desktopPreferences.stop()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await model.refreshAccountSessionIfNeeded()
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

                Button("Import from Link…") {
                    NotificationCenter.default.post(name: .importMusicFromLink, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("New Playlist…") {
                    NotificationCenter.default.post(name: .newMusicPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                Button("Previous Track") { model.previous() }
                Button("Next Track") { model.next() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openResonanceSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

final class ResonanceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: MacDesktopPreferenceKeys.runInBackground)
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
