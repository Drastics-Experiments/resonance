import AppKit
import AVFoundation
import SwiftUI

enum LocalImportPlaylistBatchPhase {
    case downloading
    case uploading
}

@MainActor
enum LocalImportPlaylistBatchPipeline {
    static func run<Item, Downloaded>(
        items: [Item],
        download: (Int, Int, Item) async throws -> Downloaded?,
        beforeUpload: ([Downloaded]) async throws -> Void,
        upload: ((Int, Int, Downloaded) async throws -> Void)?
    ) async throws -> [Downloaded] {
        var downloaded: [Downloaded] = []
        for (index, item) in items.enumerated() {
            if let value = try await download(index, items.count, item) {
                downloaded.append(value)
            }
        }

        try await beforeUpload(downloaded)
        if let upload {
            for (index, value) in downloaded.enumerated() {
                try await upload(index, downloaded.count, value)
            }
        }
        return downloaded
    }
}

enum LocalImportBatchProgressPolicy {
    static func overallProgress(
        completedItems: Int,
        totalItems: Int,
        currentItemProgress: Double?
    ) -> Double? {
        guard totalItems > 0 else { return nil }
        let completed = min(max(completedItems, 0), totalItems)
        let current = min(max(currentItemProgress ?? 0, 0), 1)
        return min((Double(completed) + current) / Double(totalItems), 1)
    }

    static func plannedTransferCount(
        matches: [LocalImportExistingSongMatch],
        requiresTransfer: (LocalImportExistingSongMatch) -> Bool
    ) -> Int {
        matches.filter(requiresTransfer).count
    }
}

enum LocalImportCandidateFallbackPolicy {
    static func firstSuccessful<Candidate, Output>(
        candidates: [Candidate],
        maximumAttempts: Int = 3,
        attempt: (Candidate) async throws -> Output
    ) async throws -> Output {
        precondition(!candidates.isEmpty)
        var lastError: Error?
        for candidate in candidates.prefix(max(maximumAttempts, 1)) {
            try Task.checkCancellation()
            do {
                return try await attempt(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }
}

@MainActor
final class MacLocalImportViewModel: ObservableObject {
    @Published var source = ""
    @Published private(set) var stage: LocalImportStage = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var resolution: LocalImportResolution?
    @Published private(set) var searchResponse: LocalImportSearchResponse?
    @Published private(set) var selectedSearchResultID: String?
    @Published var selectedVideoID: String?
    @Published var selectedPlaylistTrackIDs: Set<String> = []
    @Published var selectedReleaseInfoHash: String?
    @Published var mediaMode: LocalImportMediaMode = .audio
    @Published var syncAfterImport = true
    @Published private(set) var error: LocalImportError?
    @Published private(set) var completedTrack: Track?
    @Published private(set) var releaseActionMessage: String?
    @Published private(set) var previewingVideoID: String?
    @Published private(set) var loadingPreviewVideoID: String?
    @Published private(set) var previewErrorMessage: String?
    @Published private(set) var completedSummary: String?
    @Published private(set) var batchCurrentTitle: String?
    @Published private(set) var batchPhase: LocalImportPlaylistBatchPhase?
    @Published private(set) var batchCompletedItems = 0
    @Published private(set) var batchTotalItems = 0

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

    var isSearchMode: Bool { searchResponse != nil }

    func searchResults(for provider: LocalImportSearchProvider) -> [LocalImportSearchResult] {
        searchResponse?.results(for: provider) ?? []
    }

    var isPlaylist: Bool {
        resolution?.kind == .spotifyPlaylist || resolution?.kind == .soundCloudPlaylist
    }

    var playlistProviderName: String {
        resolution?.kind == .soundCloudPlaylist ? "SoundCloud" : "Spotify"
    }

    var selectedPlaylistItems: [LocalImportPlaylistItem] {
        resolution?.playlist?.items.filter { selectedPlaylistTrackIDs.contains($0.track.trackID) } ?? []
    }

    func existingMatch(for track: LocalImportSpotifyTrack) -> LocalImportExistingSongMatch {
        LocalImportExistingSongPolicy.match(
            spotifyTrack: track,
            deviceTracks: model.tracks,
            activeServerSongs: model.remoteSongs
        )
    }

    func existingStatus(for track: LocalImportSpotifyTrack) -> String? {
        let match = existingMatch(for: track)
        return switch (match.isOnDevice, match.isOnServer) {
        case (true, true):
            "On this Mac and \(activeProfileName) • no transfer needed"
        case (true, false):
            "On this Mac • download will be skipped"
        case (false, true):
            "On \(activeProfileName) • upload will be skipped"
        case (false, false):
            nil
        }
    }

    func existingSummary(for playlist: LocalImportPlaylist) -> String? {
        let matches = playlist.items.map { existingMatch(for: $0.track) }
        let deviceCount = matches.filter { $0.isOnDevice }.count
        let serverCount = matches.filter { $0.isOnServer }.count
        let values = [
            deviceCount > 0 ? "\(deviceCount) already on this Mac" : nil,
            serverCount > 0 ? "\(serverCount) already on \(activeProfileName)" : nil,
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " • ")
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
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !LocalImportInput.looksLikeLink(source) {
            return "Search Music"
        }
        return mediaMode == .video ? "Find Video" : "Find Audio"
    }

    var showsTransferPopup: Bool {
        if isPlaylist, batchPhase == nil { return false }
        return LocalImportPresentationPolicy.showsGlobalTransfer(for: stage)
    }

    var showsFailurePopup: Bool {
        if isPlaylist && stage == .failed { return true }
        return LocalImportPresentationPolicy.showsGlobalFailure(
            for: stage,
            hasCompletedTrack: completedTrack != nil,
            failedStage: error?.stage
        )
    }

    var failurePopupTitle: String {
        error?.stage == .syncing ? "Saved locally; upload failed" : "Playlist import incomplete"
    }

    var continuesAfterSheetDismissal: Bool {
        LocalImportPresentationPolicy.continuesAfterSheetDismissal(for: stage)
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
        if batchPhase != nil {
            let currentItemProgress: Double?
            if batchPhase == .downloading, stage == .downloading, totalBytes > 0 {
                currentItemProgress = Double(completedBytes) / Double(totalBytes)
            } else {
                currentItemProgress = nil
            }
            return LocalImportBatchProgressPolicy.overallProgress(
                completedItems: batchCompletedItems,
                totalItems: batchTotalItems,
                currentItemProgress: currentItemProgress
            )
        }
        guard stage == .downloading, totalBytes > 0 else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }

    var transferTitle: String {
        if isPlaylist {
            return batchPhase == .uploading ? "Uploading Playlist" : "Downloading Playlist"
        }
        return stage == .syncing ? "Uploading" : "Downloading"
    }

    var transferStatus: String {
        switch stage {
        case .inspectingSource:
            "Inspecting source"
        case .downloading:
            "Downloading to this Mac"
        case .processing:
            "Preparing media"
        case .savingLocal:
            "Saving to your library"
        case .localComplete:
            "Saved on this Mac"
        case .syncing:
            "Uploading to \(activeProfileName)"
        default:
            "Preparing transfer"
        }
    }

    var transferDetail: String {
        let trackTitle = batchCurrentTitle
            ?? completedTrack?.title
            ?? resolution?.track.title
            ?? selectedCandidate?.title
            ?? "Import from Link"
        guard stage == .downloading, totalBytes > 0 else { return trackTitle }
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(trackTitle) • \(completed) of \(total)"
    }

    func normalizeMediaModeForSource() {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let textSearch = !value.isEmpty && !LocalImportInput.looksLikeLink(value)
        if (textSearch || LocalImportURL.isSpotify(source) || LocalImportURL.isSoundCloud(source)), mediaMode == .video {
            mediaMode = .audio
        }
    }

    func resolve() {
        guard !isRunning else { return }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            error = .init(stage: .resolvingMetadata, code: "MISSING_SOURCE", message: "Enter a song, artist, album, or supported Spotify, SoundCloud, or YouTube link first.")
            stage = .failed
            return
        }
        stopPreview()
        normalizeMediaModeForSource()
        let requestedMode = mediaMode
        let serverConfiguration = model.localImportServerConfiguration
        task?.cancel()
        error = nil
        previewErrorMessage = nil
        resolution = nil
        searchResponse = nil
        selectedSearchResultID = nil
        selectedVideoID = nil
        selectedPlaylistTrackIDs = []
        selectedReleaseInfoHash = nil
        completedTrack = nil
        releaseActionMessage = nil
        completedSummary = nil
        batchCurrentTitle = nil
        let searchesProviders = !LocalImportInput.looksLikeLink(value)
        stage = searchesProviders ? .searchingCandidates : .resolvingMetadata
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if searchesProviders {
                    let response = try await service.search(query: value)
                    try Task.checkCancellation()
                    await model.refreshRemoteCatalogForLocalImport()
                    try Task.checkCancellation()
                    searchResponse = response
                    guard let first = response.results.first else {
                        throw LocalImportError(
                            stage: .searchingCandidates,
                            code: "NO_SEARCH_RESULTS",
                            message: "Spotify, SoundCloud, and YouTube returned no previewable results for that search."
                        )
                    }
                    selectSearchResult(first)
                    stage = .awaitingSelection
                    task = nil
                    return
                }
                let result = try await service.resolve(
                    source: value,
                    mediaMode: requestedMode,
                    serverConfiguration: serverConfiguration
                ) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                if result.kind != .youtube {
                    await model.refreshRemoteCatalogForLocalImport()
                    try Task.checkCancellation()
                }
                resolution = result
                selectedVideoID = result.candidates.first?.videoID
                selectedPlaylistTrackIDs = Set(result.playlist?.items.map { $0.track.trackID } ?? [])
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

    func selectSearchResult(_ result: LocalImportSearchResult) {
        if previewingVideoID != result.candidates.first?.videoID {
            stopPreview()
        }
        resolution = result.resolution
        selectedSearchResultID = result.id
        selectedVideoID = result.candidates.first?.videoID
        selectedPlaylistTrackIDs = []
        selectedReleaseInfoHash = nil
        releaseActionMessage = nil
        previewErrorMessage = nil
    }

    func toggleSearchPreview(_ result: LocalImportSearchResult) {
        selectSearchResult(result)
        guard let candidate = result.candidates.first else { return }
        togglePreview(candidate)
    }

    @discardableResult
    func importSelected() -> Bool {
        guard !isRunning, let resolution else { return false }
        if isPlaylist {
            return importSelectedPlaylist(resolution)
        }
        guard let candidate = selectedCandidate else { return false }
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
        let existingMatch = existingMatch(for: resolution.track)
        let requestedMode = mediaMode
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var track: Track
                if let deviceTrackID = existingMatch.deviceTrackID,
                   let deviceTrack = model.tracks.first(where: { $0.id == deviceTrackID }) {
                    track = deviceTrack
                } else {
                    let outcome = try await service.importCandidate(
                        candidate,
                        metadata: metadata,
                        existingTracks: model.tracks,
                        mediaMode: requestedMode
                    ) { [weak self] progress in
                        self?.apply(progress)
                    }
                    try Task.checkCancellation()
                    switch outcome {
                    case .created(let imported):
                        track = model.insertLocalImportedAudio(imported)
                    case .duplicate(let id):
                        guard let duplicate = model.tracks.first(where: { $0.id == id }) else {
                            throw LocalImportError(stage: .savingLocal, code: "DUPLICATE_CHANGED", message: "The matching local song changed while the import was running.")
                        }
                        if let artworkData = await service.artworkData(for: metadata.artworkURL),
                           let repaired = model.repairLocalImportArtwork(trackID: id, artworkData: artworkData) {
                            track = repaired
                        } else {
                            track = duplicate
                        }
                    }
                }

                if let serverSongID = existingMatch.serverSongID {
                    model.reconcileUploadedLocalTrack(
                        trackID: track.id,
                        remoteID: serverSongID,
                        profileID: model.syncProfileID
                    )
                    track = model.tracks.first(where: { $0.id == track.id }) ?? track
                }
                completedTrack = track
                stage = .localComplete

                if syncAfterImport, existingMatch.serverSongID == nil {
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
        return true
    }

    func togglePlaylistItem(_ item: LocalImportPlaylistItem) {
        if selectedPlaylistTrackIDs.contains(item.track.trackID) {
            selectedPlaylistTrackIDs.remove(item.track.trackID)
        } else {
            selectedPlaylistTrackIDs.insert(item.track.trackID)
        }
    }

    private func importSelectedPlaylist(_ resolution: LocalImportResolution) -> Bool {
        let items = selectedPlaylistItems
        guard let playlist = resolution.playlist, !items.isEmpty else { return false }
        stopPreview()
        task?.cancel()
        error = nil
        completedBytes = 0
        totalBytes = 0
        completedSummary = nil
        completedTrack = nil
        let initialMatchesByTrackID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.track.trackID, existingMatch(for: $0.track)) }
        )
        let plannedDownloadTransfers = LocalImportBatchProgressPolicy.plannedTransferCount(
            matches: Array(initialMatchesByTrackID.values),
            requiresTransfer: { !$0.isOnDevice }
        )
        batchPhase = plannedDownloadTransfers > 0 ? .downloading : nil
        batchCompletedItems = 0
        batchTotalItems = plannedDownloadTransfers
        stage = .inspectingSource
        let shouldUpload = syncAfterImport
        task = Task { [weak self] in
            guard let self else { return }
            var keptTracks: [Track] = []
            var keptTrackIDs = Set<UUID>()
            var failures: [String] = []
            var uploadFailures: [String] = []
            var uploadedCount = 0
            var skippedDeviceDownloads = 0
            var skippedServerUploads = 0
            var knownServerSongIDsByTrackID: [UUID: String] = [:]
            var completedDownloadTransfers = 0
            var completedUploadTransfers = 0
            var plannedUploadTrackIDs = Set<UUID>()
            defer {
                batchCurrentTitle = nil
                batchPhase = nil
                batchCompletedItems = 0
                batchTotalItems = 0
                task = nil
            }
            do {
                let importedTracks: [Track] = try await LocalImportPlaylistBatchPipeline.run(
                    items: items,
                    download: { _, _, item -> Track? in
                        try Task.checkCancellation()
                        let existingMatch = initialMatchesByTrackID[item.track.trackID]
                            ?? self.existingMatch(for: item.track)
                        var track: Track
                        if let deviceTrackID = existingMatch.deviceTrackID,
                           let deviceTrack = self.model.tracks.first(where: { $0.id == deviceTrackID }) {
                            skippedDeviceDownloads += 1
                            track = deviceTrack
                        } else {
                            let transferIndex = completedDownloadTransfers
                            self.batchPhase = .downloading
                            self.batchCompletedItems = transferIndex
                            self.batchTotalItems = plannedDownloadTransfers
                            self.completedBytes = 0
                            self.totalBytes = 0
                            self.batchCurrentTitle = "\(transferIndex + 1) of \(plannedDownloadTransfers) • \(item.track.title)"
                            defer {
                                completedDownloadTransfers += 1
                                self.batchCompletedItems = completedDownloadTransfers
                            }
                            let outcome: LocalImportOutcome
                            do {
                                outcome = try await LocalImportCandidateFallbackPolicy.firstSuccessful(
                                    candidates: item.downloadCandidates
                                ) { candidate in
                                    let metadata = LocalImportMetadata(
                                        title: item.track.title,
                                        artist: item.track.artist,
                                        album: item.track.album,
                                        artworkURL: item.track.artworkURL ?? candidate.thumbnailURL,
                                        sourceURL: item.track.sourceURL
                                    )
                                    return try await self.service.importCandidate(
                                        candidate,
                                        metadata: metadata,
                                        existingTracks: self.model.tracks,
                                        mediaMode: .audio
                                    ) { [weak self] progress in self?.apply(progress) }
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                failures.append("\(item.track.title) — \(item.track.artist) (\(error.localizedDescription))")
                                return nil
                            }
                            switch outcome {
                            case .created(let imported):
                                track = self.model.insertLocalImportedAudio(imported)
                            case .duplicate(let id):
                                guard let duplicate = self.model.tracks.first(where: { $0.id == id }) else {
                                    failures.append("\(item.track.title) — \(item.track.artist) (the matching local song changed)")
                                    return nil
                                }
                                if let artworkData = await self.service.artworkData(
                                    for: item.track.artworkURL ?? item.candidate.thumbnailURL
                                ),
                                   let repaired = self.model.repairLocalImportArtwork(trackID: id, artworkData: artworkData) {
                                    track = repaired
                                } else {
                                    track = duplicate
                                }
                            }
                        }

                        if let serverSongID = existingMatch.serverSongID {
                            knownServerSongIDsByTrackID[track.id] = serverSongID
                            self.model.reconcileUploadedLocalTrack(
                                trackID: track.id,
                                remoteID: serverSongID,
                                profileID: self.model.syncProfileID
                            )
                            track = self.model.tracks.first(where: { $0.id == track.id }) ?? track
                        }
                        self.completedTrack = self.completedTrack ?? track
                        guard keptTrackIDs.insert(track.id).inserted else { return nil }
                        keptTracks.append(track)
                        return track
                    },
                    beforeUpload: { tracks in
                        self.model.upsertImportedPlaylist(named: playlist.title, tracks: tracks)
                        self.stage = .localComplete
                        guard shouldUpload, !tracks.isEmpty else { return }
                        plannedUploadTrackIDs = Set(
                            tracks.compactMap { track in
                                knownServerSongIDsByTrackID[track.id] == nil ? track.id : nil
                            }
                        )
                        self.batchPhase = plannedUploadTrackIDs.isEmpty ? nil : .uploading
                        self.batchCompletedItems = 0
                        self.batchTotalItems = plannedUploadTrackIDs.count
                        self.completedBytes = 0
                        self.totalBytes = 0
                        if !plannedUploadTrackIDs.isEmpty { self.stage = .syncing }
                    },
                    upload: shouldUpload ? { _, _, track in
                        try Task.checkCancellation()
                        guard plannedUploadTrackIDs.contains(track.id) else {
                            skippedServerUploads += 1
                            return
                        }
                        let transferIndex = completedUploadTransfers
                        self.batchPhase = .uploading
                        self.batchCompletedItems = transferIndex
                        self.batchTotalItems = plannedUploadTrackIDs.count
                        self.batchCurrentTitle = "\(transferIndex + 1) of \(plannedUploadTrackIDs.count) • \(track.title)"
                        defer {
                            completedUploadTransfers += 1
                            self.batchCompletedItems = completedUploadTransfers
                        }
                        var uploaded = false
                        var uploadError: Error?
                        for attempt in 1...3 where !uploaded {
                            do {
                                if attempt > 1 { try await Task.sleep(for: .milliseconds(attempt == 2 ? 400 : 1_200)) }
                                self.stage = .syncing
                                let didUpload = try await self.model.uploadLocalImportToActiveProfile(track)
                                uploaded = true
                                if didUpload {
                                    uploadedCount += 1
                                } else {
                                    skippedServerUploads += 1
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                uploadError = error
                            }
                        }
                        if !uploaded {
                            uploadFailures.append("\(track.title) — \(track.artist) (\(uploadError?.localizedDescription ?? "upload failed"))")
                        }
                    } : nil
                )

                completedSummary = "Imported \(importedTracks.count) of \(items.count) songs into \(playlist.title)."
                if shouldUpload, uploadedCount > 0 {
                    completedSummary = (completedSummary ?? "") + " Uploaded \(uploadedCount) to \(activeProfileName)."
                }
                if skippedDeviceDownloads > 0 {
                    completedSummary = (completedSummary ?? "") + " Skipped \(skippedDeviceDownloads) existing device download\(skippedDeviceDownloads == 1 ? "" : "s")."
                }
                if shouldUpload, skippedServerUploads > 0 {
                    completedSummary = (completedSummary ?? "") + " Skipped \(skippedServerUploads) existing server upload\(skippedServerUploads == 1 ? "" : "s")."
                }
                if !failures.isEmpty || !uploadFailures.isEmpty {
                    var messages: [String] = []
                    if !failures.isEmpty {
                        messages.append("Kept \(importedTracks.count) successful song\(importedTracks.count == 1 ? "" : "s"). Downloads failed after trying available sources: \(failures.joined(separator: "; "))")
                    }
                    if !uploadFailures.isEmpty {
                        messages.append("Server uploads failed after retrying: \(uploadFailures.joined(separator: "; "))")
                    }
                    error = .init(
                        stage: uploadFailures.isEmpty ? .downloading : .syncing,
                        code: failures.isEmpty ? "PLAYLIST_SYNC_PARTIAL_FAILURE" : "PLAYLIST_PARTIAL_FAILURE",
                        message: messages.joined(separator: " ")
                    )
                    stage = .failed
                } else {
                    stage = .complete
                }
            } catch is CancellationError {
                model.upsertImportedPlaylist(named: playlist.title, tracks: keptTracks)
                completedSummary = "Cancelled after keeping \(keptTracks.count) of \(items.count) songs."
                stage = .cancelled
            } catch {
                model.upsertImportedPlaylist(named: playlist.title, tracks: keptTracks)
                self.error = .init(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
        }
        return true
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
        selectedPlaylistTrackIDs = []
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
        completedSummary = nil
        batchCurrentTitle = nil
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
        searchResponse = nil
        selectedSearchResultID = nil
        selectedVideoID = nil
        selectedReleaseInfoHash = nil
        mediaMode = .audio
        syncAfterImport = true
        error = nil
        completedTrack = nil
        releaseActionMessage = nil
        previewErrorMessage = nil
        completedSummary = nil
        batchCurrentTitle = nil
        batchPhase = nil
        batchCompletedItems = 0
        batchTotalItems = 0
    }

    private func apply(_ progress: LocalImportProgress) {
        stage = progress.stage
        completedBytes = progress.completed
        totalBytes = progress.total
    }
}

enum LocalImportCandidatePreviewPolicy {
    static func showsPreviewButtons(
        candidateCount: Int,
        mediaMode: LocalImportMediaMode,
        isPlaylist: Bool = false
    ) -> Bool {
        mediaMode == .audio && (isPlaylist || candidateCount > 1)
    }
}

enum LocalImportPresentationPolicy {
    static func showsGlobalTransfer(for stage: LocalImportStage) -> Bool {
        switch stage {
        case .inspectingSource, .downloading, .processing, .savingLocal, .localComplete, .syncing:
            true
        default:
            false
        }
    }

    static func continuesAfterSheetDismissal(for stage: LocalImportStage) -> Bool {
        showsGlobalTransfer(for: stage)
    }

    static func showsGlobalFailure(
        for stage: LocalImportStage,
        hasCompletedTrack: Bool,
        failedStage: LocalImportStage?
    ) -> Bool {
        stage == .failed && hasCompletedTrack && failedStage == .syncing
    }
}

struct MacLocalImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: MacLocalImportViewModel
    @FocusState private var sourceFocused: Bool

    init(viewModel: MacLocalImportViewModel) {
        self.viewModel = viewModel
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

                    if let searchResponse = viewModel.searchResponse {
                        searchResultList(searchResponse)
                    } else if let resolution = viewModel.resolution {
                        resolvedTrack(resolution.track)
                        if let playlist = resolution.playlist {
                            playlistItemList(playlist)
                        } else if !resolution.candidates.isEmpty {
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
        .onAppear { sourceFocused = true }
        .onDisappear {
            viewModel.stopPreview()
            if !viewModel.continuesAfterSheetDismissal {
                viewModel.cancel()
            }
        }
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
            Text("LINK OR MUSIC SEARCH")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color.appMuted)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.appMuted)
                TextField("Song, artist, album, or supported link", text: $viewModel.source)
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

    private func searchResultList(_ response: LocalImportSearchResponse) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("SEARCH RESULTS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Text("\(response.results.count) previewable")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appViolet)
            }

            ForEach(LocalImportSearchProvider.allCases) { provider in
                let results = viewModel.searchResults(for: provider)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.displayName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.appInk)
                        Spacer()
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                    }
                    .padding(.horizontal, 3)

                    if results.isEmpty {
                        Text("No previewable results.")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.appMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.appLine, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            }
                    } else {
                        ForEach(results) { result in
                            searchResultRow(result)
                        }
                    }
                }
            }

            previewErrorNotice
        }
    }

    private func searchResultRow(_ result: LocalImportSearchResult) -> some View {
        let selected = viewModel.selectedSearchResultID == result.id
        let candidate = result.candidates.first
        return HStack(spacing: 10) {
            Button {
                viewModel.selectSearchResult(result)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.appViolet : Color.appMuted)
                    importArtwork(
                        urlValue: result.track.artworkURL ?? candidate?.thumbnailURL,
                        title: result.track.title,
                        size: 42
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.appInk)
                            .lineLimit(1)
                        Text(searchResultDetails(result))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.appMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(result.provider.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.appViolet)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.appViolet.opacity(0.12), in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let candidate {
                Button {
                    viewModel.toggleSearchPreview(result)
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.055))
                        if viewModel.loadingPreviewVideoID == candidate.videoID {
                            ProgressView().controlSize(.mini).tint(Color.appViolet)
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
                .help(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(result.track.title)")
                .accessibilityLabel(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(result.track.title)")
            }
        }
        .padding(11)
        .background(selected ? Color.appViolet.opacity(0.08) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? Color.appViolet.opacity(0.45) : Color.appLine)
        }
        .disabled(viewModel.isRunning)
    }

    private func searchResultDetails(_ result: LocalImportSearchResult) -> String {
        var values: [String?] = [
            result.track.artist,
            result.track.album,
            result.track.durationSeconds.map { Track.timeText(TimeInterval($0)) },
        ]
        if let candidate = result.candidates.first {
            let previewProvider = candidateProviderName(candidate)
            if previewProvider != result.provider.displayName {
                values.append("Preview via \(previewProvider)")
            }
        }
        return values.compactMap { $0 }.joined(separator: " • ")
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
                if let status = viewModel.existingStatus(for: track) {
                    Text(status)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(13)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func playlistItemList(_ playlist: LocalImportPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("TRACKS TO IMPORT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Color.appMuted)
                Spacer()
                Text("\(viewModel.selectedPlaylistItems.count) of \(playlist.items.count) selected")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appViolet)
            }
            if playlist.unavailableCount > 0 {
                Text("\(playlist.unavailableCount) \(viewModel.playlistProviderName) track\(playlist.unavailableCount == 1 ? "" : "s") will be skipped. Each reason is listed below.")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appMuted)
            }
            if let summary = viewModel.existingSummary(for: playlist) {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.green)
            }
            ForEach(playlist.items) { item in
                let selected = viewModel.selectedPlaylistTrackIDs.contains(item.track.trackID)
                HStack(spacing: 10) {
                    Button { viewModel.togglePlaylistItem(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16))
                                .foregroundStyle(selected ? Color.appViolet : Color.appMuted)
                            Text("\(item.position)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.appMuted)
                                .frame(width: 24, alignment: .trailing)
                            playlistItemArtwork(item)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.track.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.appInk)
                                    .lineLimit(1)
                                Text([item.track.artist, item.track.durationSeconds.map { Track.timeText(TimeInterval($0)) }].compactMap { $0 }.joined(separator: " • "))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appMuted)
                                    .lineLimit(1)
                                if let status = viewModel.existingStatus(for: item.track) {
                                    Text(status)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(Color.green)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                        candidateCount: playlist.items.count,
                        mediaMode: viewModel.mediaMode,
                        isPlaylist: true
                    ) {
                        previewButton(item.candidate)
                    }
                }
                .padding(12)
                .background(selected ? Color.appViolet.opacity(0.08) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(selected ? Color.appViolet.opacity(0.45) : Color.appLine)
                }
                .disabled(viewModel.isRunning)
            }

            if !playlist.skippedItems.isEmpty {
                Text("SKIPPED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Color.appAccent)
                    .padding(.top, 5)

                ForEach(playlist.skippedItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.appAccent)
                        Text("\(item.position)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.appMuted)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.appInk)
                                .lineLimit(1)
                            Text([item.artist, item.reason].compactMap { $0 }.joined(separator: " • "))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.appAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.appAccent.opacity(0.22))
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            previewErrorNotice
        }
    }

    private func resolvedArtwork(_ track: LocalImportSpotifyTrack) -> some View {
        importArtwork(urlValue: track.artworkURL, title: track.title, size: 58)
    }

    private func playlistItemArtwork(_ item: LocalImportPlaylistItem) -> some View {
        importArtwork(
            urlValue: item.track.artworkURL ?? item.candidate.thumbnailURL,
            title: item.track.title,
            size: 42
        )
    }

    private func importArtwork(urlValue: String?, title: String, size: CGFloat) -> some View {
        let artworkURL = LocalImportURL.youtubeArtwork(urlValue)
            ?? LocalImportURL.spotifyArtwork(urlValue)
            ?? LocalImportURL.soundCloudArtwork(urlValue)
        return Group {
            if let artworkURL {
                CroppedRemoteArtwork(url: artworkURL) { isLoading in
                    resolvedArtworkFallback
                        .overlay {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(Color.white.opacity(0.65))
                            }
                        }
                }
            } else {
                resolvedArtworkFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
        .accessibilityLabel("\(title) artwork")
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
                                Text([candidate.artist ?? "Unknown uploader", candidate.durationSeconds.map { Track.timeText(TimeInterval($0)) }, candidateProviderName(candidate)].compactMap { $0 }.joined(separator: " • "))
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
                        previewButton(candidate)
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

            previewErrorNotice
        }
    }

    @ViewBuilder
    private var previewErrorNotice: some View {
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

    private func previewButton(_ candidate: LocalImportAudioSourceMatch) -> some View {
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
            if (viewModel.selectedCandidate != nil || !viewModel.selectedPlaylistItems.isEmpty), viewModel.completedTrack == nil {
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
                    Button {
                        if viewModel.importSelected() {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 24, height: 18)
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appViolet)
                        .disabled(viewModel.isPlaylist ? viewModel.selectedPlaylistItems.isEmpty : viewModel.selectedCandidate == nil)
                        .help(viewModel.isPlaylist ? "Import Selected Playlist Songs" : viewModel.mediaMode == .video ? "Download Video" : "Save Audio on This Mac")
                        .accessibilityLabel(viewModel.isPlaylist ? "Import Selected Playlist Songs" : viewModel.mediaMode == .video ? "Download Video" : "Save Audio on This Mac")
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
        case .idle: ("Ready", "Paste a supported link, or enter a song, artist, or album to search.", "link", Color.appViolet)
        case .resolvingMetadata: ("Resolving metadata", "This link lookup runs directly from your Mac.", "magnifyingglass", Color.appViolet)
        case .searchingCandidates: (
            !LocalImportInput.looksLikeLink(viewModel.source) ? "Searching music platforms" : "Searching audio sources",
            !LocalImportInput.looksLikeLink(viewModel.source)
                ? "Querying Spotify, SoundCloud, and YouTube for previewable results."
                : viewModel.isPlaylist ? "Matching each public playlist track to a direct or alternate audio source." : "Finding direct and alternate audio sources.",
            "waveform.badge.magnifyingglass",
            Color.appViolet
        )
        case .awaitingSelection: (
            viewModel.selectedRelease != nil ? "Choose a release file" : "Ready to download",
            viewModel.selectedRelease != nil
                ? "Open the external release, choose its exact audio file, then use Import Files."
                : viewModel.isPlaylist ? "Choose the playlist songs to save in order." : "Save the selected source as \(mediaName).",
            "checkmark.circle",
            Color.appViolet
        )
        case .inspectingSource: (
            "Inspecting \(mediaName)",
            viewModel.mediaMode == .video
                ? "Checking for a direct, verifiable MP4 stream with video and audio."
                : "Checking for a direct, verifiable audio stream.",
            "doc.text.magnifyingglass",
            Color.appViolet
        )
        case .downloading: ("Downloading to this Mac", "Every expected byte range is verified while it is written.", "arrow.down.circle", Color.appViolet)
        case .processing: ("Preparing \(mediaName)", "Converting when needed and attaching available metadata.", "slider.horizontal.3", Color.appViolet)
        case .savingLocal: ("Saving locally", "Adding the completed file to this Mac's Resonance library.", "internaldrive", Color.appViolet)
        case .localComplete: ("Saved on this Mac", "This \(mediaName) remains visible when server profiles change.", "checkmark.circle.fill", Color.green)
        case .syncing: ("Uploading optional copy", "Sending the local file only to the currently active profile.", "arrow.up.circle", Color.appViolet)
        case .complete: ("Import complete", viewModel.completedSummary ?? "The \(mediaName) is ready in your local Resonance library.", "checkmark.circle.fill", Color.green)
        case .failed: ("Import stopped", "Review the stage-specific error below.", "exclamationmark.triangle", Color.appAccent)
        case .cancelled: ("Import cancelled", "No partial song was added to the library.", "xmark.circle", Color.appMuted)
        }
    }

    private func candidateProviderName(_ candidate: LocalImportAudioSourceMatch) -> String {
        switch candidate.sourceProvider {
        case .soundcloud: "SoundCloud"
        case .youtubeMusic: "YouTube Music"
        case .youtube: "YouTube"
        }
    }

    private func stageLabel(_ stage: LocalImportStage) -> String {
        stage.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
