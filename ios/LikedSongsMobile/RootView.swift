import SwiftUI
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
            NavigationStack { LibraryView(importing: $importing) }
                .tabItem { Label("Library", systemImage: "waveform") }
                .tag(MobileSection.library)
            NavigationStack { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "square.stack") }
                .tag(MobileSection.playlists)
            NavigationStack { StorageView() }
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(MobileSection.storage)
            NavigationStack { ServerView() }
                .tabItem { Label("Server", systemImage: "network") }
                .tag(MobileSection.server)
        }
        .tint(.coral)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if library.currentTrack != nil { MobilePlayerBar() }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
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
                        Button { if let first = library.tracks.first { library.play(first) } } label: {
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
                            ForEach(library.filteredTracks) { track in TrackRow(track: track) }
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

    var body: some View {
        HStack(spacing: 12) {
            ArtworkTile(symbol: library.currentTrackID == track.id && library.isPlaying ? "waveform" : "music.note")
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(track.artist) • \(track.album)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(track.durationText).font(.caption2).foregroundStyle(.secondary)
            Button { library.toggleFavorite(track) } label: {
                Image(systemName: library.favorites.contains(track.id) ? "heart.fill" : "heart")
                    .foregroundStyle(library.favorites.contains(track.id) ? Color.coral : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { library.play(track) }
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
    let playlistID: UUID
    private var playlist: MobilePlaylist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let playlist {
                        ForEach(library.tracks(in: playlist)) { TrackRow(track: $0) }
                    }
                }.padding()
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
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
            }.scrollContentBackground(.hidden)
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
                            Menu("More") {
                                Button("Download All") { Task { await library.downloadAll() } }
                                Button("Upload Songs") { choosingUploads = true }
                            }
                        }
                    }
                    TransferStatus(title: "Downloads", progress: library.downloadProgress, detail: library.downloadDetail, active: library.isSyncing, color: .coral)
                    TransferStatus(title: "Uploads", progress: library.uploadProgress, detail: library.uploadDetail, active: library.isUploading, color: .violet)
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

    var body: some View {
        VStack(spacing: 7) {
            if let track = library.currentTrack {
                HStack(spacing: 11) {
                    ArtworkTile(symbol: "music.note").frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
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
