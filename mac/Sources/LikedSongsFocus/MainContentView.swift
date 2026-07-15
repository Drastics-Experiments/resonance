import AppKit
import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var serverSearchText = ""
    @State private var serverScope: MacServerScope = .all
    @State private var serverSort: MacServerSort = .title

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(
                serverSearchText: $serverSearchText,
                serverScope: $serverScope,
                serverSort: $serverSort
            )
                .frame(height: 82)

            if model.section == .storage {
                StorageView()
            } else if model.section == .server {
                ServerLibraryView(
                    searchText: $serverSearchText,
                    scope: $serverScope,
                    sort: $serverSort
                )
            } else if model.section == .playlists && model.selectedPlaylistID == nil {
                PlaylistsOverviewView()
            } else {
                CollectionView()
            }
        }
        .background {
            LinearGradient(
                colors: [Color(hex: 0x080910).opacity(0.68), Color.appBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }
}

private struct ServerLibraryView: View {
    @EnvironmentObject private var model: PlayerModel
    @Binding var searchText: String
    @Binding var scope: MacServerScope
    @Binding var sort: MacServerSort
    @State private var deletionCandidate: RemoteSong?
    @State private var presentedSheet: MacServerSheet?
    @State private var isSelecting = false
    @State private var scopeBeforeSelection: MacServerScope?

    private var isConnected: Bool {
        let status = model.serverMessage.lowercased()
        return !model.remoteSongs.isEmpty
            || status.hasPrefix("connected")
            || status.hasPrefix("synced")
    }

    private var syncedCount: Int {
        model.remoteSongs.reduce(0) { $0 + (model.isRemoteSongSynced($1) ? 1 : 0) }
    }

    private var allSynced: Bool {
        !model.remoteSongs.isEmpty && syncedCount == model.remoteSongs.count
    }

    private var serverAddress: String {
        let address = model.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? "Add a server connection" : address
    }

    private var visibleSongs: [RemoteSong] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.remoteSongs.filter { song in
            let matchesScope = switch scope {
            case .all: true
            case .onDevice: model.isRemoteSongSynced(song)
            case .notDownloaded: !model.isRemoteSongSynced(song)
            }
            let matchesSearch = query.isEmpty
                || song.title.localizedCaseInsensitiveContains(query)
                || song.artist.localizedCaseInsensitiveContains(query)
                || song.album.localizedCaseInsensitiveContains(query)
                || song.filename.localizedCaseInsensitiveContains(query)
            return matchesScope && matchesSearch
        }
        .sorted { lhs, rhs in
            switch sort {
            case .title:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .artist:
                lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
            case .fileSize:
                lhs.size > rhs.size
            case .recentlyUpdated:
                lhs.modifiedAt > rhs.modifiedAt
            }
        }
    }

    private var localTracksByRemoteID: [String: Track] {
        model.tracks.reduce(into: [:]) { result, track in
            guard let remoteID = track.remoteID, result[remoteID] == nil else { return }
            result[remoteID] = track
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let showAlbum = proxy.size.width >= 690

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Music Server")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .tracking(-1.7)
                        .padding(.bottom, 8)

                    serverStatusLine
                        .padding(.bottom, 32)

                    HStack(alignment: .center, spacing: 12) {
                        Text("SERVER LIBRARY")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(Color(hex: 0xD4D7E0))
                        Text("\(visibleSongs.count) \(visibleSongs.count == 1 ? "song" : "songs")")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appMuted)

                        if scope != .all {
                            Text(scope.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.appViolet)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Color.appViolet.opacity(0.12), in: Capsule())
                        }

                        Spacer(minLength: 8)

                        serverActions
                    }
                    .padding(.bottom, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.appLine).frame(height: 1)
                    }

                    MacServerCatalogHeader(showAlbum: showAlbum)

                    if visibleSongs.isEmpty {
                        ContentUnavailableView(
                            model.remoteSongs.isEmpty ? "No Server Songs" : "No Results",
                            systemImage: model.remoteSongs.isEmpty ? "network.slash" : "magnifyingglass",
                            description: Text(model.remoteSongs.isEmpty ? "Open the connection settings to load the server library." : "Try another search, filter, or sort option.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        LazyVStack(spacing: 0) {
                            let localTracks = localTracksByRemoteID
                            ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                                MacServerSongRow(
                                    song: song,
                                    number: index + 1,
                                    localTrack: localTracks[song.id],
                                    isSynced: model.isRemoteSongSynced(song),
                                    isSelecting: isSelecting,
                                    isSelected: model.selectedRemoteSongIDs.contains(song.id),
                                    showAlbum: showAlbum,
                                    onToggleSelection: { model.toggleRemoteSelection(song) },
                                    onDelete: { deletionCandidate = song }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack {
                    RadialGradient(
                        colors: [Color.appViolet.opacity(0.10), .clear],
                        center: UnitPoint(x: 0.83, y: 0.04),
                        startRadius: 10,
                        endRadius: 520
                    )
                    RadialGradient(
                        colors: [Color.appViolet.opacity(0.055), .clear],
                        center: UnitPoint(x: 0.48, y: 0.88),
                        startRadius: 10,
                        endRadius: 520
                    )
                }
            }
        }
        .alert(item: $deletionCandidate) { song in
            Alert(
                title: Text("Delete \(song.title) from the server?"),
                message: Text("Other devices will no longer be able to download this song. Existing local copies are not deleted."),
                primaryButton: .destructive(Text("Delete")) { model.deleteRemoteSong(song) },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection: MacServerConnectionSheet()
            }
        }
        .task {
            let hasServer = !model.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasToken = !model.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasServer,
                  hasToken,
                  !model.isSyncingServer,
                  !model.isUploadingServer,
                  !model.isSyncingPlaylists else { return }
            await model.refreshServerCatalogNow()
            await model.syncPlaylistsNow()
        }
    }

    private var serverStatusLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                connectionSummary
                serverMetrics
            }

            VStack(alignment: .leading, spacing: 10) {
                connectionSummary
                serverMetrics
            }
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 10) {
            Label(isConnected ? "Connected" : "Offline", systemImage: "circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isConnected ? Color(hex: 0x55D98B) : Color.appMuted)
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background((isConnected ? Color(hex: 0x55D98B) : Color.appMuted).opacity(0.12), in: Capsule())

            Button { presentedSheet = .connection } label: {
                HStack(spacing: 8) {
                    Text(serverAddress)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.appMuted)
            }
            .buttonStyle(.plain)
            .help("Edit server connection")
        }
    }

    private var serverMetrics: some View {
        HStack(spacing: 12) {
            Text("•").foregroundStyle(Color.appMuted)
            MacServerInlineMetric(symbol: "music.note", color: Color.appViolet, value: "\(model.remoteSongs.count)", label: "songs")
            Text("•").foregroundStyle(Color.appMuted)
            MacServerInlineMetric(symbol: "list.bullet", color: Color.appViolet, value: "\(model.customPlaylists.count)", label: "playlists")
            Text("•").foregroundStyle(Color.appMuted)
            MacServerInlineMetric(
                symbol: allSynced ? "checkmark" : "icloud.and.arrow.down",
                color: allSynced ? Color(hex: 0x55D98B) : Color.appAccent,
                value: "\(syncedCount)",
                label: "on device"
            )
        }
    }

    private var serverActions: some View {
        HStack(spacing: 10) {
            MacServerCircleActionButton(
                symbol: "square.and.arrow.up",
                label: "Upload songs",
                isDisabled: model.isUploadingServer || model.isSyncingServer,
                action: model.chooseSongsToUpload
            )

            MacServerCircleActionButton(
                symbol: "square.and.arrow.down",
                label: isSelecting ? "Download selected songs" : "Download all missing songs",
                isDisabled: model.isUploadingServer || model.isSyncingServer || (isSelecting && model.selectedRemoteSongIDs.isEmpty)
            ) {
                if isSelecting {
                    model.downloadSelectedServerSongs()
                    endSelectionMode()
                } else {
                    model.downloadAllServerSongs()
                }
            }

            MacServerCircleActionButton(
                symbol: "checklist",
                label: isSelecting ? "Cancel song selection" : "Select songs to download",
                valueText: isSelecting ? "\(model.selectedRemoteSongIDs.count)" : nil,
                isDisabled: model.isUploadingServer || model.isSyncingServer
            ) {
                if isSelecting {
                    endSelectionMode()
                } else {
                    withAnimation {
                        scopeBeforeSelection = scope
                        isSelecting = true
                        scope = .notDownloaded
                    }
                }
            }

            MacServerCircleActionButton(
                symbol: "arrow.clockwise",
                label: "Refresh catalog and sync playlists",
                isRotating: model.isRefreshingServerCatalog || model.isSyncingPlaylists,
                isDisabled: model.isUploadingServer || model.isSyncingServer || model.isSyncingPlaylists,
                action: model.refreshServerCatalog
            )
        }
    }

    private func endSelectionMode() {
        withAnimation {
            isSelecting = false
            model.selectedRemoteSongIDs.removeAll()
            if let scopeBeforeSelection {
                scope = scopeBeforeSelection
            }
            scopeBeforeSelection = nil
        }
    }
}

private enum MacServerSheet: String, Identifiable {
    case connection
    var id: String { rawValue }
}

private enum MacServerScope: String, CaseIterable, Identifiable {
    case all = "All"
    case onDevice = "On Device"
    case notDownloaded = "Not Downloaded"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .all: "music.note.list"
        case .onDevice: "checkmark.icloud"
        case .notDownloaded: "icloud.and.arrow.down"
        }
    }
}

private enum MacServerSort: String, CaseIterable, Identifiable {
    case title, artist, fileSize, recentlyUpdated
    var id: Self { self }
    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .fileSize: "File Size"
        case .recentlyUpdated: "Recently Updated"
        }
    }
    var symbol: String {
        switch self {
        case .title: "textformat"
        case .artist: "person"
        case .fileSize: "internaldrive"
        case .recentlyUpdated: "clock"
        }
    }
}

private struct MacServerInlineMetric: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: Circle())
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
            }
        }
    }
}

private struct MacServerCircleActionButton: View {
    let symbol: String
    let label: String
    var valueText: String? = nil
    var isRotating = false
    var isDisabled = false
    let action: () -> Void
    @State private var rotationDegrees = 0.0

    var body: some View {
        Button(action: action) {
            Group {
                if let valueText {
                    Text(valueText)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .rotationEffect(.degrees(rotationDegrees))
                }
            }
            .foregroundStyle(Color.appAccent)
            .frame(width: 42, height: 42)
            .background(Color.white.opacity(0.045), in: Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.035)) }
        }
        .buttonStyle(PressableScaleStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .help(label)
        .accessibilityLabel(label)
        .onChange(of: isRotating) { _, isRotating in
            guard isRotating else { return }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.8)) {
                rotationDegrees += 360
            }
        }
    }
}

private struct MacServerCatalogHeader: View {
    let showAlbum: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text("Title")
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
            if showAlbum {
                Text("Album")
                    .frame(width: 135, alignment: .leading)
            }
            Text("Time")
                .frame(width: 45, alignment: .leading)
            Color.clear.frame(width: 44)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(hex: 0x9299AA))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
    }
}

private struct MacServerSongRow: View {
    @EnvironmentObject private var model: PlayerModel
    let song: RemoteSong
    let number: Int
    let localTrack: Track?
    let isSynced: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let showAlbum: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var displayTitle: String {
        guard let localTrack, !localTrack.title.isEmpty else { return song.title }
        return localTrack.title
    }

    private var displayArtist: String {
        guard let localTrack, !localTrack.artist.isEmpty, localTrack.artist != "Unknown Artist" else { return song.artist }
        return localTrack.artist
    }

    private var displayAlbum: String {
        guard let localTrack, !localTrack.album.isEmpty, localTrack.album != "Server Library" else { return song.album }
        return localTrack.album
    }

    private var durationText: String {
        localTrack?.durationText ?? "—"
    }

    private var mediaKind: String {
        let type = song.contentType.lowercased()
        let fileExtension = URL(fileURLWithPath: song.filename).pathExtension.lowercased()
        return type.contains("video") || ["mp4", "mov", "m4v", "webm"].contains(fileExtension) ? "Video" : "Audio"
    }

    private var isCurrent: Bool {
        localTrack?.id == model.currentTrackID
    }

    private var isFavorite: Bool {
        guard let localTrack else { return false }
        return model.favorites.contains(localTrack.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: isSelecting ? onToggleSelection : primaryAction) {
                HStack(spacing: 10) {
                    Group {
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.appAccent : Color.appMuted)
                        } else if isCurrent && model.isPlaying {
                            EqualizerGlyph(isAnimating: true)
                        } else {
                            Text("\(number)")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xAEB4C2))
                    .frame(width: 28, alignment: .leading)

                    HStack(spacing: 12) {
                        Group {
                            if let localTrack {
                                TrackArtworkView(track: localTrack, symbolSize: 14, cornerRadius: 5)
                            } else {
                                MiniArtwork(
                                    style: .electric,
                                    symbol: mediaKind == "Video" ? "play.fill" : "music.note",
                                    size: 38,
                                    cornerRadius: 5
                                )
                            }
                        }
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Text(displayTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xF5F6FB))
                                    .lineLimit(1)

                                if isSynced {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color(hex: 0x55D98B))
                                        .help("On this Mac")
                                }
                            }

                            Text("\(displayArtist) / \(mediaKind)")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x8F96A7))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                    }
                    .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)

                    if showAlbum {
                        Text(displayAlbum)
                            .lineLimit(1)
                            .frame(width: 135, alignment: .leading)
                    }

                    Text(durationText)
                        .monospacedDigit()
                        .frame(width: 45, alignment: .leading)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xAEB4C2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 11) {
                if let localTrack {
                    Button {
                        model.toggleFavorite(localTrack)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundStyle(isFavorite ? Color.appAccent : Color(hex: 0xAEB4C2))
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Liked Songs" : "Add to Liked Songs")
                } else {
                    Button {
                        model.downloadServerSong(song)
                    } label: {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xAEB4C2))
                    }
                    .buttonStyle(.plain)
                    .help("Download")
                }
            }
            .frame(width: 44, alignment: .trailing)
            .opacity(isSelecting ? 0 : (isHovering || isCurrent || isFavorite || !isSynced ? 1 : 0))
            .allowsHitTesting(!isSelecting)
        }
        .padding(.horizontal, 10)
        .frame(height: 61)
        .background(isHovering || isSelected || isCurrent ? Color.white.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let localTrack {
                Button("Play", action: { model.selectAndPlay(localTrack) })
                Button("Show in Finder", action: { model.revealInFinder(localTrack) })
            } else {
                Button("Download", action: { model.downloadServerSong(song) })
            }
            Divider()
            Button("Delete from Server", role: .destructive, action: onDelete)
        }
    }

    private func primaryAction() {
        if let localTrack { model.selectAndPlay(localTrack) }
        else { model.downloadServerSong(song) }
    }
}

private struct MacServerConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Connection").font(.system(size: 22, weight: .bold))
                    Text("Credentials are stored securely for future launches.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            VStack(spacing: 12) {
                Label("Server URL", systemImage: "network").frame(maxWidth: .infinity, alignment: .leading)
                TextField("https://music.example.com", text: $model.serverURLString)
                    .textFieldStyle(.roundedBorder)
                Label("Access token", systemImage: "key.fill").frame(maxWidth: .infinity, alignment: .leading)
                SecureField("Server access token", text: $model.serverToken)
                    .textFieldStyle(.roundedBorder)
                Label("Admin key", systemImage: "key.horizontal.fill").frame(maxWidth: .infinity, alignment: .leading)
                SecureField("Required for uploads and deletion", text: $model.serverAdminToken)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.system(size: 11, weight: .semibold))

            HStack {
                Text(model.serverMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(2)
                Spacer()
                Button {
                    Task {
                        await model.refreshServerCatalogNow()
                        await model.syncPlaylistsNow()
                        if model.serverMessage.localizedCaseInsensitiveContains("connected") { dismiss() }
                    }
                } label: {
                    if model.isSyncingServer { ProgressView().controlSize(.small) }
                    else { Text("Connect") }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .disabled(model.isSyncingServer)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.appPanel)
    }
}

private struct PlaylistsOverviewView: View {
    @EnvironmentObject private var model: PlayerModel
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("YOUR COLLECTIONS")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.7)
                    .foregroundStyle(Color(hex: 0xA9AFBD))
                Text("Playlists")
                    .font(.system(size: 52, weight: .regular))
                    .tracking(-2.2)
                    .padding(.top, 6)
                Text("Organize your local music into collections.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
                    .padding(.top, 6)

                Button {
                    NotificationCenter.default.post(name: .newMusicPlaylist, object: nil)
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Color.appAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle())
                .padding(.top, 22)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.playlists) { playlist in
                        Button { model.selectPlaylist(playlist) } label: {
                            HStack(spacing: 12) {
                                MiniArtwork(
                                    style: playlist.artwork,
                                    symbol: playlist.isSystem ? "heart.fill" : "music.note",
                                    size: 58,
                                    cornerRadius: 9
                                )
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(playlist.count) \(playlist.count == 1 ? "track" : "tracks")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.appMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.appMuted)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.045))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).stroke(Color.appLine)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableScaleStyle())
                    }
                }
                .padding(.top, 30)
            }
            .padding(42)
        }
        .background {
            RadialGradient(
                colors: [Color.appViolet.opacity(0.20), .clear],
                center: UnitPoint(x: 0.72, y: 0.08),
                startRadius: 10,
                endRadius: 420
            )
        }
    }
}

private struct TopBarView: View {
    @EnvironmentObject private var model: PlayerModel
    @Binding var serverSearchText: String
    @Binding var serverScope: MacServerScope
    @Binding var serverSort: MacServerSort
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                CircleIconButton(
                    systemImage: "chevron.left",
                    label: "Back",
                    size: 36,
                    symbolSize: 15,
                    background: Color.white.opacity(0.055),
                    action: model.navigateBack
                )
                .disabled(!model.canNavigateBack)
                CircleIconButton(
                    systemImage: "chevron.right",
                    label: "Forward",
                    size: 36,
                    symbolSize: 15,
                    background: Color.white.opacity(0.055),
                    action: model.navigateForward
                )
                .disabled(!model.canNavigateForward)
            }

            if model.section == .server {
                serverSearchField
                serverSortMenu
                Spacer(minLength: 0)
            } else {
                librarySearchField
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .background(Color(hex: 0x050609).opacity(0.94))
        .background(.ultraThinMaterial.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusMusicSearch)) { _ in
            searchIsFocused = true
        }
    }

    private var librarySearchField: some View {
        searchField(
            placeholder: model.section == .playlists && model.selectedPlaylist != nil
                ? "Search \(model.selectedPlaylist?.name ?? "playlist")…"
                : "Search your music…",
            text: $model.searchText,
            showsShortcut: true
        )
        .frame(maxWidth: 460)
    }

    private var serverSearchField: some View {
        searchField(
            placeholder: "Search server library…",
            text: $serverSearchText,
            showsShortcut: false
        )
        .frame(maxWidth: 460)
    }

    private var serverSortMenu: some View {
        Menu {
            Section("Sort By") {
                ForEach(MacServerSort.allCases) { option in
                    Button {
                        serverSort = option
                    } label: {
                        Label(option.title, systemImage: serverSort == option ? "checkmark" : option.symbol)
                    }
                }
            }

            Section("Show") {
                ForEach(MacServerScope.allCases) { option in
                    Button {
                        serverScope = option
                    } label: {
                        Label(option.rawValue, systemImage: serverScope == option ? "checkmark" : option.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xC7CBD6))
                .frame(width: 39, height: 39)
                .background(Color.white.opacity(0.055), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.07)) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 39, height: 39)
        .help("Sort and filter server library")
    }

    private func searchField(
        placeholder: String,
        text: Binding<String>,
        showsShortcut: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x8E96A8))

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .focused($searchIsFocused)

            if showsShortcut {
                Text("⌘ K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x8C93A2))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 39)
        .background(Color.white.opacity(0.075), in: Capsule())
        .overlay { Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1) }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct CollectionView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var playlistForSongPicker: Playlist?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    CollectionHeroView(onAddSongs: presentSongPicker)
                        .frame(height: 310)

                    TrackAreaView(
                        showAlbum: proxy.size.width >= 535,
                        showHelperText: proxy.size.width > 560,
                        onAddSongs: presentSongPicker
                    )
                    .frame(minHeight: max(proxy.size.height - 310, 360), alignment: .top)
                }
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $playlistForSongPicker) { playlist in
            MacPlaylistSongPicker(playlistID: playlist.id)
        }
    }

    private func presentSongPicker() {
        guard let playlist = model.selectedPlaylist, !playlist.isSystem else { return }
        playlistForSongPicker = playlist
    }
}

private struct CollectionHeroView: View {
    @EnvironmentObject private var model: PlayerModel
    let onAddSongs: () -> Void

    private var isLikedCollection: Bool { model.collectionTitle == "Liked Songs" }
    private var canAddSongs: Bool {
        model.section == .playlists && model.selectedPlaylist?.isSystem == false
    }

    private var symbol: String {
        isLikedCollection ? "heart.fill" : "music.note"
    }

    private func addSongs() {
        if canAddSongs {
            onAddSongs()
        } else {
            model.importLocalFiles()
        }
    }

    private func showMoreMenu() {
        guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Import Songs…", action: model.importLocalFiles))
        menu.addItem(ClosureMenuItem(title: "Next Track", action: model.next))
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: contentView)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x08090E), Color(hex: 0x09080F), Color(hex: 0x07070B)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                RadialGradient(
                    colors: [Color.appViolet.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.12, y: 0.20),
                    startRadius: 10,
                    endRadius: 270
                )

                RadialGradient(
                    colors: [Color.appAccent.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.72, y: 0.70),
                    startRadius: 8,
                    endRadius: 260
                )

                HStack(spacing: proxy.size.width < 620 ? 24 : 32) {
                    ArtworkView(
                        style: model.collectionArtwork,
                        symbol: symbol,
                        symbolSize: proxy.size.width < 550 ? 54 : 70,
                        cornerRadius: 9,
                        glow: true
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: proxy.size.width < 550 ? 202 : 232)
                    .shadow(color: Color(hex: 0x1F1B6F).opacity(0.42), radius: 28, y: 18)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(isLikedCollection ? "YOUR COLLECTION" : "PLAYLIST")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.7)
                            .foregroundStyle(Color(hex: 0xB7BBCC))
                            .padding(.bottom, 10)

                        Text(model.collectionTitle)
                            .font(.system(size: model.collectionTitle.count > 13 ? 48 : 58, weight: .regular))
                            .tracking(-2.2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)

                        Text("\(model.collectionTrackCount) \(model.collectionTrackCount == 1 ? "track" : "tracks") / Stored locally")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xADB2C1))

                        HStack(spacing: 16) {
                            Button(action: model.toggleCollectionPlayback) {
                                HStack(spacing: 10) {
                                    Image(systemName: model.isCollectionPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text(model.isCollectionPlaying ? "Pause" : "Play")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .frame(width: 128, height: 48)
                                .background(Color.appAccent)
                                .clipShape(Capsule())
                                .shadow(color: Color.appAccent.opacity(0.18), radius: 18, y: 9)
                            }
                            .buttonStyle(PressableScaleStyle())
                            .disabled(model.collectionTrackCount == 0)
                            .opacity(model.collectionTrackCount == 0 ? 0.55 : 1)

                            HStack(spacing: 8) {
                                CircleIconButton(
                                    systemImage: "shuffle",
                                    label: "Shuffle",
                                    size: 34,
                                    symbolSize: 14,
                                    background: .clear,
                                    hoverBackground: Color.white.opacity(0.12),
                                    isActive: model.shuffleEnabled,
                                    showsActiveBackground: false,
                                    action: model.toggleShuffle
                                )

                                CircleIconButton(
                                    systemImage: "plus",
                                    label: "Add Songs",
                                    size: 34,
                                    symbolSize: 15,
                                    background: .clear,
                                    hoverBackground: Color.white.opacity(0.12),
                                    action: addSongs
                                )

                                CircleIconButton(
                                    systemImage: "ellipsis",
                                    label: "More",
                                    size: 34,
                                    symbolSize: 14,
                                    background: .clear,
                                    hoverBackground: Color.white.opacity(0.12),
                                    action: showMoreMenu
                                )
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color(hex: 0x1D1D29).opacity(0.98), in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .padding(.top, 32)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        self.action = #selector(performAction)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction() {
        handler()
    }
}

private struct TrackAreaView: View {
    @EnvironmentObject private var model: PlayerModel
    let showAlbum: Bool
    let showHelperText: Bool
    let onAddSongs: () -> Void
    @State private var draggedTrackID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dropPreviewIndex: Int?

    private var reorderablePlaylistID: UUID? {
        guard model.section == .playlists,
              let playlist = model.selectedPlaylist else { return nil }
        return playlist.id
    }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 9) {
                    ForEach(SongFilter.allCases) { filter in
                        Button {
                            model.filter = filter
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(model.filter == filter ? Color.white : Color(hex: 0xAEB3C1))
                                .padding(.horizontal, 15)
                                .frame(height: 34)
                                .background {
                                    if model.filter == filter {
                                        LinearGradient(
                                            colors: [Color(hex: 0x4D67FF), Color(hex: 0x8A42EB)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    } else {
                                        Color.white.opacity(0.06)
                                    }
                                }
                                .clipShape(Capsule())
                                .shadow(
                                    color: model.filter == filter ? Color(hex: 0x5B4AFF).opacity(0.30) : .clear,
                                    radius: 12,
                                    y: 6
                                )
                        }
                        .buttonStyle(PressableScaleStyle())
                    }

                    Spacer(minLength: 4)

                    if showHelperText {
                        Text("Desktop app plays your local files")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(hex: 0x7F8796))
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 10)

                TrackHeaderRow(showAlbum: showAlbum)

                if model.unfilteredCollectionTracks.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: model.selectedPlaylist?.isSystem == false ? "music.note.list" : (model.section == .playlists ? "heart" : "music.note.house"))
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.appViolet)
                        Text(model.section == .playlists ? "This playlist is empty" : "Build your music library")
                            .font(.system(size: 17, weight: .semibold))
                        Text(model.selectedPlaylist?.isSystem == true
                            ? "Heart songs in your Library to add them to Liked Songs."
                            : (model.section == .playlists
                                ? "Add songs from your library to this playlist."
                                : "Add audio files or an entire folder. Music stays on this Mac."))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appMuted)
                        if model.selectedPlaylist?.isSystem == false {
                            Button(action: onAddSongs) {
                                Label("Add Songs", systemImage: "plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(Color.appAccent)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(PressableScaleStyle())
                        } else if model.section != .playlists {
                            Button(action: model.importLocalFiles) {
                                Label("Add Music", systemImage: "plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(Color.appAccent)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(PressableScaleStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.displayedTracks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                        Text(model.hasActiveLibraryFilter ? "No songs match the current search or filter." : "No songs to show.")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color.appMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.displayedTracks.enumerated()), id: \.element.id) { index, track in
                            let row = TrackRowView(
                                track: track,
                                number: index + 1,
                                showAlbum: showAlbum
                            )
                            let previewEdge = playlistDropPreviewEdge(for: track.id)

                            if let playlistID = reorderablePlaylistID {
                                row
                                    .frame(height: draggedTrackID == track.id ? 0 : 61)
                                    .padding(
                                        .top,
                                        previewEdge == .top ? 61 : 0
                                    )
                                    .padding(
                                        .bottom,
                                        previewEdge == .bottom ? 61 : 0
                                    )
                                    .overlay(alignment: .top) {
                                        if previewEdge == .top {
                                            playlistDropPreview(number: dropPreviewNumber)
                                                .transition(.move(edge: .top).combined(with: .opacity))
                                        }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if previewEdge == .bottom {
                                            playlistDropPreview(number: dropPreviewNumber)
                                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                        }
                                    }
                                    .animation(.spring(response: 0.24, dampingFraction: 0.84), value: dropPreviewIndex)
                                    .offset(y: draggedTrackID == track.id ? draggedRowOffset : 0)
                                    .scaleEffect(draggedTrackID == track.id ? 1.015 : 1)
                                    .shadow(
                                        color: draggedTrackID == track.id ? Color.black.opacity(0.38) : .clear,
                                        radius: draggedTrackID == track.id ? 12 : 0,
                                        y: draggedTrackID == track.id ? 6 : 0
                                    )
                                    .zIndex(draggedTrackID == track.id ? 2 : 0)
                                    .animation(.easeOut(duration: 0.12), value: draggedTrackID)
                                    .highPriorityGesture(
                                        DragGesture(minimumDistance: 5)
                                            .onChanged { value in
                                                updatePlaylistDrag(
                                                    trackID: track.id,
                                                    translation: value.translation.height
                                                )
                                            }
                                            .onEnded { _ in
                                                finishPlaylistDrag(trackID: track.id, playlistID: playlistID)
                                            }
                                    )
                            } else {
                                row
                            }
                        }
                    }
                    .animation(
                        .spring(response: 0.26, dampingFraction: 0.86),
                        value: model.displayedTracks.map(\.id)
                    )
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private func playlistDropPreview(number: Int) -> some View {
        if let draggedTrackID,
           let draggedTrack = model.displayedTracks.first(where: { $0.id == draggedTrackID }) {
            TrackRowView(
                track: draggedTrack,
                number: number,
                showAlbum: showAlbum
            )
            .opacity(0.32)
            .scaleEffect(0.985)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var dropPreviewNumber: Int {
        (dropPreviewIndex ?? 0) + 1
    }

    private var draggedRowOffset: CGFloat {
        guard let draggedTrackID,
              let sourceIndex = model.displayedTracks.firstIndex(where: { $0.id == draggedTrackID })
        else { return dragOffset + 30.5 }
        let layoutCompensation: CGFloat = (dropPreviewIndex ?? sourceIndex) < sourceIndex ? -61 : 0
        return dragOffset + 30.5 + layoutCompensation
    }

    private func playlistDropPreviewEdge(for trackID: UUID) -> PlaylistTrackDropEdge? {
        guard let draggedTrackID,
              let dropPreviewIndex
        else { return nil }

        let remainingTracks = model.displayedTracks.filter { $0.id != draggedTrackID }
        if remainingTracks.isEmpty {
            return trackID == draggedTrackID ? .top : nil
        }
        if dropPreviewIndex < remainingTracks.count {
            return remainingTracks[dropPreviewIndex].id == trackID ? .top : nil
        }
        return remainingTracks.last?.id == trackID ? .bottom : nil
    }

    private func updatePlaylistDrag(trackID: UUID, translation: CGFloat) {
        if draggedTrackID == nil {
            draggedTrackID = trackID
        }
        guard draggedTrackID == trackID else { return }

        dragOffset = translation
        let visibleTrackIDs = model.displayedTracks.map(\.id)
        guard let sourceIndex = visibleTrackIDs.firstIndex(of: trackID), !visibleTrackIDs.isEmpty else { return }
        let destinationIndex = min(
            max(Int((CGFloat(sourceIndex) + (translation / 61)).rounded()), visibleTrackIDs.startIndex),
            visibleTrackIDs.index(before: visibleTrackIDs.endIndex)
        )
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            dropPreviewIndex = destinationIndex
        }
    }

    private func finishPlaylistDrag(trackID: UUID, playlistID: UUID) {
        guard draggedTrackID == trackID else { return }
        let destinationIndex = dropPreviewIndex
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if let destinationIndex {
                model.moveTrack(trackID, to: destinationIndex, in: playlistID)
            }
            draggedTrackID = nil
            dragOffset = 0
            dropPreviewIndex = nil
        }
    }
}

private enum PlaylistTrackDropEdge: Equatable {
    case top
    case bottom
}

private struct MacPlaylistSongPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: PlayerModel
    let playlistID: UUID
    @State private var searchText = ""

    private var playlist: Playlist? {
        model.playlists.first { $0.id == playlistID }
    }

    private var visibleTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.tracks }
        return model.tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query)
                || track.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Songs")
                        .font(.system(size: 22, weight: .bold))
                    Text(playlist?.name ?? "Playlist")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
                TextField("Search songs, artists, or albums…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.appMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.appLine)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            Rectangle().fill(Color.appLine).frame(height: 1)

            if model.tracks.isEmpty {
                ContentUnavailableView(
                    "No Songs in Your Library",
                    systemImage: "music.note",
                    description: Text("Import or download songs before adding them to a playlist.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleTracks) { track in
                            let isAdded = playlist?.trackIDs.contains(track.id) == true
                            Button {
                                guard let playlist else { return }
                                if isAdded {
                                    model.removeTrack(track, from: playlist.id)
                                } else {
                                    model.addTrack(track, to: playlist)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    TrackArtworkView(
                                        track: track,
                                        symbol: track.kind == .video ? "play.fill" : "music.note",
                                        cornerRadius: 6
                                    )
                                    .frame(width: 42, height: 42)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.appInk)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.appMuted)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 12)

                                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(isAdded ? Color.appAccent : Color.appMuted)
                                }
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.appLine).frame(height: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 600, height: 600)
        .background(Color.appBackground)
    }
}

private struct TrackHeaderRow: View {
    let showAlbum: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("#").frame(width: 28, alignment: .leading)
            Text("Title").frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
            if showAlbum {
                Text("Album").frame(width: 135, alignment: .leading)
            }
            Text("Time").frame(width: 45, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(hex: 0x8E94A4))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
    }
}

private struct TrackRowView: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    let number: Int
    let showAlbum: Bool
    @State private var hovering = false
    @State private var confirmingLibraryRemoval = false

    private var isCurrent: Bool { model.currentTrackID == track.id }
    private var isFavorite: Bool { model.favorites.contains(track.id) }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent && model.isPlaying {
                    EqualizerGlyph(isAnimating: true)
                } else {
                    Text("\(number)")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color(hex: 0xAEB4C2))
            .frame(width: 28, alignment: .leading)

            HStack(spacing: 12) {
                TrackArtworkView(
                    track: track,
                    symbol: track.kind == .video ? "play.fill" : "music.note",
                    cornerRadius: 5
                )
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF5F6FB))
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(Color.appAccent)
                        }
                    }

                    Text("\(track.artist) / \(track.kind == .video ? "Video" : "Audio")")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0x8F96A7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xAEB4C2))
                    .lineLimit(1)
                    .frame(width: 135, alignment: .leading)
            }

            Text(track.durationText)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xAEB4C2))
                .frame(width: 45, alignment: .leading)

            Button {
                model.toggleFavorite(track)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 10))
                    .foregroundStyle(isFavorite ? Color.appAccent : Color(hex: 0xAEB4C2))
            }
            .buttonStyle(.plain)
            .frame(width: 44, alignment: .trailing)
            .opacity(hovering || isCurrent ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 61)
        .background((hovering || isCurrent) ? Color.white.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectAndPlay(track) }
        .onHover { hovering = $0 }
        .contextMenu {
            if model.customPlaylists.isEmpty {
                Button("Create a playlist first") {
                    NotificationCenter.default.post(name: .newMusicPlaylist, object: nil)
                }
            } else {
                Menu("Add to Playlist") {
                    ForEach(model.customPlaylists) { playlist in
                        Button(playlist.name) { model.addTrack(track, to: playlist) }
                    }
                }
            }

            Button("Show in Finder") { model.revealInFinder(track) }
            Divider()

            if let selected = model.selectedPlaylist, model.section == .playlists {
                if selected.isSystem {
                    Button("Remove from Liked Songs", role: .destructive) {
                        model.toggleFavorite(track)
                    }
                } else {
                    Button("Remove from \(selected.name)", role: .destructive) {
                        model.removeTrackFromSelectedPlaylist(track)
                    }
                }
            } else {
                Button("Remove from Library", role: .destructive) {
                    confirmingLibraryRemoval = true
                }
            }
        }
        .alert("Remove “\(track.title)”?", isPresented: $confirmingLibraryRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { model.removeTrackFromLibrary(track) }
        } message: {
            Text("This removes the song from the app and its playlists. The original audio file will not be deleted.")
        }
    }
}

private struct StorageView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var searchText = ""
    @State private var scope: MacStorageScope = .songs
    @State private var sort: MacStorageSort = .title
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var fileSizes: [UUID: Int64] = [:]
    @State private var availableBytes: Int64 = 0
    @State private var deletionCandidate: Track?
    @State private var confirmsBatchDeletion = false

    private var visibleTracks: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.tracks.filter { track in
            let matchesScope = switch scope {
            case .songs: true
            case .downloads: track.remoteID != nil
            case .files: track.remoteID == nil
            }
            let matchesSearch = query.isEmpty
                || track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query)
                || track.album.localizedCaseInsensitiveContains(query)
                || (track.fileURL?.lastPathComponent.localizedCaseInsensitiveContains(query) ?? false)
            return matchesScope && matchesSearch
        }
        .sorted { lhs, rhs in
            switch sort {
            case .title:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .artist:
                lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
            case .recentlyAdded:
                lhs.dateAdded > rhs.dateAdded
            case .fileSize:
                fileSizes[lhs.id, default: 0] > fileSizes[rhs.id, default: 0]
            }
        }
    }

    private var downloadedTracks: [Track] { visibleTracks.filter { $0.remoteID != nil } }
    private var importedTracks: [Track] { visibleTracks.filter { $0.remoteID == nil } }
    private var downloadedBytes: Int64 {
        model.tracks.filter { $0.remoteID != nil }.reduce(0) { $0 + fileSizes[$1.id, default: 0] }
    }
    private var importedBytes: Int64 {
        model.tracks.filter { $0.remoteID == nil }.reduce(0) { $0 + fileSizes[$1.id, default: 0] }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Song Storage")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                    Spacer()
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation {
                            isEditing.toggle()
                            if !isEditing { selectedTrackIDs.removeAll() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.tracks.isEmpty)
                    Button(action: model.importLocalFiles) {
                        Label("Import Songs", systemImage: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(Color.appAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                MacStorageSummaryCard(
                    importedBytes: importedBytes,
                    importedCount: model.tracks.filter { $0.remoteID == nil }.count,
                    downloadedBytes: downloadedBytes,
                    downloadedCount: model.tracks.filter { $0.remoteID != nil }.count,
                    availableBytes: availableBytes
                )

                HStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.appMuted)
                        TextField("Search songs, artists, albums, files…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.appLine) }

                    Menu {
                        Section("Sort By") {
                            ForEach(MacStorageSort.allCases) { option in
                                Button { sort = option } label: {
                                    Label(option.title, systemImage: sort == option ? "checkmark.circle.fill" : option.symbol)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 40)
                    .help("Sort stored songs")
                }

                MacStorageScopePicker(scope: $scope)

                if isEditing, !selectedTrackIDs.isEmpty {
                    HStack {
                        Text("\(selectedTrackIDs.count) selected")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button("Delete Selected", role: .destructive) { confirmsBatchDeletion = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 4)
                }

                if visibleTracks.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? scope.emptyTitle : "No Results",
                        systemImage: searchText.isEmpty ? scope.symbol : "magnifyingglass",
                        description: Text(searchText.isEmpty ? scope.emptyMessage : "Try another search or storage filter.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    if !downloadedTracks.isEmpty {
                        MacStorageSection(
                            title: "DOWNLOADED FROM SERVER",
                            symbol: "icloud.and.arrow.down",
                            tracks: downloadedTracks,
                            fileSizes: fileSizes,
                            showAlbum: proxy.size.width >= 690,
                            isEditing: isEditing,
                            selectedTrackIDs: $selectedTrackIDs,
                            deletionCandidate: $deletionCandidate
                        )
                    }

                    if !importedTracks.isEmpty {
                        MacStorageSection(
                            title: "IMPORTED ON THIS MAC",
                            symbol: "desktopcomputer",
                            tracks: importedTracks,
                            fileSizes: fileSizes,
                            showAlbum: proxy.size.width >= 690,
                            isEditing: isEditing,
                            selectedTrackIDs: $selectedTrackIDs,
                            deletionCandidate: $deletionCandidate
                        )
                    }
                }
                }
                .padding(34)
            }
            .background {
                RadialGradient(
                    colors: [Color.appViolet.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.72, y: 0.06),
                    startRadius: 10,
                    endRadius: 360
                )
            }
        }
        .task(id: model.tracks.map(\.id)) {
            refreshStorageMetrics()
            selectedTrackIDs.formIntersection(Set(model.tracks.map(\.id)))
        }
        .alert(item: $deletionCandidate) { track in
            Alert(
                title: Text(track.remoteID == nil ? "Delete original file?" : "Delete downloaded copy?"),
                message: Text(track.remoteID == nil
                    ? "This permanently deletes \(track.title) from this Mac."
                    : "This removes the cached copy from this Mac. The song remains available on the music server."),
                primaryButton: .destructive(Text("Delete")) { delete(track) },
                secondaryButton: .cancel()
            )
        }
        .alert("Delete \(selectedTrackIDs.count) selected files?", isPresented: $confirmsBatchDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Files", role: .destructive) {
                let selected = model.tracks.filter { selectedTrackIDs.contains($0.id) }
                selected.forEach(delete)
                selectedTrackIDs.removeAll()
                isEditing = false
            }
        } message: {
            Text("Imported originals will be permanently deleted. Server downloads remain available to download again.")
        }
    }

    private func delete(_ track: Track) {
        track.remoteID == nil ? model.deleteOriginalFile(track) : model.deleteDownloadedCopy(track)
    }

    private func refreshStorageMetrics() {
        fileSizes = Dictionary(uniqueKeysWithValues: model.tracks.map { ($0.id, model.fileSize(for: $0)) })
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0)
    }
}

private enum MacStorageScope: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case downloads = "Downloads"
    case files = "Files"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .songs: "music.note.list"
        case .downloads: "icloud.and.arrow.down"
        case .files: "desktopcomputer"
        }
    }
    var emptyTitle: String {
        switch self {
        case .songs: "No Stored Songs"
        case .downloads: "No Downloads"
        case .files: "No Imported Files"
        }
    }
    var emptyMessage: String {
        switch self {
        case .songs: "Import audio or download songs from your music server."
        case .downloads: "Songs downloaded from the server will appear here."
        case .files: "Audio imported on this Mac will appear here."
        }
    }
}

private enum MacStorageSort: String, CaseIterable, Identifiable {
    case title, artist, recentlyAdded, fileSize
    var id: Self { self }
    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .recentlyAdded: "Recently Added"
        case .fileSize: "File Size"
        }
    }
    var symbol: String {
        switch self {
        case .title: "textformat"
        case .artist: "person"
        case .recentlyAdded: "clock"
        case .fileSize: "internaldrive"
        }
    }
}

private struct MacStorageScopePicker: View {
    @Binding var scope: MacStorageScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MacStorageScope.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { scope = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .foregroundStyle(scope == option ? Color.white : Color.appMuted)
                        .background(scope == option ? Color.appAccent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.appLine) }
    }
}

private struct MacStorageSummaryCard: View {
    let importedBytes: Int64
    let importedCount: Int
    let downloadedBytes: Int64
    let downloadedCount: Int
    let availableBytes: Int64

    private var totalUsedBytes: Int64 { importedBytes + downloadedBytes }
    private var usedBytes: Double { max(Double(totalUsedBytes), 1) }
    private var importedEnd: Double { Double(importedBytes) / usedBytes }

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 14)
                if importedBytes > 0 {
                    Circle()
                        .trim(from: 0, to: importedEnd)
                        .stroke(Color.appViolet, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                if downloadedBytes > 0 {
                    Circle()
                        .trim(from: importedEnd, to: 1)
                        .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "internaldrive").foregroundStyle(Color.appMuted)
            }
            .frame(width: 96, height: 96)

            MacStorageMetric(color: Color.appViolet, title: "Local audio", bytes: importedBytes, detail: "\(importedCount) files")
            Divider().frame(height: 70)
            MacStorageMetric(color: Color.appAccent, title: "Server downloads", bytes: downloadedBytes, detail: "\(downloadedCount) files")
            Divider().frame(height: 70)
            MacStorageMetric(color: Color(hex: 0x7BA7E8), title: "Available", bytes: availableBytes, detail: "on this Mac")
            Spacer()
        }
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(LinearGradient(colors: [Color.appViolet.opacity(0.8), Color(hex: 0x6C9CD8).opacity(0.55)], startPoint: .leading, endPoint: .trailing))
        }
    }
}

private struct MacStorageMetric: View {
    let color: Color
    let title: String
    let bytes: Int64
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            Text(storageByteText(bytes)).font(.system(size: 16, weight: .semibold))
            Text(detail).font(.system(size: 9)).foregroundStyle(Color.appMuted)
        }
        .frame(minWidth: 120, alignment: .leading)
    }
}

private struct MacStorageSection: View {
    let title: String
    let symbol: String
    let tracks: [Track]
    let fileSizes: [UUID: Int64]
    let showAlbum: Bool
    let isEditing: Bool
    @Binding var selectedTrackIDs: Set<UUID>
    @Binding var deletionCandidate: Track?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appViolet)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color(hex: 0xD4D7E0))
                Spacer()
                Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)

            MacStorageCatalogHeader(showAlbum: showAlbum)

            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    MacStorageTrackRow(
                        track: track,
                        number: index + 1,
                        fileSize: fileSizes[track.id, default: 0],
                        showAlbum: showAlbum,
                        isEditing: isEditing,
                        isSelected: selectedTrackIDs.contains(track.id),
                        onToggleSelection: {
                            if selectedTrackIDs.contains(track.id) { selectedTrackIDs.remove(track.id) }
                            else { selectedTrackIDs.insert(track.id) }
                        },
                        onDelete: { deletionCandidate = track }
                    )
                }
            }
        }
    }
}

private struct MacStorageCatalogHeader: View {
    let showAlbum: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text("Title")
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
            if showAlbum {
                Text("Album")
                    .frame(width: 135, alignment: .leading)
            }
            Text("Size")
                .frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 44)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(hex: 0x8E94A4))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
    }
}

private struct MacStorageTrackRow: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    let number: Int
    let fileSize: Int64
    let showAlbum: Bool
    let isEditing: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var isCurrent: Bool { model.currentTrackID == track.id }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: isEditing ? onToggleSelection : { model.selectAndPlay(track) }) {
                HStack(spacing: 10) {
                    Group {
                        if isEditing {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.appAccent : Color.appMuted)
                        } else if isCurrent && model.isPlaying {
                            EqualizerGlyph(isAnimating: true)
                        } else {
                            Text("\(number)")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xAEB4C2))
                    .frame(width: 28, alignment: .leading)

                    HStack(spacing: 12) {
                        TrackArtworkView(
                            track: track,
                            symbol: track.kind == .video ? "play.fill" : "music.note",
                            cornerRadius: 5
                        )
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(track.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xF5F6FB))
                                    .lineLimit(1)

                                Image(systemName: track.remoteID == nil ? "desktopcomputer" : "checkmark.circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(track.remoteID == nil ? Color(hex: 0x7BA7E8) : Color(hex: 0x55D98B))
                                    .help(track.remoteID == nil ? "Imported on this Mac" : "Downloaded from server")
                            }

                            Text("\(track.artist) / \(track.kind == .video ? "Video" : "Audio")")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x8F96A7))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)

                    if showAlbum {
                        Text(track.album)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xAEB4C2))
                            .lineLimit(1)
                            .frame(width: 135, alignment: .leading)
                    }

                    Text(storageByteText(fileSize))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xAEB4C2))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .padding(.horizontal, 10)
        .frame(height: 61)
        .background((isHovering || isCurrent || isSelected) ? Color.white.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play", action: { model.selectAndPlay(track) })
            Button("Show in Finder", action: { model.revealInFinder(track) })
            Divider()
            Button(track.remoteID == nil ? "Delete Original File" : "Delete Downloaded Copy", role: .destructive, action: onDelete)
        }
    }
}

private func storageByteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension Notification.Name {
    static let focusMusicSearch = Notification.Name("focusMusicSearch")
    static let newMusicPlaylist = Notification.Name("newMusicPlaylist")
}
