import AVFoundation
import Combine
import Foundation

enum MobileLocalImportSearchPolicy {
    struct Preparation: Equatable {
        let searchesProviders: Bool
        let syncAfterImport: Bool
        let usesReviewedServerMatch: Bool
    }

    static func prepare(
        input: String,
        explicitlyReviewedServerMatch: Bool,
        syncAfterImport: Bool,
        activeUploadMode: MobileUploadMode?
    ) -> Preparation {
        let searchesProviders = !LocalImportInput.looksLikeLink(input)
        let requiresDeviceOnlySearch = searchesProviders
            && !explicitlyReviewedServerMatch
            && (activeUploadMode == .serverSourceLink || activeUploadMode == .reviewedMatch)
        let adjustedSync = requiresDeviceOnlySearch ? false : syncAfterImport
        return Preparation(
            searchesProviders: searchesProviders,
            syncAfterImport: adjustedSync,
            usesReviewedServerMatch: explicitlyReviewedServerMatch
                || (adjustedSync && activeUploadMode == .reviewedMatch)
        )
    }
}

@MainActor
final class MobileLocalImportViewModel: ObservableObject {
    @Published var source = "" {
        didSet {
            if source != oldValue { invalidateResolvedSource() }
        }
    }
    @Published var mediaMode: LocalImportMediaMode = .audio {
        didSet {
            if mediaMode != oldValue { invalidateResolvedSource() }
        }
    }
    @Published var syncAfterImport = true
    @Published private(set) var stage: LocalImportStage = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var resolution: LocalImportResolution?
    @Published private(set) var searchResponse: LocalImportSearchResponse?
    @Published private(set) var selectedSearchResultID: String?
    @Published private(set) var selectedVideoID: String?
    @Published private(set) var hasExplicitCandidateSelection = false
    @Published var selectedPlaylistTrackIDs: Set<String> = []
    @Published private(set) var error: LocalImportError?
    @Published private(set) var completedTrack: MobileTrack?
    @Published private(set) var completedSummary: String?
    @Published private(set) var batchCurrentTitle: String?
    @Published private(set) var previewingVideoID: String?
    @Published private(set) var previewLoadingVideoID: String?
    @Published private(set) var previewError: String?

    private let service = LocalDeviceImportService()
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewStopTask: Task<Void, Never>?
    private var previewPlayer: AVPlayer?
    private var reviewedMatchLease: MobileReviewedMatchLease?
    private var resolvedSourceIdentity: String?
    private var sourceGeneration: UInt64 = 0

    var isRunning: Bool {
        switch stage {
        case .resolvingMetadata, .searchingCandidates, .inspectingSource, .downloading, .processing, .savingLocal, .localComplete, .syncing:
            true
        default:
            false
        }
    }

    var selectedCandidate: LocalImportAudioSourceMatch? {
        guard let selectedVideoID else { return nil }
        return resolution?.candidates.first { $0.videoID == selectedVideoID }
    }

    func searchResults(for provider: LocalImportSearchProvider) -> [LocalImportSearchResult] {
        searchResponse?.results(for: provider) ?? []
    }

    var isPlaylist: Bool {
        resolution.map { $0.kind == .spotifyPlaylist || $0.kind == .soundCloudPlaylist } ?? false
    }

    var selectedPlaylistItems: [LocalImportPlaylistItem] {
        resolution?.playlist?.items.filter { selectedPlaylistTrackIDs.contains($0.track.trackID) } ?? []
    }

    var resolveButtonTitle: String {
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !LocalImportInput.looksLikeLink(source) {
            return mediaMode == .video ? "Search Videos" : "Search Music"
        }
        return mediaMode == .video ? "Find Video" : "Find Audio"
    }

    func normalizeMediaModeForSource() {
        if (LocalImportURL.isSpotify(source) || LocalImportURL.isSoundCloud(source)), mediaMode == .video {
            mediaMode = .audio
        }
    }

    var continuesAfterSheetDismissal: Bool {
        switch stage {
        case .inspectingSource, .downloading, .processing, .savingLocal, .localComplete, .syncing:
            true
        default:
            false
        }
    }

    func resolve(using library: MusicLibrary, reviewedServerMatch: Bool) {
        guard !isRunning else { return }
        normalizeMediaModeForSource()
        let rawInput = source
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            error = LocalImportError(stage: .resolvingMetadata, code: "MISSING_SOURCE", message: "Enter a song, artist, album, or supported Spotify, SoundCloud, or YouTube link first.")
            stage = .failed
            return
        }
        stopPreview()
        task?.cancel()
        error = nil
        resolution = nil
        searchResponse = nil
        selectedSearchResultID = nil
        selectedVideoID = nil
        hasExplicitCandidateSelection = false
        selectedPlaylistTrackIDs = []
        reviewedMatchLease = nil
        resolvedSourceIdentity = nil
        completedTrack = nil
        completedSummary = nil
        batchCurrentTitle = nil
        let preparation = MobileLocalImportSearchPolicy.prepare(
            input: value,
            explicitlyReviewedServerMatch: reviewedServerMatch,
            syncAfterImport: syncAfterImport,
            activeUploadMode: library.activeUploadMode
        )
        syncAfterImport = preparation.syncAfterImport
        let usesReviewedServerMatch = preparation.usesReviewedServerMatch
        let searchesProviders = preparation.searchesProviders
        if usesReviewedServerMatch, searchesProviders {
            error = LocalImportError(
                stage: .resolvingMetadata,
                code: "REVIEW_LINK_REQUIRED",
                message: "Reviewed Match requires one supported Spotify track or YouTube video link."
            )
            stage = .failed
            return
        }
        stage = searchesProviders ? .searchingCandidates : .resolvingMetadata
        let generation = sourceGeneration
        task = Task { [weak self, library] in
            guard let self else { return }
            do {
                if usesReviewedServerMatch {
                    guard let lease = library.captureReviewedMatchLease() else {
                        throw LocalImportError(
                            stage: .resolvingMetadata,
                            code: "REVIEW_POLICY_UNAVAILABLE",
                            message: "Reviewed Match is no longer enabled by the current signed server policy."
                        )
                    }
                    let result = try await library.resolveReviewedMatch(source: value, lease: lease)
                    try Task.checkCancellation()
                    guard generation == sourceGeneration,
                          source == rawInput,
                          library.isReviewedMatchLeaseCurrent(lease) else {
                        throw LocalImportError(
                            stage: .resolvingMetadata,
                            code: "REVIEW_POLICY_CHANGED",
                            message: "The signed transfer policy changed. Resolve the link again before importing."
                        )
                    }
                    resolution = result
                    reviewedMatchLease = lease
                    resolvedSourceIdentity = rawInput
                    selectedVideoID = nil
                    selectedPlaylistTrackIDs = []
                    stage = .awaitingSelection
                    task = nil
                    return
                }
                if searchesProviders {
                    let response = try await service.search(query: value, mediaMode: mediaMode)
                    try Task.checkCancellation()
                    guard generation == sourceGeneration, source == rawInput else {
                        throw CancellationError()
                    }
                    searchResponse = response
                    guard let first = response.results.first else {
                        throw LocalImportError(
                            stage: .searchingCandidates,
                            code: "NO_SEARCH_RESULTS",
                            message: "Spotify, SoundCloud, and YouTube returned no previewable results for that search."
                        )
                    }
                    selectSearchResult(first)
                    resolvedSourceIdentity = rawInput
                    stage = .awaitingSelection
                    task = nil
                    return
                }
                let result = try await service.resolve(source: value, mediaMode: mediaMode) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                guard generation == sourceGeneration, source == rawInput else {
                    throw CancellationError()
                }
                resolution = result
                resolvedSourceIdentity = rawInput
                selectedVideoID = result.candidates.first?.videoID
                selectedPlaylistTrackIDs = Set(result.playlist?.items.map { $0.track.trackID } ?? [])
                stage = .awaitingSelection
            } catch is CancellationError {
                if generation == sourceGeneration { stage = .cancelled }
            } catch let failure as LocalImportError {
                guard generation == sourceGeneration, source == rawInput else { return }
                error = failure
                stage = .failed
            } catch {
                guard generation == sourceGeneration, source == rawInput else { return }
                self.error = LocalImportError(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
            if generation == sourceGeneration { task = nil }
        }
    }

    func selectSearchResult(_ result: LocalImportSearchResult) {
        if previewingVideoID != result.candidates.first?.videoID {
            stopPreview()
        }
        resolution = result.resolution
        selectedSearchResultID = result.id
        selectedVideoID = result.candidates.first?.videoID
        hasExplicitCandidateSelection = selectedVideoID != nil
        selectedPlaylistTrackIDs = []
        previewError = nil
    }

    func selectCandidate(_ candidate: LocalImportAudioSourceMatch) {
        selectedVideoID = candidate.videoID
        hasExplicitCandidateSelection = true
    }

    func toggleSearchPreview(_ result: LocalImportSearchResult) {
        selectSearchResult(result)
        guard let candidate = result.candidates.first else { return }
        togglePreview(candidate)
    }

    @discardableResult
    func importSelected(into library: MusicLibrary, reviewedServerMatch: Bool) -> Bool {
        guard !isRunning, let resolution else { return false }
        guard LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: resolvedSourceIdentity,
            displayedInput: source
        ) else {
            error = LocalImportError(
                stage: .resolvingMetadata,
                code: "SOURCE_CHANGED",
                message: "The source changed after it was resolved. Find audio again before importing."
            )
            stage = .failed
            return false
        }
        guard !library.isUploadTransferBusy else {
            error = LocalImportError(
                stage: .inspectingSource,
                code: "TRANSFER_BUSY",
                message: "Wait for the current upload or download to finish before starting an import."
            )
            stage = .failed
            return false
        }
        if syncAfterImport, !library.canUploadLocalImports {
            error = LocalImportError(
                stage: .syncing,
                code: "SERVER_UPLOAD_NOT_CONFIGURED",
                message: "Sign in to your Resonance account, or turn off server upload."
            )
            stage = .failed
            return false
        }
        let usesReviewedUpload = syncAfterImport && library.activeUploadMode == .reviewedMatch
        if reviewedServerMatch, !usesReviewedUpload {
            error = LocalImportError(
                stage: .syncing,
                code: "REVIEW_POLICY_CHANGED",
                message: "Reviewed Match is no longer enabled. Close this sheet and choose an available upload mode."
            )
            stage = .failed
            return false
        }
        if usesReviewedUpload, isPlaylist {
            error = LocalImportError(
                stage: .syncing,
                code: "REVIEW_PLAYLIST_UNSUPPORTED",
                message: "Reviewed Match imports one explicitly reviewed song at a time."
            )
            stage = .failed
            return false
        }
        if usesReviewedUpload {
            guard hasExplicitCandidateSelection,
                  let reviewedMatchLease,
                  library.isReviewedMatchLeaseCurrent(reviewedMatchLease) else {
                error = LocalImportError(
                    stage: .syncing,
                    code: "REVIEW_SELECTION_REQUIRED",
                    message: "Select one reviewed audio candidate. If the signed policy changed, resolve the link again."
                )
                stage = .failed
                return false
            }
        }
        stopPreview()
        library.dismissTransferNotice()
        if isPlaylist {
            importPlaylist(resolution, into: library)
            return true
        }
        guard let candidate = selectedCandidate else { return false }
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
        let candidates = usesReviewedUpload
            ? [candidate]
            : [candidate] + resolution.candidates.filter { $0.videoID != candidate.videoID }
        let shouldSync = syncAfterImport
        let reviewLease = usesReviewedUpload ? reviewedMatchLease : nil
        let selectedMediaMode = mediaMode
        guard let transferSessionID = reserveTransfer(
            title: resolution.track.title,
            total: 1,
            library: library
        ) else {
            error = LocalImportError(
                stage: .inspectingSource,
                code: "TRANSFER_BUSY",
                message: "Wait for the current upload or download to finish before starting an import."
            )
            stage = .failed
            return false
        }
        task = Task { [self, library] in
            await runSingleImport(
                spotifyTrack: resolution.track,
                metadata: metadata,
                candidates: candidates,
                mediaMode: selectedMediaMode,
                shouldSync: shouldSync,
                reviewedMatchLease: reviewLease,
                transferSessionID: transferSessionID,
                library: library
            )
            task = nil
        }
        return true
    }

    func togglePlaylistItem(_ item: LocalImportPlaylistItem) {
        if selectedPlaylistTrackIDs.contains(item.track.trackID) {
            selectedPlaylistTrackIDs.remove(item.track.trackID)
        } else {
            selectedPlaylistTrackIDs.insert(item.track.trackID)
        }
    }

    private func importPlaylist(_ resolution: LocalImportResolution, into library: MusicLibrary) {
        let items = selectedPlaylistItems
        guard let playlist = resolution.playlist, !items.isEmpty else { return }
        task?.cancel()
        error = nil
        completedBytes = 0
        totalBytes = 0
        completedSummary = nil
        stage = .inspectingSource
        let shouldSync = syncAfterImport
        let selectedMediaMode = mediaMode
        guard let transferSessionID = reserveTransfer(
            title: items.first?.track.title ?? playlist.title,
            total: items.count,
            library: library
        ) else {
            error = LocalImportError(
                stage: .inspectingSource,
                code: "TRANSFER_BUSY",
                message: "Wait for the current upload or download to finish before starting an import."
            )
            stage = .failed
            return
        }
        task = Task { [self, library] in
            await runPlaylistImport(
                items: items,
                playlist: playlist,
                mediaMode: selectedMediaMode,
                shouldSync: shouldSync,
                transferSessionID: transferSessionID,
                library: library
            )
            task = nil
        }
    }

    func cancel() {
        stopPreview()
        task?.cancel()
        task = nil
        if isRunning { stage = .cancelled }
    }

    private func invalidateResolvedSource() {
        sourceGeneration &+= 1
        task?.cancel()
        task = nil
        stopPreview()
        resolution = nil
        searchResponse = nil
        selectedSearchResultID = nil
        selectedVideoID = nil
        hasExplicitCandidateSelection = false
        selectedPlaylistTrackIDs = []
        reviewedMatchLease = nil
        resolvedSourceIdentity = nil
        completedTrack = nil
        completedSummary = nil
        batchCurrentTitle = nil
        error = nil
        if !continuesAfterSheetDismissal { stage = .idle }
    }

    private func apply(_ progress: LocalImportProgress) {
        stage = progress.stage
        completedBytes = progress.completed
        totalBytes = progress.total
    }

    func existingStatus(for track: LocalImportSpotifyTrack, in library: MusicLibrary) -> String? {
        let match = LocalImportExistingSongPolicy.match(
            spotifyTrack: track,
            deviceTracks: library.tracks,
            activeServerSongs: library.cachedRemoteSongsForUploadPlanning,
            activeServerURL: library.activeServerURLForUploadPlanning,
            activeProfileID: library.syncProfileID,
            mediaMode: mediaMode
        )
        switch (match.isOnDevice, match.isOnServer) {
        case (true, true): return "On device and server — both transfers will be skipped"
        case (true, false): return "On device — download will be skipped"
        case (false, true): return "On server — upload will be skipped"
        case (false, false): return nil
        }
    }

    func togglePreview(_ candidate: LocalImportAudioSourceMatch) {
        if previewingVideoID == candidate.videoID || previewLoadingVideoID == candidate.videoID {
            stopPreview()
            return
        }
        stopPreview()
        previewError = nil
        previewLoadingVideoID = candidate.videoID
        previewTask = Task { [self] in
            do {
                let stream = try await service.previewStream(for: candidate)
                try Task.checkCancellation()
                let asset = AVURLAsset(
                    url: stream.url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": stream.httpHeaders]
                )
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                previewPlayer = player
                previewLoadingVideoID = nil
                previewingVideoID = candidate.videoID
                player.play()
                previewStopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.stopPreview()
                }
            } catch is CancellationError {
                previewLoadingVideoID = nil
            } catch {
                previewLoadingVideoID = nil
                previewError = "Preview unavailable: \(error.localizedDescription)"
            }
            previewTask = nil
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewStopTask?.cancel()
        previewTask = nil
        previewStopTask = nil
        previewPlayer?.pause()
        previewPlayer = nil
        previewLoadingVideoID = nil
        previewingVideoID = nil
    }

    private func runSingleImport(
        spotifyTrack: LocalImportSpotifyTrack,
        metadata: LocalImportMetadata,
        candidates: [LocalImportAudioSourceMatch],
        mediaMode: LocalImportMediaMode,
        shouldSync: Bool,
        reviewedMatchLease: MobileReviewedMatchLease?,
        transferSessionID: UUID,
        library: MusicLibrary
    ) async {
        defer {
            finishTransfers(sessionID: transferSessionID, library: library)
            batchCurrentTitle = nil
        }
        do {
            try Task.checkCancellation()
            let isReviewedUpload = reviewedMatchLease != nil
            var match = isReviewedUpload
                ? LocalImportExistingSongMatch(deviceTrackID: nil, serverSongID: nil)
                : LocalImportExistingSongPolicy.match(
                    spotifyTrack: spotifyTrack,
                    deviceTracks: library.tracks,
                    activeServerSongs: library.cachedRemoteSongsForUploadPlanning,
                    activeServerURL: library.activeServerURLForUploadPlanning,
                    activeProfileID: library.syncProfileID,
                    mediaMode: mediaMode
                )
            var track = match.deviceTrackID.flatMap { id in library.tracks.first { $0.id == id } }
            if let existingTrack = track {
                track = library.associateLocalImportSource(
                    trackID: existingTrack.id,
                    source: LocalImportSourceAssociation(
                        sourceURL: metadata.sourceURL,
                        downloadSourceURL: nil
                    )
                ) ?? existingTrack
            }
            let plannedDownloads = track == nil ? 1 : 0
            if plannedDownloads > 0 {
                beginDownloads(
                    sessionID: transferSessionID,
                    total: plannedDownloads,
                    title: spotifyTrack.title,
                    itemID: spotifyTrack.trackID,
                    library: library
                )
                batchCurrentTitle = "1 of 1 • \(spotifyTrack.title)"
                track = try await downloadTrack(
                    spotifyTrack,
                    metadata: metadata,
                    candidates: candidates,
                    mediaMode: mediaMode,
                    completedBefore: 0,
                    total: plannedDownloads,
                    transferSessionID: transferSessionID,
                    library: library
                )
                updateTransfer(
                    sessionID: transferSessionID,
                    kind: .download,
                    itemID: spotifyTrack.trackID,
                    title: spotifyTrack.title,
                    detail: "Download complete",
                    currentItem: 1,
                    totalItems: plannedDownloads,
                    fallbackProgress: 1,
                    library: library
                )
            }
            guard let track else {
                throw LocalImportError(stage: .savingLocal, code: "LOCAL_IMPORT_MISSING", message: "The imported song could not be found on this device.")
            }
            completedTrack = track
            match = isReviewedUpload
                ? LocalImportExistingSongMatch(deviceTrackID: track.id, serverSongID: nil)
                : LocalImportExistingSongPolicy.match(
                    spotifyTrack: spotifyTrack,
                    deviceTracks: library.tracks,
                    activeServerSongs: library.cachedRemoteSongsForUploadPlanning,
                    activeServerURL: library.activeServerURLForUploadPlanning,
                    activeProfileID: library.syncProfileID,
                    mediaMode: mediaMode
                )
            if let serverID = match.serverSongID {
                guard library.reconcileLocalImportWithServer(trackID: track.id, remoteID: serverID) else {
                    let detail = "\(track.title) — \(track.artist) (\(library.serverMessage))"
                    self.error = LocalImportError(
                        stage: .syncing,
                        code: "REMOTE_ASSOCIATION_CONFLICT",
                        message: detail
                    )
                    stage = .failed
                    library.showTransferNotice(
                        title: "Saved locally; server link kept",
                        detail: detail,
                        isError: true
                    )
                    return
                }
            }
            var uploadFailure: String?
            if shouldSync, match.serverSongID == nil {
                stage = .syncing
                beginUploads(
                    sessionID: transferSessionID,
                    total: 1,
                    title: track.title,
                    itemID: track.id.uuidString,
                    library: library
                )
                do {
                    _ = try await uploadWithRetry(
                        track,
                        index: 0,
                        total: 1,
                        reviewedMatchLease: reviewedMatchLease,
                        transferSessionID: transferSessionID,
                        library: library
                    )
                    updateTransfer(
                        sessionID: transferSessionID,
                        kind: .upload,
                        itemID: track.id.uuidString,
                        title: track.title,
                        detail: "Upload complete",
                        currentItem: 1,
                        totalItems: 1,
                        fallbackProgress: 1,
                        library: library
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    uploadFailure = error.localizedDescription
                }
            }
            if let uploadFailure {
                let detail = "\(track.title) — \(track.artist) (\(uploadFailure))"
                self.error = LocalImportError(stage: .syncing, code: "SERVER_UPLOAD_FAILED", message: detail)
                stage = .failed
                library.showTransferNotice(title: "Saved locally; upload failed", detail: detail, isError: true)
            } else {
                stage = .complete
                let localDetail = plannedDownloads == 0 ? "Already on this device." : "Downloaded to this device."
                let serverDetail = shouldSync ? (match.serverSongID == nil ? " Uploaded to the server." : " Already on the server.") : ""
                completedSummary = localDetail + serverDetail
                library.showTransferNotice(title: "Import complete", detail: localDetail + serverDetail, isError: false)
            }
        } catch is CancellationError {
            stage = .cancelled
        } catch {
            let message = (error as? LocalImportError)?.message ?? error.localizedDescription
            self.error = LocalImportError(stage: stage, code: "LOCAL_IMPORT_FAILED", message: message)
            stage = .failed
            library.showTransferNotice(title: "Import failed", detail: "\(spotifyTrack.title) — \(spotifyTrack.artist): \(message)", isError: true)
        }
    }

    private func runPlaylistImport(
        items: [LocalImportPlaylistItem],
        playlist: LocalImportPlaylist,
        mediaMode: LocalImportMediaMode,
        shouldSync: Bool,
        transferSessionID: UUID,
        library: MusicLibrary
    ) async {
        defer {
            finishTransfers(sessionID: transferSessionID, library: library)
            batchCurrentTitle = nil
        }
        var importedTracks: [(item: LocalImportPlaylistItem, track: MobileTrack)] = []
        var downloadFailures: [String] = []
        var associationFailures: [String] = []
        var associationFailedTrackIDs = Set<UUID>()
        var uploadFailures: [String] = []
        do {
            let initialMatches = items.reduce(into: [String: LocalImportExistingSongMatch]()) { result, item in
                guard result[item.track.trackID] == nil else { return }
                result[item.track.trackID] = LocalImportExistingSongPolicy.match(
                    spotifyTrack: item.track,
                    deviceTracks: library.tracks,
                    activeServerSongs: library.cachedRemoteSongsForUploadPlanning,
                    activeServerURL: library.activeServerURLForUploadPlanning,
                    activeProfileID: library.syncProfileID,
                    mediaMode: mediaMode
                )
            }
            let downloadItems = items.filter { initialMatches[$0.track.trackID]?.deviceTrackID == nil }
            if let firstDownload = downloadItems.first {
                beginDownloads(
                    sessionID: transferSessionID,
                    total: downloadItems.count,
                    title: firstDownload.track.title,
                    itemID: firstDownload.track.trackID,
                    library: library
                )
            }
            var completedDownloads = 0
            for item in items {
                try Task.checkCancellation()
                let initialMatch = initialMatches[item.track.trackID]
                var track = initialMatch?.deviceTrackID.flatMap { id in library.tracks.first { $0.id == id } }
                if let existingTrack = track {
                    track = library.associateLocalImportSource(
                        trackID: existingTrack.id,
                        source: LocalImportSourceAssociation(
                            sourceURL: item.track.sourceURL,
                            downloadSourceURL: nil
                        )
                    ) ?? existingTrack
                }
                if track == nil {
                    let metadata = LocalImportMetadata(
                        title: item.track.title,
                        artist: item.track.artist,
                        album: item.track.album,
                        artworkURL: item.track.artworkURL ?? item.candidate.thumbnailURL,
                        sourceURL: item.track.sourceURL
                    )
                    batchCurrentTitle = "\(completedDownloads + 1) of \(downloadItems.count) • \(item.track.title)"
                    do {
                        track = try await downloadTrack(
                            item.track,
                            metadata: metadata,
                            candidates: item.downloadCandidates,
                            mediaMode: mediaMode,
                            completedBefore: completedDownloads,
                            total: downloadItems.count,
                            transferSessionID: transferSessionID,
                            library: library
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        downloadFailures.append("\(item.track.title) — \(item.track.artist) (\(error.localizedDescription))")
                    }
                    completedDownloads += 1
                    updateTransfer(
                        sessionID: transferSessionID,
                        kind: .download,
                        itemID: item.track.trackID,
                        title: item.track.title,
                        detail: track == nil ? "Download failed" : "Download complete",
                        currentItem: completedDownloads,
                        totalItems: downloadItems.count,
                        fallbackProgress: track == nil ? nil : 1,
                        library: library
                    )
                }
                if let track {
                    if let serverID = initialMatch?.serverSongID,
                       !library.reconcileLocalImportWithServer(trackID: track.id, remoteID: serverID) {
                        associationFailures.append(
                            "\(track.title) — \(track.artist) (\(library.serverMessage))"
                        )
                        associationFailedTrackIDs.insert(track.id)
                    }
                    if !importedTracks.contains(where: { $0.track.id == track.id }) {
                        importedTracks.append((item, track))
                        completedTrack = importedTracks.first?.track
                    }
                }
            }
            library.upsertImportedPlaylist(named: playlist.title, tracks: importedTracks.map(\.track))

            let uploadQueue = shouldSync ? importedTracks.filter { pair in
                guard !associationFailedTrackIDs.contains(pair.track.id) else { return false }
                return LocalImportExistingSongPolicy.match(
                    spotifyTrack: pair.item.track,
                    deviceTracks: library.tracks,
                    activeServerSongs: library.cachedRemoteSongsForUploadPlanning,
                    activeServerURL: library.activeServerURLForUploadPlanning,
                    activeProfileID: library.syncProfileID,
                    mediaMode: mediaMode
                ).serverSongID == nil
            } : []
            if !uploadQueue.isEmpty {
                stage = .syncing
                beginUploads(
                    sessionID: transferSessionID,
                    total: uploadQueue.count,
                    title: uploadQueue[0].track.title,
                    itemID: uploadQueue[0].track.id.uuidString,
                    library: library
                )
                for (index, pair) in uploadQueue.enumerated() {
                    try Task.checkCancellation()
                    var uploadFailed = false
                    do {
                        _ = try await uploadWithRetry(
                            pair.track,
                            index: index,
                            total: uploadQueue.count,
                            reviewedMatchLease: nil,
                            transferSessionID: transferSessionID,
                            library: library
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        uploadFailed = true
                        uploadFailures.append("\(pair.track.title) — \(pair.track.artist) (\(error.localizedDescription))")
                    }
                    updateTransfer(
                        sessionID: transferSessionID,
                        kind: .upload,
                        itemID: pair.track.id.uuidString,
                        title: pair.track.title,
                        detail: uploadFailed ? "Upload failed" : "Upload complete",
                        currentItem: index + 1,
                        totalItems: uploadQueue.count,
                        fallbackProgress: uploadFailed ? nil : 1,
                        library: library
                    )
                }
            }
            completedSummary = "Kept \(importedTracks.count) of \(items.count) selected songs in \(playlist.title)."
            if !downloadFailures.isEmpty {
                let detail = "Kept \(importedTracks.count) song\(importedTracks.count == 1 ? "" : "s"). Downloads failed after retrying: \(downloadFailures.joined(separator: "; "))"
                error = LocalImportError(stage: .downloading, code: "PLAYLIST_DOWNLOAD_PARTIAL_FAILURE", message: detail)
                stage = .failed
                library.showTransferNotice(title: "Playlist import incomplete", detail: detail, isError: true)
            } else if !associationFailures.isEmpty || !uploadFailures.isEmpty {
                var issues: [String] = []
                if !associationFailures.isEmpty {
                    issues.append("Existing server links were kept: \(associationFailures.joined(separator: "; "))")
                }
                if !uploadFailures.isEmpty {
                    issues.append("Server uploads failed after retrying: \(uploadFailures.joined(separator: "; "))")
                }
                let detail = "Saved every downloaded song locally. \(issues.joined(separator: " "))"
                error = LocalImportError(stage: .syncing, code: "PLAYLIST_SERVER_SYNC_PARTIAL_FAILURE", message: detail)
                stage = .failed
                library.showTransferNotice(title: "Saved locally; server sync incomplete", detail: detail, isError: true)
            } else {
                stage = .complete
                let deviceSkips = initialMatches.values.filter(\.isOnDevice).count
                let serverSkips = shouldSync ? initialMatches.values.filter(\.isOnServer).count : 0
                let detail = "Imported \(importedTracks.count) song\(importedTracks.count == 1 ? "" : "s"). Skipped \(deviceSkips) device download\(deviceSkips == 1 ? "" : "s") and \(serverSkips) server upload\(serverSkips == 1 ? "" : "s")."
                library.showTransferNotice(title: "Playlist import complete", detail: detail, isError: false)
            }
        } catch is CancellationError {
            library.upsertImportedPlaylist(named: playlist.title, tracks: importedTracks.map(\.track))
            stage = .cancelled
        } catch {
            library.upsertImportedPlaylist(named: playlist.title, tracks: importedTracks.map(\.track))
            let message = error.localizedDescription
            self.error = LocalImportError(stage: stage, code: "LOCAL_IMPORT_FAILED", message: message)
            stage = .failed
            library.showTransferNotice(title: "Playlist import failed", detail: message, isError: true)
        }
    }

    private func downloadTrack(
        _ spotifyTrack: LocalImportSpotifyTrack,
        metadata: LocalImportMetadata,
        candidates: [LocalImportAudioSourceMatch],
        mediaMode: LocalImportMediaMode,
        completedBefore: Int,
        total: Int,
        transferSessionID: UUID,
        library: MusicLibrary
    ) async throws -> MobileTrack {
        var lastError: Error?
        for (candidateIndex, candidate) in candidates.enumerated() {
            do {
                if candidateIndex > 0 { try await Task.sleep(for: .milliseconds(400)) }
                let outcome = try await service.importCandidate(
                    candidate,
                    metadata: metadata,
                    existingTracks: library.tracks,
                    mediaMode: mediaMode
                ) { [weak self, weak library] progress in
                    self?.apply(progress)
                    guard let library else { return }
                    self?.updateTransfer(
                        sessionID: transferSessionID,
                        kind: .download,
                        itemID: spotifyTrack.trackID,
                        title: spotifyTrack.title,
                        detail: progress.stage == .downloading ? "Downloading song" : "Preparing song",
                        currentItem: completedBefore + 1,
                        totalItems: total,
                        completedBytes: progress.completed,
                        totalBytes: progress.total,
                        fallbackProgress: progress.stage == .complete ? 1 : nil,
                        library: library
                    )
                }
                switch outcome {
                case .created(let imported): return try library.insertLocalImportedAudio(imported)
                case .duplicate(let id, let source):
                    if let track = (
                        library.associateLocalImportSource(trackID: id, source: source)
                            ?? library.tracks.first(where: { $0.id == id })
                    ) {
                        return track
                    }
                    throw LocalImportError(stage: .savingLocal, code: "DUPLICATE_NOT_FOUND", message: "The existing local song could not be found.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LocalImportError(stage: .downloading, code: "ALL_SOURCES_FAILED", message: "Every matched \(mediaMode.rawValue) source failed.")
    }

    private func uploadWithRetry(
        _ track: MobileTrack,
        index: Int,
        total: Int,
        reviewedMatchLease: MobileReviewedMatchLease?,
        transferSessionID: UUID,
        library: MusicLibrary
    ) async throws -> Bool {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                if let reviewedMatchLease,
                   !library.isReviewedMatchLeaseCurrent(reviewedMatchLease) {
                    throw LocalImportError(
                        stage: .syncing,
                        code: "REVIEW_POLICY_CHANGED",
                        message: "The signed Reviewed Match policy expired or changed before upload."
                    )
                }
                if attempt > 1 { try await Task.sleep(for: .milliseconds(attempt == 2 ? 500 : 1_500)) }
                updateTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: track.id.uuidString,
                    title: track.title,
                    detail: attempt == 1 ? "Uploading song" : "Retrying upload (\(attempt)/3)",
                    currentItem: index + 1,
                    totalItems: total,
                    library: library
                )
                return try await library.uploadLocalImportToActiveProfile(
                    track,
                    reviewedMatchLease: reviewedMatchLease,
                    transferSessionID: transferSessionID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func beginDownloads(
        sessionID: UUID,
        total: Int,
        title: String,
        itemID: String,
        library: MusicLibrary
    ) {
        updateTransfer(
            sessionID: sessionID,
            kind: .download,
            itemID: itemID,
            title: title,
            detail: "Preparing song",
            currentItem: 1,
            totalItems: total,
            library: library
        )
    }

    private func reserveTransfer(
        title: String,
        total: Int,
        library: MusicLibrary
    ) -> UUID? {
        library.beginTransferSession(with: MobileTransferDisplayState(
            kind: .download,
            itemID: "local-import-\(UUID().uuidString)",
            songTitle: title,
            detail: "Preparing import",
            currentItem: 1,
            totalItems: max(total, 1),
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        ))
    }

    private func beginUploads(
        sessionID: UUID,
        total: Int,
        title: String,
        itemID: String,
        library: MusicLibrary
    ) {
        updateTransfer(
            sessionID: sessionID,
            kind: .upload,
            itemID: itemID,
            title: title,
            detail: "Preparing upload",
            currentItem: 1,
            totalItems: total,
            library: library
        )
    }

    private func updateTransfer(
        sessionID: UUID,
        kind: MobileTransferDisplayState.Kind,
        itemID: String,
        title: String,
        detail: String,
        currentItem: Int,
        totalItems: Int,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        fallbackProgress: Double? = nil,
        library: MusicLibrary
    ) {
        library.updateTransferSession(sessionID, with: MobileTransferDisplayState(
            kind: kind,
            itemID: itemID,
            songTitle: title,
            detail: detail,
            currentItem: currentItem,
            totalItems: max(totalItems, 1),
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fallbackProgress: fallbackProgress
        ))
    }

    private func finishTransfers(sessionID: UUID, library: MusicLibrary) {
        library.finishTransferSession(sessionID)
    }
}
