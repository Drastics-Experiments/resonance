import AVFoundation
import Foundation

enum ClipEditorError: LocalizedError {
    case missingSource
    case invalidRange
    case missingAudio
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSource:
            "The source file is no longer available on this Mac."
        case .invalidRange:
            "Choose a clip that is at least 0.25 seconds long."
        case .missingAudio:
            "The selected file does not contain an audio track."
        case .exportUnavailable:
            "This file cannot be converted into an M4A clip."
        case .exportFailed(let message):
            "The clip could not be created: \(message)"
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

enum ClipAudioProcessor {
    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }

    static func exportM4AClip(
        input: URL,
        output: URL,
        range: ClosedRange<TimeInterval>,
        title: String,
        artist: String,
        album: String,
        artwork: Data?
    ) async throws {
        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ClipEditorError.missingAudio }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
              exporter.supportedFileTypes.contains(.m4a) else {
            throw ClipEditorError.exportUnavailable
        }

        var metadata = [
            metadataItem(.commonIdentifierTitle, value: title as NSString),
            metadataItem(.commonIdentifierArtist, value: artist as NSString),
            metadataItem(.commonIdentifierAlbumName, value: album as NSString),
        ]
        if let artwork {
            metadata.append(metadataItem(.commonIdentifierArtwork, value: artwork as NSData))
        }

        exporter.metadata = metadata
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 44_100),
            duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 44_100)
        )

        let box = ExportSessionBox(exporter)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.value.outputURL = output
                box.value.outputFileType = .m4a
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: ClipEditorError.exportFailed(
                            box.value.error?.localizedDescription ?? "Unknown export error"
                        ))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
    }

    private static func metadataItem(
        _ identifier: AVMetadataIdentifier,
        value: NSCopying & NSObjectProtocol
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item.copy() as! AVMetadataItem
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
        (0..<count).map { index in
            let primary = abs(sin(Double(index) * 0.31))
            let secondary = abs(cos(Double(index) * 0.13))
            return 0.18 + (primary * 0.48) + (secondary * 0.20)
        }
    }
}
