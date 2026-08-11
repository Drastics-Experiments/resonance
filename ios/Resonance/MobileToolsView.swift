import AVFoundation
import AVKit
import QuartzCore
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
                    CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: buffer.baseAddress!
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
                                .font(.caption2)
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

            trackSelectionMenu
                .frame(maxWidth: .infinity)

            Button("Save", action: saveRange)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 12)
                .frame(height: 32)
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
            }

            Button {
                showsSettings.toggle()
                showsHelp = false
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(height: 42)
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
            .frame(height: 34)
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
                    MobileCinematicVisualizer(
                        samples: waveformSamples,
                        isPlaying: preview.isPlaying,
                        position: preview.position,
                        duration: track.duration,
                        player: preview.player
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
                        .frame(width: 32, height: 32)
                }
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 22) {
                Button { preview.seek(to: startSeconds) } label: { Image(systemName: "backward.end.fill") }
                Button { togglePreview() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.bold())
                        .frame(width: 38, height: 38)
                }
                Button { preview.seek(to: max(startSeconds, endSeconds - 0.01)) } label: { Image(systemName: "forward.end.fill") }
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
            MobileCinematicWaveform(
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
                overlayHeader("CLIP SETTINGS", "Fine tune your clip") { showsSettings = false }
                if let track = selectedTrack {
                    settingsTrackSummary(track)
                }

                HStack(spacing: 10) {
                    exactTimeField("START", text: $startText, boundary: .start)
                    exactTimeField("END", text: $endText, boundary: .end)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLIP LENGTH").eyebrow()
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
                overlayHeader("HOW IT WORKS", "Create your perfect clip") { showsHelp = false }
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(palette.raisedSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
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

    private func overlayHeader(_ eyebrow: String, _ title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow).eyebrow()
                Text(title).font(.headline)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle()) }
                .buttonStyle(.plain)
        }
    }

    private func exactTimeField(_ label: String, text: Binding<String>, boundary: ClipBoundary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).eyebrow()
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

private struct MobileCinematicVisualizer: View {
    @Environment(\.resonancePalette) private var palette
    let samples: [Double]
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let player: AVPlayer?
    @State private var livePosition: TimeInterval?

    var body: some View {
        GeometryReader { _ in
            let count = 96
            let renderedPosition = isPlaying ? livePosition ?? position : position
            let progress = duration > 0 ? min(max(renderedPosition / duration, 0), 1) : 0
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
                    with: .linearGradient(
                        Gradient(colors: [palette.secondary, palette.tertiary]),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: .zero
                    )
                )
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
            .background {
                MobileClipVisualizerFrameClock(isActive: isPlaying) {
                    let current = player?.currentTime().seconds ?? position
                    if current.isFinite {
                        livePosition = min(max(current, 0), duration)
                    }
                }
            }
        }
        .background(RadialGradient(colors: [palette.secondary.opacity(0.5), palette.background], center: .center, startRadius: 8, endRadius: 380))
        .onChange(of: isPlaying) { _, playing in
            if !playing { livePosition = nil }
        }
    }
}

private struct MobileClipVisualizerFrameClock: UIViewRepresentable {
    let isActive: Bool
    let onFrame: () -> Void

    func makeUIView(context: Context) -> MobileClipVisualizerFrameClockView {
        let view = MobileClipVisualizerFrameClockView()
        view.isActive = isActive
        view.onFrame = onFrame
        return view
    }

    func updateUIView(_ uiView: MobileClipVisualizerFrameClockView, context: Context) {
        uiView.isActive = isActive
        uiView.onFrame = onFrame
    }

    static func dismantleUIView(_ uiView: MobileClipVisualizerFrameClockView, coordinator: ()) {
        uiView.stop()
        uiView.onFrame = nil
    }
}

@MainActor
private final class MobileClipVisualizerFrameClockView: UIView {
    static let frameRate: Float = 60

    var onFrame: (() -> Void)?
    var isActive = false {
        didSet { displayLink?.isPaused = !isActive }
    }

    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        startIfNeeded()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(renderFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: Self.frameRate,
            maximum: Self.frameRate,
            preferred: Self.frameRate
        )
        displayLink.isPaused = !isActive
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func renderFrame(_ displayLink: CADisplayLink) {
        onFrame?()
    }
}

private struct MobileClipRuler: View {
    let duration: TimeInterval
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                ForEach(0...5, id: \.self) { index in
                    Text(formatTime(duration * Double(index) / 5))
                        .font(.system(size: 9, design: .monospaced))
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

private struct MobileCinematicWaveform: View {
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

                Rectangle().fill(Color(hex: 0xFFD329)).frame(width: max(width * (endRatio - startRatio), 0), height: 2).position(x: width * (startRatio + endRatio) / 2, y: 1)
                Rectangle().fill(Color(hex: 0xFFD329)).frame(width: max(width * (endRatio - startRatio), 0), height: 2).position(x: width * (startRatio + endRatio) / 2, y: geometry.size.height - 1)

                Rectangle().fill(.white).frame(width: 1.5).position(x: width * min(max(playhead / duration, 0), 1), y: geometry.size.height / 2)

                mobileHandle(symbol: "chevron.right", x: min(max(width * startRatio, 13), width - 13), height: geometry.size.height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mobile-cinematic-waveform")).onChanged {
                        startSeconds = min(max(Double($0.location.x / width) * duration, 0), endSeconds - 0.25)
                        onChange()
                    })
                mobileHandle(symbol: "chevron.left", x: min(max(width * endRatio, 13), width - 13), height: geometry.size.height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mobile-cinematic-waveform")).onChanged {
                        endSeconds = max(min(Double($0.location.x / width) * duration, duration), startSeconds + 0.25)
                        onChange()
                    })
            }
            .coordinateSpace(name: "mobile-cinematic-waveform")
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("mobile-cinematic-waveform")).onEnded {
                onSeek(min(max(Double($0.location.x / width) * duration, startSeconds), endSeconds))
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(videoFrames.isEmpty ? "Clip waveform" : "Video frame timeline")
    }

    private func mobileHandle(symbol: String, x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xFFC91D), Color(hex: 0xFFE044)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 26, height: height)
            .overlay(Image(systemName: symbol).font(.caption2.bold()).foregroundStyle(.black.opacity(0.82)))
            .position(x: x, y: height / 2)
            .shadow(color: Color(hex: 0xFFD329).opacity(0.3), radius: 8)
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

private func mobileClipLevels(seed: String, count: Int) -> [Double] {
    var state = UInt64(abs(seed.hashValue)) | 1
    var previous = 0.58
    return (0..<count).map { index in
        state = state &* 1_664_525 &+ 1_013_904_223
        let noise = Double(state & 0xffff) / Double(0xffff)
        previous = previous * 0.54 + noise * 0.46
        let envelope = 0.58 + sin(Double(index) * 0.083) * 0.16 + sin(Double(index) * 0.029) * 0.11
        return min(max(previous * 0.62 + envelope * 0.38, 0.12), 1)
    }
}

private struct LegacyMobileClipEditorSheet: View {
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
                palette.background.ignoresSafeArea()
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
                                videoPreview(track)
                                waveform(track)
                                timeFields(track)
                                previewTransport(track)
                                Text("The range is saved for \(library.visibleSyncProfileName). The song file is never changed.")
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
            preview.clear()
            resetRange()
        }
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

    @ViewBuilder
    private func videoPreview(_ track: MobileTrack) -> some View {
        if isVideoClipTrack(track) {
            ZStack {
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
            }
            .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                Label("Video preview", systemImage: "film")
                    .font(.caption2.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(10)
            }
            .accessibilityLabel("Video preview for \(track.title)")
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
                            .fill(ratio >= startRatio && ratio <= endRatio ? palette.secondary : .white.opacity(0.16))
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

                if preview.player != nil {
                    Rectangle()
                        .fill(Color(hex: 0xFF7568))
                        .frame(width: 2, height: 88)
                        .position(
                            x: min(max(width * preview.position / duration, 1), width - 1),
                            y: 52
                        )
                        .allowsHitTesting(false)
                }
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
            .background(palette.secondary, in: Capsule())
            .shadow(color: palette.secondary.opacity(0.35), radius: 8)
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
                    .foregroundStyle(palette.foregroundAccent)
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
            .tint(palette.secondary)
        }
    }

    private func previewTransport(_ track: MobileTrack) -> some View {
        let sliderRange = startSeconds...max(endSeconds, startSeconds + 0.25)
        return HStack(spacing: 10) {
            Button {
                if preview.isPlaying {
                    stopPreview(resumeMain: true)
                } else {
                    wasPlayingBeforePreview = library.isPlaying
                    if wasPlayingBeforePreview { library.pausePlayback() }
                    if preview.player == nil {
                        preview.prepare(
                            url: library.fileURL(for: track),
                            start: startSeconds,
                            end: endSeconds,
                            volume: library.volume
                        )
                    }
                    preview.toggle()
                }
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout.bold())
                    .frame(width: 38, height: 38)
                    .background(palette.secondary, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")

            Text(formatTime(preview.position))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(max(preview.position, sliderRange.lowerBound), sliderRange.upperBound) },
                    set: { preview.seek(to: $0) }
                ),
                in: sliderRange
            )
            .tint(palette.foregroundAccent)
            .accessibilityLabel("Preview position")

            Text(formatTime(endSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func setBoundary(_ boundary: ClipBoundary, seconds: TimeInterval) {
        guard let track = selectedTrack else { return }
        stopPreview(resumeMain: true)
        let value = min(max(seconds, 0), track.duration)
        if boundary == .start {
            startSeconds = min(value, endSeconds - 0.25)
        } else {
            endSeconds = max(startSeconds + 0.25, value)
        }
        updateTexts()
        preview.updateRange(start: startSeconds, end: endSeconds)
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
        preview.prepare(
            url: library.fileURL(for: track),
            start: startSeconds,
            end: endSeconds,
            volume: library.volume
        )
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
private final class MobileLocalImportViewModel: ObservableObject {
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

    var playlistProviderName: String {
        resolution?.kind == .soundCloudPlaylist ? "SoundCloud" : "Spotify"
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
                            Text("SEARCH OR LINK").eyebrow()
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
                            Text("DOWNLOAD AS").eyebrow()
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
                            Text("Video downloads use YouTube results or direct YouTube links. Spotify and SoundCloud links remain audio-only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if reviewedServerMatch {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reviewed server upload")
                                    .font(.subheadline.weight(.semibold))
                                Text("Select exactly one server-reviewed source. Resonance downloads and verifies the chosen audio or video locally, then registers its preserved source link and media type.")
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
                                         ? "Downloads every selected song first, then registers each preserved direct source link with \(library.visibleSyncProfileName)."
                                         : "Sign in to your Resonance account, or turn this off for a local-only import.")
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
                                Text("Import stopped at \(stageTitle(error.stage, mediaMode: viewModel.mediaMode).lowercased())")
                                    .font(.headline)
                                Text(error.message).font(.subheadline)
                                Text(error.code).font(.caption.monospaced()).foregroundStyle(.secondary)
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
                            .disabled(viewModel.isRunning || (viewModel.isPlaylist ? viewModel.selectedPlaylistItems.isEmpty : viewModel.selectedCandidate == nil))
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
                Text("\(ByteCountFormatter.string(fromByteCount: viewModel.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file))")
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
                Text("SEARCH RESULTS").eyebrow()
                Spacer()
                Text("\(response.results.count) \(viewModel.mediaMode == .video ? "downloadable" : "previewable")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.foregroundAccent)
            }

            ForEach(LocalImportSearchProvider.allCases) { provider in
                let results = viewModel.searchResults(for: provider)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.displayName.uppercased()).eyebrow()
                        Spacer()
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.caption2.weight(.semibold))
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
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let candidate {
                Button { viewModel.toggleSearchPreview(result) } label: {
                    if viewModel.previewLoadingVideoID == candidate.videoID {
                        ProgressView().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: viewModel.previewingVideoID == candidate.videoID ? "stop.fill" : "play.fill")
                            .frame(width: 34, height: 34)
                            .background(palette.secondary.opacity(0.18), in: Circle())
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
            LinearGradient(
                colors: [palette.secondary.opacity(0.42), palette.tertiary.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
        .accessibilityLabel("\(result.track.title) artwork")
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
            Text("MATCHED TRACK").eyebrow()
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
            Text(viewModel.mediaMode == .video ? "VIDEO SOURCE" : "AUDIO SOURCE").eyebrow()
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

                    Button { viewModel.togglePreview(candidate) } label: {
                        if viewModel.previewLoadingVideoID == candidate.videoID {
                            ProgressView().frame(width: 32, height: 32)
                        } else {
                            Image(systemName: viewModel.previewingVideoID == candidate.videoID ? "stop.fill" : "play.fill")
                                .frame(width: 32, height: 32)
                                .background(palette.secondary.opacity(0.18), in: Circle())
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
                Text("TRACKS TO IMPORT").eyebrow()
                Spacer()
                Text("\(viewModel.selectedPlaylistItems.count) of \(playlist.items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.foregroundAccent)
            }
            if playlist.unavailableCount > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SKIPPED BY \(viewModel.playlistProviderName.uppercased()) OR MATCHING").eyebrow()
                    ForEach(playlist.skippedItems) { skipped in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(skipped.position). \(skipped.title)\(skipped.artist.map { " — \($0)" } ?? "")")
                                .font(.caption.weight(.semibold))
                            Text(skipped.reason)
                                .font(.caption2)
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
                                Text([item.track.artist, item.track.durationSeconds.map { formatTime(TimeInterval($0)) }].compactMap { $0 }.joined(separator: " • "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let status = viewModel.existingStatus(for: item.track, in: library) {
                                    Text(status)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.togglePreview(item.candidate) } label: {
                        if viewModel.previewLoadingVideoID == item.candidate.videoID {
                            ProgressView().frame(width: 32, height: 32)
                        } else {
                            Image(systemName: viewModel.previewingVideoID == item.candidate.videoID ? "stop.fill" : "play.fill")
                                .frame(width: 32, height: 32)
                                .background(palette.secondary.opacity(0.18), in: Circle())
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
            LinearGradient(
                colors: [palette.secondary.opacity(0.42), palette.tertiary.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
        .accessibilityLabel("\(item.track.title) artwork")
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
    case .idle: "Enter text to search Spotify, SoundCloud, and YouTube, or paste a supported link."
    case .resolvingMetadata: "Reading the track title, artist, artwork, and duration."
    case .searchingCandidates: mediaMode == .video
        ? "Finding a downloadable YouTube video source."
        : "Finding direct provider audio or a close alternate source."
    case .awaitingSelection: "Review the match before saving \(mediaMode.rawValue) on this device."
    case .inspectingSource: "Verifying direct \(mediaMode.rawValue) streams."
    case .downloading: "Downloading verified \(mediaMode.rawValue) directly to this device."
    case .processing: mediaMode == .video
        ? "Combining compatible MP4 video and audio while preserving metadata."
        : "Preserving metadata and artwork in the local M4A."
    case .savingLocal: "Adding the finished file to Resonance."
    case .localComplete, .complete: "The song is stored locally and ready to play."
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
