import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()
                .frame(height: 82)

            if model.section == .storage {
                StorageView()
            } else if model.section == .server {
                ServerLibraryView()
            } else if model.section == .playlists && model.selectedPlaylistID == nil {
                PlaylistsOverviewView()
            } else {
                CollectionView()
            }
        }
        .background {
            LinearGradient(
                colors: [Color(hex: 0x121730).opacity(0.40), Color(hex: 0x060D17).opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }
}

private struct ServerLibraryView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var deletionCandidate: RemoteSong?
    @State private var presentedSheet: MacServerSheet?
    @State private var searchText = ""
    @State private var scope: MacServerScope = .all
    @State private var sort: MacServerSort = .title
    @State private var isSelecting = false

    private var isConnected: Bool {
        !model.remoteSongs.isEmpty
            || model.serverMessage.localizedCaseInsensitiveContains("connected")
            || model.serverMessage.localizedCaseInsensitiveContains("synced")
    }

    private var syncedCount: Int {
        model.remoteSongs.reduce(0) { $0 + (model.isRemoteSongSynced($1) ? 1 : 0) }
    }

    private var allSynced: Bool {
        !model.remoteSongs.isEmpty && syncedCount == model.remoteSongs.count
    }

    private var serverHost: String {
        URL(string: model.serverURLString)?.host ?? model.serverURLString
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Music Server")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .tracking(-1.2)
                        HStack(spacing: 10) {
                            Label(isConnected ? "Connected" : "Not Connected", systemImage: "circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isConnected ? Color(hex: 0x55D98B) : Color.appMuted)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background((isConnected ? Color(hex: 0x55D98B) : Color.appMuted).opacity(0.12), in: Capsule())
                            Text(serverHost.isEmpty ? "No server configured" : serverHost)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appMuted)
                        }
                    }
                    Spacer()
                    Button(action: model.refreshServerCatalog) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSyncingServer || model.isUploadingServer)
                    .help("Refresh server catalog")
                }

                Button { presentedSheet = .connection } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "globe")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.appViolet)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection").font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 8) {
                                Text(model.serverURLString.isEmpty ? "No server URL" : model.serverURLString).lineLimit(1)
                                Text("•")
                                Image(systemName: "key.fill")
                                Text(model.serverToken.isEmpty ? "Not configured" : "•••• •••• ••••")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appMuted)
                        }
                        Spacer()
                        Image(systemName: "gearshape")
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                    .overlay { RoundedRectangle(cornerRadius: 13).stroke(Color.appLine) }
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    MacServerMetric(symbol: "music.note", color: Color.appCoral, value: "\(model.remoteSongs.count)", label: "songs")
                    MacServerMetric(symbol: "list.bullet", color: Color.appViolet, value: "\(model.customPlaylists.count)", label: "playlists")
                    MacServerMetric(
                        symbol: allSynced ? "checkmark.circle" : "icloud.and.arrow.down",
                        color: allSynced ? Color(hex: 0x55D98B) : Color.appCoral,
                        value: allSynced ? "All" : "\(syncedCount)/\(model.remoteSongs.count)",
                        label: "synced"
                    )
                    Spacer(minLength: 12)
                    Button(action: model.chooseSongsToUpload) {
                        Label(model.isUploadingServer ? "Uploading…" : "Upload", systemImage: "icloud.and.arrow.up")
                            .macServerActionButton()
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isUploadingServer || model.isSyncingServer)
                    Button {
                        if model.selectedRemoteSongIDs.isEmpty {
                            withAnimation { isSelecting = true; scope = .notDownloaded }
                        } else {
                            model.downloadSelectedServerSongs()
                            isSelecting = false
                        }
                    } label: {
                        Label(model.selectedRemoteSongIDs.isEmpty ? "Download" : "Get \(model.selectedRemoteSongIDs.count)", systemImage: "icloud.and.arrow.down")
                            .macServerActionButton()
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isUploadingServer || model.isSyncingServer)
                }

                HStack(spacing: 10) {
                    ServerTransferRow(
                        title: "Downloads",
                        icon: "arrow.down.circle.fill",
                        color: Color.appCoral,
                        isActive: model.isSyncingServer,
                        progress: model.downloadProgress,
                        currentFile: model.downloadCurrentFile,
                        status: model.downloadStatus
                    )
                    ServerTransferRow(
                        title: "Uploads",
                        icon: "arrow.up.circle.fill",
                        color: Color.appViolet,
                        isActive: model.isUploadingServer,
                        progress: model.uploadProgress,
                        currentFile: model.uploadCurrentFile,
                        status: model.uploadStatus
                    )
                }

                HStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.appMuted)
                        TextField("Search server library", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.appLine) }

                    Menu {
                        Section("Filter") {
                            ForEach(MacServerScope.allCases) { option in
                                Button {
                                    scope = option
                                } label: {
                                    Label(option.rawValue, systemImage: scope == option ? "checkmark.circle.fill" : option.symbol)
                                }
                            }
                        }
                        Section("Sort By") {
                            ForEach(MacServerSort.allCases) { option in
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
                    .help("Filter and sort server library")
                }

                MacServerScopePicker(scope: $scope)

                HStack(alignment: .firstTextBaseline) {
                    Text("SERVER LIBRARY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.7)
                        .foregroundStyle(Color(hex: 0xA9AFBD))
                    Text("\(visibleSongs.count) \(visibleSongs.count == 1 ? "song" : "songs")")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                    Spacer()
                    Text(model.playlistSyncStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                    if model.isSyncingPlaylists { ProgressView().controlSize(.small) }
                    if isSelecting, !model.selectedRemoteSongIDs.isEmpty {
                        Button("Download \(model.selectedRemoteSongIDs.count)") {
                            model.downloadSelectedServerSongs()
                            isSelecting = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appCoral)
                        .controlSize(.small)
                    }
                    Button(isSelecting ? "Done" : "Select") {
                        withAnimation {
                            isSelecting.toggle()
                            if !isSelecting { model.selectedRemoteSongIDs.removeAll() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if visibleSongs.isEmpty {
                    ContentUnavailableView(
                        model.remoteSongs.isEmpty ? "No Server Songs" : "No Results",
                        systemImage: model.remoteSongs.isEmpty ? "network.slash" : "magnifyingglass",
                        description: Text(model.remoteSongs.isEmpty ? "Configure the connection to load the server library." : "Try another search or filter.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 0) {
                        let localTracks = localTracksByRemoteID
                        ForEach(visibleSongs) { song in
                            MacServerSongRow(
                                song: song,
                                localTrack: localTracks[song.id],
                                isSynced: model.isRemoteSongSynced(song),
                                isSelecting: isSelecting,
                                isSelected: model.selectedRemoteSongIDs.contains(song.id),
                                onToggleSelection: { model.toggleRemoteSelection(song) },
                                onDelete: { deletionCandidate = song }
                            )
                        }
                    }
                    .background(Color.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.appLine) }
                }
            }
            .padding(34)
        }
        .background {
            RadialGradient(
                colors: [Color(hex: 0x245E7D).opacity(0.24), .clear],
                center: UnitPoint(x: 0.78, y: 0.06),
                startRadius: 10,
                endRadius: 440
            )
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

private struct MacServerMetric: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(label).font(.system(size: 9)).foregroundStyle(Color.appMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.appLine) }
    }
}

private struct MacServerScopePicker: View {
    @Binding var scope: MacServerScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MacServerScope.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { scope = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .foregroundStyle(scope == option ? Color.white : Color.appMuted)
                        .background(scope == option ? Color.appCoral : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.appLine) }
    }
}

private struct MacServerSongRow: View {
    @EnvironmentObject private var model: PlayerModel
    let song: RemoteSong
    let localTrack: Track?
    let isSynced: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.appCoral : Color.appMuted)
                }
                .buttonStyle(.plain)
            }

            Button(action: isSelecting ? onToggleSelection : primaryAction) {
                HStack(spacing: 12) {
                    Group {
                        if let localTrack {
                            TrackArtworkView(track: localTrack, symbolSize: 15, cornerRadius: 7)
                        } else {
                            MiniArtwork(style: .electric, symbol: "music.note", size: 42, cornerRadius: 7)
                        }
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(song.artist).font(.system(size: 10)).foregroundStyle(Color.appMuted).lineLimit(1)
                        Text(song.album).font(.system(size: 9)).foregroundStyle(Color.appMuted).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(ByteCountFormatter.string(fromByteCount: song.size, countStyle: .file))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appMuted)
                    Label(isSynced ? "Synced" : "Download", systemImage: isSynced ? "checkmark.icloud" : "icloud.and.arrow.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isSynced ? Color(hex: 0x55D98B) : Color.appCoral)
                        .frame(width: 76, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if !isSynced { Button("Download", action: { model.downloadServerSong(song) }) }
                Button("Delete from Server", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }
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
                .tint(Color.appCoral)
                .disabled(model.isSyncingServer)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color(hex: 0x0C1322))
    }
}

private extension View {
    func macServerActionButton() -> some View {
        font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.white.opacity(0.065), in: Capsule())
            .overlay { Capsule().stroke(Color.appLine) }
    }
}

private struct ServerTransferRow: View {
    let title: String
    let icon: String
    let color: Color
    let isActive: Bool
    let progress: Double
    let currentFile: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: isActive)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(status).font(.system(size: 9)).foregroundStyle(Color.appMuted)
                }
                if isActive {
                    ProgressView(value: progress)
                        .tint(color)
                } else {
                    Rectangle().fill(Color.appLine).frame(height: 1)
                }
                Text(currentFile.isEmpty ? (isActive ? "Starting…" : "No active transfer") : currentFile)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color.white.opacity(isActive ? 0.065 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        .background(Color.appCoral)
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

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x8E96A8))

                TextField("Search your music…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .focused($searchIsFocused)

                Text("⌘ K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x8C93A2))
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: 460)
            .frame(height: 39)
            .background(Color.white.opacity(0.075))
            .overlay {
                Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
            .clipShape(Capsule())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(hex: 0x070C18).opacity(0.82))
        .background(.ultraThinMaterial.opacity(0.22))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusMusicSearch)) { _ in
            searchIsFocused = true
        }
    }
}

private struct CollectionView: View {
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    CollectionHeroView()
                        .frame(height: 310)

                    TrackAreaView(
                        showAlbum: proxy.size.width >= 535,
                        showHelperText: proxy.size.width > 560
                    )
                    .frame(minHeight: max(proxy.size.height - 310, 360), alignment: .top)
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct CollectionHeroView: View {
    @EnvironmentObject private var model: PlayerModel

    private var isLikedCollection: Bool { model.collectionTitle == "Liked Songs" }

    private var symbol: String {
        isLikedCollection ? "heart.fill" : "music.note"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x101D3A), Color(hex: 0x17142A), Color(hex: 0x2A1532)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                RadialGradient(
                    colors: [Color(hex: 0x425BFF).opacity(0.28), .clear],
                    center: UnitPoint(x: 0.12, y: 0.20),
                    startRadius: 10,
                    endRadius: 240
                )

                RadialGradient(
                    colors: [Color(hex: 0xFF5674).opacity(0.24), .clear],
                    center: UnitPoint(x: 0.72, y: 0.70),
                    startRadius: 8,
                    endRadius: 210
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

                        Text(isLikedCollection ? "Liked\nSongs" : model.collectionTitle)
                            .font(.system(size: model.collectionTitle.count > 13 ? 48 : 58, weight: .regular))
                            .tracking(-2.2)
                            .lineSpacing(-6)
                            .lineLimit(2)
                            .minimumScaleFactor(0.68)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)

                        Text("\(model.collectionTrackCount) \(model.collectionTrackCount == 1 ? "track" : "tracks") / Stored locally")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xADB2C1))

                        HStack(spacing: 10) {
                            Button(action: model.toggleCollectionPlayback) {
                                HStack(spacing: 10) {
                                    Image(systemName: model.isCollectionPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text(model.isCollectionPlaying ? "Pause" : "Play")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .padding(.horizontal, 24)
                                .frame(height: 48)
                                .background(Color.appCoral)
                                .clipShape(Capsule())
                                .shadow(color: Color.appCoral.opacity(0.18), radius: 18, y: 9)
                            }
                            .buttonStyle(PressableScaleStyle())
                            .disabled(model.collectionTrackCount == 0)
                            .opacity(model.collectionTrackCount == 0 ? 0.55 : 1)

                            CircleIconButton(
                                systemImage: "shuffle",
                                label: "Shuffle",
                                size: 42,
                                symbolSize: 14,
                                background: Color.white.opacity(0.10),
                                isActive: model.shuffleEnabled,
                                action: model.toggleShuffle
                            )

                            Menu {
                                Button("Import Songs…", action: model.importLocalFiles)
                                Button("Next Track", action: model.next)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xAEB5C4))
                                    .frame(width: 42, height: 42)
                                    .background(Color.white.opacity(0.10))
                                    .clipShape(Circle())
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 42)
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

private struct TrackAreaView: View {
    @EnvironmentObject private var model: PlayerModel
    let showAlbum: Bool
    let showHelperText: Bool

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
                        Image(systemName: model.section == .playlists ? "heart" : "music.note.house")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.appViolet)
                        Text(model.section == .playlists ? "This playlist is empty" : "Build your music library")
                            .font(.system(size: 17, weight: .semibold))
                        Text(model.selectedPlaylist?.isSystem == true
                            ? "Heart songs in your Library to add them to Liked Songs."
                            : (model.section == .playlists
                                ? "Add songs from your Library using each song's More menu."
                                : "Add audio files or an entire folder. Music stays on this Mac."))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appMuted)
                        if model.section != .playlists {
                            Button(action: model.importLocalFiles) {
                                Label("Add Music", systemImage: "plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(Color.appCoral)
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
                            TrackRowView(
                                track: track,
                                number: index + 1,
                                showAlbum: showAlbum
                            )
                        }
                    }
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 32)
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
                                .foregroundStyle(Color.appCoral)
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

            HStack(spacing: 10) {
                Button {
                    model.toggleFavorite(track)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 10))
                        .foregroundStyle(isFavorite ? Color.appCoral : Color(hex: 0xAEB4C2))
                }
                .buttonStyle(.plain)

                Menu {
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

                    if let selected = model.selectedPlaylist, model.section == .playlists, !selected.isSystem {
                        Button("Remove from \(selected.name)") {
                            model.removeTrackFromSelectedPlaylist(track)
                        }
                    }

                    Button("Show in Finder") { model.revealInFinder(track) }
                    Divider()
                    Button("Remove from Library", role: .destructive) {
                        confirmingLibraryRemoval = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xAEB4C2))
                        .frame(width: 18, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
            }
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
                            .background(Color.appCoral, in: Capsule())
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
                        .foregroundStyle(scope == option ? Color.white : Color.appMuted)
                        .background(scope == option ? Color.appCoral : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
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
                        .stroke(Color.appCoral, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "internaldrive").foregroundStyle(Color.appMuted)
            }
            .frame(width: 96, height: 96)

            MacStorageMetric(color: Color.appViolet, title: "Local audio", bytes: importedBytes, detail: "\(importedCount) files")
            Divider().frame(height: 70)
            MacStorageMetric(color: Color.appCoral, title: "Server downloads", bytes: downloadedBytes, detail: "\(downloadedCount) files")
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
    let isEditing: Bool
    @Binding var selectedTrackIDs: Set<UUID>
    @Binding var deletionCandidate: Track?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(Color.appViolet)
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Color.appMuted)
                Spacer()
                Text("\(tracks.count) \(tracks.count == 1 ? "SONG" : "SONGS")")
                    .font(.system(size: 9)).foregroundStyle(Color.appMuted)
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 0) {
                ForEach(tracks) { track in
                    MacStorageTrackRow(
                        track: track,
                        fileSize: fileSizes[track.id, default: 0],
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
            .background(Color.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.appLine) }
        }
    }
}

private struct MacStorageTrackRow: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    let fileSize: Int64
    let isEditing: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: isEditing ? onToggleSelection : { model.selectAndPlay(track) }) {
                HStack(spacing: 12) {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.appCoral : Color.appMuted)
                    }
                    TrackArtworkView(track: track, symbol: "music.note", symbolSize: 15, cornerRadius: 7)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(track.artist) • \(track.album)")
                            .font(.system(size: 10)).foregroundStyle(Color.appMuted).lineLimit(1)
                        Text(track.fileURL?.lastPathComponent ?? "File unavailable")
                            .font(.system(size: 9)).foregroundStyle(Color.appMuted).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: track.remoteID == nil ? "desktopcomputer" : "checkmark.icloud")
                        .foregroundStyle(Color.appViolet)
                    Text(storageByteText(fileSize))
                        .font(.system(size: 9)).foregroundStyle(Color.appMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isEditing {
                Menu {
                    Button("Play", action: { model.selectAndPlay(track) })
                    Button("Show in Finder", action: { model.revealInFinder(track) })
                    Divider()
                    Button(track.remoteID == nil ? "Delete Original File" : "Delete Downloaded Copy", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }
        .contextMenu {
            Button("Show in Finder", action: { model.revealInFinder(track) })
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
