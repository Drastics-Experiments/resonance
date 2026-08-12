import AppKit
import AVFoundation
import AVKit
import QuartzCore
import SwiftUI

@MainActor
final class ClipPreviewController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var player: AVPlayer?
    let spectrumAnalyzer = ClipLiveSpectrumAnalyzer()

    private let audioEngine = AVAudioEngine()
    private let audioNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var audioAnchorPosition: TimeInterval = 0
    private var usesAudioEngine = false
    private var timer: Timer?
    private var sourceURL: URL?
    private var rangeStart: TimeInterval = 0
    private var rangeEnd: TimeInterval = 0

    var isPrepared: Bool { sourceURL != nil }

    init() {
        audioEngine.attach(audioNode)
        audioEngine.connect(audioNode, to: audioEngine.mainMixerNode, format: nil)
        let analyzer = spectrumAnalyzer
        audioEngine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 512,
            format: nil
        ) { buffer, _ in
            analyzer.consume(buffer)
        }
    }

    func prepare(
        url: URL,
        start: TimeInterval,
        end: TimeInterval,
        volume: Double,
        isVideo: Bool
    ) {
        let nextStart = max(0, start)
        let nextEnd = max(nextStart, end)
        let shouldReplaceSource = sourceURL?.standardizedFileURL != url.standardizedFileURL
            || usesAudioEngine == isVideo

        if shouldReplaceSource {
            clear()
            sourceURL = url
            if isVideo {
                player = AVPlayer(url: url)
                usesAudioEngine = false
            } else if let file = try? AVAudioFile(forReading: url) {
                audioFile = file
                usesAudioEngine = true
            } else {
                player = AVPlayer(url: url)
                usesAudioEngine = false
            }
            installTimer()
        }

        updateVolume(volume)
        rangeStart = nextStart
        rangeEnd = nextEnd
        pause()
        seek(to: nextStart)
    }

    func updateRange(start: TimeInterval, end: TimeInterval) {
        rangeStart = max(0, start)
        rangeEnd = max(rangeStart, end)
        pause()
        seek(to: rangeStart)
    }

    func updateVolume(_ volume: Double) {
        let gain = PlaybackVolumePolicy.gain(for: volume)
        player?.volume = gain
        audioNode.volume = gain
    }

    func toggle() {
        guard sourceURL != nil, rangeEnd - rangeStart >= ClipRangePolicy.minimumDuration else { return }
        if isPlaying {
            pause()
            return
        }
        if position >= rangeEnd - 0.02 || position < rangeStart {
            seek(to: rangeStart)
        }
        if usesAudioEngine {
            do {
                if !audioEngine.isRunning { try audioEngine.start() }
                audioNode.play()
                isPlaying = true
            } catch {
                isPlaying = false
            }
        } else if let player {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        let target = min(max(time, rangeStart), rangeEnd)
        if usesAudioEngine {
            let shouldResume = isPlaying
            scheduleAudio(from: target)
            if shouldResume {
                do {
                    if !audioEngine.isRunning { try audioEngine.start() }
                    audioNode.play()
                } catch {
                    isPlaying = false
                }
            }
        } else if let player {
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        position = target
    }

    func pause() {
        if usesAudioEngine {
            position = currentAudioPosition()
            audioNode.pause()
        } else {
            player?.pause()
        }
        isPlaying = false
    }

    func clear() {
        player?.pause()
        player = nil
        audioNode.stop()
        audioEngine.stop()
        audioFile = nil
        usesAudioEngine = false
        sourceURL = nil
        timer?.invalidate()
        timer = nil
        position = 0
        rangeStart = 0
        rangeEnd = 0
        audioAnchorPosition = 0
        spectrumAnalyzer.reset()
        isPlaying = false
    }

    private func scheduleAudio(from time: TimeInterval) {
        guard let audioFile else { return }
        audioNode.stop()
        let sampleRate = audioFile.processingFormat.sampleRate
        let startingFrame = min(
            max(AVAudioFramePosition(time * sampleRate), 0),
            audioFile.length
        )
        let endingFrame = min(
            max(AVAudioFramePosition(rangeEnd * sampleRate), startingFrame),
            audioFile.length
        )
        let availableFrames = endingFrame - startingFrame
        guard availableFrames > 0 else { return }
        let frameCount = AVAudioFrameCount(min(availableFrames, AVAudioFramePosition(UInt32.max)))
        audioNode.scheduleSegment(
            audioFile,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil
        )
        audioAnchorPosition = Double(startingFrame) / sampleRate
    }

    private func currentAudioPosition() -> TimeInterval {
        guard usesAudioEngine,
              let nodeTime = audioNode.lastRenderTime,
              let playerTime = audioNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return position }
        let current = audioAnchorPosition + Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(current, rangeStart), rangeEnd)
    }

    private func installTimer() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.sourceURL != nil else {
                    timer.invalidate()
                    return
                }
                let current: TimeInterval
                if self.usesAudioEngine {
                    current = self.currentAudioPosition()
                } else if let player = self.player {
                    current = player.currentTime().seconds
                } else {
                    current = self.position
                }
                if current.isFinite { self.position = current }
                if self.isPlaying && current >= self.rangeEnd - 0.02 {
                    self.position = self.rangeEnd
                    self.pause()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

struct MacClipEditorSheet: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var preferences: MacDesktopPreferences
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = ClipPreviewController()
    @State private var selectedTrackID: UUID?
    @State private var startTime: TimeInterval = 0
    @State private var endTime: TimeInterval = 0
    @State private var waveformSamples: [Double] = []
    @State private var videoFrames: [NSImage] = []
    @State private var savedStartTime: TimeInterval = 0
    @State private var savedEndTime: TimeInterval = 0
    @State private var isLoadingWaveform = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveConfirmation: String?
    @State private var showsSettings = false
    @State private var showsHelp = false
    @State private var previewExpanded = false
    let initialTrackID: UUID?

    init(initialTrackID: UUID? = nil) {
        self.initialTrackID = initialTrackID
    }

    private var editableTracks: [Track] {
        model.tracks.filter { ClipEditorTrackPolicy.isEditable($0) }
    }

    private var selectedTrack: Track? {
        guard let selectedTrackID else { return nil }
        return editableTracks.first { $0.id == selectedTrackID }
    }

    private var selectedDuration: TimeInterval { selectedTrack?.duration ?? 0 }
    private var clipLength: TimeInterval { max(endTime - startTime, 0) }
    private var hasUnsavedChanges: Bool {
        abs(startTime - savedStartTime) > 0.001 || abs(endTime - savedEndTime) > 0.001
    }
    private var canSave: Bool {
        guard selectedTrack != nil, !isSaving, hasUnsavedChanges else { return false }
        return (try? ClipRangePolicy.normalized(start: startTime, end: endTime, sourceDuration: selectedDuration)) != nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            palette.background

            VStack(spacing: 10) {
                topBar
                if editableTracks.isEmpty { emptyState } else { editor }
            }

            if showsSettings { settingsPopover }
            if showsHelp { helpPopover }
        }
        .frame(width: 1_140, height: 720)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background {
            MacClipShortcutReceiver(keybinds: preferences.keybinds) { action in
                handleShortcut(action)
            }
        }
        .task {
            guard selectedTrackID == nil else { return }
            chooseTrack(ClipEditorTrackPolicy.initialTrack(
                from: editableTracks,
                requestedTrackID: initialTrackID,
                currentTrackID: model.currentTrackID
            ))
        }
        .task(id: selectedTrackID) { await loadWaveform() }
        .onChange(of: startTime) { _, _ in
            preview.updateRange(start: startTime, end: endTime)
            saveConfirmation = nil
        }
        .onChange(of: endTime) { _, _ in
            preview.updateRange(start: startTime, end: endTime)
            saveConfirmation = nil
        }
        .onDisappear { preview.clear() }
    }

    private var topBar: some View {
        ZStack {
            trackSelectionMenu

            HStack {
                Button(action: dismissWithoutSaving) {
                    Text("Done").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.ink)

                Spacer()

                HStack(spacing: 14) {
                    Button(action: saveRange) {
                        if isSaving {
                            ProgressView().controlSize(.small).tint(.white).frame(width: 48)
                        } else {
                            Text("Save")
                                .font(.system(size: 13, weight: .bold))
                                .frame(minWidth: 48)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .foregroundStyle(canSave ? Color.white : palette.muted.opacity(0.55))
                    .background(canSave ? palette.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: [.command])

                    Button {
                        showsHelp.toggle()
                        showsSettings = false
                    } label: {
                        Image(systemName: "questionmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(palette.ink.opacity(0.9), lineWidth: 1.4))
                    }
                    .help("Clip editor help")

                    Button {
                        showsSettings.toggle()
                        showsHelp = false
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 21, weight: .regular))
                            .frame(width: 32, height: 32)
                    }
                    .help("Clip settings")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.ink)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
    }

    private var trackSelectionMenu: some View {
        Menu {
            ForEach(editableTracks) { track in
                Button { chooseTrack(track) } label: {
                    if track.id == selectedTrackID {
                        Label("\(track.title) — \(track.artist)", systemImage: "checkmark")
                    } else {
                        Text("\(track.title) — \(track.artist)")
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedTrack?.title ?? "Choose a song")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.muted)
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 380)
        .disabled(editableTracks.isEmpty)
        .accessibilityLabel("Select a song to clip")
        .help("Select another song")
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(palette.foregroundAccent)
            Text("No editable songs").font(.system(size: 20, weight: .bold)).foregroundStyle(palette.ink)
            Text("Add a local file or download a server song before creating a clip.")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
            Button("Add Music…") { model.importLocalFiles() }
                .buttonStyle(.borderedProminent).tint(palette.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(palette.divider, lineWidth: 1) }
        .padding([.horizontal, .bottom], 14)
    }

    private var editor: some View {
        VStack(spacing: 12) {
            previewStage
                .frame(maxHeight: previewExpanded ? .infinity : 430)

            if !previewExpanded {
                timeline.frame(height: 154)
            }

            statusLine
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var previewStage: some View {
        VStack(spacing: 0) {
            ZStack {
                if selectedTrack?.kind == .video {
                    ClipVideoPlayer(player: preview.player).background(Color.black)
                    if !preview.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 54, height: 54)
                            .background(Color.black.opacity(0.58), in: Circle())
                            .allowsHitTesting(false)
                    }
                } else {
                    audioPreview
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: togglePreview)

            previewTransport
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(palette.divider, lineWidth: 1) }
    }

    private var audioPreview: some View {
        ZStack {
            CinematicClipVisualizer(
                samples: waveformSamples,
                spectrumAnalyzer: preview.spectrumAnalyzer,
                isPlaying: preview.isPlaying,
                gradientColors: palette.gradientStops
            )
            if let selectedTrack {
                VStack(spacing: 9) {
                    TrackArtworkView(track: selectedTrack, symbolSize: 34, cornerRadius: 22)
                        .frame(width: 156, height: 156)
                        .shadow(color: .black.opacity(0.62), radius: 24, y: 16)
                    Text(selectedTrack.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(selectedTrack.artist)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.88))
                        .lineLimit(1)
                }
                .padding(.top, 8)
            }
        }
        .background(palette.background)
    }

    private var previewTransport: some View {
        ZStack {
            HStack(spacing: 8) {
                Text(clipTimeText(preview.position)).foregroundStyle(palette.tertiary)
                Text("/").foregroundStyle(palette.muted.opacity(0.65))
                Text(clipTimeText(endTime)).foregroundStyle(palette.ink)
                Spacer()
                Button { previewExpanded.toggle() } label: {
                    Image(systemName: previewExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .help(previewExpanded ? "Show timeline" : "Expand preview")
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))

            HStack(spacing: 28) {
                Button { preview.seek(to: startTime) } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Go to clip start")
                Button(action: togglePreview) {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .disabled(selectedTrack?.fileURL == nil)
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                Button { preview.seek(to: max(startTime, endTime - 0.01)) } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Go to clip end")
            }
            .font(.system(size: 17, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 24)
        .frame(height: 60)
        .background(palette.panel.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(palette.divider).frame(height: 1) }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            CinematicClipRuler(duration: selectedDuration).frame(height: 40)
            ZStack {
                CinematicClipWaveformSelector(
                    samples: waveformSamples,
                    videoFrames: videoFrames,
                    duration: selectedDuration,
                    startTime: $startTime,
                    endTime: $endTime,
                    previewPosition: selectedTrack == nil ? nil : preview.position,
                    onSeek: { preview.seek(to: $0) }
                )
                if isLoadingWaveform { ProgressView().controlSize(.small).tint(palette.foregroundAccent) }
            }
        }
        .background(palette.raisedSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(palette.divider, lineWidth: 1) }
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(errorMessage)
            } else if let saveConfirmation {
                Image(systemName: "checkmark.circle.fill")
                Text(saveConfirmation)
            } else {
                Text("Unsaved changes are discarded by Done. The original media file is never changed.")
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(errorMessage == nil ? palette.muted : Color(hex: 0xFF7568))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: 14)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            popoverHeader(title: "Clip settings") { showsSettings = false }
            HStack(spacing: 8) {
                ClipTimeControl(label: "Start", value: $startTime, range: 0...max(endTime - ClipRangePolicy.minimumDuration, 0))
                ClipTimeControl(label: "End", value: $endTime, range: min(startTime + ClipRangePolicy.minimumDuration, selectedDuration)...selectedDuration)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clip length")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.muted)
                    Text(clipTimeText(clipLength)).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(palette.tertiary)
                }
                Spacer()
                Button("Use Full Song") {
                    startTime = 0
                    endTime = selectedDuration
                    saveConfirmation = nil
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(width: 390)
        .background(palette.raisedSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(palette.divider, lineWidth: 1) }
        .shadow(color: .black.opacity(0.65), radius: 30, y: 14)
        .padding(.top, 58)
        .padding(.trailing, 20)
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            popoverHeader(title: "How clipping works") { showsHelp = false }
            Text("Drag the yellow handles to choose a range. Click the timeline to scrub, then use the center controls to preview exactly what will play.")
            Text("**Save** updates playback for this profile without changing the media file. **Done** closes the editor and discards anything not saved.")
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.muted)
        .lineSpacing(3)
        .padding(18)
        .frame(width: 360)
        .background(palette.raisedSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(palette.divider, lineWidth: 1) }
        .shadow(color: .black.opacity(0.65), radius: 30, y: 14)
        .padding(.top, 58)
        .padding(.trailing, 20)
    }

    private func popoverHeader(title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.ink)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func chooseTrack(_ track: Track?) {
        preview.clear()
        selectedTrackID = track?.id
        let saved = track.flatMap { model.clipRange(for: $0) }
        let duration = track?.duration ?? 0
        let defaultStart: TimeInterval = duration > 60 ? 15 : 0
        startTime = saved?.startSeconds ?? defaultStart
        endTime = saved?.endSeconds ?? min(duration, defaultStart + 45)
        savedStartTime = saved?.startSeconds ?? 0
        savedEndTime = saved?.endSeconds ?? duration
        errorMessage = nil
        saveConfirmation = nil
        waveformSamples = []
        videoFrames = []
        if let track, let url = track.fileURL {
            preview.prepare(
                url: url,
                start: startTime,
                end: endTime,
                volume: model.volume,
                isVideo: track.kind == .video
            )
        }
    }

    private func loadWaveform() async {
        guard let track = selectedTrack, let url = track.fileURL else {
            waveformSamples = []
            videoFrames = []
            return
        }
        isLoadingWaveform = true
        waveformSamples = []
        videoFrames = []
        if track.kind == .video {
            let frames = await ClipVideoFrameSampler.frames(for: url, duration: track.duration)
            guard !Task.isCancelled, track.id == selectedTrackID else { return }
            videoFrames = frames
            isLoadingWaveform = false
            return
        }
        let samples = await ClipWaveformSampler.samples(for: url, count: 180)
        guard !Task.isCancelled, track.id == selectedTrackID else { return }
        waveformSamples = samples
        isLoadingWaveform = false
    }

    private func togglePreview() {
        guard let track = selectedTrack, let url = track.fileURL else { return }
        errorMessage = nil
        if !preview.isPrepared {
            preview.prepare(
                url: url,
                start: startTime,
                end: endTime,
                volume: model.volume,
                isVideo: track.kind == .video
            )
        }
        preview.toggle()
    }

    private func handleShortcut(_ action: MacShortcutAction) {
        guard !isSaving else { return }
        switch action {
        case .togglePlayback:
            togglePreview()
        case .previousTrack:
            chooseAdjacentTrack(offset: -1)
        case .nextTrack:
            chooseAdjacentTrack(offset: 1)
        case .volumeDown:
            model.volume = max(0, model.volume - 0.05)
            preview.updateVolume(model.volume)
        case .volumeUp:
            model.volume = min(1, model.volume + 0.05)
            preview.updateVolume(model.volume)
        }
    }

    private func chooseAdjacentTrack(offset: Int) {
        guard !editableTracks.isEmpty else { return }
        let currentIndex = editableTracks.firstIndex(where: { $0.id == selectedTrackID }) ?? 0
        let nextIndex = (currentIndex + offset + editableTracks.count) % editableTracks.count
        chooseTrack(editableTracks[nextIndex])
    }

    private func dismissWithoutSaving() {
        preview.clear()
        dismiss()
    }

    private func saveRange() {
        guard let track = selectedTrack else { return }
        preview.pause()
        errorMessage = nil
        isSaving = true
        if startTime <= 0.001, endTime >= track.duration - 0.001 {
            model.clearClipRange(for: track)
            savedStartTime = 0
            savedEndTime = track.duration
            saveConfirmation = "Saved full-song playback for this profile."
        } else if let range = try? ClipRangePolicy.normalized(
            start: startTime,
            end: endTime,
            sourceDuration: track.duration
        ) {
            model.saveClipRange(for: track, start: range.lowerBound, end: range.upperBound)
            savedStartTime = range.lowerBound
            savedEndTime = range.upperBound
            saveConfirmation = "Saved \(clipTimeText(range.lowerBound))–\(clipTimeText(range.upperBound)) for this profile."
        } else {
            errorMessage = "Choose a valid playback range."
        }
        isSaving = false
    }
}

private struct CinematicClipVisualizer: NSViewRepresentable {
    let samples: [Double]
    let spectrumAnalyzer: ClipLiveSpectrumAnalyzer
    let isPlaying: Bool
    let gradientColors: [Color]

    func makeNSView(context: Context) -> ClipSpectrumVisualizerView {
        let view = ClipSpectrumVisualizerView()
        view.update(
            samples: samples,
            spectrumAnalyzer: spectrumAnalyzer,
            isPlaying: isPlaying,
            gradientColors: gradientColors
        )
        return view
    }

    func updateNSView(_ nsView: ClipSpectrumVisualizerView, context: Context) {
        nsView.update(
            samples: samples,
            spectrumAnalyzer: spectrumAnalyzer,
            isPlaying: isPlaying,
            gradientColors: gradientColors
        )
    }

    static func dismantleNSView(_ nsView: ClipSpectrumVisualizerView, coordinator: ()) {
        nsView.stop()
    }
}

@MainActor
private final class ClipSpectrumVisualizerView: NSView {
    static let frameRate: Float = 60
    private static let horizontalInset: CGFloat = 4
    private static let topInsetFraction: CGFloat = 0.12
    private static let spacing: CGFloat = 2

    private let gradientLayer = CAGradientLayer()
    private let barsLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var spectrumAnalyzer: ClipLiveSpectrumAnalyzer?
    private var sourceSamples: [Double] = []
    private var staticLevels = [Double](repeating: 0.08, count: ClipLiveSpectrumAnalyzer.barCount)
    private var displayedLevels = [Double](repeating: 0, count: ClipLiveSpectrumAnalyzer.barCount)
    private var isPlaying = false
    private var previousFrameTimestamp: CFTimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = gradientLayer
        gradientLayer.colors = []
        gradientLayer.locations = [0, 0.72, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.opacity = 0.92
        gradientLayer.mask = barsLayer
        barsLayer.fillColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.frame = bounds
        renderBars()
        CATransaction.commit()
    }

    func update(
        samples: [Double],
        spectrumAnalyzer: ClipLiveSpectrumAnalyzer,
        isPlaying: Bool,
        gradientColors: [Color]
    ) {
        gradientLayer.colors = gradientColors.map { NSColor($0).cgColor }
        self.spectrumAnalyzer = spectrumAnalyzer
        if sourceSamples != samples {
            sourceSamples = samples
            staticLevels = resampledLevels(from: samples)
        }

        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            previousFrameTimestamp = nil
            displayedLevels = isPlaying ? spectrumAnalyzer.snapshot() : staticLevels
        } else if !isPlaying {
            displayedLevels = staticLevels
        }

        displayLink?.isPaused = !isPlaying
        renderBarsWithoutAnimation()
        if window != nil { startIfNeeded() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        startIfNeeded()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousFrameTimestamp = nil
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let displayLink = displayLink(target: self, selector: #selector(renderFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Self.frameRate,
            maximum: Self.frameRate,
            preferred: Self.frameRate
        )
        displayLink.isPaused = !isPlaying
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func renderFrame(_ displayLink: CADisplayLink) {
        guard isPlaying, let spectrumAnalyzer else { return }
        let timestamp = displayLink.timestamp
        let elapsed = previousFrameTimestamp.map { timestamp - $0 } ?? (1 / Double(Self.frameRate))
        previousFrameTimestamp = timestamp
        let frameDuration = min(max(elapsed, 1 / 240), 1 / 15)
        let targetLevels = spectrumAnalyzer.snapshot()

        for index in displayedLevels.indices {
            let target = index < targetLevels.count ? targetLevels[index] : 0
            let responseTime = target >= displayedLevels[index] ? 0.015 : 0.07
            let blend = 1 - exp(-frameDuration / responseTime)
            displayedLevels[index] += (target - displayedLevels[index]) * blend
        }
        renderBarsWithoutAnimation()
    }

    private func resampledLevels(from samples: [Double]) -> [Double] {
        guard !samples.isEmpty else {
            return [Double](repeating: 0.08, count: ClipLiveSpectrumAnalyzer.barCount)
        }
        return (0..<ClipLiveSpectrumAnalyzer.barCount).map { index in
            let progress = Double(index) / Double(max(ClipLiveSpectrumAnalyzer.barCount - 1, 1))
            let position = progress * Double(samples.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, samples.count - 1)
            let fraction = position - Double(lower)
            return max(0, min(1, samples[lower] * (1 - fraction) + samples[upper] * fraction))
        }
    }

    private func renderBarsWithoutAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderBars()
        CATransaction.commit()
    }

    private func renderBars() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let barCount = ClipLiveSpectrumAnalyzer.barCount
        let contentWidth = max(bounds.width - Self.horizontalInset * 2, 1)
        let barWidth = max(
            (contentWidth - Self.spacing * CGFloat(barCount - 1)) / CGFloat(barCount),
            2
        )
        let drawableHeight = bounds.height * (1 - Self.topInsetFraction)
        let path = CGMutablePath()

        for index in 0..<barCount {
            let level = index < displayedLevels.count ? displayedLevels[index] : 0
            let percentage = isPlaying
                ? max(5, min(100, 7 + level * 93))
                : 10 + Double(Int((max(0.04, min(1, level)) * 86).rounded()))
            let height = drawableHeight * percentage / 100
            let rect = CGRect(
                x: Self.horizontalInset + CGFloat(index) * (barWidth + Self.spacing),
                y: 0,
                width: barWidth,
                height: height
            )
            path.addPath(topRoundedBarPath(in: rect, radius: barWidth / 2))
        }
        barsLayer.path = path
    }

    private func topRoundedBarPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct CinematicClipRuler: View {
    @Environment(\.resonancePalette) private var palette
    let duration: TimeInterval
    private let divisions = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for tick in 0...40 {
                        let x = size.width * CGFloat(tick) / 40
                        let major = tick % 7 == 0
                        let path = Path(CGRect(x: x, y: major ? 25 : 29, width: 1, height: major ? 14 : 10))
                        context.fill(path, with: .color(Color.white.opacity(major ? 0.42 : 0.24)))
                    }
                }

                ForEach(0...divisions, id: \.self) { index in
                    let x = proxy.size.width * CGFloat(index) / CGFloat(divisions)
                    Text(clipTimeText(max(duration, 0) * Double(index) / Double(divisions)))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.muted)
                        .position(
                            x: index == 0 ? 28 : (index == divisions ? proxy.size.width - 28 : x),
                            y: 12
                        )
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider.opacity(0.65)).frame(height: 1) }
    }
}

private struct CinematicClipWaveformSelector: View {
    @Environment(\.resonancePalette) private var palette
    let samples: [Double]
    let videoFrames: [NSImage]
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let previewPosition: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = proxy.size.height
            let startFraction = duration > 0 ? min(max(startTime / duration, 0), 1) : 0
            let endFraction = duration > 0 ? min(max(endTime / duration, 0), 1) : 0
            let startX = width * startFraction
            let endX = width * endFraction

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("cinematicClipWaveform"))
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let proposed = min(max(value.location.x / width * duration, startTime), endTime)
                                onSeek(proposed)
                            }
                    )

                if !videoFrames.isEmpty {
                    HStack(spacing: 1) {
                        ForEach(Array(videoFrames.enumerated()), id: \.offset) { _, frame in
                            Image(nsImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(max(videoFrames.count, 1)), height: height)
                                .clipped()
                        }
                    }
                    .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color.black.opacity(0.62))
                        .frame(width: max(startX, 0), height: height)
                        .position(x: max(startX, 0) / 2, y: height / 2)
                    Rectangle()
                        .fill(Color.black.opacity(0.62))
                        .frame(width: max(width - endX, 0), height: height)
                        .position(x: endX + max(width - endX, 0) / 2, y: height / 2)
                }

                Rectangle()
                    .fill(palette.secondary.opacity(0.14))
                    .frame(width: max(endX - startX, 0))
                    .position(x: startX + max(endX - startX, 0) / 2, y: height / 2)

                if videoFrames.isEmpty {
                    Canvas { context, size in
                        let values = samples.isEmpty ? [Double](repeating: 0.08, count: 120) : samples
                        let spacing: CGFloat = 1
                        let barWidth = max((size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count), 1)
                        for (index, value) in values.enumerated() {
                            let x = CGFloat(index) * (barWidth + spacing)
                            let barHeight = max(4, size.height * 0.58 * min(max(value, 0.05), 1))
                            let fraction = (CGFloat(index) + 0.5) / CGFloat(values.count)
                            let selected = fraction >= startFraction && fraction <= endFraction
                            let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                with: .color(selected ? palette.tertiary : Color.white.opacity(0.26))
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .allowsHitTesting(false)
                }

                Rectangle().fill(Color(hex: 0xFFD329)).frame(width: max(endX - startX, 0), height: 2).position(x: startX + max(endX - startX, 0) / 2, y: 1)
                Rectangle().fill(Color(hex: 0xFFD329)).frame(width: max(endX - startX, 0), height: 2).position(x: startX + max(endX - startX, 0) / 2, y: height - 1)

                if let previewPosition, duration > 0 {
                    let playheadX = width * min(max(previewPosition / duration, 0), 1)
                    Rectangle().fill(Color.white).frame(width: 1.5, height: height).position(x: playheadX, y: height / 2)
                    Triangle().fill(Color.white).frame(width: 14, height: 10).rotationEffect(.degrees(180)).position(x: playheadX, y: 5)
                }

                rangeHandle(symbol: "chevron.right")
                    .position(x: min(max(startX, 14), width - 14), y: height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("cinematicClipWaveform"))
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let proposed = min(max(value.location.x / width * duration, 0), duration)
                                startTime = max(0, min(proposed, endTime - ClipRangePolicy.minimumDuration))
                            }
                    )

                rangeHandle(symbol: "chevron.left")
                    .position(x: min(max(endX, 14), width - 14), y: height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("cinematicClipWaveform"))
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let proposed = min(max(value.location.x / width * duration, 0), duration)
                                endTime = min(duration, max(proposed, startTime + ClipRangePolicy.minimumDuration))
                            }
                    )
            }
            .coordinateSpace(name: "cinematicClipWaveform")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(videoFrames.isEmpty ? "Clip waveform" : "Video frame timeline")
            .accessibilityValue("From \(clipTimeText(startTime)) to \(clipTimeText(endTime))")
        }
    }

    private func rangeHandle(symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xFFC91D), Color(hex: 0xFFE044)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 28)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.82))
            }
            .shadow(color: Color(hex: 0xFFD329).opacity(0.28), radius: 10)
            .frame(width: 38)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MacClipShortcutReceiver: NSViewRepresentable {
    let keybinds: [MacShortcutAction: String]
    let onAction: (MacShortcutAction) -> Void

    func makeNSView(context: Context) -> MacClipShortcutCaptureView {
        let view = MacClipShortcutCaptureView()
        view.keybinds = keybinds
        view.onAction = onAction
        return view
    }

    func updateNSView(_ nsView: MacClipShortcutCaptureView, context: Context) {
        nsView.keybinds = keybinds
        nsView.onAction = onAction
    }
}

@MainActor
private final class MacClipShortcutCaptureView: NSView {
    var keybinds: [MacShortcutAction: String] = [:]
    var onAction: ((MacShortcutAction) -> Void)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { uninstallMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if handle(event) { return }
        super.keyDown(with: event)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let hostWindow = self.window,
                  let eventWindow = event.window,
                  eventWindow === hostWindow
                    || eventWindow.sheetParent === hostWindow
                    || hostWindow.sheetParent === eventWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func uninstallMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else { return false }
        if let textView = window?.firstResponder as? NSTextView, textView.isEditable { return false }
        if let textField = window?.firstResponder as? NSTextField, textField.isEditable { return false }
        guard let shortcut = MacDesktopPreferences.shortcutString(for: event),
              let action = keybinds.first(where: { $0.value == shortcut })?.key else { return false }
        onAction?(action)
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private struct ClipVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

private struct ClipTimeControl: View {
    @Environment(\.resonancePalette) private var palette
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.muted)

            TextField("0:00.0", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 8)
                .frame(height: 27)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isFocused ? palette.secondary.opacity(0.75) : palette.divider, lineWidth: 1)
                }
                .focused($isFocused)
                .onSubmit {
                    commitDraft()
                    isFocused = false
                }
                .accessibilityLabel("\(label) time")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { draft = clipTimeText(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused { draft = clipTimeText(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitDraft() }
        }
    }

    private func commitDraft() {
        guard let parsed = clipTimeValue(from: draft) else {
            draft = clipTimeText(value)
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = clamped
        draft = clipTimeText(clamped)
    }
}

func clipTimeValue(from text: String) -> TimeInterval? {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
    guard !normalized.isEmpty else { return nil }

    let components = normalized.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(components.count) else { return nil }
    let values = components.compactMap { Double($0) }
    guard values.count == components.count,
          values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
        return nil
    }

    switch values.count {
    case 1:
        return values[0]
    case 2:
        return values[0] * 60 + values[1]
    case 3:
        return values[0] * 3_600 + values[1] * 60 + values[2]
    default:
        return nil
    }
}

private func clipTimeText(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let minutes = Int(seconds) / 60
    let remaining = seconds - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, remaining)
}
