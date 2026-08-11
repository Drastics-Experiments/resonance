import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MobileSection: Hashable {
    case library, playlists, storage, server
}

struct RootView: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @State private var selection: MobileSection = .library
    @State private var importing = false
    @State private var showsNowPlaying = false

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { LibraryView() }
                }
                    .tabItem { Label("Library", systemImage: "waveform") }
                    .tag(MobileSection.library)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { PlaylistsView() }
                }
                    .tabItem { Label("Playlists", systemImage: "square.stack") }
                    .tag(MobileSection.playlists)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { StorageView(importing: $importing) }
                }
                    .tabItem { Label("Storage", systemImage: "externaldrive") }
                    .tag(MobileSection.storage)
                PlayerAwareTab(showsNowPlaying: $showsNowPlaying) {
                    NavigationStack { ServerView() }
                }
                    .tabItem { Label("Server", systemImage: "network") }
                    .tag(MobileSection.server)
            }
            .toolbarBackground(palette.background.opacity(0.96), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)

            if showsNowPlaying {
                NowPlayingView(isPresented: $showsNowPlaying)
                    .zIndex(10)
                    .transition(.move(edge: .bottom))
            }
        }
        .tint(palette.foregroundAccent)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
        .alert(item: $library.libraryRecoveryNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
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
            } else if let notice = library.transferNotice {
                MobileTransferNoticePopup(notice: notice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, library.currentTrack == nil ? 12 : 82)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.easeInOut(duration: 0.22), value: library.isDownloading || library.isUploading)
        .animation(.easeInOut(duration: 0.22), value: library.transferNotice)
    }
}

private struct LibraryView: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @State private var presentedSheet: LibrarySheet?
    @FocusState private var searchIsFocused: Bool

    private var recentlyAddedTracks: [MobileTrack] {
        Array(
            library.tracks
                .filter(library.belongsToActiveServerContext)
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(6)
        )
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("MUSIC LIBRARY").eyebrow()
                            Text("Resonance").font(.system(size: 38, weight: .regular, design: .rounded))
                            Text("\(library.tracksForActiveProfile.count) tracks • Stored locally")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProfileButton(
                            displayName: library.accountDisplayName ?? library.syncProfileName,
                            email: library.accountEmail,
                            imageURL: library.accountImageURL,
                            onClipEditor: { presentedSheet = .clipEditor },
                            onAppearance: { presentedSheet = .appearance },
                            onConnection: { presentedSheet = .profile }
                        )
                    }
                    HStack {
                        Button { library.togglePlay() } label: {
                            Label(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.fill" : "play.fill")
                                .pill(color: palette.accent)
                        }
                        .disabled(library.tracksForActiveProfile.isEmpty)
                        Button { library.shuffleEnabled.toggle() } label: {
                            Image(systemName: "shuffle").roundButton(
                                active: library.shuffleEnabled,
                                activeColor: palette.secondary
                            )
                        }
                        .disabled(library.tracksForActiveProfile.isEmpty)
                        Spacer()
                    }
                    if library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !recentlyAddedTracks.isEmpty {
                        RecentlyAddedSection(tracks: recentlyAddedTracks)
                    }
                    TextField("Search your music", text: $library.searchText)
                        .focused($searchIsFocused)
                        .submitLabel(.done)
                        .onSubmit { searchIsFocused = false }
                        .textFieldStyle(.plain)
                        .padding(13)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    if library.filteredTracks.isEmpty {
                        ContentUnavailableView("No songs yet", systemImage: "music.note", description: Text("Import audio or video, or sync your music server."))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        VStack(spacing: 0) {
                            MobileSongListHeader()
                            LazyVStack(spacing: 0) {
                                ForEach(Array(library.filteredTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(
                                        track: track,
                                        number: index + 1,
                                        playbackQueue: library.filteredTracks
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .profile:
                ServerConnectionSheet()
            case .clipEditor:
                MobileClipEditorSheet()
            case .appearance:
                ThemeSettingsSheet()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchIsFocused = false }
            }
        }
    }
}

private enum LibrarySheet: String, Identifiable {
    case profile, clipEditor, appearance
    var id: String { rawValue }
}

private struct ProfileButton: View {
    @Environment(\.resonancePalette) private var palette
    let displayName: String
    let email: String?
    let imageURL: URL?
    let onClipEditor: () -> Void
    let onAppearance: () -> Void
    let onConnection: () -> Void
    @State private var isEmailRevealed = false

    private var resolvedDisplayName: String {
        ResonanceEmailPrivacy.safeDisplayName(displayName, email: email)
    }

    private var initial: String {
        String(resolvedDisplayName.prefix(1)).uppercased()
    }

    var body: some View {
        Menu {
            Section(resolvedDisplayName) {
                if let email {
                    Button {
                        isEmailRevealed.toggle()
                    } label: {
                        Label(
                            ResonanceEmailPrivacy.displayedAddress(email, isRevealed: isEmailRevealed),
                            systemImage: isEmailRevealed ? "eye.slash" : "eye"
                        )
                    }
                    .accessibilityLabel(isEmailRevealed ? "Hide email address" : "Reveal email address")
                }
                Button("Clip Editor", systemImage: "waveform.path.ecg", action: onClipEditor)
            }
            Button("Appearance", systemImage: "paintpalette", action: onAppearance)
            Button("Account & Connection", systemImage: "person.crop.circle", action: onConnection)
        } label: {
            ZStack {
                Circle().fill(palette.secondary)
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(initial)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    Text(initial)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: palette.secondary.opacity(0.28), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(resolvedDisplayName) account")
        .accessibilityHint("Opens profile and settings tools")
        .onChange(of: email) { _, _ in isEmailRevealed = false }
    }
}

private struct ThemeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var themeStore: ResonanceThemeStore

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Choose a dark palette. Changes apply immediately and stay only on this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(ResonanceTheme.allCases) { theme in
                                themeCard(theme)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func themeCard(_ theme: ResonanceTheme) -> some View {
        let candidate = theme.palette
        let isSelected = themeStore.selectedTheme == theme

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                themeStore.selectedTheme = theme
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: candidate.gradientStops,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    HStack(spacing: 5) {
                        Circle().fill(candidate.accent).frame(width: 16, height: 16)
                        Circle().fill(candidate.secondary).frame(width: 16, height: 16)
                        Circle().fill(candidate.tertiary).frame(width: 16, height: 16)
                    }
                    .padding(9)
                }
                .frame(height: 94)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 6) {
                    Text(theme.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(candidate.ink)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(candidate.tertiary)
                    }
                }
            }
            .padding(10)
            .background(candidate.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? candidate.tertiary : candidate.divider, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Applies the \(theme.title) palette")
    }
}

private struct RecentlyAddedSection: View {
    @EnvironmentObject private var library: MusicLibrary
    let tracks: [MobileTrack]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("RECENTLY ADDED").eyebrow()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(tracks) { track in
                        Button {
                            library.play(track)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                TrackArtwork(track: track)
                                    .frame(width: 132, height: 132)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 132, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Play \(track.title) by \(track.artist)")
                        .accessibilityHint("Plays this recently added track")
                    }
                }
            }
        }
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    let number: Int
    var playbackQueue: [MobileTrack]? = nil
    var playbackPlaylistID: UUID? = nil

    private var playbackPlaylist: MobilePlaylist? {
        guard let playbackPlaylistID else { return nil }
        return library.playlists.first { $0.id == playbackPlaylistID }
    }

    var body: some View {
        HStack(spacing: 7) {
            Button {
                if let playbackQueue {
                    library.play(track, in: playbackQueue, playlistID: playbackPlaylistID)
                } else {
                    library.play(track)
                }
            } label: {
                LocalSongRowContent(
                    track: track,
                    number: number,
                    trailingDetail: track.durationText,
                    isPlaying: library.currentTrackID == track.id && library.isPlaying
                )
            }
            .buttonStyle(.plain)
        }
        .mobileCatalogRow()
        .contentShape(Rectangle())
        .contextMenu {
            trackActions
        }
    }

    @ViewBuilder
    private var trackActions: some View {
        Button {
            library.toggleFavorite(track)
        } label: {
            Label(
                library.favorites.contains(track.id) ? "Remove from Liked Songs" : "Add to Liked Songs",
                systemImage: library.favorites.contains(track.id) ? "heart.slash" : "heart"
            )
        }
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
        Button(role: .destructive) {
            library.remove(track)
        } label: {
            Label("Remove from Library", systemImage: "trash")
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
                                PlaylistArtworkTile(playlist: playlist)
                                    .frame(width: 52, height: 52)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(library.playlistEntryCount(playlist)) tracks").font(.caption).foregroundStyle(.secondary)
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
    @Environment(\.resonancePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @State private var addingToPlaylist: MobilePlaylist?
    @State private var confirmsDeletion = false
    let playlistID: UUID
    private var playlist: MobilePlaylist? { library.playlists.first { $0.id == playlistID } }
    private var playlistTracks: [MobileTrack] { playlist.map(library.tracks(in:)) ?? [] }
    private var playlistEntries: [MobilePlaylistPresentationEntry] {
        playlist.map(library.playlistEntries(in:)) ?? []
    }
    private var hasUnavailableEntries: Bool {
        playlistEntries.contains { !$0.isDownloaded }
    }

    var body: some View {
        ZStack {
            AppBackground()
            if let playlist, playlistEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Songs", systemImage: "music.note.list")
                } description: {
                    Text(playlist.isSystem ? "Like songs to add them here." : "Add songs from your library to this playlist.")
                } actions: {
                    if !playlist.isSystem {
                        Button("Add Songs") { addingToPlaylist = playlist }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.accent)
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
                                .pill(color: palette.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .disabled(playlistTracks.isEmpty)
                        .opacity(playlistTracks.isEmpty ? 0.5 : 1)
                        Button {
                            library.shuffleEnabled.toggle()
                        } label: {
                            Image(systemName: "shuffle").roundButton(
                                active: library.shuffleEnabled,
                                activeColor: palette.secondary
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Circle())
                        .disabled(playlistTracks.isEmpty)
                        .opacity(playlistTracks.isEmpty ? 0.5 : 1)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    MobileSongListHeader()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(Array(playlistEntries.enumerated()), id: \.element.id) { index, entry in
                        Group {
                            if let track = entry.track {
                                TrackRow(
                                    track: track,
                                    number: index + 1,
                                    playbackQueue: playlistTracks,
                                    playbackPlaylistID: playlistID
                                )
                            } else {
                                UnavailableMobilePlaylistRow(entry: entry, number: index + 1)
                            }
                        }
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
                .contentMargins(.horizontal, 20, for: .scrollContent)
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
                    if playlistTracks.count > 1 && !hasUnavailableEntries {
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
    @Environment(\.resonancePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    let playlistID: UUID

    private var playlist: MobilePlaylist? {
        library.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                List {
                    MobileSongListHeader()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    ForEach(Array(library.tracksForActiveProfile.enumerated()), id: \.element.id) { index, track in
                        Button {
                            guard let playlist else { return }
                            if playlist.trackIDs.contains(track.id) {
                                library.remove(track, from: playlist.id)
                            } else {
                                library.add(track, to: playlist)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                LocalSongRowContent(
                                    track: track,
                                    number: index + 1,
                                    trailingDetail: track.durationText
                                )
                                Image(systemName: playlist?.trackIDs.contains(track.id) == true ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(playlist?.trackIDs.contains(track.id) == true ? palette.accent : .secondary)
                                    .frame(width: 28, height: 44)
                            }
                            .mobileCatalogRow(isSelected: playlist?.trackIDs.contains(track.id) == true)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 1)
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
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @Binding var importing: Bool
    @State private var searchText = ""
    @State private var scope: StorageScope = .songs
    @State private var sort: StorageSort = .title
    @State private var isEditing = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var fileSizes: [UUID: Int64] = [:]
    @State private var availableBytes: Int64 = 0
    @State private var deletionCandidate: MobileTrack?
    @State private var showsBatchDeleteConfirmation = false
    @State private var presentedSheet: StorageSheet?
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
                        Menu {
                            Button("Import from Link", systemImage: "link.badge.plus") {
                                presentedSheet = .linkImport
                            }
                            Button("Import Files", systemImage: "doc.badge.plus") {
                                importing = true
                            }
                        } label: {
                            Text("Import")
                                .font(.headline)
                                .foregroundStyle(palette.foregroundAccent)
                        }
                        .accessibilityHint("Choose a link or files to import")
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isEditing.toggle()
                                if !isEditing { selectedTrackIDs.removeAll() }
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(palette.foregroundAccent)
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
                                title: "IMPORTED ON DEVICE",
                                symbol: "internaldrive",
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
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .linkImport:
                MobileLocalImportSheet()
            }
        }
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
            "Delete \(selectedTrackIDs.count) songs from this device?",
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
            "Delete \(deletionCandidate?.title ?? "this song") from this device?",
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
        fileSizes = library.tracks.reduce(into: [:]) { result, track in
            let values = try? library.fileURL(for: track).resourceValues(forKeys: [.fileSizeKey])
            result[track.id] = Int64(values?.fileSize ?? 0)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0)
    }
}

private enum StorageSheet: String, Identifiable {
    case linkImport
    var id: String { rawValue }
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
        case .files: "internaldrive"
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
        case .songs: "Import audio or video, or download songs from your music server."
        case .downloads: "Songs downloaded from the server will appear here."
        case .files: "Audio and video imported on this device will appear here."
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
    @Environment(\.resonancePalette) private var palette
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
                        .background(scope == option ? palette.accent : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
    @Environment(\.resonancePalette) private var palette
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
                    .stroke(palette.secondary, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: importedEnd, to: max(downloadedEnd, importedEnd + 0.015))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
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
                    StorageMetric(color: palette.secondary, title: "Local audio", bytes: importedBytes, detail: "\(importedCount) files")
                    Divider().padding(.horizontal, 10)
                    StorageMetric(color: palette.accent, title: "Server downloads", bytes: downloadedBytes, detail: "\(downloadedCount) files")
                    Divider().padding(.horizontal, 10)
                    StorageMetric(color: Color(hex: 0x7BA7E8), title: "Available", bytes: availableBytes, detail: "on device")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(colors: [palette.secondary.opacity(0.85), palette.tertiary.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
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
    @Environment(\.resonancePalette) private var palette
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
                Image(systemName: symbol).foregroundStyle(palette.foregroundAccent)
                Text(title).eyebrow()
                Spacer()
                Text("\(tracks.count) \(tracks.count == 1 ? "SONG" : "SONGS")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)

            VStack(spacing: 0) {
                MobileSongListHeader(trailingTitle: "Size")

                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        StorageTrackRow(
                            track: track,
                            number: index + 1,
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
                    }
                }
            }
        }
    }
}

private struct StorageTrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    let number: Int
    let fileSize: Int64
    let isEditing: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: isEditing ? onSelect : { library.play(track) }) {
                LocalSongRowContent(
                    track: track,
                    number: number,
                    trailingDetail: formatBytes(fileSize),
                    selectionState: isEditing ? isSelected : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "Select \(track.title)" : "Play \(track.title) by \(track.artist)")

        }
        .mobileCatalogRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .contextMenu {
            if !isEditing {
                Group {
                    Button { library.play(track) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete from Device", systemImage: "trash")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditing)
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct ServerView: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @State private var deletionCandidate: MobileRemoteSong?
    @State private var presentedSheet: ServerSheet?
    @State private var searchText = ""
    @State private var scope: ServerLibraryScope = .all
    @State private var sort: ServerLibrarySort = .title
    @State private var isSelecting = false
    @FocusState private var searchIsFocused: Bool

    private var isConnected: Bool { library.isServerConnected }

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
                if library.pendingRemoteSongMetadataCount > 0 {
                    return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .artist:
                if library.pendingRemoteSongMetadataCount > 0 {
                    return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
                }
                return lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
            case .fileSize:
                return lhs.size > rhs.size
            case .recentlyUpdated:
                return lhs.modifiedAt > rhs.modifiedAt
            }
        }
    }

    private var localTracksByRemoteID: [String: MobileTrack] {
        library.tracks.reduce(into: [:]) { result, track in
            guard library.belongsToActiveServerContext(track),
                  let remoteID = track.remoteID,
                  result[remoteID] == nil else { return }
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

                    if !library.transferFailures.isEmpty {
                        ServerTransferFailuresCard()
                            .padding(.bottom, 12)
                    }

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

                    if library.pendingRemoteSongMetadataCount > 0 {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(palette.foregroundAccent)
                            Text(
                                "Loading metadata for \(library.pendingRemoteSongMetadataCount) "
                                    + (library.pendingRemoteSongMetadataCount == 1 ? "song" : "songs")
                            )
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                    }

                    MobileSongListHeader()

                    if visibleSongs.isEmpty,
                       library.remoteSongs.isEmpty,
                       library.isRefreshingCatalog {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { index in
                                MobileServerCatalogPlaceholderRow(number: index + 1)
                            }
                        }
                    } else if visibleSongs.isEmpty {
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
            let hasAdminToken = !library.serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasServer,
                  hasAccessToken || hasAdminToken,
                  !library.isSyncing,
                  !library.isUploading,
                  !library.isSyncingPlaylists else { return }
            if hasAccessToken {
                await library.refreshCatalog()
            } else {
                await library.refreshClientConfiguration()
            }
        }
        .onChange(of: library.activeDownloadMode) { _, mode in
            guard mode == .streamOnly || mode == nil else { return }
            isSelecting = false
            library.selectedRemoteSongIDs.removeAll()
            scope = .all
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection: ServerConnectionSheet()
            case .linkImport: MobileLocalImportSheet()
            case .reviewedImport: MobileLocalImportSheet(reviewedServerMatch: true)
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
                ServerMetric(symbol: "music.note", color: palette.secondary, value: "\(library.remoteSongs.count)", label: "songs")
                Text("•").foregroundStyle(.tertiary)
                ServerMetric(
                    symbol: "list.bullet",
                    color: palette.secondary,
                    value: "\(library.playlists.filter { !$0.isSystem }.count)",
                    label: "playlists"
                )
                Text("•").foregroundStyle(.tertiary)
                ServerMetric(
                    symbol: allSynced ? "checkmark" : "icloud.and.arrow.down",
                    color: allSynced ? .green : palette.accent,
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
                label: library.activeDownloadMode == .streamOnly ? "Tap a Song" : "Download",
                isDisabled: library.isSyncing
                    || library.isUploading
                    || library.activeDownloadMode == nil
                    || library.activeDownloadMode == .streamOnly
                    || (isSelecting && library.selectedRemoteSongIDs.isEmpty)
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

            ServerIconActionButton(
                symbol: "icloud.and.arrow.up",
                label: "Upload downloaded songs missing from the server",
                isDisabled: library.isUploadTransferBusy || library.activeUploadMode != .localFile
            ) {
                Task { await library.uploadDownloadedSongsMissingFromServer() }
            }

            ServerActionDivider()

            ServerTextActionButton(
                symbol: uploadModeSymbol,
                label: uploadModeLabel,
                isDisabled: library.isUploadTransferBusy || library.activeUploadMode == nil
            ) {
                switch library.activeUploadMode {
                case .localFile, .serverSourceLink:
                    presentedSheet = .linkImport
                case .reviewedMatch:
                    presentedSheet = .reviewedImport
                case nil:
                    break
                }
            }

            ServerActionDivider()

            ServerIconActionButton(
                symbol: "checklist",
                label: isSelecting ? "Cancel song selection" : "Select songs",
                isDisabled: library.isSyncing
                    || library.isUploading
                    || library.activeDownloadMode == .streamOnly
                    || library.activeDownloadMode == nil,
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

    private var uploadModeLabel: String {
        switch library.activeUploadMode {
        case .localFile: "Files"
        case .serverSourceLink: "Link"
        case .reviewedMatch: "Review"
        case nil: "Upload"
        }
    }

    private var uploadModeSymbol: String {
        switch library.activeUploadMode {
        case .localFile: "square.and.arrow.up"
        case .serverSourceLink: "link.badge.plus"
        case .reviewedMatch: "checkmark.bubble"
        case nil: "nosign"
        }
    }
}

private struct ServerTransferFailuresCard: View {
    @EnvironmentObject private var library: MusicLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transfer issues", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.orange)
                Spacer()
                Button("Clear") { library.clearTransferFailures() }
                    .font(.caption.weight(.semibold))
            }

            ForEach(library.transferFailures) { failure in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(failure.operation.rawValue): \(failure.item)")
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        Text(failure.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if failure.retryTarget != nil {
                        Button("Retry") {
                            Task { await library.retryTransferFailure(failure) }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(library.isProfileTransitionBusy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }
}

private enum ServerSheet: String, Identifiable {
    case connection, linkImport, reviewedImport
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
    @Environment(\.resonancePalette) private var palette
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
                .foregroundStyle(palette.serverActionForeground)
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
    @Environment(\.resonancePalette) private var palette
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
                .foregroundStyle(palette.serverActionForeground)
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
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary

    private var progress: Double {
        if library.isUploading { return library.uploadProgress }
        return library.downloadProgress
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: library.isUploading ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.foregroundAccent)
                .frame(width: 36, height: 36)
                .background(palette.secondary.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(library.isUploading ? "Uploading" : "Downloading")
                    .font(.caption.weight(.semibold))
                Text(activeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: progress).tint(palette.foregroundAccent)
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

private struct MobileTransferNoticePopup: View {
    @EnvironmentObject private var library: MusicLibrary
    let notice: MobileTransferNotice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
                .frame(width: 36, height: 36)
                .background((notice.isError ? Color.orange : Color.green).opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.caption.weight(.semibold))
                Text(notice.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)

            Button { library.dismissTransferNotice() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss transfer message")
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

private struct MobileSongListHeader: View {
    var trailingTitle = "Time"

    var body: some View {
        HStack(spacing: 10) {
            Text("#")
                .frame(width: 24, alignment: .leading)
            Text("Title")
            Spacer()
            Text(trailingTitle)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
    }
}

private struct LocalSongRowContent: View {
    @Environment(\.resonancePalette) private var palette
    let track: MobileTrack
    let number: Int
    let trailingDetail: String
    var isPlaying = false
    var selectionState: Bool? = nil

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let selectionState {
                    Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectionState ? palette.accent : .secondary)
                } else {
                    Text("\(number)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(width: 24, alignment: .leading)

            TrackArtwork(track: track, fallbackSymbol: isPlaying ? "waveform" : "music.note")
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.green)
                        .fixedSize()
                }
                Text("\(track.artist) / \(track.mediaKindLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(track.album.isEmpty ? "Unknown Album" : track.album)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(trailingDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

private struct UnavailableMobilePlaylistRow: View {
    let entry: MobilePlaylistPresentationEntry
    let number: Int

    private var mediaKind: String {
        entry.remoteSong?.mediaKind == "video" ? "Video" : "Audio"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .frame(width: 24, alignment: .leading)

            Group {
                if let song = entry.remoteSong {
                    ServerArtwork(song: song)
                } else {
                    ArtworkTile(symbol: "icloud.slash")
                }
            }
            .frame(width: 52, height: 52)
            .grayscale(0.9)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(entry.artist) / \(mediaKind) / Not downloaded")
                    .font(.caption2)
                    .lineLimit(1)
                Text(entry.album)
                    .font(.caption2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Image(systemName: "icloud.slash")
                Text(entry.durationText)
                    .monospacedDigit()
            }
            .font(.caption2)
            .frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .opacity(0.55)
        .mobileCatalogRow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title) by \(entry.artist), not downloaded on this device")
    }
}

private extension MobileTrack {
    var mediaKindLabel: String {
        let fileExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm"].contains(fileExtension) ? "Video" : "Audio"
    }
}

private struct MobileCatalogRowStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(minHeight: 76)
            .background(isSelected ? Color.white.opacity(0.05) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 1)
            }
    }
}

private extension View {
    func mobileCatalogRow(isSelected: Bool = false) -> some View {
        modifier(MobileCatalogRowStyle(isSelected: isSelected))
    }
}

private struct ServerSongRow: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    let song: MobileRemoteSong
    let number: Int
    let localTrack: MobileTrack?
    let isSynced: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

    private var showsMetadataPlaceholder: Bool {
        song.isMetadataLoading && localTrack == nil
    }

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
        if song.mediaKind == "video" { return "Video" }
        let type = song.contentType.lowercased()
        let fileExtension = URL(fileURLWithPath: song.filename).pathExtension.lowercased()
        return type.contains("video") || ["mp4", "mov", "m4v", "webm"].contains(fileExtension) ? "Video" : "Audio"
    }

    private var trailingDetail: String {
        localTrack?.durationText ?? song.durationText ?? formatBytes(song.size)
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: isSelecting ? onToggleSelection : primaryAction) {
                HStack(spacing: 10) {
                    Group {
                        if isSelecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? palette.accent : .secondary)
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
                            ServerArtwork(song: song)
                        }
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        if showsMetadataPlaceholder {
                            MobileServerMetadataPlaceholder(width: 148, height: 11)
                            MobileServerMetadataPlaceholder(width: 96, height: 8)
                            MobileServerMetadataPlaceholder(width: 88, height: 9)
                        } else {
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
                    }
                    Spacer(minLength: 8)
                    Group {
                        if showsMetadataPlaceholder {
                            MobileServerMetadataPlaceholder(width: 42, height: 9)
                        } else {
                            Text(trailingDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                showsMetadataPlaceholder
                    ? "Loading server song metadata"
                    : isSelecting
                    ? (isSelected ? "Deselect \(song.title)" : "Select \(song.title)")
                    : (isSynced ? "Play \(song.title)" : "\(remoteActionTitle) \(song.title)")
            )

        }
        .mobileCatalogRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .contextMenu {
            if !isSelecting {
                Group {
                    if !isSynced {
                        Button(
                            remoteActionTitle,
                            systemImage: remoteActionSymbol
                        ) { Task { await library.download(song) } }
                    }
                    Button("Delete from Server", systemImage: "trash", role: .destructive, action: onDelete)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSelecting)
    }

    private func primaryAction() {
        if let localTrack {
            library.play(localTrack)
        } else {
            Task { await library.download(song) }
        }
    }

    private var remoteActionTitle: String {
        if library.activeDownloadMode == .streamOnly,
           song.contentType.lowercased().hasPrefix("video/") {
            return "Download Required"
        }
        return library.activeDownloadMode == .streamOnly ? "Stream" : "Download"
    }

    private var remoteActionSymbol: String {
        if library.activeDownloadMode == .streamOnly,
           song.contentType.lowercased().hasPrefix("video/") {
            return "video.slash"
        }
        return library.activeDownloadMode == .streamOnly
            ? "dot.radiowaves.left.and.right"
            : "icloud.and.arrow.down"
    }
}

private struct MobileServerCatalogPlaceholderRow: View {
    let number: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.45))
                .frame(width: 24, alignment: .leading)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 52, height: 52)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.65))
                }

            VStack(alignment: .leading, spacing: 7) {
                MobileServerMetadataPlaceholder(width: 148, height: 11)
                MobileServerMetadataPlaceholder(width: 96, height: 8)
                MobileServerMetadataPlaceholder(width: 88, height: 9)
            }
            Spacer(minLength: 8)
            MobileServerMetadataPlaceholder(width: 42, height: 9)
                .frame(width: 44, alignment: .trailing)
        }
        .mobileCatalogRow()
        .accessibilityLabel("Loading server song")
    }
}

private struct MobileServerMetadataPlaceholder: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .frame(width: width, height: height)
    }
}

private struct ServerConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @State private var isConnecting = false
    @State private var validationMessage: String?
    @State private var isEmailRevealed = false

    private var accountServerURL: String {
        ResonanceSocialAuthClient.accountSignInBaseURL.absoluteString
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: .constant(accountServerURL))
                        .textContentType(.URL)
                        .disabled(true)
                }
                .disabled(library.isProfileTransitionBusy)
                Section {
                    if let email = library.accountEmail {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ResonanceEmailPrivacy.safeDisplayName(library.accountDisplayName, email: email))
                                .font(.headline)
                            Button {
                                isEmailRevealed.toggle()
                            } label: {
                                Text(ResonanceEmailPrivacy.displayedAddress(email, isRevealed: isEmailRevealed))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isEmailRevealed ? "Hide email address" : "Reveal email address")
                        }
                        LabeledContent("Access", value: library.accountRole == "admin" ? "Administrator" : "Member")
                        Button("Sign out", role: .destructive) {
                            Task { await library.signOutAccount() }
                        }
                    } else {
                        if !library.serverToken.isEmpty {
                            Label("Legacy connection", systemImage: "exclamationmark.triangle")
                            Text("Continue with Clerk to finish upgrading this device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Sign in or create account") {
                            Task {
                                await library.signIn(with: .clerk)
                                validationMessage = library.serverConfigurationMessage
                            }
                        }
                        .disabled(library.isAuthenticatingAccount)
                        Text("Account sign-in always uses https://resonance-core.blithe-haven-9710.chatgpt.site/ in the secure system browser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Account")
                }
                Section {
                    Button {
                        guard saveServerDraft() else { return }
                        Task {
                            isConnecting = true
                            defer { isConnecting = false }
                            await library.refreshClientConfiguration()
                            await library.refreshCatalog()
                            if library.isServerConnected {
                                dismiss()
                            } else {
                                validationMessage = library.serverMessage
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting || library.isSyncing {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(isConnecting || library.isSyncing ? "Connecting…" : "Connect")
                            Spacer()
                        }
                    }
                    .disabled(
                        isConnecting
                            || library.isSyncing
                            || library.isProfileTransitionBusy
                            || library.serverToken.isEmpty
                    )
                }
                Section {
                    Text(validationMessage ?? library.serverConfigurationMessage ?? library.serverMessage)
                        .foregroundStyle(validationMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
            .onChange(of: library.accountEmail) { _, _ in isEmailRevealed = false }
            .onAppear {
                validationMessage = nil
            }
            .task {
                await library.refreshClientConfiguration()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard saveServerDraft() else { return }
                        Task {
                            isConnecting = true
                            defer { isConnecting = false }
                            await library.refreshClientConfiguration()
                            dismiss()
                        }
                    }
                    .disabled(isConnecting || library.isProfileTransitionBusy || library.serverToken.isEmpty)
                }
            }
        }
    }

    @discardableResult
    private func saveServerDraft() -> Bool {
        let saved = library.applyServerConfiguration(
            serverURL: accountServerURL,
            accessToken: library.serverToken,
            adminToken: library.serverAdminToken
        )
        validationMessage = saved ? nil : library.serverConfigurationMessage
        return saved
    }
}

private struct ServerSourceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @FocusState private var sourceIsFocused: Bool
    @State private var sourcePage = ""
    @State private var isSubmitting = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube source page") {
                    TextField("https://www.youtube.com/watch?v=…", text: $sourcePage)
                        .focused($sourceIsFocused)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(submit)
                    Button("Paste") {
                        if let pasted = UIPasteboard.general.string {
                            sourcePage = pasted
                        }
                    }
                }

                Section {
                    Text("Resonance sends only the canonical page address to your server. The server verifies and ingests the audio into its own R2 storage; provider playback links and credentials are never forwarded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Section("Status") {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Upload from Link")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { sourceIsFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Uploading…" : "Upload", action: submit)
                        .disabled(isSubmitting || sourcePage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { sourceIsFocused = false }
                }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        sourceIsFocused = false
        isSubmitting = true
        message = nil
        Task {
            let succeeded = await library.importServerSourceLink(sourcePage)
            isSubmitting = false
            if succeeded {
                dismiss()
            } else {
                message = library.serverMessage
            }
        }
    }
}

private struct MobilePlayerBar: View {
    @Environment(\.resonancePalette) private var palette
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
                        .disabled(library.isTransientStreamActive)
                    Button { library.togglePlay() } label: {
                        Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                            .background(palette.raisedSurface, in: Circle())
                            .overlay { Circle().stroke(palette.accent.opacity(0.72), lineWidth: 1.5) }
                            .foregroundStyle(.white)
                            .shadow(color: palette.accent.opacity(0.22), radius: 8)
                    }
                    Button { library.next() } label: { Image(systemName: "forward.end.fill") }
                        .disabled(library.isTransientStreamActive)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.13)).frame(height: 3)
                        Capsule().fill(palette.foregroundAccent).frame(width: geometry.size.width * library.playbackProgress(for: track), height: 3)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { library.seek(to: $0.location.x / max(geometry.size.width, 1)) })
                }.frame(height: 5)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(palette.surface.opacity(0.98))
        .background(.ultraThinMaterial.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct NowPlayingView: View {
    @Environment(\.resonancePalette) private var palette
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
                            if !library.isTransientStreamActive {
                                Button { library.toggleFavorite(track) } label: {
                                    Image(systemName: library.favorites.contains(track.id) ? "heart.fill" : "heart")
                                        .font(.title2)
                                        .foregroundStyle(library.favorites.contains(track.id) ? palette.accent : .primary)
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel(library.favorites.contains(track.id) ? "Remove from Liked Songs" : "Add to Liked Songs")
                            }
                        }

                        progress(for: track)
                        transportControls
                        volumeControl
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
                    get: { library.playbackProgress(for: track) },
                    set: { library.seek(to: $0) }
                ),
                in: 0...1
            )
            .tint(palette.foregroundAccent)
            HStack {
                Text(timeText(library.playbackElapsed(for: track)))
                Spacer()
                Text("-\(timeText(max(library.playbackDuration(for: track) - library.playbackElapsed(for: track), 0)))")
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
            .disabled(library.isTransientStreamActive)
            Button { library.togglePlay() } label: {
                Image(systemName: library.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 72, height: 72)
                    .background(palette.raisedSurface, in: Circle())
                    .overlay { Circle().stroke(palette.accent.opacity(0.72), lineWidth: 2) }
                    .foregroundStyle(.white)
                    .shadow(color: palette.accent.opacity(0.24), radius: 14)
            }
            Button { library.next() } label: {
                Image(systemName: "forward.end.fill").font(.title)
            }
            .disabled(library.isTransientStreamActive)
        }
        .buttonStyle(.plain)
    }

    private var volumeControl: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Volume", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((library.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $library.volume, in: 0...1)
                .tint(palette.foregroundAccent)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((library.volume * 100).rounded())) percent")
        }
        .padding(.horizontal, 10)
    }

    private var playbackOptions: some View {
        HStack {
            Button { library.shuffleEnabled.toggle() } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .foregroundStyle(
                        library.isTransientStreamActive
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(library.shuffleEnabled ? palette.accent : .secondary)
                    )
            }
            .disabled(library.isTransientStreamActive)
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
                    .foregroundStyle(library.repeatEnabled ? palette.accent : .secondary)
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
    @Environment(\.resonancePalette) private var palette
    var body: some View {
        ZStack {
            palette.background
            RadialGradient(
                colors: [palette.secondary.opacity(0.16), .clear],
                center: UnitPoint(x: 0.76, y: 0.04),
                startRadius: 10,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

private struct SquareArtworkContainer<Content: View>: View {
    let content: (CGSize) -> Content

    init(@ViewBuilder content: @escaping (CGSize) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            content(geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ArtworkTile: View {
    let symbol: String
    var body: some View {
        SquareArtworkContainer { _ in
            ArtworkPlaceholder(symbol: symbol)
        }
    }
}

private struct ArtworkPlaceholder: View {
    @Environment(\.resonancePalette) private var palette
    let symbol: String
    var compact = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette.gradientStops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(compact ? .caption.weight(.semibold) : .title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

private struct PlaylistArtworkTile: View {
    @EnvironmentObject private var library: MusicLibrary
    let playlist: MobilePlaylist

    private var artworkTracks: [MobileTrack?] {
        let tracksByID = Dictionary(
            library.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let trackIDs = playlist.automaticArtworkTrackIDs
        return (0..<4).map { index in
            guard trackIDs.indices.contains(index) else { return nil }
            return tracksByID[trackIDs[index]]
        }
    }

    var body: some View {
        if playlist.isSystem || playlist.automaticArtworkTrackIDs.isEmpty {
            ArtworkTile(symbol: playlist.isSystem ? "heart.fill" : "music.note.list")
        } else {
            SquareArtworkContainer { size in
                let cellSize = CGSize(width: size.width / 2, height: size.height / 2)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        artworkCell(artworkTracks[0], size: cellSize)
                        artworkCell(artworkTracks[1], size: cellSize)
                    }
                    HStack(spacing: 0) {
                        artworkCell(artworkTracks[2], size: cellSize)
                        artworkCell(artworkTracks[3], size: cellSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artworkCell(_ track: MobileTrack?, size: CGSize) -> some View {
        if let track, let artwork = library.artwork(for: track) {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ArtworkPlaceholder(symbol: "music.note", compact: true)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
}

struct TrackArtwork: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    var fallbackSymbol = "music.note"

    var body: some View {
        SquareArtworkContainer { size in
            if let artwork = library.artwork(for: track) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                ArtworkTile(symbol: fallbackSymbol)
            }
        }
    }
}

private struct ServerArtwork: View {
    let song: MobileRemoteSong

    var body: some View {
        SquareArtworkContainer { size in
            if song.isMetadataLoading {
                ZStack {
                    ArtworkTile(symbol: "music.note")
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.72))
                }
            } else if let artworkURL = song.artworkURL {
                AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    case .empty:
                        ZStack {
                            ArtworkTile(symbol: "music.note")
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    case .failure:
                        ArtworkTile(symbol: "music.note")
                    @unknown default:
                        ArtworkTile(symbol: "music.note")
                    }
                }
            } else {
                ArtworkTile(symbol: "music.note")
            }
        }
        .accessibilityHidden(true)
    }
}

extension Text {
    func eyebrow() -> some View { font(.caption2.weight(.semibold)).tracking(1.6).foregroundStyle(.secondary) }
}

extension View {
    func pill(color: Color) -> some View { font(.subheadline.weight(.bold)).padding(.horizontal, 17).frame(height: 42).background(color, in: Capsule()).foregroundStyle(.white) }
    func roundButton(active: Bool, activeColor: Color) -> some View {
        frame(width: 42, height: 42)
            .background(active ? activeColor : .white.opacity(0.08), in: Circle())
            .foregroundStyle(.white)
    }
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
