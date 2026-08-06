import AppKit
import AVKit
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
    static let geometryDuration: TimeInterval = 0.52
    static let revealDuration: TimeInterval = 0.20

    static var geometryAnimation: Animation {
        .timingCurve(0.2, 0.78, 0.18, 1, duration: geometryDuration)
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

struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel
    let onDismiss: () -> Void
    @State private var isQueuePresented = false
    @State private var isSpeedPickerPresented = false
    @State private var installedVideoSession: InstalledVideoSession?
    @State private var isInstalledVideoExpanded = false
    @State private var isInstalledVideoRevealed = false
    @State private var isClosingInstalledVideo = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                nowPlayingBackground

                VStack(spacing: 0) {
                    topBar
                        .opacity(installedVideoSession == nil ? 1 : 0)
                        .allowsHitTesting(installedVideoSession == nil)

                    if let track = model.currentTrack {
                        playerContent(track, metrics: NowPlayingLayoutPolicy.metrics(in: proxy.size))
                    } else {
                        emptyState
                    }
                }
                .accessibilityHidden(installedVideoSession != nil)

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
                        isExpanded: isInstalledVideoExpanded,
                        isVideoRevealed: isInstalledVideoRevealed,
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

            if let track = model.currentTrack {
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
                if installedVideoSession == nil {
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
            .opacity(installedVideoSession == nil ? 1 : 0)
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

            NowPlayingProgressView(duration: track.duration, onSeek: model.seek)
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
        let shouldResumeAudio = model.isPlaying
        if shouldResumeAudio {
            model.togglePlay()
        }
        isQueuePresented = false

        let player = AVPlayer(url: url)
        let startTime = min(max(model.position, 0), max(track.duration, 0))
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
            resumeAudioOnClose: shouldResumeAudio,
            viewportSize: NSApp.windows
                .filter(\.isVisible)
                .compactMap { $0.contentView?.bounds.size }
                .max { lhs, rhs in
                    lhs.width * lhs.height < rhs.width * rhs.height
                } ?? CGSize(width: 1_200, height: 750)
        )
        isClosingInstalledVideo = false
        isInstalledVideoExpanded = false
        isInstalledVideoRevealed = false
        withAnimation(.easeOut(duration: 0.20)) {
            installedVideoSession = session
        }
        DispatchQueue.main.async {
            guard installedVideoSession?.id == session.id,
                  !isClosingInstalledVideo else { return }
            withAnimation(InstalledVideoLayoutPolicy.geometryAnimation) {
                isInstalledVideoExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + InstalledVideoLayoutPolicy.geometryDuration) {
                guard installedVideoSession?.id == session.id,
                      !isClosingInstalledVideo else { return }
                withAnimation(.easeInOut(duration: InstalledVideoLayoutPolicy.revealDuration)) {
                    isInstalledVideoRevealed = true
                }
                player.play()
            }
        }
    }

    private func closeInstalledVideo(_ session: InstalledVideoSession) {
        guard installedVideoSession?.id == session.id,
              !isClosingInstalledVideo else { return }
        isClosingInstalledVideo = true
        let currentTime = session.player.currentTime().seconds
        session.player.pause()
        withAnimation(.easeInOut(duration: InstalledVideoLayoutPolicy.revealDuration)) {
            isInstalledVideoRevealed = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + InstalledVideoLayoutPolicy.revealDuration) {
            guard installedVideoSession?.id == session.id else { return }
            withAnimation(InstalledVideoLayoutPolicy.geometryAnimation) {
                isInstalledVideoExpanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + InstalledVideoLayoutPolicy.geometryDuration) {
                guard installedVideoSession?.id == session.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    installedVideoSession = nil
                }
                finishInstalledVideoClose(session, currentTime: currentTime)
                isClosingInstalledVideo = false
            }
        }
    }

    private func finishInstalledVideoClose(
        _ session: InstalledVideoSession,
        currentTime: TimeInterval
    ) {
        let validTime = currentTime.isFinite ? max(currentTime, 0) : 0
        if model.currentTrackID == session.track.id, session.track.duration > 0 {
            model.seek(to: min(validTime / session.track.duration, 1))
        }
        let reachedEnd = session.track.duration > 0
            && validTime >= session.track.duration - 0.25
        if session.resumeAudioOnClose,
           !reachedEnd,
           model.currentTrackID == session.track.id,
           !model.isPlaying {
            model.togglePlay()
        }
    }
}

private struct InstalledVideoSession: Identifiable {
    let id = UUID()
    let track: Track
    let player: AVPlayer
    let resumeAudioOnClose: Bool
    let viewportSize: CGSize
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
    let session: InstalledVideoSession
    let isExpanded: Bool
    let isVideoRevealed: Bool
    let onClose: () -> Void
    @State private var backdropOpacity = 0.0

    private var surfaceFrame: CGRect {
        isExpanded
            ? InstalledVideoLayoutPolicy.videoFrame(in: session.viewportSize)
            : InstalledVideoLayoutPolicy.artworkFrame(in: session.viewportSize)
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
        ZStack {
            Color(hex: 0x010207).ignoresSafeArea()
                .opacity(backdropOpacity)

            RadialGradient(
                colors: [Color.appAccent.opacity(0.16), .clear],
                center: .center,
                startRadius: 40,
                endRadius: 720
            )
            .ignoresSafeArea()
            .opacity(backdropOpacity)

            ZStack {
                AspectFitVideoPlayer(player: session.player)
                    .opacity(isVideoRevealed ? 1 : 0)

                InstalledVideoTransitionArtwork(
                    track: session.track,
                    cornerRadius: surfaceCornerRadius,
                    symbolSize: min(session.viewportSize.width, session.viewportSize.height) * 0.18
                )
                .opacity(isVideoRevealed ? 0 : 1)
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
            .opacity(isVideoRevealed ? 1 : 0)
        }
        .frame(
            width: session.viewportSize.width,
            height: session.viewportSize.height,
            alignment: .top
        )
        .clipped()
        .foregroundStyle(Color.appInk)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                backdropOpacity = 1
            }
        }
        .onDisappear { session.player.pause() }
    }
}

private struct AspectFitVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AspectFitPlayerContainerView {
        let view = AspectFitPlayerContainerView()
        view.playerView.player = player
        return view
    }

    func updateNSView(_ view: AspectFitPlayerContainerView, context: Context) {
        view.playerView.player = player
    }
}

private final class AspectFitPlayerContainerView: NSView {
    let playerView = AVPlayerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.videoGravity = .resizeAspect
        playerView.controlsStyle = .floating
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        while !Task.isCancelled {
            guard await pause(seconds: 1.5) else { return }
            withAnimation(.linear(duration: travelDuration)) {
                progress = 1
            }
            guard await pause(seconds: travelDuration + 1.5) else { return }
            withAnimation(.linear(duration: travelDuration)) {
                progress = 0
            }
            guard await pause(seconds: travelDuration) else { return }
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
