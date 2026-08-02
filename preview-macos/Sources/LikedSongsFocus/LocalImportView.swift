import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class MacLocalImportViewModel: ObservableObject {
    @Published var source = ""
    @Published private(set) var stage: LocalImportStage = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var resolution: LocalImportResolution?
    @Published var selectedVideoID: String?
    @Published var selectedReleaseInfoHash: String?
    @Published var mediaMode: LocalImportMediaMode = .audio
    @Published var syncAfterImport = true
    @Published private(set) var error: LocalImportError?
    @Published private(set) var completedTrack: Track?
    @Published private(set) var releaseActionMessage: String?
    @Published private(set) var previewingVideoID: String?
    @Published private(set) var loadingPreviewVideoID: String?
    @Published private(set) var previewErrorMessage: String?

    private let model: PlayerModel
    private let service: LocalDeviceImportService
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewPlayer: AVPlayer?
    private var previewEndObserver: NSObjectProtocol?

    init(model: PlayerModel, service: LocalDeviceImportService = LocalDeviceImportService()) {
        self.model = model
        self.service = service
    }

    var isRunning: Bool {
        return switch stage {
        case .resolvingMetadata, .searchingCandidates, .inspectingSource, .downloading, .processing, .savingLocal, .syncing:
            true
        default:
            false
        }
    }

    var selectedCandidate: LocalImportAudioSourceMatch? {
        guard let selectedVideoID else { return nil }
        return resolution?.candidates.first { $0.videoID == selectedVideoID }
    }

    var selectedRelease: LocalImportDebridRelease? {
        guard let selectedReleaseInfoHash else { return nil }
        return resolution?.releases.first { $0.infoHash == selectedReleaseInfoHash }
    }

    var canSync: Bool {
        !model.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeProfileName: String {
        model.activeSyncProfileName
    }

    var resolveButtonTitle: String {
        mediaMode == .video ? "Find Video" : "Find Audio"
    }

    var showsTransferPopup: Bool {
        stage == .downloading || stage == .syncing
    }

    var showsStageCard: Bool {
        switch stage {
        case .idle:
            false
        case .awaitingSelection:
            selectedRelease != nil
        default:
            true
        }
    }

    var transferProgress: Double? {
        guard stage == .downloading, totalBytes > 0 else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }

    var transferTitle: String {
        stage == .syncing ? "Uploading" : "Downloading"
    }

    var transferDetail: String {
        let trackTitle = completedTrack?.title
            ?? resolution?.track.title
            ?? selectedCandidate?.title
            ?? "Import from Link"
        guard stage == .downloading, totalBytes > 0 else { return trackTitle }
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(trackTitle) • \(completed) of \(total)"
    }

    func normalizeMediaModeForSource() {
        if LocalImportURL.isSpotify(source), mediaMode == .video {
            mediaMode = .audio
        }
    }

    func resolve() {
        guard !isRunning else { return }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            error = .init(stage: .resolvingMetadata, code: "MISSING_SOURCE", message: "Paste a Spotify track or YouTube video URL first.")
            stage = .failed
            return
        }
        stopPreview()
        normalizeMediaModeForSource()
        let requestedMode = mediaMode
        task?.cancel()
        error = nil
        previewErrorMessage = nil
        resolution = nil
        selectedVideoID = nil
        selectedReleaseInfoHash = nil
        completedTrack = nil
        releaseActionMessage = nil
        stage = .resolvingMetadata
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.resolve(source: value, mediaMode: requestedMode) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                resolution = result
                selectedVideoID = result.candidates.first?.videoID
                selectedReleaseInfoHash = result.candidates.isEmpty ? result.releases.first?.infoHash : nil
                stage = .awaitingSelection
            } catch is CancellationError {
                stage = .cancelled
            } catch let failure as LocalImportError {
                error = failure
                stage = .failed
            } catch {
                self.error = .init(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
            task = nil
        }
    }

    func importSelected() {
        guard !isRunning, let resolution, let candidate = selectedCandidate else { return }
        stopPreview()
        task?.cancel()
        error = nil
        completedBytes = 0
        totalBytes = 0
        stage = .inspectingSource
        let metadata = LocalImportMetadata(
            title: resolution.track.title,
            artist: resolution.track.artist,
            album: resolution.track.album,
            artworkURL: resolution.track.artworkURL ?? candidate.thumbnailURL,
            sourceURL: resolution.track.sourceURL
        )
        let existing = model.tracks
        let requestedMode = mediaMode
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await service.importCandidate(
                    candidate,
                    metadata: metadata,
                    existingTracks: existing,
                    mediaMode: requestedMode
                ) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                let track: Track
                switch outcome {
                case .created(let imported):
                    track = model.insertLocalImportedAudio(imported)
                case .duplicate(let id):
                    guard let duplicate = model.tracks.first(where: { $0.id == id }) else {
                        throw LocalImportError(stage: .savingLocal, code: "DUPLICATE_CHANGED", message: "The matching local song changed while the import was running.")
                    }
                    track = duplicate
                }
                completedTrack = track
                stage = .localComplete

                if syncAfterImport {
                    stage = .syncing
                    do {
                        try await model.uploadLocalImportToActiveProfile(track)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.error = .init(
                            stage: .syncing,
                            code: "OPTIONAL_SYNC_FAILED",
                            message: "Saved locally, but the optional upload failed: \(error.localizedDescription)"
                        )
                        stage = .failed
                        task = nil
                        return
                    }
                }
                stage = .complete
            } catch is CancellationError {
                stage = .cancelled
            } catch let failure as LocalImportError {
                error = failure
                stage = .failed
            } catch {
                self.error = .init(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
            task = nil
        }
    }

    func selectCandidate(_ candidate: LocalImportAudioSourceMatch) {
        if previewingVideoID != candidate.videoID {
            stopPreview()
        }
        selectedVideoID = candidate.videoID
        selectedReleaseInfoHash = nil
        releaseActionMessage = nil
        previewErrorMessage = nil
    }

    func selectRelease(_ release: LocalImportDebridRelease) {
        stopPreview()
        selectedReleaseInfoHash = release.infoHash
        selectedVideoID = nil
        mediaMode = .audio
        syncAfterImport = false
        releaseActionMessage = nil
    }

    func copySelectedReleaseMagnet() {
        guard let selectedRelease else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedRelease.magnetLink, forType: .string)
        releaseActionMessage = "Magnet link copied. Download the exact audio file, then add it with Import Files."
    }

    func openSelectedRelease() {
        guard let selectedRelease, let url = URL(string: selectedRelease.magnetLink) else { return }
        if NSWorkspace.shared.open(url) {
            releaseActionMessage = "Opened in your torrent app. Import the exact audio file after it finishes."
        } else {
            releaseActionMessage = "No app accepted the magnet link. Copy it instead and open it in your torrent client."
        }
    }

    func cancel() {
        stopPreview()
        task?.cancel()
        task = nil
        stage = .cancelled
    }

    func togglePreview(_ candidate: LocalImportAudioSourceMatch) {
        if previewingVideoID == candidate.videoID {
            stopPreview()
            return
        }

        stopPreview()
        selectedVideoID = candidate.videoID
        selectedReleaseInfoHash = nil
        releaseActionMessage = nil
        previewErrorMessage = nil
        loadingPreviewVideoID = candidate.videoID
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await service.previewStream(for: candidate)
                try Task.checkCancellation()
                let asset = AVURLAsset(
                    url: stream.url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": stream.httpHeaders]
                )
                guard try await asset.load(.isPlayable) else {
                    throw LocalImportError(
                        stage: .inspectingSource,
                        code: "PREVIEW_NOT_PLAYABLE",
                        message: "This option did not provide playable preview audio."
                    )
                }
                try Task.checkCancellation()
                if model.isPlaying {
                    model.togglePlay()
                }
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                previewPlayer = player
                loadingPreviewVideoID = nil
                previewingVideoID = candidate.videoID
                previewEndObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.stopPreview() }
                }
                player.play()
                try await Task.sleep(for: .seconds(30))
                if previewingVideoID == candidate.videoID {
                    stopPreview()
                }
            } catch is CancellationError {
                if loadingPreviewVideoID == candidate.videoID {
                    loadingPreviewVideoID = nil
                }
            } catch {
                guard loadingPreviewVideoID == candidate.videoID
                        || previewingVideoID == candidate.videoID else { return }
                stopPreview()
                previewErrorMessage = "Preview unavailable: \(error.localizedDescription)"
            }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer?.pause()
        previewPlayer = nil
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
            self.previewEndObserver = nil
        }
        previewingVideoID = nil
        loadingPreviewVideoID = nil
    }

    func reset() {
        cancel()
        source = ""
        stage = .idle
        completedBytes = 0
        totalBytes = 0
        resolution = nil
        selectedVideoID = nil
        selectedReleaseInfoHash = nil
        mediaMode = .audio
        syncAfterImport = true
        error = nil
        completedTrack = nil
        releaseActionMessage = nil
        previewErrorMessage = nil
    }

    private func apply(_ progress: LocalImportProgress) {
        stage = progress.stage
        completedBytes = progress.completed
        totalBytes = progress.total
    }
}

enum LocalImportCandidatePreviewPolicy {
    static func showsPreviewButtons(candidateCount: Int, mediaMode: LocalImportMediaMode) -> Bool {
        candidateCount > 1 && mediaMode == .audio
    }
}

struct MacLocalImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MacLocalImportViewModel
    @FocusState private var sourceFocused: Bool

    init(model: PlayerModel) {
        _viewModel = StateObject(wrappedValue: MacLocalImportViewModel(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(Color.appLine)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceField
                    if viewModel.showsStageCard {
                        stageCard
                    }

                    if let resolution = viewModel.resolution {
                        resolvedTrack(resolution.track)
                        if !resolution.candidates.isEmpty {
                            candidateList(resolution.candidates)
                        }
                        if !resolution.releases.isEmpty {
                            releaseList(resolution.releases)
                        }
                        if let message = viewModel.releaseActionMessage {
                            releaseActionStatus(message)
                        }
                    }

                    if let error = viewModel.error {
                        errorCard(error)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Color.appLine)
            footer
        }
        .frame(width: 680, height: 650)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if viewModel.showsTransferPopup {
                TransferProgressOverlay(
                    title: viewModel.transferTitle,
                    detail: viewModel.transferDetail,
                    status: viewModel.stage == .syncing
                        ? "Uploading to \(viewModel.activeProfileName)"
                        : "Downloading to this Mac",
                    progress: viewModel.transferProgress,
                    symbol: viewModel.stage == .syncing ? "arrow.up.to.line" : "arrow.down.to.line",
                    color: viewModel.stage == .syncing ? Color.appAccent : Color.appViolet,
                    cancel: viewModel.cancel
                )
                .padding(.bottom, 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showsTransferPopup)
        .onAppear { sourceFocused = true }
        .onDisappear { viewModel.cancel() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Import from Link")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Spacer()

            HStack(spacing: 6) {
                Picker("Download format", selection: $viewModel.mediaMode) {
                    ForEach(LocalImportMediaMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .disabled(viewModel.isRunning)
                .onChange(of: viewModel.mediaMode) { _, _ in
                    viewModel.normalizeMediaModeForSource()
                }

                Button {
                    viewModel.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close link import")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
        .background(Color.appSurfaceRaised.opacity(0.82))
    }

    private var sourceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCE URL")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color.appMuted)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(Color.appMuted)
                TextField("https://open.spotify.com/track/… or https://youtu.be/…", text: $viewModel.source)
                    .textFieldStyle(.plain)
                    .focused($sourceFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        viewModel.resolve()
                    }
                    .disabled(viewModel.isRunning)
                    .onChange(of: viewModel.source) { _, _ in
                        viewModel.normalizeMediaModeForSource()
                    }

                Button(action: viewModel.resolve) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 22, height: 18)
                }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .tint(Color.appViolet)
                    .controlSize(.regular)
                    .disabled(viewModel.isRunning || viewModel.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(viewModel.resolveButtonTitle)
                    .accessibilityLabel(viewModel.resolveButtonTitle)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.appLine) }

        }
    }

    private var stageCard: some View {
        let copy = stageCopy(viewModel.stage)
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(copy.color.opacity(0.13))
                if viewModel.isRunning {
                    ProgressView().controlSize(.small).tint(copy.color)
                } else {
                    Image(systemName: copy.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(copy.color)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(copy.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(2)

            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.appLine) }
    }

    private func resolvedTrack(_ track: LocalImportSpotifyTrack) -> some View {
        HStack(spacing: 13) {
            resolvedArtwork(track)

            VStack(alignment: .leading, spacing: 5) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                if let duration = track.durationSeconds {
                    Text(Track.timeText(TimeInterval(duration)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                }
            }
            Spacer()
        }
        .padding(13)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func resolvedArtwork(_ track: LocalImportSpotifyTrack) -> some View {
        let artworkURL = LocalImportURL.youtubeArtwork(track.artworkURL)
            ?? LocalImportURL.spotifyArtwork(track.artworkURL)
        return Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        resolvedArtworkFallback
                            .overlay {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(Color.white.opacity(0.65))
                            }
                    case .failure:
                        resolvedArtworkFallback
                    @unknown default:
                        resolvedArtworkFallback
                    }
                }
            } else {
                resolvedArtworkFallback
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
        .accessibilityLabel("\(track.title) artwork")
    }

    private var resolvedArtworkFallback: some View {
        ZStack {
            LinearGradient(
                colors: [Color.appViolet.opacity(0.28), Color.appAccent.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: viewModel.mediaMode == .video ? "film" : "music.note")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.appViolet)
        }
    }

    private func candidateList(_ candidates: [LocalImportAudioSourceMatch]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(viewModel.mediaMode == .video ? "DIRECT YOUTUBE VIDEO" : "DIRECT AUDIO MATCHES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color.appMuted)

            ForEach(candidates) { candidate in
                HStack(spacing: 10) {
                    Button {
                        viewModel.selectCandidate(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: viewModel.selectedCandidate?.videoID == candidate.videoID ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(viewModel.selectedCandidate?.videoID == candidate.videoID ? Color.appViolet : Color.appMuted)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.appInk)
                                    .lineLimit(1)
                                Text([candidate.artist ?? "Unknown uploader", candidate.durationSeconds.map { Track.timeText(TimeInterval($0)) }, candidate.sourceProvider == .youtubeMusic ? "YouTube Music" : "YouTube"].compactMap { $0 }.joined(separator: " • "))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appMuted)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Text(candidate.confidence.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.appViolet)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Color.appViolet.opacity(0.12), in: Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                        candidateCount: candidates.count,
                        mediaMode: viewModel.mediaMode
                    ) {
                        Button {
                            viewModel.togglePreview(candidate)
                        } label: {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.055))
                                if viewModel.loadingPreviewVideoID == candidate.videoID {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(Color.appViolet)
                                } else {
                                    Image(systemName: viewModel.previewingVideoID == candidate.videoID ? "pause.fill" : "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(viewModel.previewingVideoID == candidate.videoID ? Color.white : Color.appViolet)
                                        .offset(x: viewModel.previewingVideoID == candidate.videoID ? 0 : 1)
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(candidate.title)")
                        .accessibilityLabel(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(candidate.title)")
                    }
                }
                .padding(12)
                .background(
                    viewModel.selectedCandidate?.videoID == candidate.videoID ? Color.appViolet.opacity(0.08) : Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(viewModel.selectedCandidate?.videoID == candidate.videoID ? Color.appViolet.opacity(0.45) : Color.appLine)
                }
                .disabled(viewModel.isRunning)
            }

            if let previewErrorMessage = viewModel.previewErrorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appAccent)
                    Text(previewErrorMessage)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func releaseList(_ releases: [LocalImportDebridRelease]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("OTHER RELEASE SOURCES")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Text("Debrid Vault")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appViolet)
            }

            Text("These are release torrents, not verified single-track files. Open one externally, choose the exact audio file, then use Import Files.")
                .font(.system(size: 9))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(releases.prefix(8))) { release in
                Button {
                    viewModel.selectRelease(release)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.selectedRelease?.infoHash == release.infoHash ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(viewModel.selectedRelease?.infoHash == release.infoHash ? Color.appViolet : Color.appMuted)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(release.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appInk)
                                .lineLimit(1)
                            Text(releaseDetails(release))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                    }
                    .padding(12)
                    .background(
                        viewModel.selectedRelease?.infoHash == release.infoHash ? Color.appViolet.opacity(0.08) : Color.white.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(viewModel.selectedRelease?.infoHash == release.infoHash ? Color.appViolet.opacity(0.45) : Color.appLine)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunning)
            }
        }
    }

    private func releaseDetails(_ release: LocalImportDebridRelease) -> String {
        let parts: [String?] = [
            release.quality,
            release.seeders.map { "\($0) seeders" },
            release.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
            release.indexer,
        ]
        return parts.compactMap { $0 }.joined(separator: " • ")
    }

    private func releaseActionStatus(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.appViolet)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(Color.appMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.appViolet.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.appViolet.opacity(0.2)) }
    }

    private var syncOption: some View {
        Toggle("Upload to server", isOn: $viewModel.syncAfterImport)
            .font(.system(size: 12, weight: .semibold))
            .toggleStyle(.switch)
            .tint(Color.appViolet)
            .disabled(!viewModel.canSync || viewModel.isRunning)
            .fixedSize()
            .help(viewModel.canSync
                ? "Upload a copy after saving it on this Mac"
                : "Add server credentials in Settings to enable upload")
    }

    private func errorCard(_ error: LocalImportError) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.stage == .syncing && viewModel.completedTrack != nil ? "Saved locally; upload failed" : "Import stopped at \(stageLabel(error.stage))")
                    .font(.system(size: 12, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error.code)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.appMuted.opacity(0.8))
            }
            Spacer()
        }
        .padding(13)
        .background(Color.appAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.appAccent.opacity(0.24)) }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if viewModel.selectedCandidate != nil, viewModel.completedTrack == nil {
                syncOption
            }

            if viewModel.isRunning {
                Button("Cancel", action: viewModel.cancel)
                    .buttonStyle(.bordered)
            } else if viewModel.stage == .complete || (viewModel.stage == .failed && viewModel.completedTrack != nil) {
                Button("Import Another", action: viewModel.reset)
                    .buttonStyle(.bordered)
            }

            Spacer()

            if viewModel.stage == .awaitingSelection || viewModel.stage == .failed && viewModel.resolution != nil && viewModel.completedTrack == nil {
                if viewModel.selectedRelease != nil {
                    Button("Copy Magnet", action: viewModel.copySelectedReleaseMagnet)
                        .buttonStyle(.bordered)
                    Button("Open in Torrent App", action: viewModel.openSelectedRelease)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appViolet)
                } else {
                    Button(action: viewModel.importSelected) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 24, height: 18)
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appViolet)
                        .disabled(viewModel.selectedCandidate == nil)
                        .help(viewModel.mediaMode == .video ? "Download Video" : "Save Audio on This Mac")
                        .accessibilityLabel(viewModel.mediaMode == .video ? "Download Video" : "Save Audio on This Mac")
                }
            } else if viewModel.stage == .complete || viewModel.completedTrack != nil {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appViolet)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background(Color.appSurfaceRaised.opacity(0.82))
    }

    private func stageCopy(_ stage: LocalImportStage) -> (title: String, detail: String, symbol: String, color: Color) {
        let mediaName = viewModel.mediaMode == .video ? "video" : "audio"
        return switch stage {
        case .idle: ("Ready", "Paste one Spotify track or YouTube video URL.", "link", Color.appViolet)
        case .resolvingMetadata: ("Resolving metadata", "This lookup runs directly from your Mac.", "magnifyingglass", Color.appViolet)
        case .searchingCandidates: ("Searching audio sources", "Ranking YouTube matches and finding Debrid Vault release sources.", "waveform.badge.magnifyingglass", Color.appViolet)
        case .awaitingSelection: (
            viewModel.selectedRelease != nil ? "Choose a release file" : "Ready to download",
            viewModel.selectedRelease != nil
                ? "Open the external release, choose its exact audio file, then use Import Files."
                : "Save the selected YouTube source as \(mediaName).",
            "checkmark.circle",
            Color.appViolet
        )
        case .inspectingSource: (
            "Inspecting \(mediaName)",
            viewModel.mediaMode == .video
                ? "Checking for a direct, verifiable MP4 stream with video and audio."
                : "Checking for a direct, verifiable M4A audio stream.",
            "doc.text.magnifyingglass",
            Color.appViolet
        )
        case .downloading: ("Downloading to this Mac", "Every expected byte range is verified while it is written.", "arrow.down.circle", Color.appViolet)
        case .processing: ("Preparing \(mediaName)", "Remuxing without transcoding and attaching available metadata.", "slider.horizontal.3", Color.appViolet)
        case .savingLocal: ("Saving locally", "Adding the completed file to this Mac's Resonance library.", "internaldrive", Color.appViolet)
        case .localComplete: ("Saved on this Mac", "This \(mediaName) remains visible when server profiles change.", "checkmark.circle.fill", Color.green)
        case .syncing: ("Uploading optional copy", "Sending the local file only to the currently active profile.", "arrow.up.circle", Color.appViolet)
        case .complete: ("Import complete", "The \(mediaName) is ready in your local Resonance library.", "checkmark.circle.fill", Color.green)
        case .failed: ("Import stopped", "Review the stage-specific error below.", "exclamationmark.triangle", Color.appAccent)
        case .cancelled: ("Import cancelled", "No partial song was added to the library.", "xmark.circle", Color.appMuted)
        }
    }

    private func stageLabel(_ stage: LocalImportStage) -> String {
        stage.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
