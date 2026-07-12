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

    var body: some View {
        TabView(selection: $selection) {
            PlayerAwareTab {
                NavigationStack { LibraryView(importing: $importing) }
            }
                .tabItem { Label("Library", systemImage: "waveform") }
                .tag(MobileSection.library)
            PlayerAwareTab {
                NavigationStack { PlaylistsView() }
            }
                .tabItem { Label("Playlists", systemImage: "square.stack") }
                .tag(MobileSection.playlists)
            PlayerAwareTab {
                NavigationStack { StorageView() }
            }
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(MobileSection.storage)
            PlayerAwareTab {
                NavigationStack { ServerView() }
            }
                .tabItem { Label("Server", systemImage: "network") }
                .tag(MobileSection.server)
        }
        .tint(.coral)
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
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if library.currentTrack != nil {
                MobilePlayerBar()
            }
        }
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @Binding var importing: Bool

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
                                .pill(color: .coral)
                        }
                        Button { library.shuffleEnabled.toggle() } label: {
                            Image(systemName: "shuffle").roundButton(active: library.shuffleEnabled)
                        }
                        Spacer()
                        Button { importing = true } label: { Label("Import", systemImage: "plus").pill(color: .violet) }
                    }
                    TextField("Search your music", text: $library.searchText)
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
        }
        .navigationBarHidden(true)
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    var playbackQueue: [MobileTrack]? = nil
    var playbackPlaylistID: UUID? = nil

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
                    .foregroundStyle(library.favorites.contains(track.id) ? Color.coral : .secondary)
            }
            .buttonStyle(.plain)
            Menu {
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
                    }
                } header: { Text("YOUR COLLECTIONS") }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Playlists")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") { library.createPlaylist(name); name = "" }
            Button("Cancel", role: .cancel) { name = "" }
        }
    }
}

private struct PlaylistDetailView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var addingToPlaylist: MobilePlaylist?
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
                                library.play(playlist)
                            }
                        } label: {
                            Label(library.shuffleEnabled ? "Shuffle Play" : "Play", systemImage: library.shuffleEnabled ? "shuffle" : "play.fill")
                                .pill(color: .coral)
                        }
                        Button {
                            library.shuffleEnabled.toggle()
                        } label: {
                            Image(systemName: "shuffle").roundButton(active: library.shuffleEnabled)
                        }
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
                }
            }
        }
        .sheet(item: $addingToPlaylist) { playlist in
            PlaylistSongPicker(playlistID: playlist.id)
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
                    if let playlist { library.add(track, to: playlist) }
                } label: {
                    HStack(spacing: 12) {
                        TrackArtwork(track: track).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).foregroundStyle(.primary).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if playlist?.trackIDs.contains(track.id) == true {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.coral)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(playlist?.trackIDs.contains(track.id) == true)
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

    var body: some View {
        ZStack {
            AppBackground()
            List {
                Section("LOCAL AUDIO") {
                    ForEach(library.tracks) { track in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.title)
                                Text(track.relativePath).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { library.remove(track) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Song Storage")
    }
}

private struct ServerView: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var choosingUploads = false
    @State private var deletionCandidate: MobileRemoteSong?

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("REMOTE LIBRARY").eyebrow()
                    Text("Music Server").font(.largeTitle)
                    TextField("https://music.unblocked.mov", text: $library.serverURL)
                        .textContentType(.URL).keyboardType(.URL).autocorrectionDisabled()
                        .fieldCard(symbol: "network")
                    SecureField("Server access token", text: $library.serverToken)
                        .textContentType(.password).fieldCard(symbol: "key.fill")
                    SecureField("Server admin key", text: $library.serverAdminToken)
                        .textContentType(.password).fieldCard(symbol: "key.horizontal.fill")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button { Task { await library.refreshCatalog() } } label: {
                                Label("Connect", systemImage: "network").pill(color: .coral)
                            }.disabled(library.isSyncing || library.isUploading)
                            Button("Download Selected") { Task { await library.downloadSelected() } }
                                .buttonStyle(.bordered)
                                .disabled(library.selectedRemoteSongIDs.isEmpty || library.isSyncing || library.isUploading)
                            Button("Sync Playlists") { Task { await library.syncPlaylistsNow() } }
                                .buttonStyle(.bordered)
                                .disabled(library.isSyncingPlaylists)
                            Menu("More") {
                                Button("Download All") { Task { await library.downloadAll() } }
                                Button("Upload Songs") { choosingUploads = true }
                            }
                        }
                    }
                    TransferStatus(title: "Downloads", progress: library.downloadProgress, detail: library.downloadDetail, active: library.isSyncing, color: .coral)
                    TransferStatus(title: "Uploads", progress: library.uploadProgress, detail: library.uploadDetail, active: library.isUploading, color: .violet)
                    HStack(spacing: 8) {
                        Text("Playlists").font(.caption.weight(.semibold))
                        Spacer()
                        if library.isSyncingPlaylists { ProgressView().controlSize(.small) }
                        Text(library.playlistSyncDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(library.serverMessage).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(library.remoteSongs) { song in
                        HStack {
                            Button { library.toggleRemoteSelection(song) } label: {
                                Image(systemName: library.selectedRemoteSongIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(library.selectedRemoteSongIDs.contains(song.id) ? Color.coral : .secondary)
                            }.buttonStyle(.plain)
                            ArtworkTile(symbol: "music.note").frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(song.title).font(.subheadline.weight(.semibold))
                                Text("\(song.album) • \(ByteCountFormatter.string(fromByteCount: song.size, countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: library.isSynced(song) ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                                .foregroundStyle(library.isSynced(song) ? .green : .secondary)
                        }
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button("Download") { Task { library.selectedRemoteSongIDs = [song.id]; await library.downloadSelected() } }
                            Button("Delete from Server", role: .destructive) { deletionCandidate = song }
                        }
                    }
                }.padding(20)
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingUploads, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.uploadFiles(urls) } }
        }
        .confirmationDialog("Delete this song from the server?", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } })) {
            Button("Delete from Server", role: .destructive) {
                if let song = deletionCandidate { Task { await library.deleteRemoteSong(song) } }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        }
    }
}

private struct TransferStatus: View {
    let title: String
    let progress: Double
    let detail: String
    let active: Bool
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.caption.weight(.semibold)); Spacer(); Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if active { ProgressView(value: progress).tint(color) }
        }
        .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MobilePlayerBar: View {
    @EnvironmentObject private var library: MusicLibrary
    @State private var presentedTrack: MobileTrack?

    var body: some View {
        VStack(spacing: 7) {
            if let track = library.currentTrack {
                HStack(spacing: 11) {
                    Button { presentedTrack = track } label: {
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
                            .font(.title3).frame(width: 38, height: 38).background(.white, in: Circle()).foregroundStyle(.black)
                    }
                    Button { library.next() } label: { Image(systemName: "forward.end.fill") }
                }
                GeometryReader { geometry in
                    let duration = max(track.duration, 0.01)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.13)).frame(height: 3)
                        Capsule().fill(Color.coral).frame(width: geometry.size.width * min(library.position / duration, 1), height: 3)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { library.seek(to: $0.location.x / max(geometry.size.width, 1)) })
                }.frame(height: 5)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .fullScreenCover(item: $presentedTrack) { _ in
            NowPlayingView()
        }
    }
}

private struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
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
                                    .foregroundStyle(library.favorites.contains(track.id) ? Color.coral : .primary)
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
                    dismiss()
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

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
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
            .tint(.coral)
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
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
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
                    .foregroundStyle(library.shuffleEnabled ? Color.coral : .secondary)
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
                    .foregroundStyle(library.repeatEnabled ? Color.coral : .secondary)
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
        LinearGradient(colors: [Color(hex: 0x151631), Color(hex: 0x07101C)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

private struct ArtworkTile: View {
    let symbol: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [.violet, .purple, .coral], startPoint: .topLeading, endPoint: .bottomTrailing)
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
    static let coral = Color(hex: 0xFF6F68)
    static let violet = Color(hex: 0x6558FF)
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
    func fieldCard(symbol: String) -> some View {
        HStack { Image(systemName: symbol); self }
            .padding(13).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
