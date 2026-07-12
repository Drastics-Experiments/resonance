import SwiftUI

struct PlayerBarView: View {
    @EnvironmentObject private var model: PlayerModel
    let compact: Bool

    private var progress: Double {
        guard let track = model.currentTrack, track.duration > 0 else { return 0 }
        return model.position / track.duration
    }

    var body: some View {
        HStack(spacing: 18) {
            currentTrackSummary
                .frame(width: compact ? 220 : 282, alignment: .leading)

            Spacer(minLength: 0)

            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    CircleIconButton(
                        systemImage: "shuffle",
                        label: "Shuffle",
                        size: 30,
                        symbolSize: 12,
                        isActive: model.shuffleEnabled,
                        action: model.toggleShuffle
                    )
                    CircleIconButton(
                        systemImage: "backward.end.fill",
                        label: "Previous",
                        size: 30,
                        symbolSize: 12,
                        action: model.previous
                    )
                    Button(action: model.togglePlay) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: 0x141923))
                            .offset(x: model.isPlaying ? 0 : 1)
                            .frame(width: 38, height: 38)
                            .background(Color(hex: 0xF5F5FB))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressableScaleStyle())
                    CircleIconButton(
                        systemImage: "forward.end.fill",
                        label: "Next",
                        size: 30,
                        symbolSize: 12,
                        action: model.next
                    )
                    CircleIconButton(
                        systemImage: "repeat",
                        label: "Repeat",
                        size: 30,
                        symbolSize: 12,
                        isActive: model.repeatEnabled,
                        action: model.toggleRepeat
                    )
                }

                HStack(spacing: 7) {
                    Text(Track.timeText(model.position))
                        .frame(width: 28, alignment: .trailing)
                    ClickableProgress(progress: progress, onSeek: model.seek)
                        .frame(maxWidth: 520)
                    Text(model.currentTrack?.durationText ?? "0:00")
                        .frame(width: 28, alignment: .leading)
                }
                .font(.system(size: 9))
                .foregroundStyle(Color(hex: 0x969DAC))
            }
            .frame(maxWidth: 580)
            .disabled(model.tracks.isEmpty)
            .opacity(model.tracks.isEmpty ? 0.45 : 1)

            Spacer(minLength: 0)

            if !compact {
                HStack(spacing: 13) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button {
                                model.setPlaybackRate(Float(rate))
                            } label: {
                                if abs(Double(model.playbackRate) - rate) < 0.001 {
                                    Label("\(rate.formatted())×", systemImage: "checkmark")
                                } else {
                                    Text("\(rate.formatted())×")
                                }
                            }
                        }
                    } label: {
                        Text("\(Double(model.playbackRate).formatted())×")
                            .font(.system(size: 11, weight: .medium))
                            .frame(minWidth: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Playback Speed")
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                    Slider(value: $model.volume, in: 0...1)
                        .tint(Color.appCoral)
                        .frame(width: 104)
                    Text("\(Int(model.volume * 100))%")
                        .font(.system(size: 10))
                        .frame(width: 32, alignment: .trailing)
                }
                .foregroundStyle(Color(hex: 0xA1A8B7))
                .frame(width: 250, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .background(Color(hex: 0x09101C).opacity(0.98))
        .background(.ultraThinMaterial.opacity(0.16))
    }

    @ViewBuilder
    private var currentTrackSummary: some View {
        if let track = model.currentTrack {
            HStack(spacing: 11) {
                TrackArtworkView(track: track, symbol: "music.note", symbolSize: 16, cornerRadius: 7)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(track.artist) / \(model.isPlaying ? "Now playing" : "Paused")")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x969DAC))
                        .lineLimit(1)
                }

                Button {
                    model.toggleFavorite(track)
                } label: {
                    Image(systemName: model.favorites.contains(track.id) ? "heart.fill" : "heart")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.appCoral)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 11) {
                MiniArtwork(style: .weightless, symbol: "music.note", size: 52, cornerRadius: 7)
                    .opacity(0.6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No song selected")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add music to your library")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x969DAC))
                }
            }
        }
    }
}
