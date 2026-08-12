import SwiftUI
import UIKit

struct MobileLocalImportSheet: View {
    @Environment(\.resonancePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @StateObject private var viewModel = MobileLocalImportViewModel()
    @FocusState private var sourceFocused: Bool
    var reviewedServerMatch = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search or Link").sectionLabel()
                            HStack(spacing: 8) {
                                TextField("Song, artist, album, or link", text: $viewModel.source)
                                    .focused($sourceFocused)
                                    .submitLabel(.search)
                                    .onSubmit {
                                        viewModel.resolve(
                                            using: library,
                                            reviewedServerMatch: reviewedServerMatch
                                        )
                                    }
                                    .keyboardType(.default)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(13)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                    .disabled(viewModel.isRunning)
                                Button("Paste") {
                                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                                        viewModel.source = pasted
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isRunning)
                            }
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Download As").sectionLabel()
                            Picker("Download as", selection: Binding(
                                get: { viewModel.mediaMode },
                                set: { mode in
                                    viewModel.mediaMode = mode
                                    viewModel.normalizeMediaModeForSource()
                                }
                            )) {
                                ForEach(LocalImportMediaMode.allCases) { mode in
                                    Label(
                                        mode.title,
                                        systemImage: mode == .video ? "play.rectangle.fill" : "music.note"
                                    )
                                    .tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(viewModel.isRunning)
                            Text("Spotify and SoundCloud links import audio only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if reviewedServerMatch {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reviewed server upload")
                                    .font(.subheadline.weight(.semibold))
                                Text("Choose one reviewed source to download and register with the server.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                        } else {
                            Toggle(isOn: $viewModel.syncAfterImport) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Upload after downloading")
                                        .font(.subheadline.weight(.semibold))
                                    Text(library.canUploadLocalImports
                                         ? "Upload imported songs to \(library.visibleSyncProfileName)."
                                         : "Sign in first, or turn this off for a local-only import.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(palette.secondary)
                        }

                        stageCard

                        if let response = viewModel.searchResponse {
                            searchResultList(response)
                        } else if let resolution = viewModel.resolution {
                            resolvedTrack(resolution.track)
                            if let playlist = resolution.playlist {
                                playlistItemList(playlist)
                            } else {
                                candidateList(resolution.candidates)
                            }
                        }

                        if let error = viewModel.error {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Import failed")
                                    .font(.headline)
                                Text(error.message).font(.subheadline)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        }
                        if let previewError = viewModel.previewError {
                            Text(previewError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(reviewedServerMatch ? "Reviewed Match" : "Import from Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if !viewModel.continuesAfterSheetDismissal { viewModel.cancel() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.resolution == nil {
                        Button(viewModel.resolveButtonTitle) {
                            viewModel.resolve(
                                using: library,
                                reviewedServerMatch: reviewedServerMatch
                            )
                        }
                            .disabled(viewModel.isRunning)
                    } else {
                        Button("Import") {
                            if viewModel.importSelected(
                                into: library,
                                reviewedServerMatch: reviewedServerMatch
                            ) { dismiss() }
                        }
                            .disabled(
                                viewModel.isRunning
                                    || (viewModel.isPlaylist
                                        ? viewModel.selectedPlaylistItems.isEmpty
                                        : viewModel.selectedCandidate == nil)
                            )
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { sourceFocused = false }
                }
            }
        }
        .onAppear {
            if reviewedServerMatch { viewModel.syncAfterImport = true }
            sourceFocused = true
        }
        .onDisappear {
            viewModel.stopPreview()
            if !viewModel.continuesAfterSheetDismissal { viewModel.cancel() }
        }
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stageSymbol(viewModel.stage)).foregroundStyle(palette.foregroundAccent)
                Text(stageTitle(viewModel.stage, mediaMode: viewModel.mediaMode)).font(.headline)
                Spacer()
                if viewModel.isRunning { ProgressView() }
            }
            Text(stageDetail(viewModel.stage, mediaMode: viewModel.mediaMode))
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.totalBytes > 0 {
                ProgressView(value: Double(viewModel.completedBytes), total: Double(viewModel.totalBytes))
                    .tint(palette.foregroundAccent)
                let completed = ByteCountFormatter.string(
                    fromByteCount: viewModel.completedBytes,
                    countStyle: .file
                )
                let total = ByteCountFormatter.string(
                    fromByteCount: viewModel.totalBytes,
                    countStyle: .file
                )
                Text("\(completed) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let track = viewModel.completedTrack {
                Text("Added “\(track.title)” to this device.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            if let summary = viewModel.completedSummary {
                Text(summary).font(.subheadline).foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func searchResultList(_ response: LocalImportSearchResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search Results").sectionLabel()
                Spacer()
                Text("\(response.results.count) \(viewModel.mediaMode == .video ? "downloadable" : "previewable")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.foregroundAccent)
            }

            ForEach(LocalImportSearchProvider.allCases) { provider in
                let results = viewModel.searchResults(for: provider)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.displayName).sectionLabel()
                        Spacer()
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if results.isEmpty {
                        Text(viewModel.mediaMode == .video ? "No downloadable videos." : "No previewable results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                    } else {
                        ForEach(results) { result in
                            searchResultRow(result)
                        }
                    }
                }
            }
        }
    }

    private func searchResultRow(_ result: LocalImportSearchResult) -> some View {
        let selected = viewModel.selectedSearchResultID == result.id
        let candidate = result.candidates.first
        return HStack(spacing: 9) {
            Button {
                viewModel.selectSearchResult(result)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(palette.foregroundAccent)
                    searchResultArtwork(result)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(searchResultDetails(result))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let status = viewModel.existingStatus(for: result.track, in: library) {
                            Text(status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(result.track.title)")
            .accessibilityValue(selected ? "Selected" : "Not selected")

            if let candidate {
                Button { viewModel.toggleSearchPreview(result) } label: {
                    if viewModel.previewLoadingVideoID == candidate.videoID {
                        ProgressView().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: viewModel.previewingVideoID == candidate.videoID ? "stop.fill" : "play.fill")
                            .frame(width: 34, height: 34)
                            .background(palette.secondary.opacity(0.18), in: Circle())
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(result.track.title)")
            }
        }
        .padding(12)
        .background(.white.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? palette.secondary.opacity(0.45) : Color.white.opacity(0.05))
        }
        .disabled(viewModel.isRunning)
    }

    private func searchResultArtwork(_ result: LocalImportSearchResult) -> some View {
        let artworkURL = (result.track.artworkURL ?? result.candidates.first?.thumbnailURL).flatMap(URL.init(string:))
        return ZStack {
            palette.secondary.opacity(0.42)
            Image(systemName: viewModel.mediaMode == .video ? "play.rectangle.fill" : "music.note")
                .foregroundStyle(.white.opacity(0.8))
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private func searchResultDetails(_ result: LocalImportSearchResult) -> String {
        var values: [String?] = [
            result.track.artist,
            result.track.album,
            result.track.durationSeconds.map { formatTime(TimeInterval($0)) },
            result.provider.displayName,
        ]
        if let candidate = result.candidates.first {
            let previewProvider = sourceProviderName(candidate.sourceProvider)
            if previewProvider != result.provider.displayName {
                values.append("Preview via \(previewProvider)")
            }
        }
        return values.compactMap { $0 }.joined(separator: " • ")
    }

    private func resolvedTrack(_ track: LocalImportSpotifyTrack) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Matched Track").sectionLabel()
            Text(track.title).font(.title3.bold())
            Text([track.artist, track.album].compactMap { $0 }.joined(separator: " • "))
                .foregroundStyle(.secondary)
            if let duration = track.durationSeconds {
                Text(formatTime(TimeInterval(duration))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let status = viewModel.existingStatus(for: track, in: library) {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func candidateList(_ candidates: [LocalImportAudioSourceMatch]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(viewModel.mediaMode == .video ? "Video Source" : "Audio Source").sectionLabel()
            ForEach(candidates) { candidate in
                HStack(spacing: 8) {
                    Button {
                        viewModel.selectCandidate(candidate)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: viewModel.selectedVideoID == candidate.videoID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(palette.foregroundAccent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text([
                                    candidate.artist ?? "Unknown uploader",
                                    candidate.durationSeconds.map { formatTime(TimeInterval($0)) },
                                    sourceProviderName(candidate.sourceProvider)
                                ].compactMap { $0 }.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(candidate.title)")
                    .accessibilityValue(
                        viewModel.selectedVideoID == candidate.videoID ? "Selected" : "Not selected"
                    )

                    Button { viewModel.togglePreview(candidate) } label: {
                        if viewModel.previewLoadingVideoID == candidate.videoID {
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            Image(systemName: viewModel.previewingVideoID == candidate.videoID ? "stop.fill" : "play.fill")
                                .frame(width: 32, height: 32)
                                .background(palette.secondary.opacity(0.18), in: Circle())
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.previewingVideoID == candidate.videoID ? "Stop preview" : "Preview \(candidate.title)")
                }
                .padding(12)
                .background(.white.opacity(viewModel.selectedVideoID == candidate.videoID ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func playlistItemList(_ playlist: LocalImportPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Tracks to Import").sectionLabel()
                Spacer()
                Text("\(viewModel.selectedPlaylistItems.count) of \(playlist.items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.foregroundAccent)
            }
            if playlist.unavailableCount > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Skipped Items").sectionLabel()
                    ForEach(playlist.skippedItems) { skipped in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(skipped.position). \(skipped.title)\(skipped.artist.map { " — \($0)" } ?? "")")
                                .font(.caption.weight(.semibold))
                            Text(skipped.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(playlist.items) { item in
                let selected = viewModel.selectedPlaylistTrackIDs.contains(item.track.trackID)
                HStack(spacing: 8) {
                    Button { viewModel.togglePlaylistItem(item) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(palette.foregroundAccent)
                            Text("\(item.position)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                            playlistItemArtwork(item)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.track.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                let metadata = [
                                    item.track.artist,
                                    item.track.durationSeconds.map { formatTime(TimeInterval($0)) },
                                ]
                                    .compactMap { $0 }
                                    .joined(separator: " • ")
                                Text(metadata)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let status = viewModel.existingStatus(for: item.track, in: library) {
                                    Text(status)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toggle \(item.track.title)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")

                    Button { viewModel.togglePreview(item.candidate) } label: {
                        if viewModel.previewLoadingVideoID == item.candidate.videoID {
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            Image(systemName: viewModel.previewingVideoID == item.candidate.videoID ? "stop.fill" : "play.fill")
                                .frame(width: 32, height: 32)
                                .background(palette.secondary.opacity(0.18), in: Circle())
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.previewingVideoID == item.candidate.videoID ? "Stop preview" : "Preview \(item.track.title)")
                }
                .padding(12)
                .background(.white.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                .disabled(viewModel.isRunning)
            }
        }
    }

    private func playlistItemArtwork(_ item: LocalImportPlaylistItem) -> some View {
        let artworkURL = (item.track.artworkURL ?? item.candidate.thumbnailURL).flatMap(URL.init(string:))
        return ZStack {
            palette.secondary.opacity(0.42)
            Image(systemName: "music.note")
                .foregroundStyle(.white.opacity(0.8))
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

private func stageTitle(
    _ stage: LocalImportStage,
    mediaMode: LocalImportMediaMode = .audio
) -> String {
    switch stage {
    case .idle: "Ready"
    case .resolvingMetadata: "Resolving Metadata"
    case .searchingCandidates: mediaMode == .video ? "Searching Video Sources" : "Searching Audio Sources"
    case .awaitingSelection: mediaMode == .video ? "Choose a Video Source" : "Choose an Audio Source"
    case .inspectingSource: "Inspecting Source"
    case .downloading: "Downloading"
    case .processing: mediaMode == .video ? "Processing Video" : "Processing Audio"
    case .savingLocal: "Saving on Device"
    case .localComplete, .complete: "Import Complete"
    case .syncing: "Syncing"
    case .failed: "Import Failed"
    case .cancelled: "Cancelled"
    }
}

private func stageDetail(
    _ stage: LocalImportStage,
    mediaMode: LocalImportMediaMode = .audio
) -> String {
    switch stage {
    case .idle: "Search by name or paste a supported link."
    case .resolvingMetadata: "Reading song details."
    case .searchingCandidates: mediaMode == .video
        ? "Finding a downloadable video."
        : "Finding an audio source."
    case .awaitingSelection: "Choose the \(mediaMode.rawValue) to import."
    case .inspectingSource: "Checking the selected source."
    case .downloading: "Saving \(mediaMode.rawValue) to this device."
    case .processing: mediaMode == .video
        ? "Preparing the video file."
        : "Adding song details and artwork."
    case .savingLocal: "Adding the file to Resonance."
    case .localComplete, .complete: "Ready to play."
    case .syncing: "Uploading the local import to the active profile."
    case .failed: "Review the error below and try another source."
    case .cancelled: "No unfinished import was kept."
    }
}

private func sourceProviderName(_ provider: LocalImportAudioSourceMatch.Provider) -> String {
    switch provider {
    case .youtubeMusic: "YouTube Music"
    case .youtube: "YouTube"
    case .soundcloud: "SoundCloud"
    }
}

private func stageSymbol(_ stage: LocalImportStage) -> String {
    switch stage {
    case .idle: "link.badge.plus"
    case .resolvingMetadata, .searchingCandidates: "waveform.badge.magnifyingglass"
    case .awaitingSelection: "checklist"
    case .inspectingSource: "checkmark.shield"
    case .downloading: "arrow.down.circle"
    case .processing: "slider.horizontal.3"
    case .savingLocal: "externaldrive"
    case .localComplete, .complete: "checkmark.circle.fill"
    case .syncing: "arrow.triangle.2.circlepath"
    case .failed: "exclamationmark.triangle"
    case .cancelled: "xmark.circle"
    }
}
