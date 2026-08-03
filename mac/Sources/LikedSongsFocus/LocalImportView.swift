import SwiftUI

@MainActor
final class MacLocalImportViewModel: ObservableObject {
    @Published var source = ""
    @Published private(set) var stage: LocalImportStage = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var resolution: LocalImportResolution?
    @Published var selectedVideoID: String?
    @Published var syncAfterImport = false
    @Published private(set) var error: LocalImportError?
    @Published private(set) var completedTrack: Track?

    private let model: PlayerModel
    private let service: LocalDeviceImportService
    private var task: Task<Void, Never>?

    init(model: PlayerModel, service: LocalDeviceImportService = LocalDeviceImportService()) {
        self.model = model
        self.service = service
    }

    var isRunning: Bool {
        switch stage {
        case .resolvingMetadata, .searchingCandidates, .inspectingSource, .downloading, .processing, .savingLocal, .syncing:
            true
        default:
            false
        }
    }

    var selectedCandidate: LocalImportAudioSourceMatch? {
        guard let selectedVideoID else { return resolution?.candidates.first }
        return resolution?.candidates.first { $0.videoID == selectedVideoID }
    }

    var canSync: Bool {
        !model.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeProfileName: String {
        model.syncProfiles.first(where: { $0.id == model.syncProfileID })?.name ?? model.syncProfileID
    }

    func resolve() {
        guard !isRunning else { return }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            error = .init(stage: .resolvingMetadata, code: "MISSING_SOURCE", message: "Paste a Spotify track or YouTube video URL first.")
            stage = .failed
            return
        }
        task?.cancel()
        error = nil
        resolution = nil
        selectedVideoID = nil
        completedTrack = nil
        stage = .resolvingMetadata
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.resolve(source: value) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                resolution = result
                selectedVideoID = result.candidates.first?.videoID
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
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await service.importCandidate(
                    candidate,
                    metadata: metadata,
                    existingTracks: existing
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

    func cancel() {
        task?.cancel()
        task = nil
        stage = .cancelled
    }

    func reset() {
        cancel()
        source = ""
        stage = .idle
        completedBytes = 0
        totalBytes = 0
        resolution = nil
        selectedVideoID = nil
        syncAfterImport = false
        error = nil
        completedTrack = nil
    }

    private func apply(_ progress: LocalImportProgress) {
        stage = progress.stage
        completedBytes = progress.completed
        totalBytes = progress.total
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
                    stageCard

                    if let resolution = viewModel.resolution {
                        resolvedTrack(resolution.track)
                        candidateList(resolution.candidates)
                        syncOption
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
        .onDisappear { viewModel.cancel() }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appViolet)
                .frame(width: 38, height: 38)
                .background(Color.appViolet.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Import from Link")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Spotify metadata and permitted YouTube audio are resolved on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
            }

            Spacer()

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
        .padding(.horizontal, 22)
        .frame(height: 78)
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
                    .onSubmit(viewModel.resolve)
                    .disabled(viewModel.isRunning)

                Button("Find Audio", action: viewModel.resolve)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appViolet)
                    .controlSize(.regular)
                    .disabled(viewModel.isRunning || viewModel.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

                if viewModel.stage == .downloading, viewModel.totalBytes > 0 {
                    ProgressView(value: Double(viewModel.completedBytes), total: Double(viewModel.totalBytes))
                        .progressViewStyle(.linear)
                        .tint(Color.appViolet)
                    Text("\(ByteCountFormatter.string(fromByteCount: viewModel.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.appLine) }
    }

    private func resolvedTrack(_ track: LocalImportSpotifyTrack) -> some View {
        HStack(spacing: 13) {
            ZStack {
                LinearGradient(
                    colors: [Color.appViolet.opacity(0.28), Color.appAccent.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.appViolet)
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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

    private func candidateList(_ candidates: [LocalImportAudioSourceMatch]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CONFIRM AUDIO SOURCE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color.appMuted)

            ForEach(candidates) { candidate in
                Button {
                    viewModel.selectedVideoID = candidate.videoID
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
                    .padding(12)
                    .background(
                        viewModel.selectedCandidate?.videoID == candidate.videoID ? Color.appViolet.opacity(0.08) : Color.white.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(viewModel.selectedCandidate?.videoID == candidate.videoID ? Color.appViolet.opacity(0.45) : Color.appLine)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var syncOption: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: $viewModel.syncAfterImport) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Upload a copy to \(viewModel.activeProfileName)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(viewModel.canSync
                        ? "Optional. Local success is kept even if the profile upload fails."
                        : "Add a server URL, access token, and admin key in Settings to enable optional upload.")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appMuted)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.appViolet)
            .disabled(!viewModel.canSync || viewModel.isRunning)
        }
        .padding(13)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        HStack {
            if viewModel.isRunning {
                Button("Cancel", action: viewModel.cancel)
                    .buttonStyle(.bordered)
            } else if viewModel.stage == .complete || (viewModel.stage == .failed && viewModel.completedTrack != nil) {
                Button("Import Another", action: viewModel.reset)
                    .buttonStyle(.bordered)
            }

            Spacer()

            if viewModel.stage == .awaitingSelection || viewModel.stage == .failed && viewModel.resolution != nil && viewModel.completedTrack == nil {
                Button("Save on This Mac", action: viewModel.importSelected)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appViolet)
                    .disabled(viewModel.selectedCandidate == nil)
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
        switch stage {
        case .idle: ("Ready", "Paste one Spotify track or YouTube video URL.", "link", Color.appViolet)
        case .resolvingMetadata: ("Resolving metadata", "This lookup runs directly from your Mac.", "magnifyingglass", Color.appViolet)
        case .searchingCandidates: ("Searching audio sources", "Ranking YouTube Music and YouTube results by metadata and duration.", "waveform.badge.magnifyingglass", Color.appViolet)
        case .awaitingSelection: ("Choose a source", "Confirm the match before Resonance downloads anything.", "checkmark.circle", Color.appViolet)
        case .inspectingSource: ("Inspecting source", "Checking for a direct, verifiable M4A audio stream.", "doc.text.magnifyingglass", Color.appViolet)
        case .downloading: ("Downloading to this Mac", "Every expected byte range is verified while it is written.", "arrow.down.circle", Color.appViolet)
        case .processing: ("Applying metadata", "Remuxing without transcoding and attaching available artwork.", "slider.horizontal.3", Color.appViolet)
        case .savingLocal: ("Saving locally", "Adding the completed file to this Mac's Resonance library.", "internaldrive", Color.appViolet)
        case .localComplete: ("Saved on this Mac", "This song remains visible when server profiles change.", "checkmark.circle.fill", Color.green)
        case .syncing: ("Uploading optional copy", "Sending the local file only to the currently active profile.", "arrow.up.circle", Color.appViolet)
        case .complete: ("Import complete", "The song is ready in your local Resonance library.", "checkmark.circle.fill", Color.green)
        case .failed: ("Import stopped", "Review the stage-specific error below.", "exclamationmark.triangle", Color.appAccent)
        case .cancelled: ("Import cancelled", "No partial song was added to the library.", "xmark.circle", Color.appMuted)
        }
    }

    private func stageLabel(_ stage: LocalImportStage) -> String {
        stage.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}
