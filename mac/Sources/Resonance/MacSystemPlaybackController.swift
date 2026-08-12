import AppKit
import MediaPlayer

private struct SendableNowPlayingArtwork: @unchecked Sendable {
    let image: NSImage
}

struct MacNowPlayingSnapshot: Equatable {
    let trackID: UUID
    let contentIdentifier: String
    let profileID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let isPlaying: Bool
    let isVideo: Bool
    let artworkData: Data?
    let artworkStyle: ArtworkStyle
    let assetURL: URL?
    let queueIndex: Int?
    let queueCount: Int
    let isFavorite: Bool
    let canFavorite: Bool
    let shuffleEnabled: Bool
    let repeatEnabled: Bool

    init(
        track: Track,
        position: TimeInterval,
        playbackRate: Float,
        isPlaying: Bool,
        queue: [Track],
        isFavorite: Bool,
        canFavorite: Bool = true,
        shuffleEnabled: Bool,
        repeatEnabled: Bool,
        profileID: String,
        queueIndexOverride: Int? = nil,
        queueCountOverride: Int? = nil
    ) {
        let safeDuration = track.duration.isFinite ? max(0, track.duration) : 0
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeRate = playbackRate.isFinite && playbackRate > 0 ? Double(playbackRate) : 1
        let resolvedQueue = queue.contains(where: { $0.id == track.id }) ? queue : [track]

        trackID = track.id
        contentIdentifier = track.remoteIdentity.map {
            "\($0.origin)#profile=\($0.profileID)#song=\($0.songID)"
        } ?? track.id.uuidString.lowercased()
        self.profileID = track.syncProfileID ?? profileID
        title = Self.nonempty(track.title, fallback: "Unknown song")
        artist = Self.nonempty(track.artist, fallback: "Unknown artist")
        album = Self.nonempty(track.album, fallback: "Unknown Album")
        duration = safeDuration
        elapsedTime = safeDuration > 0 ? min(safePosition, safeDuration) : safePosition
        self.playbackRate = safeRate
        self.isPlaying = isPlaying
        isVideo = track.kind == .video
        artworkData = track.artworkData
        artworkStyle = track.artwork
        assetURL = track.fileURL
        queueIndex = queueIndexOverride ?? resolvedQueue.firstIndex(where: { $0.id == track.id })
        queueCount = queueCountOverride ?? resolvedQueue.count
        self.isFavorite = isFavorite
        self.canFavorite = canFavorite
        self.shuffleEnabled = shuffleEnabled
        self.repeatEnabled = repeatEnabled
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}

@MainActor
struct MacSystemPlaybackHandlers {
    var play: () -> Void = {}
    var pause: () -> Void = {}
    var stop: () -> Void = {}
    var next: () -> Void = {}
    var previous: () -> Void = {}
    var seek: (TimeInterval) -> Void = { _ in }
    var skip: (TimeInterval) -> Void = { _ in }
    var changeRate: (Float) -> Void = { _ in }
    var setShuffle: (Bool) -> Void = { _ in }
    var setRepeat: (Bool) -> Void = { _ in }
    var setFavorite: (Bool) -> Void = { _ in }
}

@MainActor
protocol MacSystemPlaybackControlling: AnyObject {
    var handlers: MacSystemPlaybackHandlers { get set }
    func publish(_ snapshot: MacNowPlayingSnapshot?)
    func invalidate()
}

@MainActor
final class MacSystemPlaybackController: NSObject, MacSystemPlaybackControlling {
    var handlers = MacSystemPlaybackHandlers()

    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private var isInvalidated = false
    private var currentSnapshot: MacNowPlayingSnapshot?
    private var currentArtworkIdentity: String?
    private var currentArtworkImage: NSImage?
    private var currentArtworkIsDecoded = false
    private var artworkLoadIdentity: String?
    private var artworkLoadTask: Task<Void, Never>?

    override init() {
        infoCenter = .default()
        commandCenter = .shared()
        super.init()
        registerCommands()
        clearNowPlaying()
    }

    func publish(_ snapshot: MacNowPlayingSnapshot?) {
        guard !isInvalidated else { return }
        guard let snapshot else {
            resetArtworkState()
            clearNowPlaying()
            return
        }

        currentSnapshot = snapshot
        let identity = Self.artworkIdentity(for: snapshot)
        if currentArtworkIdentity != identity {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadIdentity = nil
        }
        let image: NSImage
        if currentArtworkIdentity == identity, let currentArtworkImage {
            image = currentArtworkImage
        } else if let artworkData = snapshot.artworkData {
            let cacheKey = ArtworkCropping.cacheKey(
                ownerID: snapshot.trackID.uuidString,
                data: artworkData
            )
            if let cached = ArtworkCropping.cachedSquareImage(for: cacheKey) {
                image = cached
                currentArtworkIsDecoded = true
            } else {
                image = Self.fallbackArtworkImage(style: snapshot.artworkStyle)
                currentArtworkIsDecoded = false
            }
            currentArtworkIdentity = identity
            currentArtworkImage = image
        } else {
            image = Self.fallbackArtworkImage(style: snapshot.artworkStyle)
            currentArtworkIdentity = identity
            currentArtworkImage = image
            currentArtworkIsDecoded = true
        }

        publishInfo(snapshot, artwork: image)
        if snapshot.artworkData != nil, !currentArtworkIsDecoded {
            loadArtworkIfNeeded(for: snapshot, identity: identity)
        }
    }

    private func publishInfo(_ snapshot: MacNowPlayingSnapshot, artwork image: NSImage) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyMediaType: snapshot.isVideo
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: snapshot.contentIdentifier,
            MPNowPlayingInfoPropertyExternalUserProfileIdentifier: snapshot.profileID,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.queueCount,
        ]
        if let queueIndex = snapshot.queueIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        }
        if let assetURL = snapshot.assetURL {
            info[MPNowPlayingInfoPropertyAssetURL] = assetURL
        }
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
            boundsSize: image.size,
            requestHandler: { _ in image }
        )

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
        updateCommands(for: snapshot)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        resetArtworkState()
        registeredCommands.forEach { $0.removeTarget(self) }
        handlers = MacSystemPlaybackHandlers()
        clearNowPlaying()
    }

    private var registeredCommands: [MPRemoteCommand] {
        [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.stopCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackRateCommand,
            commandCenter.changeShuffleModeCommand,
            commandCenter.changeRepeatModeCommand,
            commandCenter.likeCommand,
        ]
    }

    private func registerCommands() {
        commandCenter.playCommand.addTarget(self, action: #selector(handlePlay(_:)))
        commandCenter.pauseCommand.addTarget(self, action: #selector(handlePause(_:)))
        commandCenter.stopCommand.addTarget(self, action: #selector(handleStop(_:)))
        commandCenter.togglePlayPauseCommand.addTarget(self, action: #selector(handleToggle(_:)))
        commandCenter.nextTrackCommand.addTarget(self, action: #selector(handleNext(_:)))
        commandCenter.previousTrackCommand.addTarget(self, action: #selector(handlePrevious(_:)))
        commandCenter.skipForwardCommand.addTarget(self, action: #selector(handleSkipForward(_:)))
        commandCenter.skipBackwardCommand.addTarget(self, action: #selector(handleSkipBackward(_:)))
        commandCenter.changePlaybackPositionCommand.addTarget(self, action: #selector(handlePosition(_:)))
        commandCenter.changePlaybackRateCommand.addTarget(self, action: #selector(handleRate(_:)))
        commandCenter.changeShuffleModeCommand.addTarget(self, action: #selector(handleShuffle(_:)))
        commandCenter.changeRepeatModeCommand.addTarget(self, action: #selector(handleRepeat(_:)))
        commandCenter.likeCommand.addTarget(self, action: #selector(handleFavorite(_:)))
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        commandCenter.likeCommand.localizedTitle = "Like"
        commandCenter.likeCommand.localizedShortTitle = "Like"
    }

    private func clearNowPlaying() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        registeredCommands.forEach { $0.isEnabled = false }
    }

    private func updateCommands(for snapshot: MacNowPlayingSnapshot) {
        commandCenter.playCommand.isEnabled = !snapshot.isPlaying
        commandCenter.pauseCommand.isEnabled = snapshot.isPlaying
        commandCenter.stopCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = snapshot.queueCount > 1
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = snapshot.duration > 0
        commandCenter.skipBackwardCommand.isEnabled = snapshot.duration > 0
        commandCenter.changePlaybackPositionCommand.isEnabled = snapshot.duration > 0
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.isEnabled = snapshot.queueCount > 1
        commandCenter.changeRepeatModeCommand.isEnabled = true
        commandCenter.likeCommand.isEnabled = snapshot.canFavorite
        commandCenter.likeCommand.isActive = snapshot.isFavorite
        commandCenter.changeShuffleModeCommand.currentShuffleType = snapshot.shuffleEnabled ? .items : .off
        commandCenter.changeRepeatModeCommand.currentRepeatType = snapshot.repeatEnabled ? .one : .off
    }

    private nonisolated func dispatch(_ action: @escaping @MainActor (MacSystemPlaybackHandlers) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self.handlers)
        }
    }

    @objc nonisolated private func handlePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { $0.play() }
        return .success
    }

    @objc nonisolated private func handlePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { $0.pause() }
        return .success
    }

    @objc nonisolated private func handleStop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { $0.stop() }
        return .success
    }

    @objc nonisolated private func handleToggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { handlers in
            if MPNowPlayingInfoCenter.default().playbackState == .playing {
                handlers.pause()
            } else {
                handlers.play()
            }
        }
        return .success
    }

    @objc nonisolated private func handleNext(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { $0.next() }
        return .success
    }

    @objc nonisolated private func handlePrevious(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        dispatch { $0.previous() }
        return .success
    }

    @objc nonisolated private func handleSkipForward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
        dispatch { $0.skip(interval) }
        return .success
    }

    @objc nonisolated private func handleSkipBackward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
        dispatch { $0.skip(-interval) }
        return .success
    }

    @objc nonisolated private func handlePosition(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
        let position = positionEvent.positionTime
        dispatch { $0.seek(position) }
        return .success
    }

    @objc nonisolated private func handleRate(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
        let rate = rateEvent.playbackRate
        dispatch { $0.changeRate(rate) }
        return .success
    }

    @objc nonisolated private func handleShuffle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let shuffleEvent = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
        let enabled = shuffleEvent.shuffleType != .off
        dispatch { $0.setShuffle(enabled) }
        return .success
    }

    @objc nonisolated private func handleRepeat(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let repeatEvent = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
        let enabled = repeatEvent.repeatType != .off
        dispatch { $0.setRepeat(enabled) }
        return .success
    }

    @objc nonisolated private func handleFavorite(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let shouldFavorite = !((event as? MPFeedbackCommandEvent)?.isNegative ?? false)
        dispatch { $0.setFavorite(shouldFavorite) }
        return .success
    }

    private func loadArtworkIfNeeded(for snapshot: MacNowPlayingSnapshot, identity: String) {
        guard artworkLoadIdentity != identity, let data = snapshot.artworkData else { return }
        artworkLoadTask?.cancel()
        artworkLoadIdentity = identity
        let cacheKey = ArtworkCropping.cacheKey(ownerID: snapshot.trackID.uuidString, data: data)
        artworkLoadTask = Task { @MainActor [weak self] in
            let decodeTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled,
                      let image = ArtworkCropping.squareImage(from: data, cacheKey: cacheKey),
                      image.size.width > 0,
                      image.size.height > 0 else {
                    return nil as SendableNowPlayingArtwork?
                }
                return SendableNowPlayingArtwork(image: image)
            }
            let decoded = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  artworkLoadIdentity == identity else { return }
            artworkLoadTask = nil
            artworkLoadIdentity = nil
            guard let latestSnapshot = currentSnapshot,
                  Self.artworkIdentity(for: latestSnapshot) == identity else { return }
            currentArtworkIsDecoded = true
            guard let decoded else { return }
            currentArtworkIdentity = identity
            currentArtworkImage = decoded.image
            publishInfo(latestSnapshot, artwork: decoded.image)
        }
    }

    private func resetArtworkState() {
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        artworkLoadIdentity = nil
        currentSnapshot = nil
        currentArtworkIdentity = nil
        currentArtworkImage = nil
        currentArtworkIsDecoded = false
    }

    private static func artworkIdentity(for snapshot: MacNowPlayingSnapshot) -> String {
        guard let data = snapshot.artworkData else {
            return "fallback:\(snapshot.artworkStyle.rawValue)"
        }
        return "data:\(ArtworkCropping.cacheKey(ownerID: snapshot.trackID.uuidString, data: data))"
    }

    private static func fallbackArtworkImage(style: ArtworkStyle) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let color = fallbackColor(for: style)
        return NSImage(size: size, flipped: false) { bounds in
            color.setFill()
            NSBezierPath(rect: bounds).fill()
            return true
        }
    }

    private static func fallbackColor(for style: ArtworkStyle) -> NSColor {
        let hex: UInt32
        switch style {
        case .liked, .midnight: hex = 0x3349C9
        case .electric: hex = 0x263857
        case .echoes: hex = 0x5B281E
        case .golden: hex = 0xF49C44
        case .weightless: hex = 0x151A29
        case .falling: hex = 0x42435F
        case .lateNight: hex = 0x26345A
        case .softFocus: hex = 0x715A6D
        case .onRepeat: hex = 0x13233A
        }
        return NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
