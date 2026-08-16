import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MobileSection: Hashable {
    case library, playlists, server
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

            if let transfer = library.transferDisplay {
                ServerTransferPopup(transfer: transfer)
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
        .animation(.easeInOut(duration: 0.22), value: library.transferDisplay)
        .animation(.easeInOut(duration: 0.22), value: library.transferNotice)
    }
}

private struct LibraryView: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @Binding var importing: Bool
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
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Library")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                            Text("\(library.tracksForActiveProfile.count) songs on this device")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NavigationLink {
                            NativeStorageView(importing: $importing)
                        } label: {
                            Image(systemName: "internaldrive")
                                .roundButton(active: false, activeColor: palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Storage")
                        .accessibilityHint("Manage imports, downloads, and device storage")
                        ProfileButton(
                            displayName: library.accountDisplayName ?? library.syncProfileName,
                            email: library.accountEmail,
                            imageURL: library.accountImageURL,
                            onClipEditor: { presentedSheet = .clipEditor },
                            onSettings: { presentedSheet = .settings }
                        )
                    }
                    TextField("Search your music", text: $library.searchText)
                        .focused($searchIsFocused)
                        .submitLabel(.done)
                        .onSubmit { searchIsFocused = false }
                        .textFieldStyle(.plain)
                        .padding(13)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    if library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !recentlyAddedTracks.isEmpty {
                        RecentlyAddedSection(tracks: recentlyAddedTracks)
                    }
                    if library.filteredTracks.isEmpty {
                        ContentUnavailableView("No songs yet", systemImage: "music.note", description: Text("Import audio or video, or sync your music server."))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Text("All Songs")
                                    .font(.headline)
                                Spacer()
                                Text("\(library.filteredTracks.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
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
            case .clipEditor:
                MobileClipEditorSheet()
            case .settings:
                MobileSettingsSheet()
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
    case clipEditor, settings
    var id: String { rawValue }
}

private struct MobileSettingsSheet: View {
    private enum PresentedSheet: String, Identifiable {
        case connection
        var id: String { rawValue }
    }

    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var themeStore: ResonanceThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var presentedSheet: PresentedSheet?

    private var displayName: String {
        ResonanceEmailPrivacy.safeDisplayName(
            library.accountDisplayName ?? library.syncProfileName,
            email: library.accountEmail
        )
    }

    private var accountStatus: String {
        if let role = library.accountRole {
            return role == "admin" ? "Administrator" : "Member"
        }
        return library.serverToken.isEmpty ? "Not signed in" : "Legacy connection"
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    accountSummary
                }

                Section("Playback") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Volume", systemImage: "speaker.wave.2")
                            Spacer()
                            Text("\(Int((library.volume * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $library.volume, in: 0...1)
                            .tint(palette.accent)
                            .accessibilityLabel("Playback volume")
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $library.crossfadeEnabled) {
                            Label("Crossfade", systemImage: "waveform.path")
                        }
                        HStack {
                            Text("Transition duration")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(library.crossfadeSeconds.rounded())) sec")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $library.crossfadeSeconds, in: 1...12, step: 1)
                            .tint(palette.accent)
                            .disabled(!library.crossfadeEnabled)
                            .accessibilityLabel("Crossfade duration")
                            .accessibilityValue("\(Int(library.crossfadeSeconds.rounded())) seconds")
                    }
                    .padding(.vertical, 4)
                }

                Section("Appearance") {
                    MobileThemePicker(selectedTheme: $themeStore.selectedTheme)
                }

                Section("App") {
                    Button {
                        presentedSheet = .connection
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .foregroundStyle(palette.foregroundAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Music Server")
                                    .foregroundStyle(.primary)
                                Text(library.isServerConnected ? "Connected as \(displayName)" : library.serverMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("Configure")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.foregroundAccent)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    LabeledContent {
                        Text("Enabled").foregroundStyle(.secondary)
                    } label: {
                        Label("Background Audio", systemImage: "waveform")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: versionText)
                    LabeledContent("Platform", value: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS")
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection:
                ServerConnectionSheet()
            }
        }
    }

    private var accountSummary: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(palette.secondary)
                if let imageURL = library.accountImageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(String(displayName.prefix(1)).uppercased())
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(accountStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MobileThemePicker: View {
    @Binding var selectedTheme: ResonanceTheme

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ResonanceTheme.allCases) { theme in
                let candidate = theme.palette
                let isSelected = selectedTheme == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTheme = theme
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        LinearGradient(
                            colors: candidate.gradientStops,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack(spacing: 5) {
                            Text(theme.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(candidate.ink)
                            Spacer(minLength: 2)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(candidate.tertiary)
                            }
                        }
                    }
                    .padding(9)
                    .background(candidate.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(isSelected ? candidate.tertiary : candidate.divider, lineWidth: isSelected ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.title) theme")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProfileButton: View {
    @Environment(\.resonancePalette) private var palette
    let displayName: String
    let email: String?
    let imageURL: URL?
    let onClipEditor: () -> Void
    let onSettings: () -> Void
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
            Button("Settings", systemImage: "gearshape", action: onSettings)
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
        .accessibilityHint("Opens account tools")
        .onChange(of: email) { _, _ in isEmailRevealed = false }
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
                } header: {
                    Text("\(library.playlists.count) \(library.playlists.count == 1 ? "collection" : "collections")")
                }
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
                            Image(systemName: "shuffle")
                                .roundButton(active: library.shuffleEnabled, activeColor: palette.secondary)
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
                        library.movePlaylistEntries(in: playlistID, fromOffsets: source, toOffset: destination)
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
                    if playlistEntries.count > 1 {
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

private struct NativeStorageView: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @Binding var importing: Bool
    @State private var searchText = ""
    @State private var scope: StorageScope = .songs
    @State private var sort: StorageSort = .title
    @State private var editMode: EditMode = .inactive
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var fileSizes: [UUID: Int64] = [:]
    @State private var availableBytes: Int64 = 0
    @State private var deletionCandidate: MobileTrack?
    @State private var showsBatchDeleteConfirmation = false
    @State private var presentedSheet: StorageSheet?
    @State private var startsFileImportAfterSheet = false

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

    private var presentedTracks: [MobileTrack] {
        downloadedTracks + importedTracks
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
        List(selection: $selectedTrackIDs) {
            Section {
                StorageSummaryCard(
                    importedBytes: importedBytes,
                    importedCount: library.tracks.filter { $0.sourceServer == nil && $0.remoteID == nil }.count,
                    downloadedBytes: downloadedBytes,
                    downloadedCount: library.tracks.filter { $0.sourceServer != nil || $0.remoteID != nil }.count,
                    availableBytes: availableBytes
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Show", selection: $scope) {
                    ForEach(StorageScope.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Storage filter")
            }

            if visibleTracks.isEmpty {
                Section {
                    ContentUnavailableView(
                        searchText.isEmpty ? scope.emptyTitle : "No Results",
                        systemImage: searchText.isEmpty ? scope.symbol : "magnifyingglass",
                        description: Text(searchText.isEmpty ? scope.emptyMessage : "Try a different search term or storage filter.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                    .listRowBackground(Color.clear)
                }
            } else {
                if !downloadedTracks.isEmpty {
                    Section {
                        ForEach(downloadedTracks) { track in
                            NativeStorageTrackRow(
                                track: track,
                                number: storageIndex(for: track),
                                fileSize: fileSizes[track.id, default: 0],
                                onDelete: { deletionCandidate = track }
                            )
                            .tag(track.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Label("Downloaded from Server", systemImage: "icloud.and.arrow.down")
                    }
                }

                if !importedTracks.isEmpty {
                    Section {
                        ForEach(importedTracks) { track in
                            NativeStorageTrackRow(
                                track: track,
                                number: storageIndex(for: track),
                                fileSize: fileSizes[track.id, default: 0],
                                onDelete: { deletionCandidate = track }
                            )
                            .tag(track.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Label("Imported on Device", systemImage: "internaldrive")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.background)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 1)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Songs, artists, albums, or files"
        )
        .navigationTitle("Song Storage")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .environment(\.editMode, $editMode)
        .sheet(item: $presentedSheet, onDismiss: {
            guard startsFileImportAfterSheet else { return }
            startsFileImportAfterSheet = false
            importing = true
        }) { sheet in
            switch sheet {
            case .importChooser:
                StorageImportChooser(
                    presentedSheet: $presentedSheet,
                    startsFileImportAfterSheet: $startsFileImportAfterSheet
                )
            case .webImport:
                MobileLocalImportSheet()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(library.tracks.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(StorageSort.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { presentedSheet = .importChooser } label: {
                    Label("Import", systemImage: "plus")
                }
                .accessibilityHint("Choose whether to import from the web or Files")
            }
            if editMode.isEditing {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        showsBatchDeleteConfirmation = true
                    } label: {
                        Label(
                            selectedTrackIDs.isEmpty ? "Delete" : "Delete \(selectedTrackIDs.count)",
                            systemImage: "trash"
                        )
                    }
                    .disabled(selectedTrackIDs.isEmpty)
                }
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
                editMode = .inactive
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
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { selectedTrackIDs.removeAll() }
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

    private func storageIndex(for track: MobileTrack) -> Int {
        (presentedTracks.firstIndex(where: { $0.id == track.id }) ?? 0) + 1
    }
}

private struct NativeStorageTrackRow: View {
    @Environment(\.editMode) private var editMode
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    let number: Int
    let fileSize: Int64
    let onDelete: () -> Void

    var body: some View {
        Group {
            if editMode?.wrappedValue.isEditing == true {
                rowContent
            } else {
                Button { library.play(track) } label: { rowContent }
                    .buttonStyle(.plain)
            }
        }
        .mobileCatalogRow()
        .contextMenu {
            Button { library.play(track) } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete from Device", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.artist), \(formatBytes(fileSize))")
        .accessibilityAction(named: "Play") { library.play(track) }
    }

    private var rowContent: some View {
        LocalSongRowContent(
            track: track,
            number: number,
            trailingDetail: formatBytes(fileSize),
            isPlaying: library.currentTrackID == track.id && library.isPlaying
        )
    }
}

private struct StorageImportChooser: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var presentedSheet: StorageSheet?
    @Binding var startsFileImportAfterSheet: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        presentedSheet = .webImport
                    } label: {
                        Label("Import from Web", systemImage: "link.badge.plus")
                    }
                    Button {
                        startsFileImportAfterSheet = true
                        dismiss()
                    } label: {
                        Label("Import Files", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("Import from a supported web link, or choose audio and video files already available to this device.")
                }
            }
            .navigationTitle("Import Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}


private enum StorageSheet: String, Identifiable {
    case importChooser, webImport
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


private struct StorageSummaryCard: View {
    @Environment(\.resonancePalette) private var palette
    let importedBytes: Int64
    let importedCount: Int
    let downloadedBytes: Int64
    let downloadedCount: Int
    let availableBytes: Int64

    private var usedBytes: Int64 { importedBytes + downloadedBytes }
    private var totalBytes: Int64 { max(usedBytes + availableBytes, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(importedCount + downloadedCount) songs on device")
                        .font(.subheadline.weight(.semibold))
                    Text("\(formatBytes(usedBytes)) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(formatBytes(availableBytes)) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(usedBytes), total: Double(totalBytes))
                .tint(palette.foregroundAccent)
            HStack(spacing: 14) {
                Label("\(importedCount) local", systemImage: "internaldrive")
                Label("\(downloadedCount) downloaded", systemImage: "icloud.and.arrow.down")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage usage")
        .accessibilityValue("\(formatBytes(usedBytes)) used, \(formatBytes(availableBytes)) available")
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
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
                    HStack {
                        Text("Server")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Spacer()
                        Button {
                            Task { await library.refreshCatalog() }
                        } label: {
                            if library.isRefreshingCatalog {
                                ProgressView()
                                    .frame(width: 44, height: 44)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .roundButton(active: false, activeColor: palette.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(library.isSyncing || library.isTransferBusy || library.isSyncingPlaylists)
                        .accessibilityLabel("Refresh server")
                    }
                    .padding(.bottom, 8)

                    serverStatusLine
                        .padding(.bottom, 24)

                    MobileListenAlongCard()
                        .padding(.bottom, 12)

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
                guard !library.isSyncing, !library.isTransferBusy else { return }
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
                  !library.isTransferBusy,
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
        VStack(alignment: .leading, spacing: 8) {
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
                        Image(systemName: "gearshape")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage server connection")
            }

            Text(
                "\(library.remoteSongs.count) songs · "
                    + "\(library.playlists.filter { !$0.isSystem }.count) playlists · "
                    + "\(syncedCount) on device"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var serverActions: some View {
        HStack(spacing: 0) {
            ServerTextActionButton(
                symbol: "tray.and.arrow.down",
                label: library.activeDownloadMode == .streamOnly ? "Tap a Song" : "Download",
                isDisabled: library.isSyncing
                    || library.isTransferBusy
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

            ServerTextActionButton(
                symbol: "checklist",
                label: isSelecting ? "\(library.selectedRemoteSongIDs.count) Selected" : "Select",
                isDisabled: library.isSyncing
                    || library.isTransferBusy
                    || library.activeDownloadMode == .streamOnly
                    || library.activeDownloadMode == nil
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

            Menu {
                Button("Upload Missing Downloads", systemImage: "icloud.and.arrow.up") {
                    Task { await library.uploadDownloadedSongsMissingFromServer() }
                }
                .disabled(library.isUploadTransferBusy || library.activeUploadMode != .localFile)

                Button(uploadModeLabel, systemImage: uploadModeSymbol) {
                    switch library.activeUploadMode {
                    case .localFile, .serverSourceLink:
                        presentedSheet = .linkImport
                    case .reviewedMatch:
                        presentedSheet = .reviewedImport
                    case nil:
                        break
                    }
                }
                .disabled(library.isUploadTransferBusy || library.activeUploadMode == nil)

                Divider()
                Button("Account & Connection", systemImage: "gearshape") {
                    presentedSheet = .connection
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.serverActionForeground)
                    .frame(width: 54, height: 58)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More server actions")
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
    let transfer: MobileTransferDisplayState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.kind.symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.foregroundAccent)
                .frame(width: 36, height: 36)
                .background(palette.secondary.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(transfer.kind.title)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(transfer.batchPosition)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(transfer.songTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let progress = transfer.progress {
                    ProgressView(value: progress)
                        .tint(palette.foregroundAccent)
                } else {
                    ProgressView()
                        .tint(palette.foregroundAccent)
                }
            }

            if let progress = transfer.progress {
                Text(MobileTransferDisplayPolicy.percentageLabel(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.kind.title) \(transfer.songTitle), \(transfer.batchPosition)")
        .accessibilityValue(transfer.detail)
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
            .disabled(primaryActionIsDisabled)
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
                            .disabled(remoteTransferIsDisabled)
                    }
                    Button("Delete from Server", systemImage: "trash", role: .destructive, action: onDelete)
                        .disabled(library.isTransferBusy)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSelecting)
    }

    private func primaryAction() {
        if let localTrack {
            library.play(localTrack)
        } else {
            guard !library.isTransferBusy else { return }
            Task { await library.download(song) }
        }
    }

    private var primaryActionIsDisabled: Bool {
        guard !isSelecting, localTrack == nil else { return false }
        return remoteTransferIsDisabled
    }

    private var remoteTransferIsDisabled: Bool {
        if library.isTransferBusy || library.activeDownloadMode == nil { return true }
        return library.activeDownloadMode == .streamOnly
            && MobileAuthenticatedStreamPolicy.normalizedAudioMIMEType(song.contentType) == nil
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
    @Environment(\.resonancePalette) private var palette
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
                        Button {
                            Task {
                                await library.signIn(with: .clerk)
                                validationMessage = library.serverConfigurationMessage
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.headline)
                                    .frame(width: 36, height: 36)
                                    .background(.white.opacity(0.16), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sign in with Clerk")
                                        .font(.headline)
                                    Text("Secure Resonance account access")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.78))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if library.isAuthenticatingAccount {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.right")
                                        .font(.subheadline.weight(.bold))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                LinearGradient(
                                    colors: [palette.secondary, palette.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .shadow(color: palette.accent.opacity(0.24), radius: 10, y: 5)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.large)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
            .navigationTitle("Import from Web")
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
    @EnvironmentObject private var listenAlong: MobileListenAlongController
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
                    if library.isListenAlongPlaybackLocked {
                        ListenAlongParticipantIndicator(
                            count: listenAlong.participantCount,
                            height: 44,
                            iconSize: 19
                        )
                    } else {
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
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.13)).frame(height: 3)
                        Capsule().fill(palette.accent).frame(width: geometry.size.width * library.playbackProgress(for: track), height: 3)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged {
                        guard !library.isListenAlongPlaybackLocked else { return }
                        library.seek(to: $0.location.x / max(geometry.size.width, 1))
                    })
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
    @EnvironmentObject private var listenAlong: MobileListenAlongController
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
                        if !library.isListenAlongPlaybackLocked {
                            playbackOptions
                        }
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
            .tint(palette.accent)
            .disabled(library.isListenAlongPlaybackLocked)
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
        Group {
            if library.isListenAlongPlaybackLocked {
                ListenAlongParticipantIndicator(
                    count: listenAlong.participantCount,
                    height: 72,
                    iconSize: 28
                )
            } else {
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
        }
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
            .disabled(library.isTransientStreamActive || library.isListenAlongPlaybackLocked)
            Spacer()
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button("\(rate, specifier: "%g")×") { library.playbackRate = Float(rate) }
                }
            } label: {
                Label("\(Double(library.playbackRate), specifier: "%g")×", systemImage: "speedometer")
            }
            .disabled(library.isListenAlongPlaybackLocked)
            Spacer()
            Button { library.repeatEnabled.toggle() } label: {
                Label("Repeat", systemImage: "repeat")
                    .foregroundStyle(library.repeatEnabled ? palette.accent : .secondary)
            }
            .disabled(library.isListenAlongPlaybackLocked)
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

private struct ListenAlongParticipantIndicator: View {
    @Environment(\.resonancePalette) private var palette
    let count: Int?
    let height: CGFloat
    let iconSize: CGFloat

    var body: some View {
        HStack(spacing: height > 44 ? 10 : 7) {
            Image(systemName: "person.2.fill")
                .font(.system(size: iconSize, weight: .semibold))
            if let count {
                Text(count, format: .number)
                    .font(height > 44 ? .title3.weight(.bold) : .subheadline.weight(.bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .frame(height: height)
        .padding(.horizontal, height > 44 ? 22 : 13)
        .background(palette.raisedSurface, in: Capsule())
        .overlay { Capsule().stroke(palette.accent.opacity(0.72), lineWidth: height > 44 ? 2 : 1.5) }
        .shadow(color: palette.accent.opacity(0.24), radius: height > 44 ? 14 : 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "Listening Along with \($0) people" } ?? "Listening Along")
        .accessibilityHint("Playback is controlled by the session host")
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
            } else if let artworkURL = library.listenAlongArtworkURL(for: track) {
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
                            ArtworkTile(symbol: fallbackSymbol)
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.82))
                        }
                    case .failure:
                        ArtworkTile(symbol: fallbackSymbol)
                    @unknown default:
                        ArtworkTile(symbol: fallbackSymbol)
                    }
                }
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
