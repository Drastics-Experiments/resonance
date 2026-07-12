import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var updateManager: UpdateManager
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 48)

            HStack(spacing: 10) {
                Text("M")
                    .font(.system(size: 15, weight: .heavy))
                    .frame(width: 29, height: 29)
                    .background {
                        LinearGradient(
                            colors: [Color(hex: 0x4D67FF), Color(hex: 0x9452ED)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("Resonance")
                    .font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)

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

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if updateManager.canInstall {
                        updateManager.installAndRestart()
                    } else if updateManager.hasUpdate {
                        Task { await updateManager.downloadUpdate() }
                    } else {
                        Task { await updateManager.checkForUpdates() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: updateManager.canInstall ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(updateButtonTitle)
                                .font(.system(size: 12, weight: .semibold))
                            Text(updateManager.status)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if updateManager.isBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(updateManager.isBusy)

                if let error = updateManager.errorMessage {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appCoral)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.bottom, 10)

        }
        .padding(.horizontal, 12)
        .background {
            LinearGradient(
                colors: [Color(hex: 0x0F1727).opacity(0.98), Color(hex: 0x070E19).opacity(0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { _ = model.createPlaylist(named: newPlaylistName) }
        } message: {
            Text("Create a playlist for songs in your local library.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMusicPlaylist)) { _ in
            newPlaylistName = ""
            showingNewPlaylist = true
        }
    }

    private var updateButtonTitle: String {
        if updateManager.canInstall { return "Restart to update" }
        if updateManager.hasUpdate { return "Download update" }
        return "Check for updates"
    }
}

struct MusicSettingsView: View {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var updateManager: UpdateManager
    @Environment(\.dismiss) private var dismiss

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { model.shuffleEnabled },
            set: { newValue in
                if newValue != model.shuffleEnabled { model.toggleShuffle() }
            }
        )
    }

    private var repeatBinding: Binding<Bool> {
        Binding(
            get: { model.repeatEnabled },
            set: { newValue in
                if newValue != model.repeatEnabled { model.toggleRepeat() }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Music Settings")
                        .font(.system(size: 22, weight: .bold))
                    Text("Playback and local library")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox("Playback") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                        Slider(value: $model.volume, in: 0...1)
                            .tint(Color.appCoral)
                        Text("\(Int(model.volume * 100))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                    Toggle("Shuffle", isOn: shuffleBinding)
                    Toggle("Repeat current track", isOn: repeatBinding)
                }
                .padding(8)
            }

            GroupBox("Local Library") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.tracks.count) \(model.tracks.count == 1 ? "song" : "songs")")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(model.customPlaylists.count) custom \(model.customPlaylists.count == 1 ? "playlist" : "playlists")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appMuted)
                    }
                    Spacer()
                    Button("Add Music…") { model.importLocalFiles() }
                }
                .padding(8)
            }

            GroupBox("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(updateManager.status)
                            .font(.system(size: 12, weight: .semibold))
                        if let error = updateManager.errorMessage {
                            Text(error)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appCoral)
                        }
                    }
                    Spacer()
                    Button(updateManager.canInstall ? "Restart to Update" : updateManager.hasUpdate ? "Download" : "Check Now") {
                        if updateManager.canInstall { updateManager.installAndRestart() }
                        else if updateManager.hasUpdate { Task { await updateManager.downloadUpdate() } }
                        else { Task { await updateManager.checkForUpdates() } }
                    }
                    .disabled(updateManager.isBusy)
                }
                .padding(8)
            }
        }
        .padding(24)
        .frame(width: 430, height: 460)
        .background(Color(hex: 0x0C1322))
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
            .background((isSelected || isHovering) ? Color.white.opacity(0.075) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.appCoral)
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
    let isSelected: Bool
    let deleteAction: (() -> Void)?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                MiniArtwork(
                    style: playlist.artwork,
                    symbol: playlist.artwork == .liked ? "heart.fill" : "music.note",
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
            .background((isSelected || isHovering) ? Color.white.opacity(0.055) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let deleteAction {
                Button("Delete Playlist", role: .destructive, action: deleteAction)
            }
        }
    }
}
