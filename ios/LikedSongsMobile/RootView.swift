import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MobileSection: Hashable {
    case library, playlists, storage, server
}

struct RootView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var selection: MobileSection = .library
    @State private var importing = false
    @State private var showsNowPlaying = false

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { LibraryView(importing: $importing) }
                }
                    .tabItem { Label("Library", systemImage: "waveform") }
                    .tag(MobileSection.library)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { PlaylistsView() }
                }
                    .tabItem { Label("Playlists", systemImage: "square.stack") }
                    .tag(MobileSection.playlists)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { StorageView() }
                }
                    .tabItem { Label("Storage", systemImage: "externaldrive") }
                    .tag(MobileSection.storage)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { ServerView() }
                }
                    .tabItem { Label("Server", systemImage: "network") }
                    .tag(MobileSection.server)
            }
            .toolbarBackground(Color.appBackground.opacity(0.96), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)

            if showsNowPlaying {
                NowPlayingView(isPresented: $showsNowPlaying)
                    .zIndex(10)
                    .transition(.move(edge: .bottom))
            }
        }
        .tint(.accent)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
    }
}

private struct PlayerAwareTab<Content: View>: View {
    @EnvironmentObject private var library: MusicLibrary
    @Binding private var showsNowPlaying: Bool
    private let content: Content

    init(showsNowPlaying: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _showsNowPlaying = showsNowPlaying
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if library.currentTrack != nil {
                    MobilePlayerBar(showsNowPlaying: $showsNowPlaying)
                }
            }

            if library.isDownloading || library.isUploading {
                ServerTransferPopup()
                    .padding(.horizontal, 20)
                    .padding(.bottom, library.currentTrack == nil ? 12 : 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeInOut(duration: 0.22), value: library.isDownloading || library.isUploading)
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @Binding var importing: Bool
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("MUSIC LIBRARY").eyebrow()
                            Text("Resonance").font(.system(size: 38, weight: .regular, design: .rounded))
                            Text("\(library.tracks.count) tracks • Stored locally")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ArtworkTile(symbol: "waveform").frame(width: 86, height: 86)
                    }
                    HStack {
                        Button { library.togglePlay() } label: {
                            Label(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.fill" : "play.fill")
                                .pill(color: .accent)
                        }
                        Button { library.shuffleEnabled.toggle() } label: {
                            Image(systemName: "shuffle").roundButton(active: library.shuffleEnabled)
                        }
                        Spacer()
                        Button { importing = true } label: { Label("Import", systemImage: "plus").pill(color: .violet) }
                    }
                    TextField("Search your music", text: $library.searchText)
                        .focused($searchIsFocused)
                        .submitLabel(.done)
                        .onSubmit { searchIsFocused = false }
                        .textFieldStyle(.plain)
                        .padding(13)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    if library.filteredTracks.isEmpty {
                        ContentUnavailableView("No songs yet", systemImage: "music.note", description: Text("Import audio or sync your music server."))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(library.filteredTracks) { track in
                                TrackRow(track: track, playbackQueue: library.filteredTracks)
                            }
                        }
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchIsFocused = false }
            }
        }
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    var playbackQueue: [MobileTrack]? = nil
    var playbackPlaylistID: UUID? = nil

    private var playbackPlaylist: MobilePlaylist? {
        guard let playbackPlaylistID else { return nil }
        return library.playlists.first { $0.id == playbackPlaylistID }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let playbackQueue {
                    library.play(track, in: playbackQueue, playlistID: playbackPlaylistID)
                } else {
                    library.play(track)
                }
            } label: {
                HStack(spacing: 12) {
                    TrackArtwork(track: track, fallbackSymbol: library.currentTrackID == track.id && library.isPlaying ? "waveform" : "music.note")
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(track.artist) • \(track.album)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(track.durationText).font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { library.toggleFavorite(track) } label: {
                Image(systemName: library.favorites.contains(track.id) ? "heart.fill" : "heart")
                    .foregroundStyle(library.favorites.contains(track.id) ? Color.accent : .secondary)
            }
            .buttonStyle(.plain)
            Menu {
                if let playlist = playbackPlaylist, playlist.trackIDs.contains(track.id) {
                    Button(role: .destructive) {
                        library.remove(track, from: playlist.id)
                    } label: {
                        Label(
                            playlist.isSystem ? "Remove from Liked Songs" : "Remove from Playlist",
                            systemImage: "text.badge.minus"
                        )
                    }
                    Divider()
                }
                let customPlaylists = library.playlists.filter { !$0.isSystem }
                if customPlaylists.isEmpty {
                    Text("Create a playlist first")
                } else {
                    Menu("Add to Playlist", systemImage: "text.badge.plus") {
                        ForEach(customPlaylists) { playlist in
                            Button {
                                library.add(track, to: playlist)
                            } label: {
                                Label(
                                    playlist.name,
                                    systemImage: playlist.trackIDs.contains(track.id) ? "checkmark" : "music.note.list"
                                )
                            }
                            .disabled(playlist.trackIDs.contains(track.id))
                        }
                    }
                }
                Button(role: .destructive) { library.remove(track) } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options for \(track.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contextMenu {
            if let playlist = playbackPlaylist, playlist.trackIDs.contains(track.id) {
                Button(
                    playlist.isSystem ? "Remove from Liked Songs" : "Remove from Playlist",
                    role: .destructive
                ) {
                    library.remove(track, from: playlist.id)
                }
                Divider()
            }
            ForEach(library.playlists.filter { !$0.isSystem }) { playlist in
                Button("Add to \(playlist.name)") { library.add(track, to: playlist) }
            }
            Button("Remove from library", role: .destructive) { library.remove(track) }
        }
    }
}

private struct PlaylistsView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var creating = false
    @State private var name = ""
    @State private var deletionCandidate: MobilePlaylist?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        ZStack {
            AppBackground()
            List {
                Section {
                    ForEach(library.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkTile(symbol: playlist.isSystem ? "heart.fill" : "music.note.list")
                                    .frame(width: 52, height: 52)
                                VStack(alignment: .leading) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(library.tracks(in: playlist).count) tracks").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !playlist.isSystem {
                                Button(role: .destructive) {
                                    deletionCandidate = playlist
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if !playlist.isSystem {
                                Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                    deletionCandidate = playlist
                                }
                            }
                        }
                    }
                } header: { Text("YOUR COLLECTIONS") }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Playlists")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $name)
                .focused($nameIsFocused)
                .submitLabel(.done)
                .onSubmit { createPlaylist() }
            Button("Create") { createPlaylist() }
            Button("Cancel", role: .cancel) { nameIsFocused = false; name = "" }
        }
        .confirmationDialog(
            "Delete \(deletionCandidate?.name ?? "this playlist")?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                library.deletePlaylist(playlist)
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("Songs in this playlist will remain in your music library.")
        }
    }

    private func createPlaylist() {
        nameIsFocused = false
        library.createPlaylist(name)
        name = ""
        creating = false
    }
}

private struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @State private var addingToPlaylist: MobilePlaylist?
    @State private var confirmsDeletion = false
    let playlistID: UUID
    private var playlist: MobilePlaylist? { library.playlists.first { $0.id == playlistID } }
    private var playlistTracks: [MobileTrack] { playlist.map(library.tracks(in:)) ?? [] }

    var body: some View {
        ZStack {
            AppBackground()
            if let playlist, playlistTracks.isEmpty {
                ContentUnavailableView {
                    Label("No Songs", systemImage: "music.note.list")
                } description: {
                    Text(playlist.isSystem ? "Like songs to add them here." : "Add songs from your library to this playlist.")
                } actions: {
                    if !playlist.isSystem {
                        Button("Add Songs") { addingToPlaylist = playlist }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    HStack(spacing: 12) {
                        Button {
                            if let playlist {
                                library.togglePlayback(of: playlist)
                            }
                        } label: {
                            if let playlist {
                                let isPlaying = library.isPlaylistPlaying(playlist)
                                let isActive = library.isPlaylistPlaybackActive(playlist)
                                Label(
                                    isPlaying ? "Pause" : (library.shuffleEnabled && !isActive ? "Shuffle Play" : "Play"),
                                    systemImage: isPlaying ? "pause.fill" : (library.shuffleEnabled && !isActive ? "shuffle" : "play.fill")
                                )
                                .pill(color: .accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        Button {
                            library.shuffleEnabled.toggle()
                        } label: {
                            Image(systemName: "shuffle").roundButton(active: library.shuffleEnabled)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    ForEach(playlistTracks) {
                        TrackRow(
                            track: $0,
                            playbackQueue: playlistTracks,
                            playbackPlaylistID: playlistID
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        library.moveTracks(in: playlistID, fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            if let playlist, !playlist.isSystem {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { addingToPlaylist = playlist } label: {
                        Label("Add Songs", systemImage: "plus")
                    }
                    if playlistTracks.count > 1 {
                        EditButton()
                    }
                    Menu {
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            confirmsDeletion = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $addingToPlaylist) { playlist in
            PlaylistSongPicker(playlistID: playlist.id)
        }
        .confirmationDialog(
            "Delete \(playlist?.name ?? "this playlist")?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible,
            presenting: playlist
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                library.deletePlaylist(playlist)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Songs in this playlist will remain in your music library.")
        }
    }
}

private struct PlaylistSongPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    let playlistID: UUID

    private var playlist: MobilePlaylist? {
        library.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        NavigationStack {
            List(library.tracks) { track in
                Button {
                    guard let playlist else { return }
                    if playlist.trackIDs.contains(track.id) {
                        library.remove(track, from: playlist.id)
                    } else {
                        library.add(track, to: playlist)
                    }
                } label: {
                    HStack(spacing: 12) {
                        TrackArtwork(track: track).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).foregroundStyle(.primary).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if playlist?.trackIDs.contains(track.id) == true {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct StorageView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var searchText = ""
    @State private var scope: StorageScope = .songs
    @State private var sort: StorageSort = .title
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var fileSizes: [UUID: Int64] = [:]
    @State private var availableBytes: Int64 = 0
    @State private var deletionCandidate: MobileTrack?
    @State private var showsBatchDeleteConfirmation = false
    @FocusState private var searchIsFocused: Bool

    private var visibleTracks: [MobileTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = library.tracks.filter { track in
            switch scope {
            case .songs: true
            case .downloads: track.sourceServer != nil || track.remoteID != nil
            case .files: track.sourceServer == nil && track.remoteID == nil
            }
        }
        let searched = query.isEmpty ? scoped : scoped.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
                || $0.relativePath.localizedCaseInsensitiveContains(query)
        }
        return searched.sorted { lhs, rhs in
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

    private var downloadedTracks: [MobileTrack] {
        visibleTracks.filter { $0.sourceServer != nil || $0.remoteID != nil }
    }

    private var importedTracks: [MobileTrack] {
        visibleTracks.filter { $0.sourceServer == nil && $0.remoteID == nil }
    }

    private var downloadedBytes: Int64 {
        library.tracks
            .filter { $0.sourceServer != nil || $0.remoteID != nil }
            .reduce(0) { $0 + fileSizes[$1.id, default: 0] }
    }

    private var importedBytes: Int64 {
        library.tracks
            .filter { $0.sourceServer == nil && $0.remoteID == nil }
            .reduce(0) { $0 + fileSizes[$1.id, default: 0] }
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Song Storage")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Spacer()
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditing.toggle()
                                if !isEditing { selectedTrackIDs.removeAll() }
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(Color.accent)
                        .disabled(library.tracks.isEmpty)
                    }

                    StorageSummaryCard(
                        importedBytes: importedBytes,
                        importedCount: library.tracks.filter { $0.sourceServer == nil && $0.remoteID == nil }.count,
                        downloadedBytes: downloadedBytes,
                        downloadedCount: library.tracks.filter { $0.sourceServer != nil || $0.remoteID != nil }.count,
                        availableBytes: availableBytes
                    )

                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search songs, artists, albums, files…", text: $searchText)
                                .focused($searchIsFocused)
                                .submitLabel(.done)
                                .onSubmit { searchIsFocused = false }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(.white.opacity(0.09), lineWidth: 1)
                        }

                        Menu {
                            Picker("Sort songs", selection: $sort) {
                                ForEach(StorageSort.allCases) { option in
                                    Label(option.title, systemImage: option.symbol).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.headline)
                                .frame(width: 48, height: 48)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(.white.opacity(0.09), lineWidth: 1)
                                }
                        }
                        .accessibilityLabel("Sort songs")
                    }

                    StorageScopePicker(scope: $scope)

                    if isEditing, !selectedTrackIDs.isEmpty {
                        HStack {
                            Text("\(selectedTrackIDs.count) selected")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(role: .destructive) {
                                showsBatchDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if visibleTracks.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? scope.emptyTitle : "No Results",
                            systemImage: searchText.isEmpty ? scope.symbol : "magnifyingglass",
                            description: Text(searchText.isEmpty ? scope.emptyMessage : "Try a different search term or storage filter.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        if !downloadedTracks.isEmpty {
                            StorageSection(
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
                            StorageSection(
                                title: "IMPORTED ON IPHONE",
                                symbol: "iphone",
                                tracks: importedTracks,
                                fileSizes: fileSizes,
                                isEditing: isEditing,
                                selectedTrackIDs: $selectedTrackIDs,
                                deletionCandidate: $deletionCandidate
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchIsFocused = false }
            }
        }
        .task(id: library.tracks.map(\.id)) {
            refreshStorageMetrics()
            selectedTrackIDs.formIntersection(Set(library.tracks.map(\.id)))
        }
        .confirmationDialog(
            "Delete \(selectedTrackIDs.count) songs from this iPhone?",
            isPresented: $showsBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Songs", role: .destructive) {
                let selectedTracks = library.tracks.filter { selectedTrackIDs.contains($0.id) }
                selectedTracks.forEach(library.remove)
                selectedTrackIDs.removeAll()
                isEditing = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local song files. Songs stored on your server are not deleted.")
        }
        .confirmationDialog(
            "Delete \(deletionCandidate?.title ?? "this song") from this iPhone?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { track in
            Button("Delete Song", role: .destructive) { library.remove(track) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The server copy, if one exists, will remain available to download again.")
        }
    }

    private func refreshStorageMetrics() {
        fileSizes = Dictionary(uniqueKeysWithValues: library.tracks.map { track in
            let values = try? library.fileURL(for: track).resourceValues(forKeys: [.fileSizeKey])
            return (track.id, Int64(values?.fileSize ?? 0))
        })
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0)
    }
}

private enum StorageScope: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case downloads = "Downloads"
    case files = "Files"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .songs: "music.note.list"
        case .downloads: "icloud.and.arrow.down"
        case .files: "iphone"
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
        case .files: "Audio imported on this iPhone will appear here."
        }
    }
}

private enum StorageSort: String, CaseIterable, Identifiable {
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

private struct StorageScopePicker: View {
    @Binding var scope: StorageScope

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StorageScope.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { scope = option }
                } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(scope == option ? Color.accent : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .foregroundStyle(scope == option ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct StorageSummaryCard: View {
    let importedBytes: Int64
    let importedCount: Int
    let downloadedBytes: Int64
    let downloadedCount: Int
    let availableBytes: Int64

    private var totalBytes: Double {
        max(Double(importedBytes + downloadedBytes + availableBytes), 1)
    }

    private var importedEnd: Double { Double(importedBytes) / totalBytes }
    private var downloadedEnd: Double { importedEnd + Double(downloadedBytes) / totalBytes }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 15)
                Circle()
                    .trim(from: 0, to: max(importedEnd, 0.015))
                    .stroke(Color.violet, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: importedEnd, to: max(downloadedEnd, importedEnd + 0.015))
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage usage")
            .accessibilityValue("\(formatBytes(importedBytes + downloadedBytes)) used, \(formatBytes(availableBytes)) available")

            VStack(alignment: .leading, spacing: 11) {
                Text("Local audio").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    StorageMetric(color: .violet, title: "Local audio", bytes: importedBytes, detail: "\(importedCount) files")
                    Divider().padding(.horizontal, 10)
                    StorageMetric(color: .accent, title: "Server downloads", bytes: downloadedBytes, detail: "\(downloadedCount) files")
                    Divider().padding(.horizontal, 10)
                    StorageMetric(color: Color(hex: 0x7BA7E8), title: "Available", bytes: availableBytes, detail: "on iPhone")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(colors: [.violet.opacity(0.85), Color(hex: 0x6C9CD8).opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        }
    }
}

private struct StorageMetric: View {
    let color: Color
    let title: String
    let bytes: Int64
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
            }
            Text(formatBytes(bytes)).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.72)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StorageSection: View {
    let title: String
    let symbol: String
    let tracks: [MobileTrack]
    let fileSizes: [UUID: Int64]
    let isEditing: Bool
    @Binding var selectedTrackIDs: Set<UUID>
    @Binding var deletionCandidate: MobileTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(Color.violet)
                Text(title).eyebrow()
                Spacer()
                Text("\(tracks.count) \(tracks.count == 1 ? "SONG" : "SONGS")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)

            LazyVStack(spacing: 0) {
                ForEach(tracks) { track in
                    StorageTrackRow(
                        track: track,
                        fileSize: fileSizes[track.id, default: 0],
                        isEditing: isEditing,
                        isSelected: selectedTrackIDs.contains(track.id),
                        onSelect: {
                            if selectedTrackIDs.contains(track.id) {
                                selectedTrackIDs.remove(track.id)
                            } else {
                                selectedTrackIDs.insert(track.id)
                            }
                        },
                        onDelete: { deletionCandidate = track }
                    )
                    if track.id != tracks.last?.id {
                        Divider().padding(.leading, isEditing ? 112 : 70)
                    }
                }
            }
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
        }
    }
}

private struct StorageTrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    let fileSize: Int64
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: isEditing ? onSelect : { library.play(track) }) {
                HStack(spacing: 12) {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accent : .secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                    TrackArtwork(track: track)
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(track.artist) • \(track.album)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: track.sourceServer == nil ? "iphone" : "checkmark.circle")
                        .foregroundStyle(Color.violet)
                        .accessibilityHidden(true)
                    Text(formatBytes(fileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "Select \(track.title)" : "Play \(track.title) by \(track.artist)")

            if !isEditing {
                Menu {
                    Button { library.play(track) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete from iPhone", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 42, height: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options for \(track.title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isEditing ? 12 : 2)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.18), value: isEditing)
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct ServerView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var choosingUploads = false
    @State private var deletionCandidate: MobileRemoteSong?
    @State private var presentedSheet: ServerSheet?
    @State private var searchText = ""
    @State private var scope: ServerLibraryScope = .all
    @State private var sort: ServerLibrarySort = .title
    @State private var isSelecting = false
    @FocusState private var searchIsFocused: Bool

    private var isConnected: Bool {
        !library.remoteSongs.isEmpty
            || library.serverMessage.localizedCaseInsensitiveContains("connected")
            || library.serverMessage.localizedCaseInsensitiveContains("synced")
    }

    private var syncedCount: Int {
        library.remoteSongs.reduce(0) { $0 + (library.isSynced($1) ? 1 : 0) }
    }

    private var allSynced: Bool {
        !library.remoteSongs.isEmpty && syncedCount == library.remoteSongs.count
    }

    private var serverHost: String {
        URL(string: library.serverURL)?.host ?? library.serverURL
    }

    private var visibleSongs: [MobileRemoteSong] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.remoteSongs.filter { song in
            let matchesScope = switch scope {
            case .all: true
            case .onDevice: library.isSynced(song)
            case .notDownloaded: !library.isSynced(song)
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

    private var localTracksByRemoteID: [String: MobileTrack] {
        library.tracks.reduce(into: [:]) { result, track in
            guard let remoteID = track.remoteID, result[remoteID] == nil else { return }
            result[remoteID] = track
        }
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Music Server")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.2)
                        .padding(.bottom, 10)

                    serverStatusLine
                        .padding(.bottom, 24)

                    serverActions
                        .padding(.bottom, 12)

                    Divider()

                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search server library", text: $searchText)
                                .focused($searchIsFocused)
                                .submitLabel(.done)
                                .onSubmit { searchIsFocused = false }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(.white.opacity(0.045), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }

                        Menu {
                            Section("Filter") {
                                ForEach(ServerLibraryScope.allCases) { option in
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.18)) { scope = option }
                                    } label: {
                                        Label(option == .all ? "All Songs" : option.rawValue, systemImage: scope == option ? "checkmark" : option.symbol)
                                    }
                                }
                            }
                            Section("Sort By") {
                                ForEach(ServerLibrarySort.allCases) { option in
                                    Button {
                                        sort = option
                                    } label: {
                                        Label(option.title, systemImage: sort == option ? "checkmark" : option.symbol)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 46, height: 46)
                                .background(.white.opacity(0.045), in: Circle())
                                .overlay { Circle().stroke(.white.opacity(0.08), lineWidth: 1) }
                        }
                        .accessibilityLabel("Filter and sort server library")
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    ServerCatalogHeader()

                    if visibleSongs.isEmpty {
                        ContentUnavailableView(
                            library.remoteSongs.isEmpty ? "No Server Songs" : "No Results",
                            systemImage: library.remoteSongs.isEmpty ? "network.slash" : "magnifyingglass",
                            description: Text(library.remoteSongs.isEmpty ? "Connect and sync to load the server library." : "Try another search or filter.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        LazyVStack(spacing: 0) {
                            let artworkTracks = localTracksByRemoteID
                            ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                                ServerSongRow(
                                    song: song,
                                    number: index + 1,
                                    localTrack: artworkTracks[song.id],
                                    isSynced: library.isSynced(song),
                                    isSelecting: isSelecting,
                                    isSelected: library.selectedRemoteSongIDs.contains(song.id),
                                    onToggleSelection: { library.toggleRemoteSelection(song) },
                                    onDelete: { deletionCandidate = song }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .refreshable {
                guard !library.isSyncing, !library.isUploading else { return }
                await library.refreshCatalog()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchIsFocused = false }
            }
        }
        .task {
            let hasServer = !library.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAccessToken = !library.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasServer,
                  hasAccessToken,
                  !library.isSyncing,
                  !library.isUploading,
                  !library.isSyncingPlaylists else { return }
            await library.refreshCatalog()
        }
        .fileImporter(isPresented: $choosingUploads, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.uploadFiles(urls) } }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection: ServerConnectionSheet()
            }
        }
        .confirmationDialog("Delete this song from the server?", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } })) {
            Button("Delete from Server", role: .destructive) {
                if let song = deletionCandidate { Task { await library.deleteRemoteSong(song) } }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        }
    }

    private var serverStatusLine: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Label(isConnected ? "Connected" : "Offline", systemImage: "circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isConnected ? Color.green : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background((isConnected ? Color.green : Color.secondary).opacity(0.12), in: Capsule())

                Button { presentedSheet = .connection } label: {
                    HStack(spacing: 7) {
                        Text(serverHost.isEmpty ? "Add a server connection" : serverHost)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage server connection")
            }

            HStack(spacing: 8) {
                ServerMetric(symbol: "music.note", color: .violet, value: "\(library.remoteSongs.count)", label: "songs")
                Text("•").foregroundStyle(.tertiary)
                ServerMetric(
                    symbol: "list.bullet",
                    color: .violet,
                    value: "\(library.playlists.filter { !$0.isSystem }.count)",
                    label: "playlists"
                )
                Text("•").foregroundStyle(.tertiary)
                ServerMetric(
                    symbol: allSynced ? "checkmark" : "icloud.and.arrow.down",
                    color: allSynced ? .green : .accent,
                    value: "\(syncedCount)",
                    label: "on device"
                )
            }
        }
    }

    private var serverActions: some View {
        HStack(spacing: 0) {
            ServerTextActionButton(
                symbol: "tray.and.arrow.down",
                label: "Download",
                isDisabled: library.isSyncing || library.isUploading || (isSelecting && library.selectedRemoteSongIDs.isEmpty)
            ) {
                Task {
                    if isSelecting {
                        await library.downloadSelected()
                        isSelecting = false
                    } else {
                        await library.downloadAll()
                    }
                }
            }

            ServerActionDivider()

            ServerTextActionButton(symbol: "square.and.arrow.up", label: "Upload", isDisabled: library.isSyncing || library.isUploading) {
                choosingUploads = true
            }

            ServerActionDivider()

            ServerIconActionButton(
                symbol: "checklist",
                label: isSelecting ? "Cancel song selection" : "Select songs",
                isDisabled: library.isSyncing || library.isUploading,
                count: isSelecting ? library.selectedRemoteSongIDs.count : nil
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isSelecting {
                        isSelecting = false
                        library.selectedRemoteSongIDs.removeAll()
                    } else {
                        isSelecting = true
                        scope = .notDownloaded
                    }
                }
            }

            ServerActionDivider()

            ServerIconActionButton(
                symbol: "arrow.clockwise",
                label: "Refresh catalog and sync playlists",
                isDisabled: library.isSyncing || library.isUploading || library.isSyncingPlaylists,
                isSpinning: library.isRefreshingCatalog
            ) {
                Task {
                    await library.refreshCatalog()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 58)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private enum ServerSheet: String, Identifiable {
    case connection
    var id: String { rawValue }
}

private enum ServerLibraryScope: String, CaseIterable, Identifiable {
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

private enum ServerLibrarySort: String, CaseIterable, Identifiable {
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

private struct ServerMetric: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(color.opacity(0.12), in: Circle())
            Text(value)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    }
}

private struct ServerTextActionButton: View {
    let symbol: String
    let label: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
        } label: {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.serverActionForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(ServerActionButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityValue(isDisabled ? "Unavailable while another transfer is active" : "")
    }
}

private struct ServerIconActionButton: View {
    let symbol: String
    let label: String
    var isDisabled = false
    var isSpinning = false
    var count: Int? = nil
    let action: () -> Void
    @State private var spinRotation = 0.0

    var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
        } label: {
            Group {
                if let count {
                    Text("\(count)")
                        .fontWeight(.bold)
                        .monospacedDigit()
                } else {
                    Image(systemName: symbol)
                }
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.serverActionForeground)
                .rotationEffect(.degrees(spinRotation))
                .frame(width: 54, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(ServerActionButtonStyle())
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(isDisabled ? "Unavailable while another transfer is active" : "")
        .onAppear {
            if isSpinning { performFullSpin() }
        }
        .onChange(of: isSpinning) { _, active in
            if active { performFullSpin() }
        }
    }

    private func performFullSpin() {
        withAnimation(.timingCurve(0.55, 0, 0.1, 1, duration: 0.82)) {
            spinRotation += 360
        }
    }
}

private struct ServerActionDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 30)
    }
}

private struct ServerActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.055 : 0))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct ServerTransferPopup: View {
    @EnvironmentObject private var library: MusicLibrary

    private var progress: Double {
        if library.isUploading { return library.uploadProgress }
        return library.downloadProgress
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: library.isUploading ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.violet)
                .frame(width: 36, height: 36)
                .background(Color.violet.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(library.isUploading ? "Uploading" : "Downloading")
                    .font(.caption.weight(.semibold))
                Text(activeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: progress).tint(.violet)
            }

            Spacer(minLength: 4)

            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private var activeDetail: String {
        if library.isUploading { return library.uploadDetail }
        return library.downloadDetail
    }
}

private struct ServerCatalogHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("#")
                .frame(width: 24, alignment: .leading)
            Text("Title")
            Spacer()
            Text("Time")
                .frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 28)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ServerSongRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let song: MobileRemoteSong
    let number: Int
    let localTrack: MobileTrack?
    let isSynced: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

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

    private var mediaKind: String {
        let type = song.contentType.lowercased()
        let fileExtension = URL(fileURLWithPath: song.filename).pathExtension.lowercased()
        return type.contains("video") || ["mp4", "mov", "m4v", "webm"].contains(fileExtension) ? "Video" : "Audio"
    }

    private var trailingDetail: String {
        localTrack?.durationText ?? formatBytes(song.size)
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: isSelecting ? onToggleSelection : primaryAction) {
                HStack(spacing: 10) {
                    Group {
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accent : .secondary)
                        } else {
                            Text("\(number)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(width: 24, alignment: .leading)

                    Group {
                        if let localTrack {
                            TrackArtwork(track: localTrack)
                        } else {
                            ArtworkTile(symbol: "music.note")
                        }
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if isSynced {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color.green)
                            }
                        }
                        Text("\(displayArtist) / \(mediaKind)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !displayAlbum.isEmpty {
                            Text(displayAlbum)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(trailingDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelecting ? (isSelected ? "Deselect \(song.title)" : "Select \(song.title)") : (isSynced ? "Play \(song.title)" : "Download \(song.title)"))

            if !isSelecting {
                Menu {
                    if !isSynced {
                        Button("Download", systemImage: "icloud.and.arrow.down") { Task { await library.download(song) } }
                    }
                    Button("Delete from Server", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options for \(song.title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 76)
        .background(isSelected ? Color.white.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .bottom) { Divider() }
        .animation(.easeInOut(duration: 0.18), value: isSelecting)
    }

    private func primaryAction() {
        if let localTrack {
            library.play(localTrack)
        } else {
            Task { await library.download(song) }
        }
    }
}

private struct ServerConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @FocusState private var focusedField: ConnectionField?

    private enum ConnectionField: Hashable {
        case url, accessToken, adminKey
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://music.unblocked.mov", text: $library.serverURL)
                        .focused($focusedField, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .accessToken }
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Server access token", text: $library.serverToken)
                        .focused($focusedField, equals: .accessToken)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .adminKey }
                        .textContentType(.password)
                    SecureField("Server admin key", text: $library.serverAdminToken)
                        .focused($focusedField, equals: .adminKey)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .textContentType(.password)
                }
                Section {
                    Button {
                        focusedField = nil
                        Task {
                            await library.refreshCatalog()
                            if library.serverMessage.localizedCaseInsensitiveContains("connected") {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if library.isSyncing { ProgressView().padding(.trailing, 6) }
                            Text(library.isSyncing ? "Connecting…" : "Connect")
                            Spacer()
                        }
                    }
                    .disabled(library.isSyncing)
                }
                Section {
                    Text(library.serverMessage).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        focusedField = nil
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
    }
}

private struct MobilePlayerBar: View {
    @EnvironmentObject private var library: MusicLibrary
    @Binding var showsNowPlaying: Bool

    var body: some View {
        VStack(spacing: 7) {
            if let track = library.currentTrack {
                HStack(spacing: 11) {
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                            showsNowPlaying = true
                        }
                    } label: {
                        HStack(spacing: 11) {
                            TrackArtwork(track: track).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing for \(track.title)")
                    Button { library.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button { library.togglePlay() } label: {
                        Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                            .background(Color.appSurfaceRaised, in: Circle())
                            .overlay { Circle().stroke(Color.accent.opacity(0.72), lineWidth: 1.5) }
                            .foregroundStyle(.white)
                            .shadow(color: Color.accent.opacity(0.22), radius: 8)
                    }
                    Button { library.next() } label: { Image(systemName: "forward.end.fill") }
                }
                GeometryReader { geometry in
                    let duration = max(track.duration, 0.01)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.13)).frame(height: 3)
                        Capsule().fill(Color.accent).frame(width: geometry.size.width * min(library.position / duration, 1), height: 3)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { library.seek(to: $0.location.x / max(geometry.size.width, 1)) })
                }.frame(height: 5)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(Color.appSurface.opacity(0.98))
        .background(.ultraThinMaterial.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct NowPlayingView: View {
    @EnvironmentObject private var library: MusicLibrary
    @Binding var isPresented: Bool
    @State private var dismissalOffset: CGFloat = 0

    var body: some View {
        ZStack {
            AppBackground()
            if let track = library.currentTrack {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        TrackArtwork(track: track, fallbackSymbol: "waveform")
                            .frame(maxWidth: 330)
                            .aspectRatio(1, contentMode: .fit)
                            .shadow(color: .black.opacity(0.35), radius: 28, y: 18)

                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(track.title)
                                    .font(.title2.weight(.bold))
                                    .lineLimit(2)
                                Text(track.artist)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text(track.album)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { library.toggleFavorite(track) } label: {
                                Image(systemName: library.favorites.contains(track.id) ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(library.favorites.contains(track.id) ? Color.accent : .primary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(library.favorites.contains(track.id) ? "Remove from Liked Songs" : "Add to Liked Songs")
                        }

                        progress(for: track)
                        transportControls
                        playbackOptions
                        trackDetails(track)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note")
            }
        }
        .offset(y: dismissalOffset)
        .scaleEffect(1 - min(dismissalOffset / 4_000, 0.025))
        .simultaneousGesture(dismissGesture)
        .preferredColorScheme(.dark)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard isDismissGesture(value) else { return }
                dismissalOffset = value.translation.height
            }
            .onEnded { value in
                guard isDismissGesture(value) else {
                    resetDismissalOffset()
                    return
                }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 220 {
                    dismissPlayer()
                } else {
                    resetDismissalOffset()
                }
            }
    }

    private func isDismissGesture(_ value: DragGesture.Value) -> Bool {
        value.startLocation.y < 340
            && value.translation.height > 0
            && abs(value.translation.height) > abs(value.translation.width)
    }

    private func resetDismissalOffset() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dismissalOffset = 0
        }
    }

    private func dismissPlayer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isPresented = false
        }
    }

    private var header: some View {
        HStack {
            Button { dismissPlayer() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("NOW PLAYING").eyebrow()
                Text("Resonance").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    private func progress(for track: MobileTrack) -> some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(max(library.position / max(track.duration, 0.01), 0), 1) },
                    set: { library.seek(to: $0) }
                ),
                in: 0...1
            )
            .tint(.accent)
            HStack {
                Text(timeText(library.position))
                Spacer()
                Text("-\(timeText(max(track.duration - library.position, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 44) {
            Button { library.previous() } label: {
                Image(systemName: "backward.end.fill").font(.title)
            }
            Button { library.togglePlay() } label: {
                Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 72, height: 72)
                    .background(Color.appSurfaceRaised, in: Circle())
                    .overlay { Circle().stroke(Color.accent.opacity(0.72), lineWidth: 2) }
                    .foregroundStyle(.white)
                    .shadow(color: Color.accent.opacity(0.24), radius: 14)
            }
            Button { library.next() } label: {
                Image(systemName: "forward.end.fill").font(.title)
            }
        }
        .buttonStyle(.plain)
    }

    private var playbackOptions: some View {
        HStack {
            Button { library.shuffleEnabled.toggle() } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .foregroundStyle(library.shuffleEnabled ? Color.accent : .secondary)
            }
            Spacer()
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button("\(rate, specifier: "%g")×") { library.playbackRate = Float(rate) }
                }
            } label: {
                Label("\(Double(library.playbackRate), specifier: "%g")×", systemImage: "speedometer")
            }
            Spacer()
            Button { library.repeatEnabled.toggle() } label: {
                Label("Repeat", systemImage: "repeat")
                    .foregroundStyle(library.repeatEnabled ? Color.accent : .secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
    }

    private func trackDetails(_ track: MobileTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SONG DETAILS").eyebrow()
            detailRow("Title", track.title)
            detailRow("Artist", track.artist)
            detailRow("Album", track.album)
            detailRow("Duration", track.durationText)
            detailRow("Source", track.sourceServer == nil ? "Stored locally" : "Music server")
            if let sourceServer = track.sourceServer {
                detailRow("Server", sourceServer)
            }
        }
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.subheadline)
    }

    private func timeText(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.appBackground
            RadialGradient(
                colors: [Color.violet.opacity(0.16), .clear],
                center: UnitPoint(x: 0.76, y: 0.04),
                startRadius: 10,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

private struct ArtworkTile: View {
    let symbol: String
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.violet, Color(hex: 0x874BFF), Color(hex: 0xB079FF)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
        }.clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct TrackArtwork: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    var fallbackSymbol = "music.note"

    var body: some View {
        Group {
            if let artwork = library.artwork(for: track) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkTile(symbol: fallbackSymbol)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private extension Color {
    static let appBackground = Color(hex: 0x020305)
    static let appSurface = Color(hex: 0x0B0C11)
    static let appSurfaceRaised = Color(hex: 0x12131A)
    static let accent = Color(hex: 0x7547FF)
    static let violet = Color(hex: 0x6540F5)
    static let serverActionForeground = Color(hex: 0xB0ADBF)
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private extension Text {
    func eyebrow() -> some View { font(.caption2.weight(.semibold)).tracking(1.6).foregroundStyle(.secondary) }
}

private extension View {
    func pill(color: Color) -> some View { font(.subheadline.weight(.bold)).padding(.horizontal, 17).frame(height: 42).background(color, in: Capsule()).foregroundStyle(.white) }
    func roundButton(active: Bool) -> some View { frame(width: 42, height: 42).background(active ? Color.violet : .white.opacity(0.08), in: Circle()).foregroundStyle(.white) }
    func serverActionButton() -> some View {
        font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(.white.opacity(0.07), in: Capsule())
            .foregroundStyle(.primary)
    }
    func fieldCard(symbol: String) -> some View {
        HStack { Image(systemName: symbol); self }
            .padding(13).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
