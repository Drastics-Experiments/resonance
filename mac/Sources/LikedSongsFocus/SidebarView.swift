import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""

    private var newPlaylistNameError: String? {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a playlist name." }
        if model.playlists.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return "A playlist with this name already exists."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    SidebarNavigationRow(
                        section: section,
                        isSelected: model.section == section
                    ) {
                        model.selectSection(section)
                    }
                }
            }

            HStack {
                Text("Your playlists")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xB9BECB))
                Spacer()
                Text("\(model.playlists.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x7F8796))
                Button {
                    newPlaylistName = ""
                    showingNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New Playlist")
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.playlists) { playlist in
                        PlaylistSidebarRow(
                            playlist: playlist,
                            tracks: model.tracks,
                            isSelected: model.section == .playlists && model.selectedPlaylistID == playlist.id,
                            deleteAction: playlist.isSystem ? nil : { model.deletePlaylist(playlist) }
                        ) {
                            model.selectPlaylist(playlist)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 12)

        }
        .padding(.horizontal, 12)
        .background {
            LinearGradient(
                colors: [Color(hex: 0x08090E).opacity(0.99), Color.appBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { _ = model.createPlaylist(named: newPlaylistName) }
                .disabled(newPlaylistNameError != nil)
        } message: {
            Text(newPlaylistNameError ?? "Create a playlist for songs in your local library.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMusicPlaylist)) { _ in
            newPlaylistName = ""
            showingNewPlaylist = true
        }
    }
}

struct MacSettingsSheet: View {
    private enum Panel: String, CaseIterable, Identifiable {
        case general = "General"
        case keybinds = "Keybinds"

        var id: String { rawValue }
        var symbol: String { self == .general ? "gearshape" : "keyboard" }
    }

    @EnvironmentObject private var preferences: MacDesktopPreferences
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = MacShortcutRecorder()
    @State private var panel: Panel = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.appInk)
                    Text("Manage how Resonance behaves on this Mac.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.appMuted)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Rectangle().fill(Color.appLine).frame(height: 1)

            HStack(spacing: 0) {
                VStack(spacing: 7) {
                    ForEach(Panel.allCases) { candidate in
                        Button {
                            recorder.cancel()
                            panel = candidate
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: candidate.symbol)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 18)
                                Text(candidate.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(panel == candidate ? Color.white : Color.appMuted)
                            .padding(.horizontal, 13)
                            .frame(height: 44)
                            .background(panel == candidate ? Color.appViolet.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(panel == candidate ? Color.appViolet.opacity(0.8) : Color.clear)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(width: 176)
                .background(Color.black.opacity(0.13))

                Rectangle().fill(Color.appLine).frame(width: 1)

                Group {
                    if panel == .general { generalPanel }
                    else { keybindPanel }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Rectangle().fill(Color.appLine).frame(height: 1)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appViolet)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 62)
            .background(Color.appSurfaceRaised.opacity(0.55))
        }
        .frame(width: 760, height: 520)
        .background(
            RadialGradient(
                colors: [Color.appViolet.opacity(0.14), Color.appPanel],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
        )
        .preferredColorScheme(.dark)
        .onDisappear { recorder.cancel() }
    }

    private var generalPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsHeading("MAC", detail: "Desktop behavior and connected services.")
                VStack(spacing: 0) {
                    settingsToggleRow(
                        symbol: "macwindow.on.rectangle",
                        title: "Running in the background",
                        detail: "Keep playback active after the last Resonance window closes.",
                        isOn: $preferences.runInBackground
                    )
                    Rectangle().fill(Color.appLine).frame(height: 1)
                    settingsToggleRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: "Discord Rich Presence",
                        detail: preferences.discordStatus.message,
                        isOn: Binding(
                            get: { preferences.discordStatus.applicationConfigured && preferences.discordRichPresence },
                            set: { preferences.discordRichPresence = $0 }
                        ),
                        isEnabled: preferences.discordStatus.applicationConfigured
                    )
                }
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(Color.appLine) }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var keybindPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    settingsHeading("PLAYBACK", detail: "Choose a shortcut, then press its new key combination.")
                    Spacer()
                    Button("Reset defaults", action: preferences.resetKeybinds)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                VStack(spacing: 0) {
                    ForEach(Array(MacShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                        HStack(spacing: 13) {
                            Image(systemName: action == .togglePlayback ? "playpause" : action == .previousTrack ? "backward.end" : action == .nextTrack ? "forward.end" : action == .volumeDown ? "speaker.minus" : "speaker.plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appViolet)
                                .frame(width: 34, height: 34)
                                .background(Color.appViolet.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.appInk)
                                Text(action.detail).font(.system(size: 9)).foregroundStyle(Color.appMuted)
                            }
                            Spacer()
                            Button {
                                recorder.start(action) { shortcut in preferences.setKeybind(shortcut, for: action) }
                            } label: {
                                Text(recorder.recordingAction == action ? "Press keys…" : preferences.keybinds[action, default: "—"])
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .frame(minWidth: 92)
                                    .frame(height: 31)
                            }
                            .buttonStyle(.bordered)
                            .tint(recorder.recordingAction == action ? Color.appViolet : Color.appMuted)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 63)
                        if index < MacShortcutAction.allCases.count - 1 {
                            Rectangle().fill(Color.appLine).frame(height: 1)
                        }
                    }
                }
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(Color.appLine) }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private func settingsHeading(_ eyebrow: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.7)
                .foregroundStyle(Color.appViolet)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Color.appMuted)
        }
    }

    private func settingsToggleRow(
        symbol: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appViolet)
                .frame(width: 36, height: 36)
                .background(Color.appViolet.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.appInk)
                Text(detail).font(.system(size: 9)).foregroundStyle(Color.appMuted).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.appViolet)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
    }

}

private struct SidebarNavigationRow: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color(hex: 0xAEB4C3))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background {
                if isSelected {
                    LinearGradient(
                        colors: [Color.appViolet.opacity(0.26), Color.appViolet.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else if isHovering {
                    Color.white.opacity(0.055)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.appAccent)
                        .frame(width: 3, height: 28)
                        .offset(x: -12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: Playlist
    let tracks: [Track]
    let isSelected: Bool
    let deleteAction: (() -> Void)?
    let action: () -> Void
    @State private var isHovering = false
    @State private var confirmingDeletion = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                PlaylistArtworkView(
                    playlist: playlist,
                    tracks: tracks,
                    size: 39,
                    cornerRadius: 6
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appInk)
                        .lineLimit(1)
                    Text("Playlist / \(playlist.count) \(playlist.count == 1 ? "track" : "tracks")")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 55)
            .background {
                if isSelected {
                    Color.appViolet.opacity(0.11)
                } else if isHovering {
                    Color.white.opacity(0.045)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if deleteAction != nil {
                Button("Delete Playlist", role: .destructive) {
                    confirmingDeletion = true
                }
            }
        }
        .alert("Delete “\(playlist.name)”?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            if let deleteAction {
                Button("Delete Playlist", role: .destructive, action: deleteAction)
            }
        } message: {
            Text("The songs remain in your library. This playlist deletion will sync to your other devices.")
        }
    }
}
