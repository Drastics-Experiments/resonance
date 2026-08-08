import AppKit
import Combine
import Foundation
import Network

enum MacDesktopPreferenceKeys {
    static let runInBackground = "LikedSongsFocus.desktop.runInBackground.v1"
    static let discordRichPresence = "LikedSongsFocus.desktop.discordRichPresence.v1"
    static let keybinds = "LikedSongsFocus.desktop.keybinds.v1"
}

enum MacShortcutAction: String, CaseIterable, Identifiable, Codable {
    case togglePlayback
    case previousTrack
    case nextTrack
    case volumeDown
    case volumeUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePlayback: "Play / pause"
        case .previousTrack: "Previous track"
        case .nextTrack: "Next track"
        case .volumeDown: "Volume down"
        case .volumeUp: "Volume up"
        }
    }

    var detail: String {
        switch self {
        case .togglePlayback: "Toggle the current song."
        case .previousTrack: "Return to the previous song."
        case .nextTrack: "Advance to the next song."
        case .volumeDown: "Lower volume by five percent."
        case .volumeUp: "Raise volume by five percent."
        }
    }
}

struct DiscordPresenceStatus: Equatable {
    enum State: String {
        case disabled
        case configurationRequired
        case connecting
        case connected
        case discordNotRunning
        case disconnected
        case error
    }

    let state: State
    let message: String
    let applicationConfigured: Bool
}

struct DiscordPresencePayload {
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let artworkURL: String?

    func rpcActivity(now: TimeInterval = Date().timeIntervalSince1970) -> [String: Any]? {
        guard playing else { return nil }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: [String: Any] = [
            "type": 2,
            "details": String(title.prefix(128)),
            "state": String((trimmedArtist.isEmpty
                ? (trimmedAlbum.isEmpty ? "Listening in Resonance" : trimmedAlbum)
                : "by \(trimmedArtist)").prefix(128)),
            "instance": false,
        ]
        if duration > 0, position < duration {
            let start = max(1, Int(now - max(position, 0)))
            value["timestamps"] = ["start": start, "end": max(start + 1, start + Int(duration))]
        }
        if let artworkURL = DiscordArtworkAsset.externalURL(from: artworkURL) {
            value["assets"] = [
                "large_image": artworkURL,
            ]
        }
        return value
    }
}

enum DiscordArtworkAsset {
    static func externalURL(from value: String?) -> String? {
        var url = LocalImportURL.spotifyArtwork(value)
            ?? LocalImportURL.soundCloudArtwork(value)
        if url == nil, let youtubeURL = LocalImportURL.youtubeArtwork(value) {
            var components = URLComponents(url: youtubeURL, resolvingAgainstBaseURL: false)
            if components?.host?.lowercased() == "i.ytimg.com" {
                components?.host = "img.youtube.com"
            }
            url = components?.url
        }
        if url == nil, let value, let components = URLComponents(string: value),
           components.scheme?.lowercased() == "https",
           components.user == nil,
           components.password == nil,
           components.host?.lowercased() == "img.youtube.com" {
            url = components.url
        }
        guard let result = url?.absoluteString, !result.isEmpty, result.count <= 300 else { return nil }
        return result
    }

    static func externalURL(for track: Track) -> String? {
        if let artworkURL = externalURL(from: track.artworkURL) { return artworkURL }
        guard let sourceURL = track.sourceURL,
              let videoID = try? LocalImportURL.youtubeVideoID(sourceURL) else { return nil }
        return externalURL(from: "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg")
    }
}

enum DiscordIPCFrame {
    static func encode(opcode: Int32, payload: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var encoded = Data(capacity: body.count + 8)
        var littleOpcode = opcode.littleEndian
        var littleLength = Int32(body.count).littleEndian
        Swift.withUnsafeBytes(of: &littleOpcode) { encoded.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &littleLength) { encoded.append(contentsOf: $0) }
        encoded.append(body)
        return encoded
    }

    static func decodeHeader(_ data: Data) -> (opcode: Int32, length: Int)? {
        guard data.count >= 8 else { return nil }
        let opcode = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        let length = data.dropFirst(4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        guard length >= 0, length <= 1_048_576 else { return nil }
        return (opcode, Int(length))
    }
}

final class MacDiscordRPCClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mov.unblocked.resonance.discord-rpc")
    private let onStatus: @Sendable (DiscordPresenceStatus) -> Void
    private var connection: NWConnection?
    private var reconnectWorkItem: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var enabled = false
    private var applicationID = ""
    private var activity: DiscordPresencePayload?
    private var ready = false
    private var generation = 0
    private var status = DiscordPresenceStatus(
        state: .disabled,
        message: "Rich Presence is off.",
        applicationConfigured: false
    )

    init(onStatus: @escaping @Sendable (DiscordPresenceStatus) -> Void) {
        self.onStatus = onStatus
    }

    func configure(enabled: Bool, applicationID: String) {
        queue.async { [self] in
            let validatedID = Self.validApplicationID(applicationID) ?? ""
            let changed = self.enabled != enabled || self.applicationID != validatedID
            self.enabled = enabled
            self.applicationID = validatedID
            if !enabled {
                disconnect(clear: true)
                publish(.disabled, "Rich Presence is off.")
            } else if validatedID.isEmpty {
                disconnect(clear: true)
                publish(.configurationRequired, "Rich Presence is unavailable in this development build.")
            } else if changed || connection == nil {
                connect()
            }
        }
    }

    func update(_ payload: DiscordPresencePayload?) {
        queue.async { [self] in
            activity = payload
            if ready { sendActivity() }
        }
    }

    func stop() {
        queue.sync {
            enabled = false
            disconnect(clear: true)
        }
    }

    static func validApplicationID(_ value: String?) -> String? {
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (15...22).contains(candidate.count), candidate.allSatisfy(\.isNumber) else { return nil }
        return candidate
    }

    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var prefixes: [String] = []
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let value = environment[key], !value.isEmpty, !prefixes.contains(value) { prefixes.append(value) }
        }
        if !prefixes.contains("/tmp") { prefixes.append("/tmp") }
        return prefixes.flatMap { prefix in
            (0..<10).map { URL(fileURLWithPath: prefix).appendingPathComponent("discord-ipc-\($0)").path }
        }
    }

    private func publish(_ state: DiscordPresenceStatus.State, _ message: String) {
        let next = DiscordPresenceStatus(
            state: state,
            message: message,
            applicationConfigured: !applicationID.isEmpty
        )
        guard next != status else { return }
        status = next
        DispatchQueue.main.async { [onStatus] in onStatus(next) }
    }

    private func connect() {
        disconnect(clear: false)
        guard enabled, !applicationID.isEmpty else { return }
        generation += 1
        let connectionGeneration = generation
        publish(.connecting, "Connecting to the Discord desktop app…")
        connectCandidate(at: 0, paths: Self.socketPaths(), generation: connectionGeneration)
    }

    private func connectCandidate(at index: Int, paths: [String], generation connectionGeneration: Int) {
        guard enabled, connectionGeneration == generation else { return }
        guard index < paths.count else {
            publish(.discordNotRunning, "Discord desktop is not running. Resonance will retry automatically.")
            scheduleReconnect()
            return
        }

        let candidate = NWConnection(to: .unix(path: paths[index]), using: .tcp)
        var reachedReady = false
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate else { return }
            self.queue.async {
                guard connectionGeneration == self.generation else {
                    candidate.cancel()
                    return
                }
                switch state {
                case .ready:
                    reachedReady = true
                    self.connection = candidate
                    self.receiveBuffer.removeAll(keepingCapacity: true)
                    self.ready = false
                    self.sendHandshake()
                    self.receiveNext(on: candidate, generation: connectionGeneration)
                case .failed:
                    candidate.cancel()
                    if reachedReady {
                        self.connection = nil
                        self.ready = false
                        self.publish(.disconnected, "Discord disconnected. Resonance will retry automatically.")
                        self.scheduleReconnect()
                    } else {
                        self.connectCandidate(at: index + 1, paths: paths, generation: connectionGeneration)
                    }
                case .cancelled:
                    if self.connection === candidate { self.connection = nil }
                default:
                    break
                }
            }
        }
        candidate.start(queue: queue)
    }

    private func receiveNext(on candidate: NWConnection, generation connectionGeneration: Int) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 1_048_584) { [weak self, weak candidate] data, _, complete, error in
            guard let self, let candidate else { return }
            self.queue.async {
                guard connectionGeneration == self.generation, self.connection === candidate else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.consumeFrames()
                }
                if error != nil || complete {
                    candidate.cancel()
                    self.connection = nil
                    self.ready = false
                    if self.enabled {
                        self.publish(.disconnected, "Discord disconnected. Resonance will retry automatically.")
                        self.scheduleReconnect()
                    }
                } else {
                    self.receiveNext(on: candidate, generation: connectionGeneration)
                }
            }
        }
    }

    private func consumeFrames() {
        while let header = DiscordIPCFrame.decodeHeader(receiveBuffer), receiveBuffer.count >= header.length + 8 {
            let body = receiveBuffer.subdata(in: 8..<(header.length + 8))
            receiveBuffer.removeSubrange(0..<(header.length + 8))
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            switch header.opcode {
            case 1 where payload?["evt"] as? String == "READY":
                ready = true
                publish(.connected, "Connected to Discord desktop.")
                sendActivity()
            case 1 where payload?["evt"] as? String == "ERROR":
                let data = payload?["data"] as? [String: Any]
                publish(.error, data?["message"] as? String ?? "Discord rejected the Rich Presence update.")
            case 2:
                publish(.error, payload?["message"] as? String ?? "Discord closed the Rich Presence connection.")
                connection?.cancel()
            case 3:
                send(opcode: 4, payload: payload ?? [:])
            default:
                break
            }
        }
    }

    private func sendHandshake() {
        send(opcode: 0, payload: ["v": 1, "client_id": applicationID])
    }

    private func sendActivity() {
        guard ready else { return }
        let activityValue: Any
        if let value = activity?.rpcActivity() {
            activityValue = value
        } else {
            activityValue = NSNull()
        }
        send(opcode: 1, payload: [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": activityValue],
            "nonce": UUID().uuidString,
        ])
    }

    private func send(opcode: Int32, payload: Any, completion: NWConnection.SendCompletion = .contentProcessed { _ in }) {
        guard let connection, let frame = DiscordIPCFrame.encode(opcode: opcode, payload: payload) else { return }
        connection.send(content: frame, completion: completion)
    }

    private func disconnect(clear: Bool) {
        generation += 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let oldConnection = connection
        connection = nil
        let wasReady = ready
        ready = false
        receiveBuffer.removeAll(keepingCapacity: false)
        guard let oldConnection else { return }
        if clear, wasReady, let frame = DiscordIPCFrame.encode(opcode: 1, payload: [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": NSNull()],
            "nonce": UUID().uuidString,
        ]) {
            oldConnection.send(content: frame, completion: .contentProcessed { _ in oldConnection.cancel() })
        } else {
            oldConnection.cancel()
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }
}

@MainActor
final class MacDesktopPreferences: ObservableObject {
    static let bundledDiscordApplicationID = "1535574125395841154"

    static let defaultKeybinds: [MacShortcutAction: String] = [
        .togglePlayback: "Space",
        .previousTrack: "⌥←",
        .nextTrack: "⌥→",
        .volumeDown: "⌥↓",
        .volumeUp: "⌥↑",
    ]

    @Published var runInBackground: Bool {
        didSet { defaults.set(runInBackground, forKey: MacDesktopPreferenceKeys.runInBackground) }
    }
    @Published var discordRichPresence: Bool {
        didSet {
            defaults.set(discordRichPresence, forKey: MacDesktopPreferenceKeys.discordRichPresence)
            reconfigureDiscord()
        }
    }
    @Published private(set) var keybinds: [MacShortcutAction: String]
    @Published private(set) var discordStatus = DiscordPresenceStatus(
        state: .disabled,
        message: "Rich Presence is off.",
        applicationConfigured: false
    )

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private weak var model: PlayerModel?
    private var shortcutMonitor: Any?
    private lazy var discordRPC = MacDiscordRPCClient { [weak self] status in
        Task { @MainActor [weak self] in self?.discordStatus = status }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        runInBackground = defaults.bool(forKey: MacDesktopPreferenceKeys.runInBackground)
        discordRichPresence = defaults.bool(forKey: MacDesktopPreferenceKeys.discordRichPresence)
        if let data = defaults.data(forKey: MacDesktopPreferenceKeys.keybinds),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            keybinds = Self.defaultKeybinds.reduce(into: [:]) { result, entry in
                result[entry.key] = stored[entry.key.rawValue] ?? entry.value
            }
        } else {
            keybinds = Self.defaultKeybinds
        }
        reconfigureDiscord()
    }

    func bind(to model: PlayerModel) {
        guard self.model !== model else { return }
        self.model = model
        cancellables.removeAll()
        Publishers.Merge4(
            model.$currentTrackID.map { _ in () }.eraseToAnyPublisher(),
            model.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            model.$playbackDuration.map { _ in () }.eraseToAnyPublisher(),
            model.playbackPositionState.$position.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        .sink { [weak self, weak model] in
            guard let self, let model else { return }
            self.publishDiscordActivity(from: model)
        }
        .store(in: &cancellables)
        installShortcutMonitor()
        publishDiscordActivity(from: model)
    }

    func setKeybind(_ value: String, for action: MacShortcutAction) {
        guard !value.isEmpty else { return }
        for duplicate in keybinds.keys where duplicate != action && keybinds[duplicate] == value {
            keybinds[duplicate] = Self.defaultKeybinds[duplicate]
        }
        keybinds[action] = value
        persistKeybinds()
    }

    func resetKeybinds() {
        keybinds = Self.defaultKeybinds
        persistKeybinds()
    }

    func stop() {
        discordRPC.stop()
    }

    static func shortcutString(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var prefix = ""
        if flags.contains(.command) { prefix += "⌘" }
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        let key: String
        switch event.keyCode {
        case 49: key = "Space"
        case 123: key = "←"
        case 124: key = "→"
        case 125: key = "↓"
        case 126: key = "↑"
        case 36: key = "Return"
        case 51: key = "Delete"
        case 53: key = "Escape"
        default:
            guard let characters = event.charactersIgnoringModifiers?.uppercased(), characters.count == 1 else { return nil }
            key = characters
        }
        return prefix + key
    }

    static func configuredDiscordApplicationID(
        environment: [String: String],
        bundleValue: String?
    ) -> String {
        if let environment = MacDiscordRPCClient.validApplicationID(environment["RESONANCE_DISCORD_CLIENT_ID"]) {
            return environment
        }
        if let bundle = MacDiscordRPCClient.validApplicationID(bundleValue) {
            return bundle
        }
        return bundledDiscordApplicationID
    }

    private var effectiveDiscordApplicationID: String {
        Self.configuredDiscordApplicationID(
            environment: ProcessInfo.processInfo.environment,
            bundleValue: Bundle.main.object(forInfoDictionaryKey: "ResonanceDiscordApplicationID") as? String
        )
    }

    private func reconfigureDiscord() {
        discordRPC.configure(enabled: discordRichPresence, applicationID: effectiveDiscordApplicationID)
    }

    private func publishDiscordActivity(from model: PlayerModel) {
        guard discordRichPresence, model.isPlaying, let track = model.currentTrack else {
            discordRPC.update(nil)
            return
        }
        discordRPC.update(DiscordPresencePayload(
            title: track.title,
            artist: track.artist,
            album: track.album,
            playing: model.isPlaying,
            position: model.position,
            duration: model.playbackDuration > 0 ? model.playbackDuration : track.duration,
            artworkURL: DiscordArtworkAsset.externalURL(for: track)
        ))
    }

    private func persistKeybinds() {
        let stored = Dictionary(uniqueKeysWithValues: keybinds.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: MacDesktopPreferenceKeys.keybinds)
        }
    }

    private func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, !event.isARepeat else { return event }
            guard NSApp.keyWindow?.attachedSheet == nil else { return event }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField { return event }
            guard let shortcut = Self.shortcutString(for: event),
                  let action = self.keybinds.first(where: { $0.value == shortcut })?.key else { return event }
            switch action {
            case .togglePlayback: model.togglePlay()
            case .previousTrack: model.previous()
            case .nextTrack: model.next()
            case .volumeDown: model.volume = max(0, model.volume - 0.05)
            case .volumeUp: model.volume = min(1, model.volume + 0.05)
            }
            return nil
        }
    }
}

@MainActor
final class MacShortcutRecorder: ObservableObject {
    @Published private(set) var recordingAction: MacShortcutAction?
    private var monitor: Any?

    func start(_ action: MacShortcutAction, onCapture: @escaping (String) -> Void) {
        cancel()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            guard let shortcut = MacDesktopPreferences.shortcutString(for: event) else { return nil }
            onCapture(shortcut)
            self.cancel()
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingAction = nil
    }
}
