import AppKit
import Accelerate
import AVFoundation
import Foundation

enum ClipEditorError: LocalizedError {
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "Choose a clip that is at least 0.25 seconds long."
        }
    }
}

struct ClipRangePolicy {
    static let minimumDuration: TimeInterval = 0.25

    static func normalized(
        start: TimeInterval,
        end: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> ClosedRange<TimeInterval> {
        guard sourceDuration.isFinite, sourceDuration >= minimumDuration else {
            throw ClipEditorError.invalidRange
        }
        let lower = min(max(start.isFinite ? start : 0, 0), sourceDuration)
        let upper = min(max(end.isFinite ? end : sourceDuration, 0), sourceDuration)
        guard upper - lower >= minimumDuration else {
            throw ClipEditorError.invalidRange
        }
        return lower...upper
    }
}

enum ClipEditorTrackPolicy {
    static func isEditable(
        _ track: Track,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> Bool {
        guard let fileURL = track.fileURL else { return false }
        return fileExists(fileURL.path)
    }

    static func initialTrack(
        from editableTracks: [Track],
        requestedTrackID: UUID?,
        currentTrackID: UUID?
    ) -> Track? {
        if let requestedTrackID,
           let requestedTrack = editableTracks.first(where: { $0.id == requestedTrackID }) {
            return requestedTrack
        }
        if let currentTrackID,
           let currentTrack = editableTracks.first(where: { $0.id == currentTrackID }) {
            return currentTrack
        }
        return editableTracks.first
    }
}

final class ClipLiveSpectrumAnalyzer: @unchecked Sendable {
    static let barCount = 112
    private static let sampleCount = 512
    private static let smoothing = 0.72

    private let queue = DispatchQueue(label: "Resonance.ClipLiveSpectrum", qos: .userInteractive)
    private let transform: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let levelsLock = NSLock()
    private let pendingSamplesLock = NSLock()
    private var smoothedMagnitudes = [Double](repeating: 0, count: sampleCount / 2)
    private var latestLevels = [Double](repeating: 0, count: barCount)
    private var pendingSamples: [Float]?
    private var isAnalysisScheduled = false

    init() {
        transform = try! vDSP.DiscreteFourierTransform(
            count: Self.sampleCount,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        window = (0..<Self.sampleCount).map { index in
            let phase = 2 * .pi * Float(index) / Float(Self.sampleCount)
            return 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else { return }
        let availableFrames = Int(buffer.frameLength)
        let copiedFrames = min(availableFrames, Self.sampleCount)
        let sourceStart = availableFrames - copiedFrames
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: Self.sampleCount)
        for frame in 0..<copiedFrames {
            var mixedSample: Float = 0
            for channel in 0..<channelCount {
                mixedSample += channels[channel][sourceStart + frame]
            }
            samples[Self.sampleCount - copiedFrames + frame] = mixedSample / Float(channelCount)
        }
        pendingSamplesLock.lock()
        pendingSamples = samples
        let shouldScheduleAnalysis = !isAnalysisScheduled
        isAnalysisScheduled = true
        pendingSamplesLock.unlock()

        guard shouldScheduleAnalysis else { return }
        queue.async { [self] in analyzePendingSamples() }
    }

    func snapshot() -> [Double] {
        levelsLock.lock()
        defer { levelsLock.unlock() }
        return latestLevels
    }

    func reset() {
        queue.async { [self] in
            smoothedMagnitudes = [Double](repeating: 0, count: Self.sampleCount / 2)
            levelsLock.lock()
            latestLevels = [Double](repeating: 0, count: Self.barCount)
            levelsLock.unlock()
        }
    }

    private func analyzePendingSamples() {
        while true {
            pendingSamplesLock.lock()
            guard let samples = pendingSamples else {
                isAnalysisScheduled = false
                pendingSamplesLock.unlock()
                return
            }
            pendingSamples = nil
            pendingSamplesLock.unlock()

            analyze(samples)
        }
    }

    private func analyze(_ samples: [Float]) {
        var windowed = samples
        for index in windowed.indices { windowed[index] *= window[index] }
        let imaginary = [Float](repeating: 0, count: Self.sampleCount)
        let spectrum = transform.transform(real: windowed, imaginary: imaginary)
        let usableBinCount = Int(Double(Self.sampleCount / 2) * 0.72)
        var normalizedBins = [Double](repeating: 0, count: Self.sampleCount / 2)

        for bin in normalizedBins.indices {
            let magnitude = Double(hypot(spectrum.real[bin], spectrum.imaginary[bin]))
                / Double(Self.sampleCount / 2)
            smoothedMagnitudes[bin] = smoothedMagnitudes[bin] * Self.smoothing
                + magnitude * (1 - Self.smoothing)
            let decibels = 20 * log10(max(smoothedMagnitudes[bin], 0.000_000_1))
            let normalized = min(max((decibels + 100) / 70, 0), 1)
            normalizedBins[bin] = Double(Int(normalized * 255)) / 255
        }

        var levels = [Double](repeating: 0, count: Self.barCount)
        for bar in 0..<Self.barCount {
            let lowerBin = Int(Double(bar) / Double(Self.barCount) * Double(usableBinCount))
            let upperBin = max(
                lowerBin + 1,
                Int(Double(bar + 1) / Double(Self.barCount) * Double(usableBinCount))
            )
            var energy = 0.0
            for bin in lowerBin..<min(upperBin, usableBinCount) {
                energy = max(energy, normalizedBins[bin])
            }
            levels[bar] = energy
        }
        levelsLock.lock()
        latestLevels = levels
        levelsLock.unlock()
    }
}

enum ClipWaveformSampler {
    static func samples(for url: URL, count: Int = 132) async -> [Double] {
        guard count > 0 else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds.isFinite,
                  duration.seconds > 0,
                  let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else {
                return fallback(count: count)
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
            guard reader.canAdd(output) else { return fallback(count: count) }
            reader.add(output)
            guard reader.startReading() else { return fallback(count: count) }

            var peaks = [Double](repeating: 0, count: count)
            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(dataBuffer)
                guard byteCount >= MemoryLayout<Int16>.size else { continue }
                var bytes = [UInt8](repeating: 0, count: byteCount)
                let copyStatus = bytes.withUnsafeMutableBytes { buffer in
                    CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: buffer.baseAddress!
                    )
                }
                guard copyStatus == kCMBlockBufferNoErr else { continue }

                var peak = 0.0
                bytes.withUnsafeBytes { buffer in
                    let values = buffer.bindMemory(to: Int16.self)
                    for value in values {
                        peak = max(peak, min(Double(abs(Int(value))) / Double(Int16.max), 1))
                    }
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                guard timestamp.isFinite else { continue }
                let index = min(max(Int((timestamp / duration.seconds) * Double(count)), 0), count - 1)
                peaks[index] = max(peaks[index], peak)
            }

            guard peaks.contains(where: { $0 > 0 }) else { return fallback(count: count) }
            fillEmptySamples(&peaks)
            let maximum = peaks.max() ?? 1
            return peaks.map { max(0.08, sqrt($0 / max(maximum, 0.000_1))) }
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

    private static func fallback(count: Int) -> [Double] {
        [Double](repeating: 0.08, count: count)
    }
}

enum ClipVideoFrameSampler {
    static func frames(for url: URL, duration: TimeInterval, count: Int = 12) async -> [NSImage] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        let encodedFrames = await Task.detached(priority: .userInitiated) { () -> [Data] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 203)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            return (0..<count).compactMap { index in
                guard !Task.isCancelled else { return nil }
                let seconds = duration * (Double(index) + 0.5) / Double(count)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                let representation = NSBitmapImageRep(cgImage: image)
                return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
            }
        }.value
        return encodedFrames.compactMap(NSImage.init(data:))
    }
}
