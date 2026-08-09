import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

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
                StorageView {
                    NotificationCenter.default.post(name: .importMusicFromLink, object: nil)
                }
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
        model.visibleTracks.reduce(into: [:]) { result, track in
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
            case .settings: MacSettingsSheet(opensServerPanel: true)
            }
        }
        .task {
            let hasServer = !model.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasToken = !model.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAdminToken = !model.serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasServer,
                  hasToken || hasAdminToken,
                  !model.isSyncingServer,
                  !model.isUploadingServer,
                  !model.isSyncingPlaylists else { return }
            await model.refreshClientConfigurationNow()
            guard hasToken else { return }
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

            Button { presentedSheet = .settings } label: {
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
                symbol: "icloud.and.arrow.up",
                label: "Upload downloaded songs missing from the server",
                isDisabled: model.localFileUploadActionsDisabled,
                action: model.uploadMissingDownloadedSongs
            )

            MacServerCircleActionButton(
                symbol: "square.and.arrow.up",
                label: "Upload mode: \(model.uploadMode.title)",
                isDisabled: model.selectedUploadActionDisabled,
                action: model.chooseSongsToUpload
            )

            MacServerCircleActionButton(
                symbol: "square.and.arrow.down",
                label: isSelecting ? "Download selected songs" : "Download all missing songs",
                isDisabled: model.offlineDownloadActionsDisabled || (isSelecting && model.selectedRemoteSongIDs.isEmpty)
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
                isDisabled: model.offlineDownloadActionsDisabled
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
                label: "Refresh server catalog",
                isRotating: model.isRefreshingServerCatalog,
                isDisabled: model.isUploadingServer || model.isSyncingServer || model.isSyncingPlaylists,
                action: model.refreshServerCatalog
            )

            MacServerCircleActionButton(
                symbol: "wrench.and.screwdriver",
                label: "Repair server metadata (admin)",
                isRotating: model.isRepairingServerMetadata,
                isDisabled: model.serverUploadActionsDisabled || model.isSyncingPlaylists,
                action: model.repairServerMetadata
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
    case settings
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
            Text("Size / Time")
                .frame(width: 72, alignment: .trailing)
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
        guard song.title.isEmpty, let localTrack, !localTrack.title.isEmpty else { return song.title }
        return localTrack.title
    }

    private var displayArtist: String {
        guard song.artist.isEmpty || song.artist == "Unknown Artist",
              let localTrack,
              !localTrack.artist.isEmpty,
              localTrack.artist != "Unknown Artist"
        else { return song.artist }
        return localTrack.artist
    }

    private var displayAlbum: String {
        guard song.album.isEmpty || song.album == "Server Library",
              let localTrack,
              !localTrack.album.isEmpty,
              localTrack.album != "Server Library"
        else { return song.album }
        return localTrack.album
    }

    private var sizeOrDurationText: String {
        song.durationText ?? localTrack?.durationText ?? storageByteText(song.size)
    }

    private var mediaKind: String {
        song.kind == .video ? "Video" : "Audio"
    }

    private var isCurrent: Bool {
        localTrack?.id == model.currentTrackID || model.isStreamingRemoteSong(song)
    }

    private var isFavorite: Bool {
        guard let localTrack else { return false }
        return model.favorites.contains(localTrack.id)
    }

    private var isUnsupportedStreamVideo: Bool {
        localTrack == nil
            && model.clientConfiguration.allowsStreamOnlyPlayback
            && song.kind == .video
    }

    private var remoteActionSymbol: String {
        if isUnsupportedStreamVideo { return "video.slash.fill" }
        if model.clientConfiguration.allowsStreamOnlyPlayback {
            return model.isStreamingRemoteSong(song) && model.isPlaying ? "pause.fill" : "play.fill"
        }
        return "icloud.and.arrow.down"
    }

    private var remoteActionHelp: String {
        if isUnsupportedStreamVideo {
            return MacRemoteStreamMediaPolicy.videoUnavailableMessage
        }
        if model.clientConfiguration.allowsStreamOnlyPlayback {
            return "Play without saving to this Mac"
        }
        return model.clientConfiguration.allowsOfflineDownload
            ? "Download"
            : model.offlineDownloadUnavailableMessage
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
                        MacServerArtwork(song: song, localTrack: localTrack, mediaKind: mediaKind)
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

                    Text(sizeOrDurationText)
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
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
                        if model.isStreamingRemoteSong(song) {
                            model.togglePlay()
                        } else if model.clientConfiguration.allowsStreamOnlyPlayback {
                            model.playRemoteSong(song)
                        } else {
                            model.downloadServerSong(song)
                        }
                    } label: {
                        Image(systemName: remoteActionSymbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xAEB4C2))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        !model.clientConfiguration.allowsOfflineDownload
                            && !model.clientConfiguration.allowsStreamOnlyPlayback
                    )
                    .help(remoteActionHelp)
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
                if model.clientConfiguration.allowsStreamOnlyPlayback {
                    Button(isUnsupportedStreamVideo
                        ? "Video Stream Unavailable"
                        : model.isStreamingRemoteSong(song) && model.isPlaying ? "Pause Stream" : "Play Stream") {
                        if model.isStreamingRemoteSong(song) {
                            model.togglePlay()
                        } else {
                            model.playRemoteSong(song)
                        }
                    }
                } else {
                    Button("Download", action: { model.downloadServerSong(song) })
                        .disabled(!model.clientConfiguration.allowsOfflineDownload)
                }
            }
            Divider()
            Button("Delete from Server", role: .destructive, action: onDelete)
        }
    }

    private func primaryAction() {
        if let localTrack { model.selectAndPlay(localTrack) }
        else if model.isStreamingRemoteSong(song) { model.togglePlay() }
        else if model.clientConfiguration.allowsStreamOnlyPlayback { model.playRemoteSong(song) }
        else { model.downloadServerSong(song) }
    }
}

private struct MacServerArtwork: View {
    let song: RemoteSong
    let localTrack: Track?
    let mediaKind: String

    var body: some View {
        Group {
            if let rawArtworkURL = song.artworkURL,
               let artworkURL = URL(string: rawArtworkURL) {
                CroppedRemoteArtwork(url: artworkURL) { isLoading in
                    fallbackArtwork
                        .overlay {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(Color.white.opacity(0.65))
                            }
                        }
                }
            } else {
                fallbackArtwork
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
        .accessibilityLabel("\(song.title) artwork")
    }

    @ViewBuilder
    private var fallbackArtwork: some View {
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
                                PlaylistArtworkView(
                                    playlist: playlist,
                                    tracks: model.tracks,
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

            MacProfileMenu()
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

private struct MacProfileMenu: View {
    private enum PresentedSheet: String, Identifiable {
        case listeningHistory
        case clipEditor
        case settings

        var id: String { rawValue }
    }

    @State private var isShowingProfileMenu = false
    @State private var presentedSheet: PresentedSheet?
    @State private var isProfileHeaderHovering = false
    @State private var isEmailRevealed = false
    @EnvironmentObject private var model: PlayerModel

    private var profileName: String {
        ResonanceEmailPrivacy.safeDisplayName(
            model.accountDisplayName ?? model.activeSyncProfileName,
            email: model.accountEmail
        )
    }

    private var profileInitial: String {
        String(profileName.prefix(1)).uppercased()
    }

    var body: some View {
        Button {
            if !isShowingProfileMenu { isEmailRevealed = false }
            isShowingProfileMenu.toggle()
        } label: {
            ProfileAvatar(
                initial: profileInitial,
                size: 42,
                fontSize: 15,
                imageURL: model.accountImageURL
            )
        }
        .buttonStyle(PressableScaleStyle())
        .help("Profile and settings")
        .accessibilityLabel("Profile and settings, \(profileName)")
        .popover(isPresented: $isShowingProfileMenu, arrowEdge: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 13) {
                    Button {
                        isShowingProfileMenu = false
                        presentedSheet = .settings
                    } label: {
                        ProfileAvatar(
                            initial: profileInitial,
                            size: 48,
                            fontSize: 17,
                            imageURL: model.accountImageURL
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage \(profileName) account")

                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            isShowingProfileMenu = false
                            presentedSheet = .settings
                        } label: {
                            Text(profileName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appInk)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Manage \(profileName) account")

                        if let email = model.accountEmail {
                            Button {
                                isEmailRevealed.toggle()
                            } label: {
                                Text(ResonanceEmailPrivacy.displayedAddress(email, isRevealed: isEmailRevealed))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.appMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isEmailRevealed ? "Hide email address" : "Reveal email address")
                        } else {
                            Text("Clerk account")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appMuted)
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        isShowingProfileMenu = false
                        presentedSheet = .settings
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage \(profileName) account")
                }
                .padding(.horizontal, 9)
                .frame(height: 64)
                .background(
                    isProfileHeaderHovering ? Color.white.opacity(0.075) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(8)
                .onHover { isProfileHeaderHovering = $0 }

                Rectangle()
                    .fill(Color.appLine)
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                VStack(spacing: 2) {
                    Button {
                        isShowingProfileMenu = false
                        presentedSheet = .listeningHistory
                    } label: {
                        ProfilePopoverRow(symbol: "clock.arrow.circlepath", title: "Listening History")
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingProfileMenu = false
                        presentedSheet = .clipEditor
                    } label: {
                        ProfilePopoverRow(symbol: "scissors", title: "Clip Editor")
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingProfileMenu = false
                        presentedSheet = .settings
                    } label: {
                        ProfilePopoverRow(symbol: "gearshape", title: "Settings")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
            .frame(width: 274)
            .background(Color.appSurfaceRaised)
            .presentationBackground(Color.appSurfaceRaised)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .listeningHistory:
                MacListeningHistorySheet()
            case .clipEditor:
                MacClipEditorSheet()
            case .settings:
                MacSettingsSheet()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openResonanceSettings)) { _ in
            isShowingProfileMenu = false
            presentedSheet = .settings
        }
        .onChange(of: model.accountEmail) { _, _ in isEmailRevealed = false }
    }

}

private struct ProfileAvatar: View {
    let initial: String
    let size: CGFloat
    let fontSize: CGFloat
    var imageData: Data? = nil
    var imageURL: URL? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x9A68FF), Color.appViolet],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let imageURL {
                AsyncImage(url: imageURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Text(initial)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                }
            } else if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
            }
        }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().stroke(Color.white.opacity(0.20), lineWidth: 1)
            }
            .shadow(color: Color.appViolet.opacity(0.26), radius: 9, y: 4)
            .contentShape(Circle())
    }
}

private struct ProfilePopoverRow: View {
    let symbol: String
    let title: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.appInk)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appInk)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            isHovering ? Color.white.opacity(0.075) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct MacListeningHistorySheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case overall
        case stats

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overall: "Overall"
            case .stats: "Stats"
            }
        }
    }

    private enum Range: Int, CaseIterable, Identifiable {
        case last1 = 1
        case last7 = 7
        case last30 = 30
        case last90 = 90

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .last1: "Last 1 day"
            case .last7: "Last 7 days"
            case .last30: "Last 30 days"
            case .last90: "Last 90 days"
            }
        }
    }

    private struct DaySong: Identifiable {
        let track: Track
        let seconds: TimeInterval
        let plays: Int

        var id: UUID { track.id }
    }

    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .overall
    @State private var range: Range = .last30
    @State private var windowOffset = 0
    @State private var selectedDayDate: Date?
    @State private var songsExpanded = false

    init(
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        _selectedDayDate = State(
            initialValue: calendar.startOfDay(for: now)
        )
    }

    private var summary: ListeningHistoryCalendarSummary {
        calendarSummary(windowOffset: windowOffset)
    }

    private func calendarSummary(
        windowOffset: Int
    ) -> ListeningHistoryCalendarSummary {
        ListeningHistoryCalendarSummary(
            entries: model.activeProfileListeningHistoryEntries,
            tracks: model.tracks,
            dayCount: range.rawValue,
            windowOffset: windowOffset
        )
    }

    private var allTimeStats: ListeningHistoryStatsSummary {
        ListeningHistoryStatsSummary(
            entries: model.activeProfileListeningHistoryEntries,
            tracks: model.tracks
        )
    }

    private var selectedDay: ListeningHistoryDay? {
        guard let selectedDayDate else { return nil }
        return summary.days.first { $0.date == selectedDayDate }
    }

    private var preferredDayDate: Date? {
        preferredDayDate(in: summary)
    }

    private func preferredDayDate(
        in summary: ListeningHistoryCalendarSummary
    ) -> Date? {
        summary.days.last { $0.date <= Date.now }?.date
            ?? summary.days.last?.date
    }

    private var chartMaximum: Double {
        if summary.granularity == .hour { return 60 }
        return niceChartMaximum(summary.days.map(\.minutes).max() ?? 0)
    }

    private var chartTicks: [Double] {
        (0..<5).map { index in
            chartMaximum * (1 - (Double(index) / 4))
        }
    }

    private var sheetWidth: CGFloat {
        mode == .overall && selectedDay != nil ? 980 : 860
    }

    private var sheetHeight: CGFloat {
        switch mode {
        case .overall:
            selectedDay == nil ? 396 : 650
        case .stats:
            songsExpanded && !allTimeStats.songRanking.isEmpty ? 540 : 314
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                header
                if mode == .overall {
                    historyToolbar
                    chart

                    if let selectedDay {
                        dayDetails(selectedDay)
                    }
                } else {
                    stats
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.visible)
        .frame(width: sheetWidth, height: sheetHeight, alignment: .top)
        .background(historyBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.17), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(Color.appInk)
        .preferredColorScheme(.dark)
        .presentationBackground(Color.clear)
        .onChange(of: range) {
            windowOffset = 0
            selectedDayDate = preferredDayDate
        }
        .onChange(of: mode) {
            if mode == .overall {
                songsExpanded = false
                selectedDayDate = preferredDayDate
            } else {
                selectedDayDate = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color(hex: 0x9B62FF))
                .frame(width: 28, height: 28)

            Text("Listening History")
                .font(.system(size: 22, weight: .bold))

            Spacer(minLength: 24)

            modePicker

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xC5C4CE))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.047), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close listening history")
        }
        .padding(.horizontal, 26)
        .frame(height: 76)
        .overlay(alignment: .bottom) {
            divider
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            mode == option
                                ? Color(hex: 0xDAC8FF)
                                : Color.appMuted
                        )
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background {
                            if mode == option {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(hex: 0x302051))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(
                                                Color(hex: 0x9B62FF).opacity(0.52),
                                                lineWidth: 1
                                            )
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(hex: 0x0F1118))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.071), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var historyToolbar: some View {
        HStack(spacing: 12) {
            Text(windowLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xD7D3DF))
                .lineLimit(1)

            Spacer(minLength: 16)

            HStack(spacing: 5) {
                windowButton(
                    symbol: "chevron.left",
                    label: previousWindowLabel
                ) {
                    let nextOffset = windowOffset + 1
                    windowOffset = nextOffset
                    selectedDayDate = preferredDayDate(
                        in: calendarSummary(windowOffset: nextOffset)
                    )
                }

                rangePicker

                windowButton(
                    symbol: "chevron.right",
                    label: nextWindowLabel,
                    disabled: windowOffset == 0
                ) {
                    let nextOffset = max(0, windowOffset - 1)
                    windowOffset = nextOffset
                    selectedDayDate = preferredDayDate(
                        in: calendarSummary(windowOffset: nextOffset)
                    )
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .frame(height: 42)
    }

    private var rangePicker: some View {
        Menu {
            ForEach(Range.allCases) { option in
                Button {
                    range = option
                } label: {
                    if range == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .medium))
                Text(range.title)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.appMuted)
            }
            .foregroundStyle(Color(hex: 0xCBC8D3))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color(hex: 0x11131B), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func windowButton(
        symbol: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    disabled
                        ? Color(hex: 0x5D5967)
                        : Color(hex: 0xCBC8D3)
                )
                .frame(width: 32, height: 32)
                .background(Color(hex: 0x11131B), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private var stats: some View {
        VStack(spacing: 0) {
            statsMetrics
            divider
            topSongSection
        }
    }

    private var statsMetrics: some View {
        HStack(spacing: 0) {
            ListeningHistoryMetric(
                symbol: "clock",
                accent: Color(hex: 0x9B62FF),
                value: historyListenedTime(allTimeStats.totalSeconds),
                label: "Total Time Listened"
            )

            metricDivider

            ListeningHistoryMetric(
                symbol: "waveform",
                accent: Color(hex: 0xFF735D),
                value: allTimeStats.plays.formatted(),
                label: "Total Plays"
            )

            metricDivider

            ListeningHistoryMetric(
                symbol: "music.note",
                accent: Color(hex: 0xAD70FF),
                value: allTimeStats.songs.formatted(),
                label: "Total Songs Heard"
            )

            metricDivider

            ListeningHistoryMetric(
                symbol: "music.note",
                accent: Color(hex: 0xAD70FF),
                value: allTimeStats.topArtist,
                label: "Most Popular Artist"
            )
        }
        .frame(height: 116)
    }

    @ViewBuilder
    private var historyContent: some View {
        switch mode {
        case .overall:
            chart
        case .stats:
            bySongContent
        }
    }

    private var chart: some View {
        VStack(spacing: 0) {
            ZStack {
                overallChart

                if summary.plays == 0 {
                    Text("Play something and your activity will appear here.")
                        .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x7F7C89))
                }
            }
            .frame(height: 258)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(height: 278)
    }

    private var overallChart: some View {
        ListeningHistoryBarChart(
            summary: summary,
            chartMaximum: chartMaximum,
            chartTicks: chartTicks,
            selectedDayDate: selectedDayDate
        ) { date in
            selectedDayDate = date
        }
    }

    private var bySongContent: some View {
        let songs = Array(summary.songSeries.prefix(5))
        let longestListeningTime = songs.first?.seconds ?? 1

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top songs in this period")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xA8A4B0))

                Spacer()

                Text(windowLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0x777481))
            }
            .frame(height: 25)

            if songs.isEmpty {
                Text("Play something and your most-listened songs will appear here.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x7F7C89))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) {
                        index,
                        song in
                        ListeningHistorySongRow(
                            position: index + 1,
                            song: song,
                            maximumSeconds: longestListeningTime,
                            listeningTime: historyListenedTime(song.seconds)
                        )

                        if index < songs.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.055))
                                .frame(height: 1)
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(height: 247)
    }

    private var summaryFooter: some View {
        HStack(spacing: 0) {
            if mode == .overall {
                ListeningHistoryFooterItem(
                    value: footerDateTitle,
                    label: "Most active day",
                    accent: Color(hex: 0xF5F3FA)
                )

                metricDivider

                ListeningHistoryFooterItem(
                    value: historyListenedTime(
                        summary.mostActiveDay?.seconds ?? 0
                    ),
                    label: "Listening time",
                    accent: Color(hex: 0xA66CFF)
                )

                metricDivider

                ListeningHistoryFooterItem(
                    value: (summary.mostActiveDay?.plays ?? 0).formatted(),
                    label: "Tracks started",
                    accent: Color(hex: 0xFF735D)
                )
            } else {
                ListeningHistoryFooterItem(
                    value: summary.songs.formatted(),
                    label: "Songs heard",
                    accent: Color(hex: 0xF5F3FA)
                )

                metricDivider

                ListeningHistoryFooterItem(
                    value: summary.songSeries.first?.track.title ?? "No song yet",
                    label: "Most listened",
                    accent: Color(hex: 0xA66CFF)
                )

                metricDivider

                ListeningHistoryFooterItem(
                    value: historyListenedTime(
                        summary.songSeries.first?.seconds ?? 0
                    ),
                    label: "Top song time",
                    accent: Color(hex: 0xFF735D)
                )
            }
        }
        .frame(height: 63)
    }

    private var topSongSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 17) {
                Button {
                    guard !allTimeStats.songRanking.isEmpty else { return }
                    songsExpanded.toggle()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        historyArtwork(
                            for: allTimeStats.songRanking.first?.track,
                            size: 78,
                            cornerRadius: 14
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 14,
                                style: .continuous
                            )
                            .stroke(
                                Color(hex: 0xB699FF).opacity(0.31),
                                lineWidth: 1
                            )
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0xF4EFFF))
                            .frame(width: 22, height: 22)
                            .background(Color(hex: 0x090A11).opacity(0.85), in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color.white.opacity(0.15),
                                        lineWidth: 1
                                    )
                            }
                            .padding(5)
                            .rotationEffect(
                                songsExpanded ? .degrees(90) : .zero
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(allTimeStats.songRanking.isEmpty)
                .help(
                    songsExpanded
                        ? "Hide songs ranked by listening time"
                        : "Show songs ranked by listening time"
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text("MOST LISTENED SONG")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color(hex: 0x8F8C99))

                    Text(topSongTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFAF9FD))
                        .lineLimit(1)
                        .padding(.top, 5)

                    Text(topSongSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xAAA6B2))
                        .lineLimit(1)
                        .padding(.top, 5)

                    Text(
                        allTimeStats.songRanking.isEmpty
                            ? "Your song ranking will appear here."
                            : "Click the cover to view every song from most to least listened."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0x827E8B))
                    .lineLimit(1)
                    .padding(.top, 8)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 78)

            if songsExpanded, !allTimeStats.songRanking.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 13) {
                        ForEach(
                            Array(allTimeStats.songRanking.enumerated()),
                            id: \.element.id
                        ) { index, song in
                            ListeningHistoryRankedSongCard(
                                position: index + 1,
                                song: song,
                                listeningTime: historyListenedTime(
                                    song.seconds
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 11)
                }
                .scrollIndicators(.visible)
                .padding(.top, 20)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dayDetails(_ day: ListeningHistoryDay) -> some View {
        let songs = songs(for: day)
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        summary.granularity == .hour
                            ? "HOUR BREAKDOWN"
                            : "DAY BREAKDOWN"
                    )
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color(hex: 0x8F8C99))

                    Text(dayDetailsTitle(day.date))
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.35)
                        .lineLimit(1)
                }

                Spacer(minLength: 20)

                HStack(spacing: 22) {
                    dayTotal(
                        value: historyListenedTime(day.seconds),
                        label: "Listening time"
                    )
                    dayTotal(
                        value: day.plays.formatted(),
                        label: day.plays == 1 ? "Play" : "Plays"
                    )
                    dayTotal(
                        value: songs.count.formatted(),
                        label: songs.count == 1 ? "Song" : "Songs"
                    )

                    Button {
                        selectedDayDate = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xAAA6B2))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.047), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Collapse day details")
                }
            }

            daySongList(songs)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func dayTotal(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xF8F7FC))
                .lineLimit(1)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(Color(hex: 0x85818E))
        }
        .frame(minWidth: 62, alignment: .trailing)
    }

    private func daySongList(_ songs: [DaySong]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                dayHeader("#", width: 28)
                dayHeader("", width: 46)
                dayHeader("Title", width: 420, alignment: .leading)
                dayHeader("Album", width: 220, alignment: .leading)
                dayHeader("Listening time", width: 96, alignment: .leading)
                dayHeader("Plays", width: 52, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 27)
            .overlay(alignment: .bottom) { divider }

            if songs.isEmpty {
                Text(
                    "No song activity was recorded for this "
                        + (summary.granularity == .hour ? "hour." : "day.")
                )
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x85818E))
                .frame(maxWidth: .infinity)
                .frame(height: 143)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) {
                        index,
                        song in
                        HStack(spacing: 10) {
                            Text((index + 1).formatted())
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appMuted)
                                .frame(width: 28)

                            historyArtwork(
                                for: song.track,
                                size: 46,
                                cornerRadius: 7
                            )
                            .frame(width: 46)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.track.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0xF5F4F8))
                                    .lineLimit(2)
                                Text("\(song.track.artist) / Audio")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 420, alignment: .leading)

                            Text(song.track.album)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(2)
                                .frame(width: 220, alignment: .leading)

                            Text(historyListenedTime(song.seconds))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: 0xBBA7FF))
                                .monospacedDigit()
                                .frame(width: 96, alignment: .leading)

                            Text(song.plays.formatted())
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appMuted)
                                .monospacedDigit()
                                .frame(width: 52, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 60)
                        .overlay(alignment: .bottom) { divider }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func dayHeader(
        _ title: String,
        width: CGFloat,
        alignment: Alignment = .center
    ) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.appMuted)
            .frame(width: width, alignment: alignment)
    }

    private func songs(for day: ListeningHistoryDay) -> [DaySong] {
        guard let dayIndex = summary.days.firstIndex(where: { $0.id == day.id }) else {
            return []
        }
        return summary.songSeries.compactMap { series in
            guard series.days.indices.contains(dayIndex) else { return nil }
            let activity = series.days[dayIndex]
            guard activity.seconds > 0 || activity.plays > 0 else { return nil }
            return DaySong(
                track: series.track,
                seconds: activity.seconds,
                plays: activity.plays
            )
        }
        .sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds {
                return lhs.seconds > rhs.seconds
            }
            return lhs.plays > rhs.plays
        }
    }

    private var topSongTitle: String {
        allTimeStats.songRanking.first?.track.title ?? "No listening yet"
    }

    private var topSongSubtitle: String {
        guard let song = allTimeStats.songRanking.first else {
            return "Play a song to build your ranking"
        }
        return "\(song.track.artist) · \(historyListenedTime(song.seconds))"
    }

    @ViewBuilder
    private func historyArtwork(
        for track: Track?,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        if let track {
            TrackArtworkView(
                track: track,
                symbolSize: size * 0.34,
                cornerRadius: cornerRadius
            )
            .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(hex: 0x151722))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.30, weight: .medium))
                        .foregroundStyle(Color(hex: 0x8F6BEB))
                }
                .frame(width: size, height: size)
        }
    }

    private var windowLabel: String {
        guard
            let start = summary.days.first?.date,
            let end = summary.days.last?.date
        else { return "" }
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date.now)
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let sameDay = calendar.isDate(start, inSameDayAs: end)

        if sameDay {
            return formattedDate(
                start,
                format: startYear == currentYear ? "MMMM d" : "MMMM d, yyyy"
            )
        }

        if startYear == endYear,
           calendar.component(.month, from: start)
            == calendar.component(.month, from: end)
        {
            let month = formattedDate(start, format: "MMMM")
            let suffix = endYear == currentYear ? "" : ", \(endYear)"
            return "\(month) \(calendar.component(.day, from: start))–"
                + "\(calendar.component(.day, from: end))\(suffix)"
        }

        if startYear == endYear {
            let suffix = endYear == currentYear ? "" : ", \(endYear)"
            return "\(formattedDate(start, format: "MMMM d"))–"
                + "\(formattedDate(end, format: "MMMM d"))\(suffix)"
        }

        return "\(formattedDate(start, format: "MMMM d, yyyy"))–"
            + formattedDate(end, format: "MMMM d, yyyy")
    }

    private var previousWindowLabel: String {
        range == .last1
            ? "Show previous day"
            : "Show previous \(range.rawValue) days"
    }

    private var nextWindowLabel: String {
        if windowOffset == 1, range == .last1 {
            return "Show today"
        }
        return range == .last1
            ? "Show next day"
            : "Show next \(range.rawValue) days"
    }

    private func chartAxisDate(_ date: Date) -> String {
        formattedDate(
            date,
            format: summary.granularity == .hour ? "ha" : "MMM d"
        )
    }

    private var footerDateTitle: String {
        guard summary.totalSeconds > 0, let date = summary.mostActiveDay?.date else {
            return "No activity yet"
        }
        return formattedDate(
            date,
            format: summary.granularity == .hour
                ? "EEEE, h a"
                : "EEEE, MMMM d"
        )
    }

    private func dayDetailsTitle(_ date: Date) -> String {
        formattedDate(
            date,
            format: summary.granularity == .hour
                ? "EEEE, MMMM d, yyyy, h a"
                : "EEEE, MMMM d, yyyy"
        )
    }

    private func formattedDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func historyListenedTime(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        if value > 0, value < 60 {
            return "\(max(1, Int(value.rounded()))) sec"
        }
        return "\(Int((value / 60).rounded()).formatted()) min"
    }

    private func historyYAxisLabel(_ value: Double) -> String {
        Int(max(0, value).rounded()).formatted()
    }

    private func niceChartMaximum(_ value: Double) -> Double {
        let peak = max(0, value.isFinite ? value : 0)
        guard peak > 0 else { return 1 }
        let roughStep = peak / 4
        let magnitude = pow(10, floor(log10(roughStep)))
        let normalizedStep = roughStep / magnitude
        let multiplier: Double
        if normalizedStep <= 1 {
            multiplier = 1
        } else if normalizedStep <= 2 {
            multiplier = 2
        } else if normalizedStep <= 2.5 {
            multiplier = 2.5
        } else if normalizedStep <= 5 {
            multiplier = 5
        } else {
            multiplier = 10
        }
        let step = multiplier * magnitude
        var maximum = ceil(peak / step) * step
        if maximum <= peak { maximum += step }
        return maximum
    }

    private var historyBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x090B13), Color(hex: 0x070910)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(hex: 0x536BFF).opacity(0.14), .clear],
                center: UnitPoint(x: 0.16, y: 0.12),
                startRadius: 0,
                endRadius: 330
            )
            RadialGradient(
                colors: [Color(hex: 0x7547FF).opacity(0.12), .clear],
                center: UnitPoint(x: 0.76, y: 0.20),
                startRadius: 0,
                endRadius: 380
            )
            RadialGradient(
                colors: [Color(hex: 0xFF806C).opacity(0.06), .clear],
                center: UnitPoint(x: 0.88, y: 1),
                startRadius: 0,
                endRadius: 300
            )
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.071))
            .frame(height: 1)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.071))
            .frame(width: 1)
    }
}

enum ListeningHistoryChartHitTesting {
    static func nearestIndex(
        to locationX: CGFloat,
        positions: [CGFloat]
    ) -> Int? {
        guard locationX.isFinite else { return nil }
        return positions.indices
            .filter { positions[$0].isFinite }
            .min {
                abs(positions[$0] - locationX)
                    < abs(positions[$1] - locationX)
            }
    }
}

private struct ListeningHistoryBarChart: View {
    let summary: ListeningHistoryCalendarSummary
    let chartMaximum: Double
    let chartTicks: [Double]
    let selectedDayDate: Date?
    let onSelect: (Date) -> Void

    @State private var hoveredDayDate: Date?

    private var hoveredDay: ListeningHistoryDay? {
        guard let hoveredDayDate else { return nil }
        return summary.days.first { $0.date == hoveredDayDate }
    }

    private var peakDayID: Date? {
        guard summary.totalSeconds > 0 else { return nil }
        return summary.mostActiveDay?.id
    }

    private var calendarComponent: Calendar.Component {
        summary.granularity == .hour ? .hour : .day
    }

    private var barWidthRatio: CGFloat {
        let value = 0.78 - (CGFloat(summary.days.count) / 180)
        return min(0.72, max(0.28, value))
    }

    var body: some View {
        Chart {
            ForEach(summary.days) { day in
                BarMark(
                    x: .value("Time", day.date, unit: calendarComponent),
                    y: .value(
                        "Listening minutes",
                        min(day.minutes, chartMaximum)
                    ),
                    width: .ratio(barWidthRatio)
                )
                .cornerRadius(
                    min(5, 90 / CGFloat(max(1, summary.days.count)))
                )
                .foregroundStyle(barStyle(for: day))
                .opacity(
                    selectedDayDate == nil || selectedDayDate == day.date
                        ? 1
                        : 0.72
                )
                .accessibilityLabel(accessibilityLabel(for: day))
            }

            if let hoveredDay {
                RuleMark(
                    x: .value(
                        "Hovered time",
                        hoveredDay.date,
                        unit: calendarComponent
                    )
                )
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color(hex: 0xD2C3FF))
            }
        }
        .chartYScale(domain: 0...chartMaximum)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: chartTicks) { value in
                AxisGridLine()
                    .foregroundStyle(Color.white.opacity(0.14))
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(axisLabel(minutes))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xAAA7B0))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let nextDate = chartDay(
                                    at: location,
                                    proxy: proxy,
                                    geometry: geometry
                                )?.date
                                if hoveredDayDate != nextDate {
                                    hoveredDayDate = nextDate
                                }
                            case .ended:
                                if hoveredDayDate != nil {
                                    hoveredDayDate = nil
                                }
                            }
                        }
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    guard let day = chartDay(
                                        at: value.location,
                                        proxy: proxy,
                                        geometry: geometry
                                    ) else { return }
                                    onSelect(day.date)
                                }
                        )

                    if let hoveredDay,
                       let origin = tooltipOrigin(
                           for: hoveredDay,
                           proxy: proxy,
                           geometry: geometry
                       )
                    {
                        ListeningHistoryChartTooltip(
                            date: bucketLabel(
                                hoveredDay.date,
                                includesWeekday: true
                            ),
                            listeningTime: listenedTime(hoveredDay.seconds),
                            plays: hoveredDay.plays,
                            topSong: topSongTitle(for: hoveredDay)
                        )
                        .frame(width: 190, alignment: .leading)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func chartDay(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> ListeningHistoryDay? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return nil }

        let plotX = location.x - frame.minX
        let positionedDays: [(day: ListeningHistoryDay, x: CGFloat)] =
            summary.days.compactMap { day in
                guard let x = proxy.position(forX: day.date) else { return nil }
                return (day, x)
            }
        guard let index = ListeningHistoryChartHitTesting.nearestIndex(
            to: plotX,
            positions: positionedDays.map(\.x)
        ) else { return nil }
        return positionedDays[index].day
    }

    private func tooltipOrigin(
        for day: ListeningHistoryDay,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard
            let plotFrame = proxy.plotFrame,
            let plotX = proxy.position(forX: day.date)
        else { return nil }
        let frame = geometry[plotFrame]
        let anchorX = frame.minX + plotX
        let tooltipWidth: CGFloat = 190
        let gap: CGFloat = 10
        let trailingCandidate = anchorX + gap
        let unclampedX = trailingCandidate + tooltipWidth
                <= geometry.size.width - 8
            ? trailingCandidate
            : anchorX - tooltipWidth - gap
        let maximumX = max(8, geometry.size.width - tooltipWidth - 8)
        return CGPoint(
            x: min(maximumX, max(8, unclampedX)),
            y: max(0, frame.minY + 8)
        )
    }

    private func barStyle(for day: ListeningHistoryDay) -> AnyShapeStyle {
        let colors = day.id == peakDayID
            ? [Color(hex: 0xFF806C), Color(hex: 0x8A42EB)]
            : [Color(hex: 0x9B7AFF), Color(hex: 0x5D35D8)]
        return AnyShapeStyle(
            LinearGradient(
                colors: colors,
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func accessibilityLabel(for day: ListeningHistoryDay) -> String {
        let playLabel = day.plays == 1 ? "play" : "plays"
        return "\(bucketLabel(day.date)): \(listenedTime(day.seconds)), "
            + "\(day.plays) \(playLabel)"
    }

    private func topSongTitle(for day: ListeningHistoryDay) -> String? {
        guard let dayIndex = summary.days.firstIndex(where: { $0.id == day.id }) else {
            return nil
        }
        return summary.songSeries
            .filter { $0.days.indices.contains(dayIndex) }
            .max {
                let lhs = $0.days[dayIndex]
                let rhs = $1.days[dayIndex]
                if lhs.seconds != rhs.seconds {
                    return lhs.seconds < rhs.seconds
                }
                return lhs.plays < rhs.plays
            }?
            .track.title
    }

    private func bucketLabel(
        _ date: Date,
        includesWeekday: Bool = false
    ) -> String {
        let format: String
        if summary.granularity == .hour {
            format = includesWeekday ? "EEEE, MMM d, h a" : "MMM d, h a"
        } else {
            format = includesWeekday ? "EEEE, MMM d" : "MMM d"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func listenedTime(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        if value > 0, value < 60 {
            return "\(max(1, Int(value.rounded()))) sec"
        }
        return "\(Int((value / 60).rounded()).formatted()) min"
    }

    private func axisLabel(_ value: Double) -> String {
        let absolute = abs(value)
        if absolute == 0 { return "0m" }
        if absolute >= 60 {
            let hours = value / 60
            let precision = abs(hours) >= 10 ? 0 : 1
            return "\(formattedNumber(hours, precision: precision))h"
        }
        if absolute >= 10 {
            return "\(Int(value.rounded()).formatted())m"
        }
        let precision = absolute >= 1 ? 1 : 2
        return "\(formattedNumber(value, precision: precision))m"
    }

    private func formattedNumber(_ value: Double, precision: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0...precision))
                .grouping(.automatic)
        )
    }
}

private struct ListeningHistoryMetric: View {
    let symbol: String
    let accent: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.07), in: Circle())
                .overlay {
                    Circle().stroke(accent, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(value)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFAF9FD))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0x8F8C99))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
    }
}

private struct ListeningHistorySongRow: View {
    let position: Int
    let song: ListeningHistorySongSeries
    let maximumSeconds: TimeInterval
    let listeningTime: String

    private var progress: CGFloat {
        CGFloat(min(1, max(0, song.seconds / max(1, maximumSeconds))))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(position.formatted())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(hex: 0x777481))
                .frame(width: 18, alignment: .trailing)

            TrackArtworkView(
                track: song.track,
                symbolSize: 11,
                cornerRadius: 6
            )
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.track.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF5F3F9))
                    .lineLimit(1)

                Text(song.track.artist)
                    .font(.system(size: 8))
                    .foregroundStyle(Color(hex: 0x85818E))
                    .lineLimit(1)
            }
            .frame(width: 188, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.055))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: 0xA36CFF),
                                    Color(hex: 0x7545ED)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geometry.size.width * progress))
                }
            }
            .frame(height: 5)

            Text(listeningTime)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(hex: 0xBEA8FF))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)

            Text("\(song.plays.formatted()) \(song.plays == 1 ? "play" : "plays")")
                .font(.system(size: 8))
                .foregroundStyle(Color(hex: 0x777481))
                .monospacedDigit()
                .frame(width: 55, alignment: .trailing)
        }
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }
}

private struct ListeningHistoryFooterItem: View {
    let value: String
    let label: String
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(hex: 0x85818E))
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ListeningHistoryChartTooltip: View {
    let date: String
    let listeningTime: String
    let plays: Int
    let topSong: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(date)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(hex: 0xAAA6B2))

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(listeningTime)
                    .font(.system(size: 14, weight: .bold))
                Text("\(plays.formatted()) \(plays == 1 ? "play" : "plays")")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0xAAA6B2))
            }

            Text(topSong.map { "Top song: \($0)" } ?? "No listening recorded")
                .font(.system(size: 9))
                .foregroundStyle(Color(hex: 0x8C8895))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minWidth: 156, maxWidth: 230, alignment: .leading)
        .background(Color(hex: 0x11131D).opacity(0.93))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(hex: 0xB99CFF).opacity(0.25), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: Color.black.opacity(0.75), radius: 19, y: 7)
    }
}

private struct ListeningHistoryRankedSongCard: View {
    let position: Int
    let song: ListeningHistoryRankedSong
    let listeningTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TrackArtworkView(
                    track: song.track,
                    symbolSize: 28,
                    cornerRadius: 12
                )
                .frame(width: 146, height: 146)

                Text("#\(position)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0x080910).opacity(0.85), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .padding(7)
            }

            Text(song.track.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0xF8F7FB))
                .lineLimit(1)
                .padding(.top, 9)

            Text(song.track.artist)
                .font(.system(size: 9))
                .foregroundStyle(Color(hex: 0x9894A1))
                .lineLimit(1)
                .padding(.top, 4)

            Text(
                "\(listeningTime) · \(song.plays.formatted()) "
                    + (song.plays == 1 ? "play" : "plays")
            )
            .font(.system(size: 9))
            .foregroundStyle(Color(hex: 0xBBA7FF))
            .lineLimit(1)
            .padding(.top, 5)
        }
        .frame(width: 146, alignment: .leading)
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
                    if LibraryCollectionLayoutPolicy.showsHero(for: model.section) {
                        CollectionHeroView(onAddSongs: presentSongPicker)
                            .frame(height: 310)
                    } else {
                        LibraryFilterPills(style: .compactTop)

                        if !LibraryCollectionLayoutPolicy.recentlyAddedTracks(
                            from: model.displayedTracks
                        ).isEmpty {
                            RecentlyAddedSection(availableWidth: max(proxy.size.width - 56, 0))
                        }
                    }

                    TrackAreaView(
                        showAlbum: proxy.size.width >= 535,
                        onAddSongs: presentSongPicker,
                        showsFilters: model.section != .library,
                        topPadding: model.section == .library ? 0 : 18
                    )
                    .frame(
                        minHeight: model.section == .library
                            ? 360
                            : max(proxy.size.height - 310, 360),
                        alignment: .top
                    )
                }
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $playlistForSongPicker) { playlist in
            MacPlaylistSongPicker(playlistID: playlist.id)
        }
    }

    private func presentSongPicker() {
        guard let playlist = model.selectedPlaylist else { return }
        playlistForSongPicker = playlist
    }
}

enum LibraryCollectionLayoutPolicy {
    static func showsHero(for section: AppSection) -> Bool {
        section != .library
    }

    static func recentlyAddedTracks(from tracks: [Track]) -> [Track] {
        tracks.sorted {
            if $0.dateAdded == $1.dateAdded {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.dateAdded > $1.dateAdded
        }
    }
}

private struct LibraryFilterPills: View {
    enum Style {
        case compactTop
        case standard
    }

    @EnvironmentObject private var model: PlayerModel
    let style: Style

    private var isCompact: Bool { style == .compactTop }

    var body: some View {
        HStack(spacing: isCompact ? 7 : 9) {
            ForEach(SongFilter.allCases) { filter in
                Button {
                    model.filter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: isCompact ? 10 : 11, weight: .medium))
                        .foregroundStyle(model.filter == filter ? Color.white : Color(hex: 0xAEB3C1))
                        .padding(.horizontal, isCompact ? 12 : 15)
                        .frame(height: isCompact ? 26 : 34)
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
                            radius: isCompact ? 8 : 12,
                            y: isCompact ? 4 : 6
                        )
                }
                .buttonStyle(PressableScaleStyle())
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, isCompact ? 28 : 0)
        .padding(.top, isCompact ? 26 : 0)
        .padding(.bottom, isCompact ? 8 : 10)
    }
}

private struct RecentlyAddedSection: View {
    @EnvironmentObject private var model: PlayerModel
    let availableWidth: CGFloat

    private var tracks: [Track] {
        LibraryCollectionLayoutPolicy.recentlyAddedTracks(from: model.displayedTracks)
    }

    private var cardWidth: CGFloat {
        max(128, (availableWidth - 90) / 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FRESH TO YOUR LIBRARY")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.3)
                        .foregroundStyle(Color(hex: 0x8F8A9D))

                    Text("Recently Added")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.appInk)
                }

                Spacer(minLength: 0)

                Text("\(tracks.count) newest")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(tracks) { track in
                        RecentlyAddedArtworkCard(track: track, cardWidth: cardWidth)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

enum RecentlyAddedArtworkOverlayPolicy {
    static func shouldShow(isHovering: Bool, isCurrent _: Bool) -> Bool {
        isHovering
    }
}

enum RecentlyAddedArtworkActionPolicy {
    enum Action {
        case togglePlayback
        case selectAndPlay
    }

    static func action(isCurrent: Bool) -> Action {
        isCurrent ? .togglePlayback : .selectAndPlay
    }
}

private struct RecentlyAddedArtworkCard: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    let cardWidth: CGFloat
    @State private var isHovering = false

    private var isCurrent: Bool {
        model.currentTrackID == track.id
    }

    private var playbackActionTitle: String {
        isCurrent && model.isPlaying ? "Pause" : "Play"
    }

    var body: some View {
        Button {
            switch RecentlyAddedArtworkActionPolicy.action(isCurrent: isCurrent) {
            case .togglePlayback:
                model.togglePlay()
            case .selectAndPlay:
                model.selectAndPlay(track)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                TrackArtworkView(
                    track: track,
                    symbol: track.kind == .video ? "play.fill" : "music.note",
                    symbolSize: 30,
                    cornerRadius: 9,
                    size: cardWidth
                )
                .frame(width: cardWidth, height: cardWidth)
                .overlay {
                    if RecentlyAddedArtworkOverlayPolicy.shouldShow(
                        isHovering: isHovering,
                        isCurrent: isCurrent
                    ) {
                        ZStack {
                            Color.black.opacity(0.18)

                            Image(systemName: isCurrent && model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 54, height: 54)
                                .background(Color.appAccent, in: Circle())
                                .shadow(color: Color(hex: 0x321690).opacity(0.50), radius: 14, y: 6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .transition(.opacity)
                    }
                }
                .shadow(color: Color.black.opacity(0.30), radius: 12, y: 7)

                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.appAccent : Color.appInk)
                    .lineLimit(1)
                    .padding(.top, 10)

                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .frame(width: cardWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("\(playbackActionTitle) \(track.title)")
        .accessibilityLabel("\(playbackActionTitle) \(track.title) by \(track.artist)")
    }
}

private struct CollectionHeroView: View {
    @EnvironmentObject private var model: PlayerModel
    let onAddSongs: () -> Void

    private var isLikedCollection: Bool { model.collectionTitle == "Liked Songs" }
    private var canAddSongs: Bool {
        model.section == .playlists && model.selectedPlaylist != nil
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
                    Group {
                        if model.section == .playlists, let playlist = model.selectedPlaylist {
                            PlaylistArtworkView(
                                playlist: playlist,
                                tracks: model.tracks,
                                size: proxy.size.width < 550 ? 202 : 232,
                                cornerRadius: 9
                            )
                        } else {
                            ArtworkView(
                                style: model.collectionArtwork,
                                symbol: symbol,
                                symbolSize: proxy.size.width < 550 ? 54 : 70,
                                cornerRadius: 9,
                                glow: true
                            )
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: proxy.size.width < 550 ? 202 : 232)
                        }
                    }
                    .shadow(color: Color(hex: 0x1F1B6F).opacity(0.42), radius: 28, y: 18)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(collectionKindLabel)
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

    private var collectionKindLabel: String {
        if model.section == .library { return "LIBRARY" }
        return isLikedCollection ? "YOUR COLLECTION" : "PLAYLIST"
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
    let onAddSongs: () -> Void
    let showsFilters: Bool
    let topPadding: CGFloat
    @State private var draggedTrackID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dropPreviewIndex: Int?
    @State private var isShowingImportChooser = false

    private var reorderablePlaylistID: UUID? {
        guard model.section == .playlists,
              let playlist = model.selectedPlaylist else { return nil }
        return playlist.id
    }

    var body: some View {
        VStack(spacing: 0) {
                if showsFilters {
                    LibraryFilterPills(style: .standard)
                }

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
                            Button {
                                isShowingImportChooser.toggle()
                            } label: {
                                Label("Add Music", systemImage: "plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    .background(Color.appAccent)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(PressableScaleStyle())
                            .help("Choose how to import music")
                            .popover(isPresented: $isShowingImportChooser, arrowEdge: .top) {
                                MacImportChooser(
                                    linkImportEnabled: LocalImportFeature.isEnabled,
                                    onImportLink: {
                                        isShowingImportChooser = false
                                        DispatchQueue.main.async {
                                            NotificationCenter.default.post(name: .importMusicFromLink, object: nil)
                                        }
                                    },
                                    onImportFiles: {
                                        isShowingImportChooser = false
                                        DispatchQueue.main.async { model.importLocalFiles() }
                                    }
                                )
                            }
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
        .padding(.top, topPadding)
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
                                if playlist.isSystem {
                                    model.toggleFavorite(track)
                                } else if isAdded {
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
            Button {
                model.selectAndPlay(track)
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title), by \(track.artist)")
            .accessibilityValue(isCurrent ? (model.isPlaying ? "Now playing" : "Selected") : "")
            .accessibilityHint("Starts playback of this song")
            .accessibilityAction(named: isFavorite ? "Remove from Liked Songs" : "Add to Liked Songs") {
                model.toggleFavorite(track)
            }
            .help("Play \(track.title)")

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
            .accessibilityLabel(isFavorite ? "Remove \(track.title) from Liked Songs" : "Add \(track.title) to Liked Songs")
            .help(isFavorite ? "Remove from Liked Songs" : "Add to Liked Songs")
        }
        .padding(.horizontal, 10)
        .frame(height: 61)
        .background((hovering || isCurrent) ? Color.white.opacity(0.055) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.appLine).frame(height: 1)
        }
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

private struct StorageFileInspection: Sendable {
    let id: UUID
    let url: URL?
}

private struct StorageInspectionResult: Sendable {
    let fileSizes: [UUID: Int64]
    let availableBytes: Int64
}

private struct StorageView: View {
    @EnvironmentObject private var model: PlayerModel
    let onImportLink: () -> Void
    @State private var searchText = ""
    @State private var scope: MacStorageScope = .songs
    @State private var sort: MacStorageSort = .title
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var fileSizes: [UUID: Int64] = [:]
    @State private var availableBytes: Int64 = 0
    @State private var deletionCandidate: Track?
    @State private var confirmsBatchDeletion = false
    @State private var isShowingImportChooser = false

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
    private var visibleTrackIDs: Set<UUID> { Set(visibleTracks.map(\.id)) }
    private var selectedVisibleTrackIDs: Set<UUID> {
        StorageSelectionPolicy.visibleSelection(
            from: selectedTrackIDs,
            visibleTrackIDs: visibleTrackIDs
        )
    }
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
                    Button {
                        isShowingImportChooser.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Import")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .opacity(0.78)
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 17)
                        .frame(height: 36)
                        .background(Color.appAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Choose how to import music")
                    .accessibilityLabel("Import music")
                    .popover(isPresented: $isShowingImportChooser, arrowEdge: .top) {
                        MacImportChooser(
                            linkImportEnabled: LocalImportFeature.isEnabled,
                            onImportLink: {
                                isShowingImportChooser = false
                                DispatchQueue.main.async { onImportLink() }
                            },
                            onImportFiles: {
                                isShowingImportChooser = false
                                DispatchQueue.main.async { model.importLocalFiles() }
                            }
                        )
                    }
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

                if isEditing, !selectedVisibleTrackIDs.isEmpty {
                    HStack {
                        Text("\(selectedVisibleTrackIDs.count) selected")
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
            await refreshStorageMetrics()
            reconcileVisibleSelection()
        }
        .onChange(of: scope) {
            reconcileVisibleSelection()
        }
        .onChange(of: searchText) {
            reconcileVisibleSelection()
        }
        .alert(item: $deletionCandidate) { track in
            Alert(
                title: Text(track.remoteID == nil ? "Delete original file?" : "Delete downloaded copy?"),
                message: Text(track.remoteID == nil
                    ? "This permanently deletes \(track.title) from this Mac."
                    : "This removes the cached copy from this Mac. The song remains available on the music server."),
                primaryButton: .destructive(Text("Delete")) { _ = delete(track) },
                secondaryButton: .cancel()
            )
        }
        .alert("Delete \(selectedVisibleTrackIDs.count) selected files?", isPresented: $confirmsBatchDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Files", role: .destructive) {
                let selected = visibleTracks.filter { selectedVisibleTrackIDs.contains($0.id) }
                let failedIDs = Set(selected.filter { !delete($0) }.map(\.id))
                selectedTrackIDs = failedIDs
                isEditing = !failedIDs.isEmpty
            }
        } message: {
            Text("Imported originals will be permanently deleted. Server downloads remain available to download again.")
        }
        .alert(
            "Couldn’t Delete File",
            isPresented: Binding(
                get: { model.fileOperationError != nil },
                set: { if !$0 { model.fileOperationError = nil } }
            )
        ) {
            Button("OK") { model.fileOperationError = nil }
        } message: {
            Text(model.fileOperationError ?? "The file could not be deleted.")
        }
    }

    @discardableResult
    private func delete(_ track: Track) -> Bool {
        if track.remoteID == nil {
            return model.deleteOriginalFile(track)
        } else {
            return model.deleteDownloadedCopy(track)
        }
    }

    private func refreshStorageMetrics() async {
        let inspections = model.tracks.map {
            StorageFileInspection(id: $0.id, url: $0.fileURL)
        }
        let result = await Task.detached(priority: .utility) {
            let fileSizes = Dictionary(uniqueKeysWithValues: inspections.map { inspection in
                let bytes = inspection.url.flatMap {
                    try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
                } ?? 0
                return (inspection.id, Int64(bytes))
            })
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? home.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return StorageInspectionResult(
                fileSizes: fileSizes,
                availableBytes: max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0)
            )
        }.value
        guard !Task.isCancelled else { return }
        fileSizes = result.fileSizes
        availableBytes = result.availableBytes
    }

    private func reconcileVisibleSelection() {
        selectedTrackIDs = selectedVisibleTrackIDs
    }
}

private struct MacImportChooser: View {
    let linkImportEnabled: Bool
    let onImportLink: () -> Void
    let onImportFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Music")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Text("Choose where your music is coming from.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
            }
            .padding(.horizontal, 17)
            .padding(.top, 16)
            .padding(.bottom, 13)

            Rectangle()
                .fill(Color.appLine)
                .frame(height: 1)
                .padding(.horizontal, 16)

            VStack(spacing: 3) {
                if linkImportEnabled {
                    Button(action: onImportLink) {
                        MacImportChoiceRow(
                            symbol: "link.badge.plus",
                            title: "Import from Link",
                            detail: "Paste a supported link, or search Spotify, SoundCloud, and YouTube"
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onImportFiles) {
                    MacImportChoiceRow(
                        symbol: "folder.badge.plus",
                        title: "Import Files",
                        detail: "Choose audio, video, files, or folders on this Mac"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
        .frame(width: 310)
        .background(Color.appSurfaceRaised)
        .presentationBackground(Color.appSurfaceRaised)
    }
}

private struct MacImportChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appViolet)
                .frame(width: 34, height: 34)
                .background(Color.appViolet.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.appMuted.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .contentShape(Rectangle())
        .background(
            Color.white.opacity(isHovering ? 0.055 : 0.001),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { isHovering = $0 }
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
    static let importMusicFromLink = Notification.Name("importMusicFromLink")
    static let openResonanceSettings = Notification.Name("openResonanceSettings")
}
