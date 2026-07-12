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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("REMOTE LIBRARY")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.7)
                    .foregroundStyle(Color(hex: 0xA9AFBD))
                Text("Music Server")
                    .font(.system(size: 52, weight: .regular))
                    .tracking(-2.2)
                    .padding(.top, 6)
                Text("Connect to your server and download its catalog for offline playback.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .foregroundStyle(Color.appViolet)
                        TextField("http://192.168.1.20:8765", text: $model.serverURLString)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.appCoral)
                        SecureField("Server access token", text: $model.serverToken)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 10) {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(Color.appViolet)
                        SecureField("Server admin key (required for uploads)", text: $model.serverAdminToken)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 10) {
                        Button(action: model.connectAndSyncServer) {
                            Label("Connect", systemImage: "network")
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 18)
                                .frame(height: 40)
                                .background(Color.appCoral)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(PressableScaleStyle())
                        .disabled(model.isSyncingServer || model.isUploadingServer)

                        Button("Refresh Catalog", action: model.refreshServerCatalog)
                            .buttonStyle(.bordered)
                            .disabled(model.isSyncingServer || model.isUploadingServer)

                        Button("Sync Playlists", action: model.syncPlaylists)
                            .buttonStyle(.bordered)
                            .disabled(model.isSyncingPlaylists)

                        Button("Download Selected", action: model.downloadSelectedServerSongs)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.appCoral)
                            .disabled(model.selectedRemoteSongIDs.isEmpty || model.isSyncingServer || model.isUploadingServer)

                        Button(action: model.chooseSongsToUpload) {
                            Label(model.isUploadingServer ? "Uploading…" : "Upload Songs", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isUploadingServer || model.isSyncingServer)

                        Menu("More") {
                            Button("Download All", action: model.downloadAllServerSongs)
                                .disabled(model.isSyncingServer || model.isUploadingServer)
                            if model.isSyncingServer {
                                Button("Cancel Download", role: .destructive, action: model.cancelServerDownload)
                            }
                            if model.isUploadingServer {
                                Button("Cancel Upload", role: .destructive, action: model.cancelServerUpload)
                            }
                        }

                        Spacer()
                        if model.isSyncingServer {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text(model.serverMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(Color.appViolet)
                        Text("Playlists")
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        if model.isSyncingPlaylists {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.playlistSyncStatus)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(1)
                    }

                    VStack(spacing: 10) {
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
                    .padding(.top, 4)
                }
                .padding(18)
                .background(Color.white.opacity(0.035))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.appLine) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 26)

                HStack {
                    Text("Server Catalog")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(model.remoteSongs.count) \(model.remoteSongs.count == 1 ? "song" : "songs")")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.top, 28)
                .padding(.bottom, 8)

                if model.remoteSongs.isEmpty {
                    Text("Connect to view and sync songs hosted by the server.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.remoteSongs) { song in
                            HStack(spacing: 12) {
                                Button {
                                    model.toggleRemoteSelection(song)
                                } label: {
                                    Image(systemName: model.selectedRemoteSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.selectedRemoteSongIDs.contains(song.id) ? Color.appCoral : Color.appMuted)
                                }
                                .buttonStyle(.plain)
                                MiniArtwork(style: .electric, symbol: "music.note", size: 40, cornerRadius: 7)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(song.album) • \(ByteCountFormatter.string(fromByteCount: song.size, countStyle: .file))")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.appMuted)
                                }
                                Spacer()
                                if model.isRemoteSongSynced(song) {
                                    Label("Synced", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Color(hex: 0x55D98B))
                                } else {
                                    Text("Available")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.appMuted)
                                }
                                Menu {
                                    Button("Download") {
                                        model.downloadServerSong(song)
                                    }
                                    Button("Delete from Server", role: .destructive) { deletionCandidate = song }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }
                        }
                    }
                }

                Text("Synced files are cached locally and play without a network connection.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
                    .padding(.top, 18)
            }
            .padding(42)
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

            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hex: 0x55D98B))
                    .frame(width: 6, height: 6)
                    .shadow(color: Color(hex: 0x55D98B), radius: 5)
                Text("macOS app")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0xAAB1BF))
            }
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

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("LOCAL STORAGE")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Color(hex: 0xA9AFBD))
                    .padding(.bottom, 8)

                Text("Song Storage")
                    .font(.system(size: 56, weight: .regular))
                    .tracking(-2.4)
                    .padding(.bottom, 10)

                Text("Your music stays on this Mac. Import audio files to add them to the local library.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)

                Button(action: model.importLocalFiles) {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                        Text("Import Songs")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(Color.appCoral)
                    .clipShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle())
                .padding(.top, 22)

                LazyVGrid(columns: columns, spacing: 12) {
                    StorageCard(
                        title: "Songs",
                        subtitle: "\(model.tracks.count) files • \(ByteCountFormatter.string(fromByteCount: model.localLibraryBytes, countStyle: .file))",
                        style: .midnight,
                        symbol: "music.note"
                    )
                    StorageCard(
                        title: "Artists",
                        subtitle: "\(Set(model.tracks.map(\.artist)).count) artists",
                        style: .electric,
                        symbol: "person.2.fill"
                    )
                    StorageCard(
                        title: "Albums",
                        subtitle: "\(Set(model.tracks.map(\.album)).count) albums",
                        style: .golden,
                        symbol: "square.stack.fill"
                    )
                    StorageCard(
                        title: "Playlists",
                        subtitle: "\(model.customPlaylists.count) playlists",
                        style: .weightless,
                        symbol: "square.stack"
                    )
                }
                .padding(.top, 30)

                HStack {
                    Text("Stored Files")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(model.downloadedTrackCount) downloaded from server")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.top, 30)
                .padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(model.tracks) { track in
                        StorageTrackRow(track: track)
                    }
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 52)
            .padding(.bottom, 70)
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
}

private struct StorageTrackRow: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(track: track, symbol: "music.note", symbolSize: 13, cornerRadius: 6)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(track.remoteID == nil ? "Original local file" : "Downloaded server copy")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: model.fileSize(for: track), countStyle: .file))
                .font(.system(size: 9))
                .foregroundStyle(Color.appMuted)
            Button("Show in Finder") { model.revealInFinder(track) }
                .buttonStyle(.borderless)
            if track.remoteID != nil {
                Button("Delete Download", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.borderless)
            } else {
                Button("Delete File", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }
        .alert("Delete downloaded copy?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                track.remoteID == nil ? model.deleteOriginalFile(track) : model.deleteDownloadedCopy(track)
            }
        } message: {
            Text(track.remoteID == nil
                ? "This permanently deletes the original audio file from this Mac."
                : "This deletes the cached file from this Mac. It remains available on the music server.")
        }
    }
}

private struct StorageCard: View {
    let title: String
    let subtitle: String
    let style: ArtworkStyle
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            MiniArtwork(style: style, symbol: symbol, size: 42, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(Color.appLine, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Notification.Name {
    static let focusMusicSearch = Notification.Name("focusMusicSearch")
    static let newMusicPlaylist = Notification.Name("newMusicPlaylist")
}
