import AVFoundation
import AppKit
import Combine
import SwiftUI

struct NowPlayingLayoutMetrics: Equatable {
    let isCompact: Bool
    let artworkSize: CGFloat
    let detailsWidth: CGFloat
    let contentHeight: CGFloat
    let horizontalPadding: CGFloat
    let columnSpacing: CGFloat
}

enum NowPlayingLayoutPolicy {
    static func metrics(in size: CGSize) -> NowPlayingLayoutMetrics {
        let isCompact = size.width < 1_100 || size.height < 720
        let horizontalPadding: CGFloat = isCompact ? 42 : 70
        let columnSpacing: CGFloat = isCompact ? 38 : 40
        let minimumDetailsWidth: CGFloat = isCompact ? 340 : 380
        let minimumArtworkSize: CGFloat = isCompact ? 290 : 360
        let availableWidth = max(size.width - horizontalPadding * 2, 0)
        let maximumArtworkSize = max(availableWidth - columnSpacing - minimumDetailsWidth, 0)
        let artworkLimit = min(
            max(size.height - 166, 0),
            size.width * (isCompact ? 0.38 : 0.405),
            680
        )
        let artworkSize = min(max(minimumArtworkSize, artworkLimit), maximumArtworkSize)
        let detailsWidth = max(0, min(680, availableWidth - artworkSize - columnSpacing))
        let availableHeight = max(size.height - 166, 0)
        let preferredContentHeight = max(artworkSize, isCompact ? 400 : 520)
        let contentHeight = min(preferredContentHeight, availableHeight)

        return NowPlayingLayoutMetrics(
            isCompact: isCompact,
            artworkSize: artworkSize,
            detailsWidth: detailsWidth,
            contentHeight: contentHeight,
            horizontalPadding: horizontalPadding,
            columnSpacing: columnSpacing
        )
    }
}

enum NowPlayingMarqueePolicy {
    static let pointsPerSecond: CGFloat = 28
    static let minimumTravelDuration: TimeInterval = 8
    static let initialPauseDuration: TimeInterval = 1
    static let endPauseDuration: TimeInterval = 1.25
    static let restartPauseDuration: TimeInterval = 0.2

    static func travel(contentWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        max(contentWidth - availableWidth, 0)
    }

    static func duration(for travel: CGFloat) -> TimeInterval {
        guard travel > 0 else { return 0 }
        return max(minimumTravelDuration, TimeInterval(travel / pointsPerSecond))
    }
}

enum InstalledVideoLayoutPolicy {
    static let edgeInset: CGFloat = 38
    static let nowPlayingTopBarHeight: CGFloat = 110
    static let nowPlayingContentTopPadding: CGFloat = 28
    static let artworkCornerRadius: CGFloat = 22
    static let videoCornerRadius: CGFloat = 18
    static let leadInDuration: TimeInterval = 0.035
    static let revealDelay: TimeInterval = leadInDuration
    static let geometryDuration: TimeInterval = 0.40
    static let revealDuration: TimeInterval = 0.14
    static let chromeFadeDuration: TimeInterval = 0.30
    static let exitArtworkRestoreLeadDuration: TimeInterval = 0.19
    static let chromeRestoreLeadDuration: TimeInterval = 0.12

    static var geometryAnimation: Animation {
        .timingCurve(0.25, 0.10, 0.25, 1, duration: geometryDuration)
    }

    static var chromeAnimation: Animation {
        .easeOut(duration: chromeFadeDuration)
    }

    static func duration(_ duration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : duration
    }

    static func exitArtworkRestoreDelay(reduceMotion: Bool) -> TimeInterval {
        max(
            duration(geometryDuration, reduceMotion: reduceMotion)
                - duration(exitArtworkRestoreLeadDuration, reduceMotion: reduceMotion),
            0
        )
    }

    static func artworkFrame(in viewport: CGSize) -> CGRect {
        let metrics = NowPlayingLayoutPolicy.metrics(in: viewport)
        let contentWidth = metrics.artworkSize + metrics.columnSpacing + metrics.detailsWidth
        return CGRect(
            x: max((viewport.width - contentWidth) / 2, 0),
            y: nowPlayingTopBarHeight + nowPlayingContentTopPadding,
            width: metrics.artworkSize,
            height: metrics.artworkSize
        )
    }

    static func videoFrame(in viewport: CGSize) -> CGRect {
        CGRect(
            x: edgeInset,
            y: edgeInset,
            width: max(viewport.width - edgeInset * 2, 1),
            height: max(viewport.height - edgeInset * 2, 1)
        )
    }
}

enum InstalledVideoControlsPolicy {
    static let autoHideDelay: TimeInterval = 2.2
    static let pointerExitDelay: TimeInterval = 0.45

    static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    static func seekTime(progress: Double, duration: TimeInterval) -> TimeInterval {
        guard progress.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(progress, 0), 1) * duration
    }
}

enum InstalledVideoAudioHandoffPolicy {
    static func videoGain(
        volume: Double,
        audioWasPlayingOnOpen: Bool,
        videoOwnsPlayback: Bool
    ) -> Float {
        audioWasPlayingOnOpen && !videoOwnsPlayback
            ? 0
            : PlaybackVolumePolicy.gain(for: volume)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onDismiss: () -> Void
    @State private var isQueuePresented = false
    @State private var isSpeedPickerPresented = false
    @State private var installedVideoSession: InstalledVideoSession?
    @State private var isInstalledVideoExpanded = false
    @State private var isInstalledVideoRevealed = false
    @State private var isInstalledVideoArtworkRestored = false
    @State private var isClosingInstalledVideo = false
    @State private var isRestoringNowPlayingChrome = false

    private var isNowPlayingChromeVisible: Bool {
        installedVideoSession == nil || isRestoringNowPlayingChrome
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                nowPlayingBackground

                VStack(spacing: 0) {
                    topBar
                        .opacity(isNowPlayingChromeVisible ? 1 : 0)
                        .offset(y: isNowPlayingChromeVisible ? 0 : -8)
                        .allowsHitTesting(installedVideoSession == nil)

                    if let track = model.currentTrack {
                        playerContent(track, metrics: NowPlayingLayoutPolicy.metrics(in: proxy.size))
                    } else {
                        emptyState
                    }
                }
                .accessibilityHidden(!isNowPlayingChromeVisible)

                if isQueuePresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissQueue)

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        NowPlayingQueueDrawer(onDismiss: dismissQueue)
                            .frame(width: min(390, max(330, proxy.size.width * 0.32)))
                            .padding(.top, min(120, max(90, proxy.size.height * 0.14)))
                            .padding(.trailing, min(48, max(26, proxy.size.width * 0.03)))
                            .padding(.bottom, min(54, max(30, proxy.size.height * 0.05)))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                if let installedVideoSession {
                    InstalledVideoPlayerView(
                        session: installedVideoSession,
                        viewportSize: proxy.size,
                        isExpanded: isInstalledVideoExpanded,
                        isVideoRevealed: isInstalledVideoRevealed,
                        isArtworkRestored: isInstalledVideoArtworkRestored,
                        isClosing: isClosingInstalledVideo,
                        onPlaybackStarted: {
                            handOffAudioToInstalledVideo(installedVideoSession)
                        },
                        onClose: { closeInstalledVideo(installedVideoSession) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)
                    .zIndex(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Color.appInk)
        .preferredColorScheme(.dark)
        .onExitCommand {
            if let installedVideoSession {
                closeInstalledVideo(installedVideoSession)
            } else {
                onDismiss()
            }
        }
        .onChange(of: model.currentTrackID) { _, trackID in
            guard let installedVideoSession,
                  trackID != installedVideoSession.track.id else { return }
            closeInstalledVideo(installedVideoSession)
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            CircleIconButton(
                systemImage: "chevron.down",
                label: "Close Now Playing",
                size: 48,
                symbolSize: 18,
                background: Color.black.opacity(0.22),
                hoverBackground: Color.white.opacity(0.10),
                foreground: Color.white,
                action: onDismiss
            )
            .overlay {
                Circle().stroke(Color.white.opacity(0.24), lineWidth: 1)
            }

            Text("NOW PLAYING")
                .font(.system(size: 14, weight: .semibold))
                .tracking(2.6)

            Spacer(minLength: 24)

            if let track = model.currentTrack, model.canFavorite(track) {
                CircleIconButton(
                    systemImage: model.favorites.contains(track.id) ? "heart.fill" : "heart",
                    label: model.favorites.contains(track.id)
                        ? "Remove from Liked Songs"
                        : "Add to Liked Songs",
                    size: 48,
                    symbolSize: 19,
                    background: Color.black.opacity(0.22),
                    hoverBackground: Color.white.opacity(0.10),
                    isActive: model.favorites.contains(track.id),
                    foreground: Color.white,
                    action: { model.toggleFavorite(track) }
                )
                .overlay {
                    Circle().stroke(Color.white.opacity(0.24), lineWidth: 1)
                }

                Menu {
                    if track.installedVideoURL != nil {
                        Button {
                            openInstalledVideo(track)
                        } label: {
                            Label("Watch Video", systemImage: "video")
                        }
                        Divider()
                    }
                    if !model.customPlaylists.isEmpty {
                        Menu("Add to Playlist") {
                            ForEach(model.customPlaylists) { playlist in
                                Button(playlist.name) { model.addTrack(track, to: playlist) }
                            }
                        }
                    }
                    Button("Show in Finder") { model.revealInFinder(track) }
                } label: {
                    HoverCircleIconSurface(
                        systemImage: "ellipsis",
                        label: "More",
                        size: 48,
                        symbolSize: 18,
                        background: Color.black.opacity(0.22),
                        hoverBackground: Color.white.opacity(0.10),
                        foreground: Color.white
                    )
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.leading, 37)
        .padding(.trailing, 64)
        .padding(.top, 18)
        .frame(height: 110)
    }

    private func playerContent(_ track: Track, metrics: NowPlayingLayoutMetrics) -> some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            Group {
                if isNowPlayingChromeVisible {
                    InstalledVideoTransitionArtwork(
                        track: track,
                        cornerRadius: 22,
                        symbolSize: metrics.artworkSize * 0.22
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.appAccent.opacity(0.42), lineWidth: 1)
                    }
                    .shadow(color: Color.appAccent.opacity(0.24), radius: 34, y: 15)
                } else {
                    Color.clear
                }
            }
            .frame(width: metrics.artworkSize, height: metrics.artworkSize)

            controls(
                for: track,
                compact: metrics.isCompact,
                height: metrics.contentHeight
            )
            .frame(width: metrics.detailsWidth, height: metrics.contentHeight)
            .opacity(isNowPlayingChromeVisible ? 1 : 0)
            .offset(x: isNowPlayingChromeVisible ? 0 : 10)
            .allowsHitTesting(installedVideoSession == nil)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func controls(for track: Track, compact: Bool, height: CGFloat) -> some View {
        let metadataHeight: CGFloat = compact ? 110 : 142
        let seekHeight: CGFloat = 18
        let transportHeight: CGFloat = compact ? 82 : 104
        let bottomHeight: CGFloat = compact ? 120 : 54
        let flexibleHeight = max(
            height - metadataHeight - seekHeight - transportHeight - bottomHeight,
            0
        )

        return VStack(spacing: 0) {
            Spacer().frame(height: flexibleHeight * 0.26)

            VStack(spacing: compact ? 8 : 12) {
                NowPlayingMarqueeTitle(
                    title: track.title,
                    fontSize: compact ? 36 : 52
                )
                .frame(height: compact ? 46 : 66)

                Text(track.artist)
                    .font(.system(size: compact ? 23 : 31, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)

                Text(track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Local file"
                    : track.album)
                    .font(.system(size: compact ? 14 : 17, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)

            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: metadataHeight)
            .clipped()

            Spacer().frame(height: flexibleHeight * 0.26)

            NowPlayingProgressView(duration: model.playbackDuration, onSeek: model.seek)
                .frame(maxWidth: .infinity)
                .frame(height: seekHeight)

            Spacer().frame(height: flexibleHeight * 0.12)

            HStack(spacing: compact ? 14 : 24) {
                NowPlayingTransportButton(
                    systemImage: "shuffle",
                    label: "Shuffle",
                    size: compact ? 44 : 54,
                    symbolSize: compact ? 20 : 24,
                    isActive: model.shuffleEnabled,
                    action: model.toggleShuffle
                )
                NowPlayingTransportButton(
                    systemImage: "backward.end.fill",
                    label: "Previous",
                    size: compact ? 44 : 56,
                    symbolSize: compact ? 23 : 29,
                    action: model.previous
                )
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 30 : 38, weight: .bold))
                        .foregroundStyle(Color.white)
                        .offset(x: model.isPlaying ? 0 : 2)
                        .frame(width: compact ? 82 : 104, height: compact ? 82 : 104)
                        .background {
                            ZStack {
                                Circle().fill(Color(hex: 0x291B44).opacity(0.92))
                                RadialGradient(
                                    colors: [Color(hex: 0x9A5CFF).opacity(0.42), .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: compact ? 42 : 54
                                )
                            }
                        }
                        .overlay {
                            Circle().stroke(Color(hex: 0xAC69FF), lineWidth: 2)
                        }
                        .shadow(color: Color(hex: 0x8D4EFF).opacity(0.36), radius: 22)
                }
                .buttonStyle(PressableScaleStyle())
                .help(model.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                NowPlayingTransportButton(
                    systemImage: "forward.end.fill",
                    label: "Next",
                    size: compact ? 44 : 56,
                    symbolSize: compact ? 23 : 29,
                    action: model.next
                )
                NowPlayingTransportButton(
                    systemImage: "repeat",
                    label: "Repeat",
                    size: compact ? 44 : 54,
                    symbolSize: compact ? 20 : 24,
                    isActive: model.repeatEnabled,
                    action: model.toggleRepeat
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: transportHeight)

            Spacer().frame(height: flexibleHeight * 0.16)

            Group {
                if compact {
                    VStack(spacing: 12) {
                        volumeControl
                        HStack(spacing: 12) {
                            playbackSpeedMenu
                            queueButton
                        }
                    }
                } else {
                    HStack(spacing: 16) {
                        playbackSpeedMenu
                        volumeControl
                        queueButton
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomHeight)

            Spacer().frame(height: flexibleHeight * 0.20)
        }
        .frame(maxWidth: .infinity)
    }

    private var playbackSpeedMenu: some View {
        Button {
            isSpeedPickerPresented.toggle()
        } label: {
            HStack(spacing: 18) {
                Text("\(Double(model.playbackRate).formatted())×")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.black.opacity(0.24))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableScaleStyle())
        .frame(minWidth: 120, maxWidth: 144)
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
                        .frame(width: 96)
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

    private var volumeControl: some View {
        HStack(spacing: 14) {
            Image(systemName: model.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 17, weight: .medium))
            NowPlayingVolumeSlider(value: $model.volume)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(Color.black.opacity(0.24))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var queueButton: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                isQueuePresented.toggle()
            }
        } label: {
            Label("Queue", systemImage: "list.bullet.rectangle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(isQueuePresented ? Color.appAccent.opacity(0.28) : Color.black.opacity(0.24))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isQueuePresented
                                ? Color.appAccent.opacity(0.72)
                                : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableScaleStyle())
        .frame(minWidth: 118, maxWidth: 142)
        .help("Show Queue")
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ArtworkView(
                style: .weightless,
                symbol: "music.note",
                symbolSize: 80,
                cornerRadius: 24,
                glow: true
            )
            .frame(width: 330, height: 330)
            .opacity(0.72)

            Text("Nothing Playing")
                .font(.system(size: 34, weight: .semibold))
            Text("Choose a song from your library to begin.")
                .font(.system(size: 15))
                .foregroundStyle(Color.appMuted)

            Button("Add Music", action: model.importLocalFiles)
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 56)
    }

    @ViewBuilder
    private var nowPlayingBackground: some View {
        ZStack {
            Color(hex: 0x010207)

            if let track = model.currentTrack,
               let artworkData = track.artworkData,
               let image = ArtworkCropping.squareImage(from: artworkData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .saturation(1.18)
                    .blur(radius: 64, opaque: true)
                    .scaleEffect(1.14)
                    .opacity(0.88)
                    .accessibilityHidden(true)
            } else if let track = model.currentTrack {
                LinearGradient(
                    colors: AppGradient.colors(for: track.artwork).map { $0.opacity(0.58) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blur(radius: 56, opaque: true)
                .scaleEffect(1.14)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.46),
                    Color(hex: 0x070711).opacity(0.58),
                    Color.black.opacity(0.76),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color.appAccent.opacity(0.12), .clear],
                center: UnitPoint(x: 0.56, y: 0.48),
                startRadius: 20,
                endRadius: 560
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    private func dismissQueue() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isQueuePresented = false
        }
    }

    private func openInstalledVideo(_ track: Track) {
        guard let url = track.installedVideoURL else { return }
        let audioWasPlaying = model.isPlaying
        isQueuePresented = false

        let player = AVPlayer(url: url)
        let playbackDuration = model.playbackDuration > 0
            ? model.playbackDuration
            : track.duration
        let startTime = min(max(model.position, 0), max(playbackDuration, 0))
        if startTime > 0 {
            player.seek(
                to: CMTime(seconds: startTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        let session = InstalledVideoSession(
            track: track,
            player: player,
            audioWasPlayingOnOpen: audioWasPlaying
        )
        isClosingInstalledVideo = false
        isRestoringNowPlayingChrome = false
        isInstalledVideoExpanded = false
        isInstalledVideoRevealed = false
        isInstalledVideoArtworkRestored = false
        withAnimation(reduceMotion ? nil : InstalledVideoLayoutPolicy.chromeAnimation) {
            installedVideoSession = session
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + InstalledVideoLayoutPolicy.duration(
                InstalledVideoLayoutPolicy.revealDelay,
                reduceMotion: reduceMotion
            )
        ) {
            guard installedVideoSession?.id == session.id,
                  !isClosingInstalledVideo else { return }
            withAnimation(reduceMotion ? nil : InstalledVideoLayoutPolicy.geometryAnimation) {
                isInstalledVideoExpanded = true
            }
            withAnimation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: InstalledVideoLayoutPolicy.revealDuration)
            ) {
                isInstalledVideoRevealed = true
            }
            let handoffDuration = model.playbackDuration > 0
                ? model.playbackDuration
                : track.duration
            let handoffTime = min(max(model.position, 0), max(handoffDuration, 0))
            player.seek(
                to: CMTime(seconds: handoffTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            player.playImmediately(atRate: model.playbackRate)
        }
    }

    private func handOffAudioToInstalledVideo(_ session: InstalledVideoSession) {
        guard installedVideoSession?.id == session.id,
              !isClosingInstalledVideo,
              !session.ownsPlayback else { return }
        session.ownsPlayback = true
        // PlayerModel pauses the primary audio player before it unmutes and adopts
        // this AVPlayer, keeping the handoff continuous without a double-audio burst.
        model.beginInstalledVideoPlayback(session.player, trackID: session.track.id)
    }

    private func closeInstalledVideo(_ session: InstalledVideoSession) {
        guard installedVideoSession?.id == session.id,
              !isClosingInstalledVideo else { return }
        isClosingInstalledVideo = true
        let currentTime = session.player.currentTime().seconds
        let videoWasPlaying = session.player.timeControlStatus == .playing
        session.player.volume = 0
        if session.ownsPlayback {
            model.endInstalledVideoPlayback(
                session.player,
                trackID: session.track.id,
                position: currentTime,
                resumeAudio: videoWasPlaying
            )
            session.ownsPlayback = false
        }
        withAnimation(reduceMotion ? nil : InstalledVideoLayoutPolicy.geometryAnimation) {
            isInstalledVideoExpanded = false
        }
        let geometryDuration = InstalledVideoLayoutPolicy.duration(
            InstalledVideoLayoutPolicy.geometryDuration,
            reduceMotion: reduceMotion
        )
        let artworkRestoreDelay = InstalledVideoLayoutPolicy.exitArtworkRestoreDelay(
            reduceMotion: reduceMotion
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + artworkRestoreDelay) {
            guard installedVideoSession?.id == session.id,
                  isClosingInstalledVideo else { return }
            withAnimation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: InstalledVideoLayoutPolicy.revealDuration)
            ) {
                isInstalledVideoArtworkRestored = true
            }
        }
        let chromeRestoreDelay = max(
            geometryDuration - InstalledVideoLayoutPolicy.duration(
                InstalledVideoLayoutPolicy.chromeRestoreLeadDuration,
                reduceMotion: reduceMotion
            ),
            0
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + chromeRestoreDelay) {
            guard installedVideoSession?.id == session.id else { return }
            withAnimation(reduceMotion ? nil : InstalledVideoLayoutPolicy.chromeAnimation) {
                isRestoringNowPlayingChrome = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + geometryDuration) {
            guard installedVideoSession?.id == session.id else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                installedVideoSession = nil
                isInstalledVideoRevealed = false
                isInstalledVideoArtworkRestored = false
                isRestoringNowPlayingChrome = false
            }
            isClosingInstalledVideo = false
        }
    }

}

private final class InstalledVideoSession: Identifiable {
    let id = UUID()
    let track: Track
    let player: AVPlayer
    let audioWasPlayingOnOpen: Bool
    var ownsPlayback = false

    init(track: Track, player: AVPlayer, audioWasPlayingOnOpen: Bool) {
        self.track = track
        self.player = player
        self.audioWasPlayingOnOpen = audioWasPlayingOnOpen
    }
}

private struct InstalledVideoTransitionArtwork: View {
    let track: Track
    let cornerRadius: CGFloat
    let symbolSize: CGFloat

    var body: some View {
        Group {
            if let artworkData = track.artworkData,
               let image = ArtworkCropping.squareImage(from: artworkData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkView(
                    style: track.artwork,
                    symbol: "music.note",
                    symbolSize: symbolSize,
                    cornerRadius: cornerRadius,
                    glow: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct InstalledVideoPlayerView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: InstalledVideoSession
    let viewportSize: CGSize
    let isExpanded: Bool
    let isVideoRevealed: Bool
    let isArtworkRestored: Bool
    let isClosing: Bool
    let onPlaybackStarted: () -> Void
    let onClose: () -> Void
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isPlaying = false
    @State private var controlsVisible = true
    @State private var controlsAreHovered = false
    @State private var controlsHideTask: Task<Void, Never>?

    private func surfaceFrame(in viewportSize: CGSize) -> CGRect {
        isExpanded
            ? InstalledVideoLayoutPolicy.videoFrame(in: viewportSize)
            : InstalledVideoLayoutPolicy.artworkFrame(in: viewportSize)
    }

    private var surfaceCornerRadius: CGFloat {
        isExpanded
            ? InstalledVideoLayoutPolicy.videoCornerRadius
            : InstalledVideoLayoutPolicy.artworkCornerRadius
    }

    private var surfaceBorderColor: Color {
        isExpanded ? Color.white.opacity(0.18) : Color.appAccent.opacity(0.42)
    }

    private var surfaceShadowColor: Color {
        isExpanded ? Color.black.opacity(0.72) : Color.appAccent.opacity(0.24)
    }

    var body: some View {
        let surfaceFrame = surfaceFrame(in: viewportSize)

        ZStack {
            Color(hex: 0x010207).ignoresSafeArea()
                .opacity(isExpanded ? 1 : 0)

            RadialGradient(
                colors: [Color.appAccent.opacity(0.16), .clear],
                center: .center,
                startRadius: 40,
                endRadius: 720
            )
            .ignoresSafeArea()
            .opacity(isExpanded ? 1 : 0)

            ZStack {
                AspectFitVideoPlayer(player: session.player)
                    .opacity(isVideoRevealed && !isArtworkRestored ? 1 : 0)
                    .allowsHitTesting(isVideoRevealed && !isClosing)

                InstalledVideoTransitionArtwork(
                    track: session.track,
                    cornerRadius: surfaceCornerRadius,
                    symbolSize: min(viewportSize.width, viewportSize.height) * 0.18
                )
                .opacity(isVideoRevealed && !isArtworkRestored ? 0 : 1)
            }
            .frame(width: surfaceFrame.width, height: surfaceFrame.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                    .stroke(surfaceBorderColor, lineWidth: 1)
            }
            .shadow(
                color: surfaceShadowColor,
                radius: isExpanded ? 36 : 34,
                y: isExpanded ? 18 : 15
            )
            .position(x: surfaceFrame.midX, y: surfaceFrame.midY)
            .zIndex(1)

            Color.clear
                .frame(width: surfaceFrame.width, height: surfaceFrame.height)
                .contentShape(Rectangle())
                .position(x: surfaceFrame.midX, y: surfaceFrame.midY)
                .allowsHitTesting(isVideoRevealed && !isClosing)
                .zIndex(2)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        showControls()
                    case .ended:
                        scheduleControlsHide(
                            after: InstalledVideoControlsPolicy.pointerExitDelay
                        )
                    }
                }

            InstalledVideoControlsOverlay(
                track: session.track,
                currentTime: currentTime,
                duration: duration,
                isPlaying: isPlaying,
                repeatEnabled: model.repeatEnabled,
                volume: $model.volume,
                isCompact: surfaceFrame.width < 760,
                onSeek: seek,
                onPrevious: previous,
                onTogglePlayback: togglePlayback,
                onNext: next,
                onToggleRepeat: model.toggleRepeat
            )
            .frame(width: surfaceFrame.width, height: surfaceFrame.height)
            .clipShape(RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous))
            .position(x: surfaceFrame.midX, y: surfaceFrame.midY)
            .opacity(
                isVideoRevealed && !isClosing && (controlsVisible || !isPlaying)
                    ? 1
                    : 0
            )
            .offset(y: controlsVisible || !isPlaying ? 0 : 12)
            .allowsHitTesting(isVideoRevealed && !isClosing && (controlsVisible || !isPlaying))
            .zIndex(3)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.20),
                value: controlsVisible || !isPlaying
            )
            .onHover { hovering in
                controlsAreHovered = hovering
                if hovering {
                    showControls(keepVisible: true)
                } else {
                    showControls()
                }
            }

            CircleIconButton(
                systemImage: "chevron.left",
                label: "Return to Now Playing",
                size: 48,
                symbolSize: 18,
                background: Color.black.opacity(0.30),
                hoverBackground: Color.white.opacity(0.10),
                foreground: Color.white,
                action: onClose
            )
            .overlay {
                Circle().stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .padding(.leading, InstalledVideoLayoutPolicy.edgeInset + 16)
            .padding(.top, InstalledVideoLayoutPolicy.edgeInset + 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(isVideoRevealed && !isClosing ? 1 : 0)
            .allowsHitTesting(isVideoRevealed && !isClosing)
            .zIndex(4)
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .clipped()
        .foregroundStyle(Color.appInk)
        .onAppear {
            session.player.volume = InstalledVideoAudioHandoffPolicy.videoGain(
                volume: model.volume,
                audioWasPlayingOnOpen: session.audioWasPlayingOnOpen,
                videoOwnsPlayback: session.ownsPlayback
            )
            session.player.defaultRate = model.playbackRate
            refreshPlaybackState()
            showControls()
        }
        .onChange(of: model.volume) { _, volume in
            session.player.volume = InstalledVideoAudioHandoffPolicy.videoGain(
                volume: volume,
                audioWasPlayingOnOpen: session.audioWasPlayingOnOpen,
                videoOwnsPlayback: session.ownsPlayback
            )
        }
        .onChange(of: model.playbackRate) { _, rate in
            session.player.defaultRate = rate
            if isPlaying {
                session.player.rate = rate
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                showControls()
            } else {
                showControls(keepVisible: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime,
            object: session.player.currentItem
        )) { _ in
            handlePlaybackEnded()
        }
        .onReceive(session.player.publisher(for: \.timeControlStatus)) { status in
            guard status == .playing else { return }
            onPlaybackStarted()
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                refreshPlaybackState()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onDisappear {
            controlsHideTask?.cancel()
            session.player.pause()
            if session.ownsPlayback {
                model.endInstalledVideoPlayback(
                    session.player,
                    trackID: session.track.id,
                    position: currentTime,
                    resumeAudio: false
                )
                session.ownsPlayback = false
            }
        }
    }

    private func refreshPlaybackState() {
        let nextTime = session.player.currentTime().seconds
        currentTime = nextTime.isFinite ? max(nextTime, 0) : 0

        let playbackDuration = model.currentTrackID == session.track.id
            ? model.playbackDuration
            : session.track.duration
        let itemDuration = session.player.currentItem?.duration.seconds ?? 0
        if playbackDuration.isFinite, playbackDuration > 0 {
            duration = playbackDuration
        } else if itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        } else {
            duration = max(session.track.duration, 0)
        }
        isPlaying = session.player.timeControlStatus == .playing
        if session.ownsPlayback {
            model.updateInstalledVideoPlayback(
                session.player,
                trackID: session.track.id,
                position: currentTime,
                duration: duration,
                isPlaying: isPlaying
            )
        }
        if isPlaying, duration > 0, currentTime >= duration - 0.02 {
            session.player.pause()
            handlePlaybackEnded()
        }
    }

    private func showControls(keepVisible: Bool = false) {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            controlsVisible = true
        }
        guard !keepVisible, !controlsAreHovered, isPlaying else { return }
        scheduleControlsHide(after: InstalledVideoControlsPolicy.autoHideDelay)
    }

    private func scheduleControlsHide(after delay: TimeInterval) {
        controlsHideTask?.cancel()
        guard isPlaying, !controlsAreHovered else { return }
        controlsHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, !controlsAreHovered else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                controlsVisible = false
            }
        }
    }

    private func seek(to progress: Double) {
        let time = InstalledVideoControlsPolicy.seekTime(
            progress: progress,
            duration: duration
        )
        currentTime = time
        session.player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if session.ownsPlayback { model.seekToTime(time) }
        showControls()
    }

    private func togglePlayback() {
        if session.ownsPlayback {
            model.togglePlay()
            refreshPlaybackState()
            if model.isPlaying { showControls() }
            else { showControls(keepVisible: true) }
            return
        }
        if isPlaying {
            session.player.pause()
            isPlaying = false
            showControls(keepVisible: true)
            return
        }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        session.player.playImmediately(atRate: model.playbackRate)
        isPlaying = true
        showControls()
    }

    private func previous() {
        if currentTime > 3 {
            seek(to: 0)
            if isPlaying {
                session.player.playImmediately(atRate: model.playbackRate)
            }
            return
        }
        session.player.pause()
        if model.currentTrackID == session.track.id {
            model.seek(to: 0)
        }
        model.previous()
        onClose()
    }

    private func next() {
        session.player.pause()
        model.next()
        onClose()
    }

    private func handlePlaybackEnded() {
        if model.repeatEnabled {
            seek(to: 0)
            session.player.playImmediately(atRate: model.playbackRate)
            isPlaying = true
            showControls()
        } else {
            next()
        }
    }
}

private struct InstalledVideoControlsOverlay: View {
    let track: Track
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let repeatEnabled: Bool
    @Binding var volume: Double
    let isCompact: Bool
    let onSeek: (Double) -> Void
    let onPrevious: () -> Void
    let onTogglePlayback: () -> Void
    let onNext: () -> Void
    let onToggleRepeat: () -> Void

    private var progress: Double {
        InstalledVideoControlsPolicy.progress(position: currentTime, duration: duration)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(hex: 0x02030A).opacity(0.60), location: 0.30),
                    .init(color: Color(hex: 0x02030A).opacity(0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                if !isCompact {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(Color.white)
                        Text(track.artist)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(hex: 0xD4CEDF))
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityElement(children: .combine)
                }

                HStack(spacing: 12) {
                    Text(Track.timeText(currentTime))
                        .frame(width: 48, alignment: .leading)
                    ClickableProgress(
                        progress: progress,
                        activeColor: Color(hex: 0x9A5CFF),
                        height: 4,
                        onSeek: onSeek
                    )
                    Text(Track.timeText(duration))
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color(hex: 0xE8E2F2))

                if isCompact {
                    HStack(spacing: 14) {
                        transportControls
                        Spacer(minLength: 12)
                        sideControls
                    }
                } else {
                    ZStack {
                        transportControls
                        HStack {
                            Spacer(minLength: 0)
                            sideControls
                        }
                    }
                }
            }
            .padding(.top, 70)
            .padding(.horizontal, isCompact ? 18 : 38)
            .padding(.bottom, isCompact ? 22 : 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            InstalledVideoTransportButton(
                systemImage: "backward.end.fill",
                label: "Previous",
                action: onPrevious
            )
            InstalledVideoTransportButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                size: 58,
                symbolSize: 23,
                isPrimary: true,
                action: onTogglePlayback
            )
            InstalledVideoTransportButton(
                systemImage: "forward.end.fill",
                label: "Next",
                action: onNext
            )
        }
    }

    private var sideControls: some View {
        HStack(spacing: 12) {
            InstalledVideoTransportButton(
                systemImage: "repeat",
                label: "Repeat current song",
                isActive: repeatEnabled,
                action: onToggleRepeat
            )

            HStack(spacing: 10) {
                Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 21)
                    .accessibilityHidden(true)
                NowPlayingVolumeSlider(value: $volume)
                    .frame(width: isCompact ? 82 : 118)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background {
                Capsule()
                    .fill(Color(hex: 0x11121B).opacity(0.72))
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .overlay {
                Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct InstalledVideoTransportButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 46
    var symbolSize: CGFloat = 20
    var isPrimary = false
    var isActive = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(Color.white)
                .offset(x: systemImage == "play.fill" ? 1 : 0)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(backgroundColor)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .overlay {
                    Circle().stroke(borderColor, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.54), radius: 14, y: 8)
        }
        .buttonStyle(PressableScaleStyle())
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isPrimary {
            return Color(hex: 0x6E39C5).opacity(isHovering ? 0.94 : 0.78)
        }
        if isActive || isHovering {
            return Color(hex: 0x7043C7).opacity(0.34)
        }
        return Color(hex: 0x11121B).opacity(0.76)
    }

    private var borderColor: Color {
        if isPrimary { return Color(hex: 0xB08BFF).opacity(0.72) }
        if isActive || isHovering { return Color(hex: 0xA98AFF).opacity(0.60) }
        return Color.white.opacity(0.17)
    }
}

private struct AspectFitVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AspectFitPlayerContainerView {
        let view = AspectFitPlayerContainerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AspectFitPlayerContainerView, context: Context) {
        view.player = player
    }
}

private final class AspectFitPlayerContainerView: NSView {
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("AspectFitPlayerContainerView requires an AVPlayerLayer")
        }
        return playerLayer
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct NowPlayingProgressView: View {
    @EnvironmentObject private var playbackPosition: PlaybackPositionState
    let duration: TimeInterval
    let onSeek: (Double) -> Void

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return playbackPosition.position / duration
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(Track.timeText(playbackPosition.position))
                .frame(width: 44, alignment: .trailing)
            ClickableProgress(
                progress: progress,
                activeColor: Color(hex: 0x965EFF),
                height: 4,
                onSeek: onSeek
            )
            Text(Track.timeText(duration))
                .frame(width: 44, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.86))
    }
}

private struct NowPlayingTransportButton: View {
    let systemImage: String
    let label: String
    let size: CGFloat
    let symbolSize: CGFloat
    var isActive = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(
                    isActive
                        ? Color(hex: 0xA76BFF)
                        : Color.white.opacity(isHovering ? 1 : 0.82)
                )
                .frame(width: size, height: size)
                .background(isHovering ? Color.white.opacity(0.08) : .clear)
                .clipShape(Circle())
        }
        .buttonStyle(PressableScaleStyle())
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct NowPlayingVolumeSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            let clampedValue = min(max(value, 0), 1)
            let thumbSize: CGFloat = 14
            let travel = max(proxy.size.width - thumbSize, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 4)
                Capsule()
                    .fill(Color(hex: 0x9A5CFF))
                    .frame(width: thumbSize / 2 + travel * clampedValue, height: 4)
                Circle()
                    .fill(Color(hex: 0xA969FF))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.appAccent.opacity(0.4), radius: 4)
                    .offset(x: travel * clampedValue)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard travel > 0 else { return }
                        value = min(max((gesture.location.x - thumbSize / 2) / travel, 0), 1)
                    }
            )
        }
        .frame(height: 18)
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
}

private struct NowPlayingMarqueeTitle: View {
    let title: String
    let fontSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var applicationIsActive = NSApp.isActive
    @State private var contentWidth: CGFloat = 0
    @State private var progress: CGFloat = 0

    var body: some View {
        if reduceMotion {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.62)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
        } else {
            GeometryReader { proxy in
                let travel = NowPlayingMarqueePolicy.travel(
                    contentWidth: contentWidth,
                    availableWidth: proxy.size.width
                )

                ZStack(alignment: travel > 1 ? .leading : .center) {
                    Text(title)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { textProxy in
                                Color.clear.preference(
                                    key: NowPlayingMarqueeTextWidthKey.self,
                                    value: textProxy.size.width
                                )
                            }
                        }
                        .offset(x: -(travel * progress))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .task(id: MarqueeTaskID(
                    title: title,
                    travel: travel,
                    isActive: scenePhase == .active && applicationIsActive
                )) {
                    guard scenePhase == .active, applicationIsActive else {
                        withTransaction(Transaction(animation: nil)) { progress = 0 }
                        return
                    }
                    await animate(travel: travel)
                }
            }
            .onPreferenceChange(NowPlayingMarqueeTextWidthKey.self) { width in
                contentWidth = width
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in
                applicationIsActive = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )) { _ in
                applicationIsActive = false
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        }
    }

    @MainActor
    private func animate(travel: CGFloat) async {
        withTransaction(Transaction(animation: nil)) {
            progress = 0
        }
        guard travel > 1 else { return }

        let travelDuration = NowPlayingMarqueePolicy.duration(for: travel)
        guard await pause(seconds: NowPlayingMarqueePolicy.initialPauseDuration) else { return }
        while !Task.isCancelled {
            withAnimation(.linear(duration: travelDuration)) {
                progress = 1
            }
            guard await pause(seconds: travelDuration) else { return }
            guard await pause(seconds: NowPlayingMarqueePolicy.endPauseDuration) else { return }
            withTransaction(Transaction(animation: nil)) {
                progress = 0
            }
            guard await pause(seconds: NowPlayingMarqueePolicy.restartPauseDuration) else { return }
        }
    }

    private func pause(seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct MarqueeTaskID: Hashable {
    let title: String
    let travel: Int
    let isActive: Bool

    init(title: String, travel: CGFloat, isActive: Bool) {
        self.title = title
        self.travel = Int(travel.rounded())
        self.isActive = isActive
    }
}

private struct NowPlayingMarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NowPlayingQueueDrawer: View {
    @EnvironmentObject private var model: PlayerModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Queue")
                        .font(.system(size: 22, weight: .semibold))
                    Text("\(model.queueTracks.count) \(model.queueTracks.count == 1 ? "song" : "songs")")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                }

                Spacer()

                CircleIconButton(
                    systemImage: "xmark",
                    label: "Close Queue",
                    size: 34,
                    symbolSize: 12,
                    background: Color.white.opacity(0.07),
                    hoverBackground: Color.white.opacity(0.12),
                    action: onDismiss
                )
            }
            .padding(20)

            HStack(spacing: 0) {
                ForEach(QueueTab.allCases) { tab in
                    Button {
                        model.queueTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.queueTab == tab ? Color.white : Color.appMuted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .overlay(alignment: .bottom) {
                                if model.queueTab == tab {
                                    Rectangle()
                                        .fill(Color.appAccent)
                                        .frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.appLine)
                    .frame(height: 1)
            }

            ScrollView {
                if model.queueTracks.isEmpty {
                    Text(model.queueTab == .history ? "Nothing played yet" : "Queue is empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 42)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.queueTracks.enumerated()), id: \.offset) { _, track in
                            NowPlayingQueueRow(track: track)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(.ultraThinMaterial)
        .background(Color(hex: 0x090A11).opacity(0.91))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0x9B7AFF).opacity(0.26), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.82), radius: 50, x: -8, y: 20)
    }
}

private struct NowPlayingQueueRow: View {
    @EnvironmentObject private var model: PlayerModel
    let track: Track
    @State private var isHovering = false

    private var isAvailableOnDevice: Bool {
        model.tracks.contains { $0.id == track.id && $0.fileURL != nil }
    }

    var body: some View {
        Button {
            guard isAvailableOnDevice else { return }
            model.selectAndPlay(track)
        } label: {
            HStack(spacing: 11) {
                TrackArtworkView(track: track, symbol: "music.note", symbolSize: 13, cornerRadius: 9)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if track.id == model.currentTrackID {
                    EqualizerGlyph(isAnimating: model.isPlaying)
                        .frame(width: 18, height: 18)
                } else if !isAvailableOnDevice {
                    Text("Not downloaded")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                } else {
                    Text(track.durationText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appMuted)
                }
            }
            .padding(9)
            .frame(minHeight: 64)
            .background(isHovering ? Color.white.opacity(0.04) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailableOnDevice)
        .onHover { isHovering = $0 }
    }
}
