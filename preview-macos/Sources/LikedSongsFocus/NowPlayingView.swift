import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel

    private var progress: Double {
        guard let track = model.currentTrack, track.duration > 0 else { return 0 }
        return model.position / track.duration
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Now Playing")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if let track = model.currentTrack {
                    Menu {
                        if !model.customPlaylists.isEmpty {
                            Menu("Add to Playlist") {
                                ForEach(model.customPlaylists) { playlist in
                                    Button(playlist.name) { model.addTrack(track, to: playlist) }
                                }
                            }
                        }
                        Button("Show in Finder") { model.revealInFinder(track) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0xAEB4C2))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                }
            }
            .padding(.bottom, 18)

            if let track = model.currentTrack {
                TrackArtworkView(
                    track: track,
                    symbol: "music.note",
                    symbolSize: 66,
                    cornerRadius: 10,
                    glow: true
                )
                .frame(width: 274, height: 274)
                .shadow(color: Color(hex: 0x372D91).opacity(0.25), radius: 22, y: 14)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title)
                            .font(.system(size: 16, weight: .medium))
                            .lineLimit(1)
                        Text("\(track.artist) / Local file")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x9DA4B4))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        model.toggleFavorite(track)
                    } label: {
                        Image(systemName: model.favorites.contains(track.id) ? "heart.fill" : "heart")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 15)
                .padding(.bottom, 12)

                ClickableProgress(progress: progress, onSeek: model.seek)

                HStack {
                    Text(Track.timeText(model.position))
                    Spacer()
                    Text(track.durationText)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x8F96A8))
                .padding(.top, 6)

                HStack {
                    CircleIconButton(
                        systemImage: "backward.end.fill",
                        label: "Previous",
                        action: model.previous
                    )
                    Spacer()
                    Button(action: model.togglePlay) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .offset(x: model.isPlaying ? 0 : 1)
                            .frame(width: 50, height: 50)
                            .background(Color.appSurfaceRaised)
                            .overlay { Circle().stroke(Color.appAccent.opacity(0.68), lineWidth: 1.5) }
                            .clipShape(Circle())
                            .shadow(color: Color.appAccent.opacity(0.22), radius: 12)
                    }
                    .buttonStyle(PressableScaleStyle())
                    Spacer()
                    CircleIconButton(
                        systemImage: "forward.end.fill",
                        label: "Next",
                        action: model.next
                    )
                }
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 12)
            } else {
                ArtworkView(
                    style: .liked,
                    symbol: "music.note",
                    symbolSize: 60,
                    cornerRadius: 10,
                    glow: true
                )
                .frame(width: 274, height: 274)
                .opacity(0.62)

                VStack(spacing: 6) {
                    Text("Nothing Playing")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Add music to start listening")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                    Button("Add Music", action: model.importLocalFiles)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.appAccent)
                }
                .padding(.vertical, 16)
            }

            HStack(spacing: 0) {
                ForEach(QueueTab.allCases) { tab in
                    Button {
                        model.queueTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(model.queueTab == tab ? Color.white : Color(hex: 0x9BA2B3))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .overlay(alignment: .bottom) {
                                if model.queueTab == tab {
                                    Rectangle().fill(Color.appAccent).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Color.appLine).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.appLine).frame(height: 1) }

            ScrollView {
                if queueItems.isEmpty {
                    Text(model.queueTab == .history ? "Nothing played yet" : "Queue is empty")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 22)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(queueItems) { track in
                            QueueRow(track: track)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .scrollIndicators(.hidden)

            HStack {
                Text(model.queueTab == .upNext ? "Queue preview" : "Recent playback")
                Spacer()
                Text("\(model.queueTracks.count) \(model.queueTracks.count == 1 ? "track" : "tracks")")
            }
            .font(.system(size: 9))
            .foregroundStyle(Color(hex: 0x969DAC))
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.appLine).frame(height: 1) }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background {
            LinearGradient(
                colors: [Color(hex: 0x08090E).opacity(0.99), Color.appBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var queueItems: [Track] {
        Array(model.queueTracks.prefix(5))
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            TrackArtworkView(track: track, symbol: "music.note", symbolSize: 10, cornerRadius: 5)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0x8F96A7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(track.durationText)
                .font(.system(size: 9))
                .foregroundStyle(Color(hex: 0x8F96A7))
        }
        .padding(.horizontal, 2)
        .frame(height: 44)
        .background(hovering ? Color.white.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectAndPlay(track) }
        .onHover { hovering = $0 }
    }
}
