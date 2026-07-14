import SwiftUI

struct PlayerBarView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var isSpeedPickerPresented = false
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
                            .foregroundStyle(Color.appInk)
                            .offset(x: model.isPlaying ? 0 : 1)
                            .frame(width: 38, height: 38)
                            .background(Color.appSurfaceRaised)
                            .overlay {
                                Circle().stroke(Color.appAccent.opacity(0.72), lineWidth: 1.5)
                            }
                            .clipShape(Circle())
                            .shadow(color: Color.appAccent.opacity(0.25), radius: 10)
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
                    playbackSpeedMenu
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                    StableVolumeSlider(value: $model.volume)
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
        .background(Color(hex: 0x050609).opacity(0.99))
        .background(.ultraThinMaterial.opacity(0.08))
    }

    private var playbackSpeedMenu: some View {
        Button {
            isSpeedPickerPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("\(Double(model.playbackRate).formatted())×")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Playback Speed")
        .popover(isPresented: $isSpeedPickerPresented, arrowEdge: .bottom) {
            VStack(spacing: 3) {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        model.setPlaybackRate(Float(rate))
                        isSpeedPickerPresented = false
                    } label: {
                        HStack {
                            Text("\(rate.formatted())×")
                            Spacer(minLength: 18)
                            if abs(Double(model.playbackRate) - rate) < 0.001 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                        .frame(width: 92)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .foregroundStyle(Color.appInk)
            .background(Color.appSurfaceRaised)
        }
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
                        .foregroundStyle(Color.appAccent)
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

/// A compact volume slider whose appearance stays consistent across macOS
/// releases. The system slider changed its tint and thumb treatment in macOS
/// 26, which made this control look disabled even though it was interactive.
private struct StableVolumeSlider: View {
    @Binding var value: Double
    @State private var isDragging = false

    private let thumbWidth: CGFloat = 26
    private let thumbHeight: CGFloat = 18
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let clampedValue = min(max(value, 0), 1)
            let travel = max(proxy.size.width - thumbWidth, 0)
            let thumbOffset = travel * clampedValue
            let thumbCenter = thumbOffset + thumbWidth / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.appAccent)
                    .frame(width: max(thumbCenter, trackHeight), height: trackHeight)

                volumeThumb
                    .offset(x: thumbOffset)
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.16), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard travel > 0 else { return }
                        isDragging = true
                        value = min(max((gesture.location.x - thumbWidth / 2) / travel, 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: thumbHeight)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var volumeThumb: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(isDragging ? Color.clear : Color(hex: 0xD8D0FF))
                .frame(width: thumbWidth, height: thumbHeight)
                .glassEffect(
                    isDragging ? Glass.clear.interactive() : .identity,
                    in: .capsule
                )
        } else {
            ZStack {
                Capsule()
                    .fill(Color(hex: 0xD8D0FF).opacity(isDragging ? 0 : 1))

                if isDragging {
                    Capsule().fill(.ultraThinMaterial).opacity(0.55)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
        }
    }
}
