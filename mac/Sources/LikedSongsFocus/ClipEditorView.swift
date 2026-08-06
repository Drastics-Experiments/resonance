import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class ClipPreviewController: ObservableObject {
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
        let shouldReplacePlayer = sourceURL?.standardizedFileURL != url.standardizedFileURL

        if shouldReplacePlayer {
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
        guard let player, rangeEnd - rangeStart >= ClipRangePolicy.minimumDuration else { return }
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
        position = 0
        rangeStart = 0
        rangeEnd = 0
        isPlaying = false
    }

    private func installTimer() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
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
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

struct MacClipEditorSheet: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = ClipPreviewController()
    @State private var selectedTrackID: UUID?
    @State private var startTime: TimeInterval = 0
    @State private var endTime: TimeInterval = 0
    @State private var clipTitle = ""
    @State private var waveformSamples: [Double] = []
    @State private var isLoadingWaveform = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var editableTracks: [Track] {
        model.tracks.filter { track in
            guard let fileURL = track.fileURL else { return false }
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    private var selectedTrack: Track? {
        guard let selectedTrackID else { return nil }
        return editableTracks.first { $0.id == selectedTrackID }
    }

    private var selectedDuration: TimeInterval {
        selectedTrack?.duration ?? 0
    }

    private var clipLength: TimeInterval {
        max(endTime - startTime, 0)
    }

    private var canCreateClip: Bool {
        guard selectedTrack != nil, !isExporting else { return false }
        return (try? ClipRangePolicy.normalized(
            start: startTime,
            end: endTime,
            sourceDuration: selectedDuration
        )) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.appLine).frame(height: 1)

            if editableTracks.isEmpty {
                emptyState
            } else {
                editor
            }
        }
        .frame(width: 760, height: 720)
        .background(Color.appPanel)
        .task {
            if selectedTrackID == nil {
                chooseTrack(model.currentTrack.flatMap { current in
                    editableTracks.first(where: { $0.id == current.id })
                } ?? editableTracks.first)
            }
        }
        .task(id: selectedTrackID) {
            await loadWaveform()
        }
        .onChange(of: startTime) { _, _ in
            preview.updateRange(start: startTime, end: endTime)
            successMessage = nil
        }
        .onChange(of: endTime) { _, _ in
            preview.updateRange(start: startTime, end: endTime)
            successMessage = nil
        }
        .onDisappear { preview.clear() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appViolet)
                .frame(width: 34, height: 34)
                .background(Color.appViolet.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Clip Editor")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Text("Select a range, preview it, then add a new M4A clip to your library.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
            }

            Spacer()

            Button {
                preview.clear()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close Clip Editor")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.appViolet)
            Text("No editable songs")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.appInk)
            Text("Add a local file or download a server song before creating a clip.")
                .font(.system(size: 11))
                .foregroundStyle(Color.appMuted)
            Button("Add Music…") { model.importLocalFiles() }
                .buttonStyle(.borderedProminent)
                .tint(Color.appViolet)
                .padding(.top, 4)
            Spacer()
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(spacing: 12) {
                sourceTrackRow

                videoPreview

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("SELECT RANGE")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Color.appMuted)
                        Spacer()
                        Text("\(clipTimeText(startTime))  –  \(clipTimeText(endTime))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appInk)
                    }

                    ZStack {
                        ClipWaveformRangeSelector(
                            samples: waveformSamples,
                            duration: selectedDuration,
                            startTime: $startTime,
                            endTime: $endTime,
                            previewPosition: preview.player == nil ? nil : preview.position
                        )
                        .frame(height: 112)

                        if isLoadingWaveform {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .padding(14)
                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appLine, lineWidth: 1)
                }

                HStack(spacing: 10) {
                    ClipTimeControl(
                        label: "Start",
                        value: $startTime,
                        range: 0...max(endTime - ClipRangePolicy.minimumDuration, 0)
                    )
                    ClipTimeControl(
                        label: "End",
                        value: $endTime,
                        range: min(startTime + ClipRangePolicy.minimumDuration, selectedDuration)...selectedDuration
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Length")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        Text(clipTimeText(clipLength))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.appViolet)
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                previewTransport

                VStack(alignment: .leading, spacing: 5) {
                    Text("CLIP NAME")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.appMuted)
                    TextField("Clip name", text: $clipTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appInk)
                }
                .padding(.horizontal, 13)
                .frame(height: 52)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.appLine, lineWidth: 1)
                }

                footer
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var videoPreview: some View {
        if selectedTrack?.kind == .video {
            ZStack {
                ClipVideoPlayer(player: preview.player)
                    .frame(height: 150)

                if !preview.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                Label("Video preview", systemImage: "film")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(10)
            }
            .accessibilityLabel("Video preview for \(selectedTrack?.title ?? "selected track")")
        }
    }

    private var previewTransport: some View {
        let sliderRange = startTime...max(endTime, startTime + ClipRangePolicy.minimumDuration)
        return HStack(spacing: 11) {
            Button(action: togglePreview) {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.appViolet, in: Circle())
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .disabled(selectedTrack?.fileURL == nil)
            .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")

            Text(clipTimeText(preview.position))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.appMuted)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(max(preview.position, sliderRange.lowerBound), sliderRange.upperBound) },
                    set: { preview.seek(to: $0) }
                ),
                in: sliderRange
            )
            .tint(Color.appViolet)
            .accessibilityLabel("Preview position")

            Text(clipTimeText(endTime))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.appMuted)
                .frame(width: 42, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .frame(height: 54)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appLine, lineWidth: 1)
        }
    }

    private var sourceTrackRow: some View {
        HStack(spacing: 12) {
            if let selectedTrack {
                TrackArtworkView(track: selectedTrack, symbolSize: 17, cornerRadius: 9)
                    .frame(width: 52, height: 52)
            } else {
                MiniArtwork(style: .weightless, symbol: "music.note", size: 52, cornerRadius: 9)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SOURCE TRACK")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.appMuted)

                Menu {
                    ForEach(editableTracks) { track in
                        Button {
                            chooseTrack(track)
                        } label: {
                            if track.id == selectedTrackID {
                                Label("\(track.title) — \(track.artist)", systemImage: "checkmark")
                            } else {
                                Text("\(track.title) — \(track.artist)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedTrack?.title ?? "Choose a song")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appInk)
                                .lineLimit(1)
                            Text(selectedTrack.map { "\($0.artist) • \($0.durationText)" } ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.appMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(hex: 0xFF7568))
                } else if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: 0x69D39B))
                } else {
                    Text("The source file is never changed.")
                        .foregroundStyle(Color.appMuted)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)

            Spacer()

            Button("Cancel") {
                preview.clear()
                dismiss()
            }

            Button {
                createClip()
            } label: {
                HStack(spacing: 7) {
                    if isExporting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "scissors") }
                    Text(isExporting ? "Creating…" : "Create Clip")
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: 106)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appViolet)
            .disabled(!canCreateClip)
        }
    }

    private func chooseTrack(_ track: Track?) {
        preview.clear()
        selectedTrackID = track?.id
        startTime = 0
        endTime = min(track?.duration ?? 0, 30)
        clipTitle = track.map { "\($0.title) Clip" } ?? ""
        errorMessage = nil
        successMessage = nil
        waveformSamples = []
        if let track, let url = track.fileURL {
            preview.prepare(url: url, start: startTime, end: endTime, volume: model.volume)
        }
    }

    private func loadWaveform() async {
        guard let track = selectedTrack, let url = track.fileURL else {
            waveformSamples = []
            return
        }
        isLoadingWaveform = true
        let samples = await ClipWaveformSampler.samples(for: url)
        guard !Task.isCancelled, track.id == selectedTrackID else { return }
        waveformSamples = samples
        isLoadingWaveform = false
    }

    private func togglePreview() {
        guard let track = selectedTrack, let url = track.fileURL else { return }
        errorMessage = nil
        if preview.player == nil {
            preview.prepare(url: url, start: startTime, end: endTime, volume: model.volume)
        }
        preview.toggle()
    }

    private func createClip() {
        guard let selectedTrackID else { return }
        preview.pause()
        errorMessage = nil
        successMessage = nil
        isExporting = true
        Task {
            do {
                let clip = try await model.createClip(
                    from: selectedTrackID,
                    startTime: startTime,
                    endTime: endTime,
                    title: clipTitle
                )
                successMessage = "Added “\(clip.title)” to Library"
                clipTitle = "\(clip.title) Copy"
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
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

private struct ClipWaveformRangeSelector: View {
    let samples: [Double]
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let previewPosition: TimeInterval?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = proxy.size.height
            let startFraction = duration > 0 ? min(max(startTime / duration, 0), 1) : 0
            let endFraction = duration > 0 ? min(max(endTime / duration, 0), 1) : 0
            let startX = width * startFraction
            let endX = width * endFraction

            ZStack {
                Canvas { context, size in
                    let values = samples.isEmpty ? [Double](repeating: 0.24, count: 72) : samples
                    let spacing: CGFloat = 2
                    let barWidth = max((size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count), 1)
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * (barWidth + spacing)
                        let barHeight = max(4, (size.height - 20) * min(max(value, 0.05), 1))
                        let centerFraction = (CGFloat(index) + 0.5) / CGFloat(values.count)
                        let selected = centerFraction >= startFraction && centerFraction <= endFraction
                        let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(selected ? Color.appViolet : Color.white.opacity(0.18))
                        )
                    }
                }
                .padding(.horizontal, 8)

                Rectangle()
                    .fill(Color.black.opacity(0.42))
                    .frame(width: startX)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Color.black.opacity(0.42))
                    .frame(width: max(width - endX, 0))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if let previewPosition, duration > 0 {
                    Rectangle()
                        .fill(Color(hex: 0xFF7568))
                        .frame(width: 1.5, height: height - 12)
                        .position(x: width * min(max(previewPosition / duration, 0), 1), y: height / 2)
                }

                rangeHandle(symbol: "chevron.right", color: Color.appViolet)
                    .position(x: min(max(startX, 8), width - 8), y: height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipWaveform"))
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let proposed = min(max(value.location.x / width * duration, 0), duration)
                                startTime = max(0, min(proposed, endTime - ClipRangePolicy.minimumDuration))
                            }
                    )

                rangeHandle(symbol: "chevron.left", color: Color.appViolet)
                    .position(x: min(max(endX, 8), width - 8), y: height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("clipWaveform"))
                            .onChanged { value in
                                guard duration > 0 else { return }
                                let proposed = min(max(value.location.x / width * duration, 0), duration)
                                endTime = min(duration, max(proposed, startTime + ClipRangePolicy.minimumDuration))
                            }
                    )
            }
            .coordinateSpace(name: "clipWaveform")
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clip range")
            .accessibilityValue("From \(clipTimeText(startTime)) to \(clipTimeText(endTime))")
        }
    }

    private func rangeHandle(symbol: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 16, height: 34)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .shadow(color: color.opacity(0.35), radius: 6)
            .frame(width: 30, height: 54)
            .contentShape(Rectangle())
    }
}

private struct ClipTimeControl: View {
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.appMuted)

            TextField("0:00.0", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appInk)
                .padding(.horizontal, 8)
                .frame(height: 27)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isFocused ? Color.appViolet.opacity(0.75) : Color.appLine, lineWidth: 1)
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
