import AppKit
import SwiftUI

@main
struct LikedSongsFocusApp: App {
    @NSApplicationDelegateAdaptor(ResonanceApplicationDelegate.self) private var appDelegate
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
                .task { await model.runAutomaticPlaylistSync() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.syncPlaylistsAutomatically() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 750)

        Settings {
            MusicSettingsView()
                .environmentObject(model)
                .environmentObject(updateManager)
        }
    }
}

enum MacMenuPolicy {
    private static let textEditingActions = Set(["cut:", "copy:", "paste:", "selectAll:"])

    static func keepsMainMenuItem(_ item: NSMenuItem, at index: Int) -> Bool {
        if index == 0 { return true }
        guard let submenu = item.submenu else { return false }
        return submenu.items.contains { menuItem in
            guard let action = menuItem.action else { return false }
            return textEditingActions.contains(NSStringFromSelector(action))
        }
    }
}

private final class ResonanceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleMenuCleanup()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleMenuCleanup()
    }

    static func keepApplicationAndTextEditingMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        NSApp.windowsMenu = nil
        NSApp.helpMenu = nil
        for index in mainMenu.items.indices.reversed()
        where !MacMenuPolicy.keepsMainMenuItem(mainMenu.items[index], at: index) {
            mainMenu.removeItem(at: index)
        }
    }

    private func scheduleMenuCleanup() {
        for delay in [0.0, 0.1, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.keepApplicationAndTextEditingMenus()
            }
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
        ResonanceApplicationDelegate.keepApplicationAndTextEditingMenus()
    }
}
