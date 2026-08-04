import AVFoundation
import SwiftUI

@MainActor
private final class MobileClipPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var end: TimeInterval = 0

    func toggle(url: URL, start: TimeInterval, end: TimeInterval, volume: Double) {
        if isPlaying {
            stop()
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.volume = Float(volume)
            next.currentTime = min(max(start, 0), next.duration)
            self.end = min(max(end, next.currentTime), next.duration)
            guard self.end - next.currentTime >= 0.25, next.play() else { return }
            player = next
            isPlaying = true
            let previewTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    if !player.isPlaying || player.currentTime + 0.02 >= self.end {
                        self.stop()
                    }
                }
            }
            timer = previewTimer
            RunLoop.main.add(previewTimer, forMode: .common)
        } catch {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}

struct MobileClipEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @StateObject private var preview = MobileClipPreviewPlayer()
    @State private var selectedTrackID: UUID?
    @State private var startSeconds: TimeInterval = 0
    @State private var endSeconds: TimeInterval = 1
    @State private var startText = "0:00"
    @State private var endText = "0:01"
    @State private var wasPlayingBeforePreview = false
    @FocusState private var focusedBoundary: ClipBoundary?

    private enum ClipBoundary: Hashable { case start, end }

    private var selectedTrack: MobileTrack? {
        guard let selectedTrackID else { return nil }
        return library.tracksForActiveProfile.first { $0.id == selectedTrackID }
            ?? library.tracks.first { $0.id == selectedTrackID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if library.tracksForActiveProfile.isEmpty {
                            ContentUnavailableView(
                                "No songs to edit",
                                systemImage: "waveform",
                                description: Text("Import or download a song, then return to set its playback range.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else {
                            trackPicker
                            if let track = selectedTrack {
                                trackSummary(track)
                                waveform(track)
                                timeFields(track)
                                Text("The range is saved for \(library.syncProfileName). The song file is never changed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                controls(track)
                            }
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Clip Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        commit(focusedBoundary ?? .end)
                        focusedBoundary = nil
                    }
                }
            }
        }
        .onAppear {
            selectedTrackID = library.currentTrack?.id ?? library.tracksForActiveProfile.first?.id
            resetRange()
        }
        .onChange(of: selectedTrackID) {
            stopPreview(resumeMain: true)
            resetRange()
        }
        .onDisappear { stopPreview(resumeMain: true) }
    }

    private var trackPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SONG").eyebrow()
            Picker("Song", selection: $selectedTrackID) {
                ForEach(library.tracksForActiveProfile) { track in
                    Text("\(track.title) — \(track.artist)").tag(Optional(track.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private func trackSummary(_ track: MobileTrack) -> some View {
        HStack(spacing: 12) {
            TrackArtwork(track: track, fallbackSymbol: "music.note")
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.headline).lineLimit(1)
                Text("\(track.artist) • \(track.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatTime(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func waveform(_ track: MobileTrack) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(track.duration, 0.25)
            let startRatio = startSeconds / duration
            let endRatio = endSeconds / duration
            ZStack {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(waveformLevels(for: track).enumerated()), id: \.offset) { index, level in
                        let ratio = (Double(index) + 0.5) / 72
                        Capsule()
                            .fill(ratio >= startRatio && ratio <= endRatio ? Color.violet : .white.opacity(0.16))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18 + 54 * level)
                    }
                }
                .padding(.horizontal, 8)

                clipHandle(symbol: "chevron.right", x: min(max(width * startRatio, 13), width - 13), accessibilityName: "Clip start")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clip-waveform")).onChanged {
                        setBoundary(.start, seconds: Double($0.location.x / width) * duration)
                    })
                clipHandle(symbol: "chevron.left", x: min(max(width * endRatio, 13), width - 13), accessibilityName: "Clip end")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clip-waveform")).onChanged {
                        setBoundary(.end, seconds: Double($0.location.x / width) * duration)
                    })
            }
            .coordinateSpace(name: "clip-waveform")
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .frame(height: 104)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clip waveform")
    }

    private func clipHandle(symbol: String, x: CGFloat, accessibilityName: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 26, height: 38)
            .background(Color.violet, in: Capsule())
            .shadow(color: Color.violet.opacity(0.35), radius: 8)
            .position(x: x, y: 52)
            .accessibilityLabel(accessibilityName)
    }

    private func timeFields(_ track: MobileTrack) -> some View {
        HStack(spacing: 12) {
            timeField("START", text: $startText, boundary: .start)
            VStack(spacing: 5) {
                Text("CLIP LENGTH").eyebrow()
                Text(formatTime(max(endSeconds - startSeconds, 0)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.violet)
            }
            .frame(maxWidth: .infinity)
            timeField("END", text: $endText, boundary: .end)
        }
        .onChange(of: track.id) { resetRange() }
    }

    private func timeField(_ label: String, text: Binding<String>, boundary: ClipBoundary) -> some View {
        VStack(alignment: boundary == .start ? .leading : .trailing, spacing: 5) {
            Text(label).eyebrow()
            TextField(label, text: text)
                .focused($focusedBoundary, equals: boundary)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(boundary == .start ? .leading : .trailing)
                .font(.headline.monospacedDigit())
                .onSubmit { commit(boundary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func controls(_ track: MobileTrack) -> some View {
        VStack(spacing: 12) {
            Button {
                if preview.isPlaying {
                    stopPreview(resumeMain: true)
                } else {
                    wasPlayingBeforePreview = library.isPlaying
                    if wasPlayingBeforePreview { library.pausePlayback() }
                    preview.toggle(
                        url: library.fileURL(for: track),
                        start: startSeconds,
                        end: endSeconds,
                        volume: library.volume
                    )
                }
            } label: {
                Label(preview.isPlaying ? "Stop Preview" : "Preview Range", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack {
                if library.clipRange(for: track) != nil {
                    Button("Use Full Song") {
                        stopPreview(resumeMain: true)
                        library.clearClipRange(for: track)
                        resetRange()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Save Range") {
                    focusedBoundary = nil
                    stopPreview(resumeMain: true)
                    library.saveClipRange(for: track, start: startSeconds, end: endSeconds)
                }
                .buttonStyle(.borderedProminent)
                .tint(.violet)
            }
        }
    }

    private func setBoundary(_ boundary: ClipBoundary, seconds: TimeInterval) {
        guard let track = selectedTrack else { return }
        preview.stop()
        let value = min(max(seconds, 0), track.duration)
        if boundary == .start {
            startSeconds = min(value, endSeconds - 0.25)
        } else {
            endSeconds = max(startSeconds + 0.25, value)
        }
        updateTexts()
    }

    private func commit(_ boundary: ClipBoundary) {
        let text = boundary == .start ? startText : endText
        guard let seconds = parseTime(text) else {
            updateTexts()
            return
        }
        setBoundary(boundary, seconds: seconds)
    }

    private func resetRange() {
        guard let track = selectedTrack else { return }
        let saved = library.clipRange(for: track)
        let defaultStart: TimeInterval = track.duration > 60 ? 15 : 0
        startSeconds = saved?.startSeconds ?? defaultStart
        endSeconds = saved?.endSeconds ?? min(track.duration, defaultStart + 45)
        if endSeconds - startSeconds < 0.25 {
            startSeconds = 0
            endSeconds = max(track.duration, 0.25)
        }
        updateTexts()
    }

    private func updateTexts() {
        startText = formatTime(startSeconds)
        endText = formatTime(endSeconds)
    }

    private func stopPreview(resumeMain: Bool) {
        let shouldResume = resumeMain && wasPlayingBeforePreview
        preview.stop()
        wasPlayingBeforePreview = false
        if shouldResume { library.resumePlayback() }
    }

    private func waveformLevels(for track: MobileTrack) -> [Double] {
        var seed = UInt64(abs(track.id.uuidString.hashValue)) | 1
        var previous = 0.58
        return (0..<72).map { index in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed & 0xffff) / Double(0xffff)
            previous = previous * 0.54 + noise * 0.46
            let envelope = 0.58 + sin(Double(index) * 0.083) * 0.16 + sin(Double(index) * 0.029) * 0.11
            return min(max(previous * 0.62 + envelope * 0.38, 0.12), 1)
        }
    }
}

@MainActor
private final class MobileLocalImportViewModel: ObservableObject {
    @Published var source = ""
    @Published private(set) var stage: LocalImportStage = .idle
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var resolution: LocalImportResolution?
    @Published var selectedVideoID: String?
    @Published private(set) var error: LocalImportError?
    @Published private(set) var completedTrack: MobileTrack?

    private let service = LocalDeviceImportService()
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch stage {
        case .resolvingMetadata, .searchingCandidates, .inspectingSource, .downloading, .processing, .savingLocal:
            true
        default:
            false
        }
    }

    var selectedCandidate: LocalImportAudioSourceMatch? {
        guard let selectedVideoID else { return resolution?.candidates.first }
        return resolution?.candidates.first { $0.videoID == selectedVideoID }
    }

    func resolve() {
        guard !isRunning else { return }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            error = LocalImportError(stage: .resolvingMetadata, code: "MISSING_SOURCE", message: "Paste a Spotify track or YouTube video URL first.")
            stage = .failed
            return
        }
        task?.cancel()
        error = nil
        resolution = nil
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
                self.error = LocalImportError(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
            task = nil
        }
    }

    func importSelected(into library: MusicLibrary) {
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
        let existing = library.tracks
        task = Task { [weak self, weak library] in
            guard let self, let library else { return }
            do {
                let outcome = try await service.importCandidate(
                    candidate,
                    metadata: metadata,
                    existingTracks: existing
                ) { [weak self] progress in
                    self?.apply(progress)
                }
                try Task.checkCancellation()
                switch outcome {
                case .created(let imported):
                    completedTrack = try library.insertLocalImportedAudio(imported)
                case .duplicate(let id):
                    completedTrack = library.tracks.first { $0.id == id }
                }
                stage = .complete
            } catch is CancellationError {
                stage = .cancelled
            } catch let failure as LocalImportError {
                error = failure
                stage = .failed
            } catch {
                self.error = LocalImportError(stage: stage, code: "LOCAL_IMPORT_FAILED", message: error.localizedDescription)
                stage = .failed
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { stage = .cancelled }
    }

    private func apply(_ progress: LocalImportProgress) {
        stage = progress.stage
        completedBytes = progress.completed
        totalBytes = progress.total
    }
}

struct MobileLocalImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @StateObject private var viewModel = MobileLocalImportViewModel()
    @FocusState private var sourceFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SOURCE URL").eyebrow()
                            TextField("Spotify track or YouTube video", text: $viewModel.source)
                                .focused($sourceFocused)
                                .submitLabel(.search)
                                .onSubmit(viewModel.resolve)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(13)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }

                        stageCard

                        if let resolution = viewModel.resolution {
                            resolvedTrack(resolution.track)
                            candidateList(resolution.candidates)
                        }

                        if let error = viewModel.error {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Import stopped at \(stageTitle(error.stage).lowercased())")
                                    .font(.headline)
                                Text(error.message).font(.subheadline)
                                Text(error.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Import from Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.resolution == nil {
                        Button("Find Audio", action: viewModel.resolve)
                            .disabled(viewModel.isRunning)
                    } else {
                        Button("Import") { viewModel.importSelected(into: library) }
                            .disabled(viewModel.isRunning || viewModel.selectedCandidate == nil)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { sourceFocused = false }
                }
            }
        }
        .onAppear { sourceFocused = true }
        .onDisappear { viewModel.cancel() }
    }

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stageSymbol(viewModel.stage)).foregroundStyle(Color.violet)
                Text(stageTitle(viewModel.stage)).font(.headline)
                Spacer()
                if viewModel.isRunning { ProgressView() }
            }
            Text(stageDetail(viewModel.stage))
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.totalBytes > 0 {
                ProgressView(value: Double(viewModel.completedBytes), total: Double(viewModel.totalBytes))
                    .tint(.violet)
                Text("\(ByteCountFormatter.string(fromByteCount: viewModel.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let track = viewModel.completedTrack {
                Text("Added “\(track.title)” to this device.")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func resolvedTrack(_ track: LocalImportSpotifyTrack) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MATCHED TRACK").eyebrow()
            Text(track.title).font(.title3.bold())
            Text([track.artist, track.album].compactMap { $0 }.joined(separator: " • "))
                .foregroundStyle(.secondary)
            if let duration = track.durationSeconds {
                Text(formatTime(TimeInterval(duration))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func candidateList(_ candidates: [LocalImportAudioSourceMatch]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("AUDIO SOURCE").eyebrow()
            ForEach(candidates) { candidate in
                Button {
                    viewModel.selectedVideoID = candidate.videoID
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: viewModel.selectedVideoID == candidate.videoID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color.violet)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([
                                candidate.artist ?? "Unknown uploader",
                                candidate.durationSeconds.map { formatTime(TimeInterval($0)) },
                                candidate.sourceProvider == .youtubeMusic ? "YouTube Music" : "YouTube"
                            ].compactMap { $0 }.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.white.opacity(viewModel.selectedVideoID == candidate.videoID ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private func parseTime(_ value: String) -> TimeInterval? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count),
          let last = Double(parts.last ?? ""),
          last >= 0, last < 60 || parts.count == 1 else { return nil }
    if parts.count == 1 { return last }
    guard let minutes = Double(parts[parts.count - 2]), minutes >= 0,
          parts.count != 3 || minutes < 60 else { return nil }
    if parts.count == 2 { return minutes * 60 + last }
    guard let hours = Double(parts[0]), hours >= 0 else { return nil }
    return hours * 3_600 + minutes * 60 + last
}

private func formatTime(_ value: TimeInterval) -> String {
    let safe = max(value, 0)
    let whole = Int(safe)
    let tenth = Int((safe * 10).rounded()) % 10
    let base = whole >= 3_600
        ? "\(whole / 3_600):\(String(format: "%02d", (whole / 60) % 60)):\(String(format: "%02d", whole % 60))"
        : "\(whole / 60):\(String(format: "%02d", whole % 60))"
    return tenth == 0 ? base : "\(base).\(tenth)"
}

private func stageTitle(_ stage: LocalImportStage) -> String {
    switch stage {
    case .idle: "Ready"
    case .resolvingMetadata: "Resolving Metadata"
    case .searchingCandidates: "Searching Audio Sources"
    case .awaitingSelection: "Choose an Audio Source"
    case .inspectingSource: "Inspecting Source"
    case .downloading: "Downloading"
    case .processing: "Processing Audio"
    case .savingLocal: "Saving on Device"
    case .localComplete, .complete: "Import Complete"
    case .syncing: "Syncing"
    case .failed: "Import Failed"
    case .cancelled: "Cancelled"
    }
}

private func stageDetail(_ stage: LocalImportStage) -> String {
    switch stage {
    case .idle: "Paste a Spotify track or supported YouTube video URL."
    case .resolvingMetadata: "Reading the track title, artist, artwork, and duration."
    case .searchingCandidates: "Ranking YouTube Music and YouTube results."
    case .awaitingSelection: "Review the match before saving audio on this device."
    case .inspectingSource: "Verifying a direct M4A audio stream."
    case .downloading: "Downloading verified audio directly to this device."
    case .processing: "Preserving metadata and artwork in the local M4A."
    case .savingLocal: "Adding the finished file to Resonance."
    case .localComplete, .complete: "The song is stored locally and ready to play."
    case .syncing: "Uploading the local import to the active profile."
    case .failed: "Review the error below and try another source."
    case .cancelled: "No unfinished import was kept."
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
