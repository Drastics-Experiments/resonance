import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
private final class MobileClipPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var player: AVPlayer?

    private var timer: Timer?
    private var sourceURL: URL?
    private var rangeStart: TimeInterval = 0
    private var rangeEnd: TimeInterval = 0

    func prepare(url: URL, start: TimeInterval, end: TimeInterval, volume: Double) {
        let nextStart = max(0, start)
        let nextEnd = max(nextStart, end)
        if sourceURL?.standardizedFileURL != url.standardizedFileURL {
            clear()
            let player = AVPlayer(url: url)
            self.player = player
            sourceURL = url
            installTimer()
        }
        player?.volume = PlaybackVolumePolicy.gain(for: volume)
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

    func toggle() {
        guard let player, rangeEnd - rangeStart >= 0.25 else { return }
        if isPlaying {
            pause()
            return
        }
        if position >= rangeEnd - 0.02 || position < rangeStart {
            seek(to: rangeStart)
        }
        player.play()
        isPlaying = true
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let target = min(max(time, rangeStart), rangeEnd)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        position = target
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func clear() {
        player?.pause()
        player = nil
        sourceURL = nil
        timer?.invalidate()
        timer = nil
        rangeStart = 0
        rangeEnd = 0
        position = 0
        isPlaying = false
    }

    private func installTimer() {
        let previewTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else {
                    timer.invalidate()
                    return
                }
                let current = player.currentTime().seconds
                if current.isFinite { self.position = current }
                if self.isPlaying && current >= self.rangeEnd - 0.02 {
                    self.position = self.rangeEnd
                    self.pause()
                }
            }
        }
        timer = previewTimer
        RunLoop.main.add(previewTimer, forMode: .common)
    }
}

private enum MobileClipWaveformSampler {
    static func samples(for url: URL, count: Int = 192) async -> [Double] {
        guard count > 0 else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds.isFinite,
                  duration.seconds > 0,
                  let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else {
                return []
            }
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            var peaks = [Double](repeating: 0, count: count)
            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(dataBuffer)
                guard byteCount >= MemoryLayout<Int16>.size else { continue }
                var bytes = [UInt8](repeating: 0, count: byteCount)
                let status = bytes.withUnsafeMutableBytes { buffer in
                    guard let destination = buffer.baseAddress else {
                        return kCMBlockBufferBadLengthParameterErr
                    }
                    CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: destination
                    )
                }
                guard status == kCMBlockBufferNoErr else { continue }
                var peak = 0.0
                bytes.withUnsafeBytes { buffer in
                    for value in buffer.bindMemory(to: Int16.self) {
                        peak = max(peak, min(Double(abs(Int(value))) / Double(Int16.max), 1))
                    }
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                guard timestamp.isFinite else { continue }
                let index = min(max(Int(timestamp / duration.seconds * Double(count)), 0), count - 1)
                peaks[index] = max(peaks[index], peak)
            }
            guard let maximum = peaks.max(), maximum > 0 else { return [] }
            fillEmptySamples(&peaks)
            return peaks.map { max(0.04, sqrt($0 / maximum)) }
        }.value
    }

    private static func fillEmptySamples(_ samples: inout [Double]) {
        var last = 0.0
        for index in samples.indices {
            if samples[index] > 0 { last = samples[index] }
            else if last > 0 { samples[index] = last }
        }
        last = 0
        for index in samples.indices.reversed() {
            if samples[index] > 0 { last = samples[index] }
            else if last > 0 { samples[index] = last }
        }
    }
}

private enum MobileClipVideoFrameSampler {
    static func frames(for url: URL, duration: TimeInterval, count: Int = 12) async -> [UIImage] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        let encodedFrames = await Task.detached(priority: .userInitiated) { () -> [Data] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            return (0..<count).compactMap { index in
                guard !Task.isCancelled else { return nil }
                let seconds = duration * (Double(index) + 0.5) / Double(count)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                return UIImage(cgImage: image).jpegData(compressionQuality: 0.72)
            }
        }.value
        return encodedFrames.compactMap(UIImage.init(data:))
    }
}

struct MobileClipEditorSheet: View {
    @Environment(\.resonancePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MusicLibrary
    @StateObject private var preview = MobileClipPreviewPlayer()
    @State private var selectedTrackID: UUID?
    @State private var startSeconds: TimeInterval = 0
    @State private var endSeconds: TimeInterval = 1
    @State private var startText = "0:00"
    @State private var endText = "0:01"
    @State private var wasPlayingBeforePreview = false
    @State private var showsSettings = false
    @State private var showsHelp = false
    @State private var previewExpanded = false
    @State private var waveformSamples: [Double] = []
    @State private var videoFrames: [UIImage] = []
    @State private var savedStartSeconds: TimeInterval = 0
    @State private var savedEndSeconds: TimeInterval = 0
    @State private var saveConfirmation: String?
    @FocusState private var focusedBoundary: ClipBoundary?

    private enum ClipBoundary: Hashable { case start, end }

    private var tracks: [MobileTrack] { library.tracksForActiveProfile }
    private var selectedTrack: MobileTrack? {
        guard let selectedTrackID else { return nil }
        return tracks.first { $0.id == selectedTrackID } ?? library.tracks.first { $0.id == selectedTrackID }
    }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if let track = selectedTrack {
                    ScrollView {
                        VStack(spacing: 12) {
                            previewStage(track)
                            if !previewExpanded { timeline(track) }
                            Text(saveConfirmation ?? "Unsaved changes are discarded by Done. The original media file is never changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 18)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    ContentUnavailableView(
                        "No songs to edit",
                        systemImage: "waveform",
                        description: Text("Import or download a song, then return to create a playback range.")
                    )
                }
            }

            if showsSettings { settingsOverlay }
            if showsHelp { helpOverlay }
        }
        .onAppear {
            selectedTrackID = library.currentTrack?.id ?? tracks.first?.id
            resetRange()
        }
        .onChange(of: selectedTrackID) {
            stopPreview(resumeMain: true)
            preview.clear()
            resetRange()
        }
        .task(id: selectedTrackID) { await loadWaveform() }
        .onChange(of: preview.isPlaying) { wasPlaying, isPlaying in
            if wasPlaying, !isPlaying, wasPlayingBeforePreview {
                wasPlayingBeforePreview = false
                library.resumePlayback()
            }
        }
        .onDisappear {
            stopPreview(resumeMain: true)
            preview.clear()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button("Done", action: dismissWithoutSaving)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(minHeight: 44)

            trackSelectionMenu
                .frame(maxWidth: .infinity)

            Button("Save", action: saveRange)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(hasUnsavedChanges ? palette.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(hasUnsavedChanges ? Color.white : Color.white.opacity(0.35))
                .disabled(!hasUnsavedChanges || selectedTrack == nil || (selectedTrack?.duration ?? 0) < 0.25)

            Button {
                showsHelp.toggle()
                showsSettings = false
            } label: {
                Image(systemName: "questionmark")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.4))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Clip editor help")

            Button {
                showsSettings.toggle()
                showsHelp = false
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Clip settings")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(height: 44)
        .padding(.horizontal, 12)
    }

    private var trackSelectionMenu: some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    selectedTrackID = track.id
                } label: {
                    if track.id == selectedTrackID {
                        Label("\(track.title) — \(track.artist)", systemImage: "checkmark")
                    } else {
                        Text("\(track.title) — \(track.artist)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedTrack?.title ?? "Choose a song")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .disabled(tracks.isEmpty)
        .accessibilityLabel("Select a song to clip")
    }

    private func previewStage(_ track: MobileTrack) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if isVideoClipTrack(track) {
                    MobileClipVideoPlayer(player: preview.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    if !preview.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.58), in: Circle())
                            .allowsHitTesting(false)
                    }
                } else {
                    MobileClipVisualizer(
                        samples: waveformSamples,
                        isPlaying: preview.isPlaying,
                        position: preview.position,
                        duration: track.duration
                    )
                        .overlay {
                            VStack(spacing: 7) {
                                TrackArtwork(track: track, fallbackSymbol: "music.note")
                                    .frame(width: previewExpanded ? 176 : 116, height: previewExpanded ? 176 : 116)
                                    .clipShape(RoundedRectangle(cornerRadius: previewExpanded ? 24 : 17, style: .continuous))
                                    .shadow(color: .black.opacity(0.62), radius: 22, y: 13)
                                Text(track.title)
                                    .font((previewExpanded ? Font.title2 : .headline).bold())
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(previewExpanded ? .headline : .subheadline)
                                    .foregroundStyle(.white.opacity(0.86))
                                    .lineLimit(1)
                            }
                            .padding(14)
                        }
                }
            }
            .frame(minHeight: previewExpanded ? 500 : 286)
            .contentShape(Rectangle())
            .onTapGesture { togglePreview() }

            previewTransport(track)
        }
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 1) }
    }

    private func previewTransport(_ track: MobileTrack) -> some View {
        ZStack {
            HStack(spacing: 6) {
                Text(formatTime(preview.position)).foregroundStyle(palette.tertiary)
                Text("/").foregroundStyle(.secondary)
                Text(formatTime(endSeconds)).foregroundStyle(.white)
                Spacer()
                Button { previewExpanded.toggle() } label: {
                    Image(systemName: previewExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(previewExpanded ? "Collapse preview" : "Expand preview")
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 22) {
                Button { preview.seek(to: startSeconds) } label: {
                    Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
                }
                    .accessibilityLabel("Go to clip start")
                Button { togglePreview() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.bold())
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                Button { preview.seek(to: max(startSeconds, endSeconds - 0.01)) } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }
                    .accessibilityLabel("Go to clip end")
            }
            .disabled(library.fileURL(for: track).path.isEmpty)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(palette.surface.opacity(0.97))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func timeline(_ track: MobileTrack) -> some View {
        VStack(spacing: 0) {
            MobileClipRuler(duration: track.duration).frame(height: 40)
            MobileClipWaveform(
                track: track,
                samples: waveformSamples,
                videoFrames: videoFrames,
                startSeconds: $startSeconds,
                endSeconds: $endSeconds,
                playhead: preview.position,
                onChange: {
                    stopPreview(resumeMain: true)
                    updateTexts()
                    preview.updateRange(start: startSeconds, end: endSeconds)
                    saveConfirmation = nil
                },
                onSeek: { preview.seek(to: $0) }
            )
            .frame(height: 108)
        }
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.09), lineWidth: 1) }
    }

    private var settingsOverlay: some View {
        overlayScrim {
            VStack(alignment: .leading, spacing: 14) {
                overlayHeader("Clip Settings") { showsSettings = false }
                if let track = selectedTrack {
                    settingsTrackSummary(track)
                }

                HStack(spacing: 10) {
                    exactTimeField("Start", text: $startText, boundary: .start)
                    exactTimeField("End", text: $endText, boundary: .end)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clip Length").sectionLabel()
                        Text(formatTime(max(endSeconds - startSeconds, 0)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(palette.tertiary)
                    }
                    Spacer()
                    if let track = selectedTrack {
                        Button("Use Full Song") {
                            stopPreview(resumeMain: true)
                            startSeconds = 0
                            endSeconds = track.duration
                            updateTexts()
                            preview.updateRange(start: startSeconds, end: endSeconds)
                            saveConfirmation = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var helpOverlay: some View {
        overlayScrim {
            VStack(alignment: .leading, spacing: 13) {
                overlayHeader("How It Works") { showsHelp = false }
                Text("Drag the yellow handles to choose a range. Tap the waveform to scrub, then use the center controls to preview exactly what will play.")
                Text("**Save** updates playback for the active profile without changing the media file. **Done** closes the editor and discards anything not saved.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func overlayScrim<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { showsSettings = false; showsHelp = false }
            content()
                .padding(18)
                .background(palette.raisedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1) }
                .frame(maxWidth: 430)
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func settingsTrackSummary(_ track: MobileTrack) -> some View {
        HStack(spacing: 10) {
            TrackArtwork(track: track, fallbackSymbol: "music.note")
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatTime(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func overlayHeader(_ title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.headline)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
                    .frame(width: 44, height: 44)
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
        }
    }

    private func exactTimeField(_ label: String, text: Binding<String>, boundary: ClipBoundary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).sectionLabel()
            TextField(label, text: text)
                .focused($focusedBoundary, equals: boundary)
                .keyboardType(.numbersAndPunctuation)
                .font(.headline.monospacedDigit())
                .padding(10)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { commit(boundary) }
        }
        .frame(maxWidth: .infinity)
    }

    private func togglePreview() {
        guard let track = selectedTrack else { return }
        if preview.isPlaying {
            stopPreview(resumeMain: true)
        } else {
            wasPlayingBeforePreview = library.isPlaying
            if wasPlayingBeforePreview { library.pausePlayback() }
            if preview.player == nil {
                preview.prepare(url: library.fileURL(for: track), start: startSeconds, end: endSeconds, volume: library.volume)
            }
            preview.toggle()
        }
    }

    private func commit(_ boundary: ClipBoundary) {
        let value = boundary == .start ? startText : endText
        guard let seconds = parseTime(value), let track = selectedTrack else { updateTexts(); return }
        stopPreview(resumeMain: true)
        if boundary == .start {
            startSeconds = min(max(seconds, 0), max(endSeconds - 0.25, 0))
        } else {
            endSeconds = min(max(seconds, startSeconds + 0.25), track.duration)
        }
        updateTexts()
        preview.updateRange(start: startSeconds, end: endSeconds)
        saveConfirmation = nil
    }

    private func resetRange() {
        guard let track = selectedTrack else { return }
        let saved = library.clipRange(for: track)
        let defaultStart: TimeInterval = track.duration > 60 ? 15 : 0
        startSeconds = saved?.startSeconds ?? defaultStart
        endSeconds = saved?.endSeconds ?? min(track.duration, defaultStart + 45)
        savedStartSeconds = saved?.startSeconds ?? 0
        savedEndSeconds = saved?.endSeconds ?? track.duration
        if endSeconds - startSeconds < 0.25 { startSeconds = 0; endSeconds = max(track.duration, 0.25) }
        saveConfirmation = nil
        updateTexts()
        preview.prepare(url: library.fileURL(for: track), start: startSeconds, end: endSeconds, volume: library.volume)
    }

    private func loadWaveform() async {
        guard let track = selectedTrack else {
            waveformSamples = []
            videoFrames = []
            return
        }
        let trackID = track.id
        waveformSamples = []
        videoFrames = []
        let url = library.fileURL(for: track)
        if isVideoClipTrack(track) {
            let frames = await MobileClipVideoFrameSampler.frames(for: url, duration: track.duration)
            guard !Task.isCancelled, selectedTrackID == trackID else { return }
            videoFrames = frames
            return
        }
        let samples = await MobileClipWaveformSampler.samples(for: url)
        guard !Task.isCancelled, selectedTrackID == trackID else { return }
        waveformSamples = samples
    }

    private func updateTexts() {
        startText = formatTime(startSeconds)
        endText = formatTime(endSeconds)
    }

    private func stopPreview(resumeMain: Bool) {
        let shouldResume = resumeMain && wasPlayingBeforePreview
        wasPlayingBeforePreview = false
        preview.pause()
        if shouldResume { library.resumePlayback() }
    }

    private var hasUnsavedChanges: Bool {
        abs(startSeconds - savedStartSeconds) > 0.001 || abs(endSeconds - savedEndSeconds) > 0.001
    }

    private func dismissWithoutSaving() {
        focusedBoundary = nil
        stopPreview(resumeMain: true)
        dismiss()
    }

    private func saveRange() {
        guard let track = selectedTrack, track.duration >= 0.25 else { return }
        focusedBoundary = nil
        commit(.start)
        commit(.end)
        stopPreview(resumeMain: true)
        if startSeconds <= 0.001, endSeconds >= track.duration - 0.001 {
            library.clearClipRange(for: track)
            savedStartSeconds = 0
            savedEndSeconds = track.duration
            saveConfirmation = "Saved full-song playback for \(library.visibleSyncProfileName)."
        } else {
            library.saveClipRange(for: track, start: startSeconds, end: endSeconds)
            savedStartSeconds = startSeconds
            savedEndSeconds = endSeconds
            saveConfirmation = "Saved \(formatTime(startSeconds))–\(formatTime(endSeconds)) for \(library.visibleSyncProfileName)."
        }
    }
}

private struct MobileClipVisualizer: View {
    @Environment(\.resonancePalette) private var palette
    let samples: [Double]
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval

    var body: some View {
        GeometryReader { _ in
            let count = 96
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            Canvas { context, size in
                let spacing: CGFloat = 1.5
                let width = max((size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
                var bars = Path()
                for index in 0..<count {
                    let barProgress = Double(index) / Double(count - 1)
                    let samplePosition = isPlaying
                        ? min(max(progress + (barProgress - 0.30) * 0.24, 0), 1)
                        : barProgress
                    let level = mobileSampledClipLevel(samples, at: samplePosition)
                    let height = max(4, size.height * 0.72 * level)
                    let rect = CGRect(
                        x: CGFloat(index) * (width + spacing),
                        y: size.height - height,
                        width: width,
                        height: height
                    )
                    bars.addPath(Path(roundedRect: rect, cornerRadius: width / 2))
                }
                context.fill(
                    bars,
                    with: .color(palette.secondary)
                )
            }
        }
        .background(palette.surface)
    }
}

private struct MobileClipRuler: View {
    let duration: TimeInterval
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                ForEach(0...5, id: \.self) { index in
                    Text(formatTime(duration * Double(index) / 5))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if index < 5 { Spacer() }
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<31, id: \.self) { index in
                    Rectangle().fill(.white.opacity(index % 6 == 0 ? 0.4 : 0.2)).frame(maxWidth: .infinity).frame(height: index % 6 == 0 ? 13 : 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
    }
}

private struct MobileClipWaveform: View {
    @Environment(\.resonancePalette) private var palette
    let track: MobileTrack
    let samples: [Double]
    let videoFrames: [UIImage]
    @Binding var startSeconds: TimeInterval
    @Binding var endSeconds: TimeInterval
    let playhead: TimeInterval
    let onChange: () -> Void
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let duration = max(track.duration, 0.25)
            let startRatio = startSeconds / duration
            let endRatio = endSeconds / duration
            let startX = width * startRatio
            let endX = width * endRatio
            let levels = (0..<92).map { index in
                mobileSampledClipLevel(samples, at: Double(index) / 91)
            }
            ZStack {
                if !videoFrames.isEmpty {
                    HStack(spacing: 1) {
                        ForEach(Array(videoFrames.enumerated()), id: \.offset) { _, frame in
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(max(videoFrames.count, 1)), height: geometry.size.height)
                                .clipped()
                        }
                    }
                    .allowsHitTesting(false)

                    Rectangle().fill(.black.opacity(0.62))
                        .frame(width: max(startX, 0), height: geometry.size.height)
                        .position(x: max(startX, 0) / 2, y: geometry.size.height / 2)
                    Rectangle().fill(.black.opacity(0.62))
                        .frame(width: max(width - endX, 0), height: geometry.size.height)
                        .position(x: endX + max(width - endX, 0) / 2, y: geometry.size.height / 2)
                }

                Rectangle().fill(palette.secondary.opacity(0.14))
                    .frame(width: max(width * (endRatio - startRatio), 0))
                    .position(x: width * (startRatio + endRatio) / 2, y: geometry.size.height / 2)

                if videoFrames.isEmpty {
                    HStack(alignment: .center, spacing: 1) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                            let ratio = (Double(index) + 0.5) / Double(levels.count)
                            Rectangle()
                                .fill(ratio >= startRatio && ratio <= endRatio ? palette.tertiary : .white.opacity(0.25))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(9, geometry.size.height * (0.16 + 0.72 * level)))
                        }
                    }
                    .allowsHitTesting(false)
                }

                Rectangle().fill(palette.accent).frame(width: max(width * (endRatio - startRatio), 0), height: 2).position(x: width * (startRatio + endRatio) / 2, y: 1)
                Rectangle().fill(palette.accent).frame(width: max(width * (endRatio - startRatio), 0), height: 2).position(x: width * (startRatio + endRatio) / 2, y: geometry.size.height - 1)

                Rectangle().fill(.white).frame(width: 1.5).position(x: width * min(max(playhead / duration, 0), 1), y: geometry.size.height / 2)

                mobileHandle(
                    symbol: "chevron.right",
                    x: min(max(width * startRatio, 14), width - 14),
                    availableWidth: width,
                    height: geometry.size.height,
                    accessibilityName: "Clip start",
                    accessibilityValue: formatTime(startSeconds)
                )
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mobile-clip-waveform")).onChanged {
                        startSeconds = min(max(Double($0.location.x / width) * duration, 0), endSeconds - 0.25)
                        onChange()
                    })
                    .accessibilityAdjustableAction { adjustStart($0, duration: duration) }
                mobileHandle(
                    symbol: "chevron.left",
                    x: min(max(width * endRatio, 14), width - 14),
                    availableWidth: width,
                    height: geometry.size.height,
                    accessibilityName: "Clip end",
                    accessibilityValue: formatTime(endSeconds)
                )
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mobile-clip-waveform")).onChanged {
                        endSeconds = max(min(Double($0.location.x / width) * duration, duration), startSeconds + 0.25)
                        onChange()
                    })
                    .accessibilityAdjustableAction { adjustEnd($0, duration: duration) }
            }
            .coordinateSpace(name: "mobile-clip-waveform")
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("mobile-clip-waveform")).onEnded {
                onSeek(min(max(Double($0.location.x / width) * duration, startSeconds), endSeconds))
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(videoFrames.isEmpty ? "Clip waveform" : "Video frame timeline")
    }

    private func mobileHandle(
        symbol: String,
        x: CGFloat,
        availableWidth: CGFloat,
        height: CGFloat,
        accessibilityName: String,
        accessibilityValue: String
    ) -> some View {
        let hitCenter = min(max(x, 22), max(availableWidth - 22, 22))
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.accent)
                .frame(width: 28, height: height)
            Image(systemName: symbol)
                .font(.caption2.bold())
                .foregroundStyle(.white)
        }
            .offset(x: x - hitCenter)
            .frame(width: 44, height: height)
            .contentShape(Rectangle())
            .position(x: hitCenter, y: height / 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(accessibilityValue)
    }

    private func adjustStart(_ direction: AccessibilityAdjustmentDirection, duration: TimeInterval) {
        let change: TimeInterval
        switch direction {
        case .increment: change = 1
        case .decrement: change = -1
        @unknown default: return
        }
        startSeconds = min(max(startSeconds + change, 0), min(endSeconds - 0.25, duration))
        onChange()
    }

    private func adjustEnd(_ direction: AccessibilityAdjustmentDirection, duration: TimeInterval) {
        let change: TimeInterval
        switch direction {
        case .increment: change = 1
        case .decrement: change = -1
        @unknown default: return
        }
        endSeconds = max(min(endSeconds + change, duration), startSeconds + 0.25)
        onChange()
    }
}

private func mobileSampledClipLevel(_ samples: [Double], at normalizedPosition: Double) -> Double {
    guard !samples.isEmpty else { return 0.08 }
    let position = min(max(normalizedPosition, 0), 1) * Double(samples.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, samples.count - 1)
    let fraction = position - Double(lower)
    return max(0.04, samples[lower] * (1 - fraction) + samples[upper] * fraction)
}

private struct MobileClipVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

private func isVideoClipTrack(_ track: MobileTrack) -> Bool {
    ["mp4", "mov", "m4v", "webm"].contains(
        URL(fileURLWithPath: track.relativePath).pathExtension.lowercased()
    )
}
