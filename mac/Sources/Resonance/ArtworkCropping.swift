import AppKit
import SwiftUI

enum ArtworkCropping {
    private static let imageCache = NSCache<NSData, NSImage>()

    static func squareImage(from data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let source = NSImage(data: data) else { return nil }
        let image = squareImage(source)
        imageCache.setObject(image, forKey: key)
        return image
    }

    static func squareImage(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let cropRect = squareCropRect(in: source)
        let sourceRect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard cropRect.width > 0,
              cropRect.height > 0,
              cropRect != sourceRect,
              let cropped = source.cropping(to: cropRect) else { return image }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
    }

    static func squareCropRect(in image: CGImage) -> CGRect {
        let sourceBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let contentBounds = detectedContentBounds(in: image)
        let side = min(contentBounds.width, contentBounds.height)
        guard side > 0 else { return sourceBounds }
        return CGRect(
            x: contentBounds.midX - side / 2,
            y: contentBounds.midY - side / 2,
            width: side,
            height: side
        ).integral.intersection(sourceBounds)
    }

    private static func detectedContentBounds(in image: CGImage) -> CGRect {
        let sourceWidth = image.width
        let sourceHeight = image.height
        let sampleScale = min(1, 160 / Double(max(sourceWidth, sourceHeight)))
        let sampleWidth = max(Int((Double(sourceWidth) * sampleScale).rounded()), 1)
        let sampleHeight = max(Int((Double(sourceHeight) * sampleScale).rounded()), 1)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        struct LineStats {
            let channels: [Double]
            let deviation: Double
        }

        func stats(for offsets: [Int]) -> LineStats {
            guard !offsets.isEmpty else { return LineStats(channels: [0, 0, 0, 0], deviation: 255) }
            var totals = [Double](repeating: 0, count: bytesPerPixel)
            for offset in offsets {
                for channel in 0..<bytesPerPixel {
                    totals[channel] += Double(pixels[offset + channel])
                }
            }
            let means = totals.map { $0 / Double(offsets.count) }
            var totalDeviation = 0.0
            for offset in offsets {
                for channel in 0..<bytesPerPixel {
                    totalDeviation += abs(Double(pixels[offset + channel]) - means[channel])
                }
            }
            return LineStats(
                channels: means,
                deviation: totalDeviation / Double(offsets.count * bytesPerPixel)
            )
        }

        func rowStats(_ row: Int, xRange: Range<Int>) -> LineStats {
            stats(for: xRange.map { row * bytesPerRow + $0 * bytesPerPixel })
        }

        func columnStats(_ column: Int, yRange: Range<Int>) -> LineStats {
            stats(for: yRange.map { $0 * bytesPerRow + column * bytesPerPixel })
        }

        func colorDistance(_ lhs: LineStats, _ rhs: LineStats) -> Double {
            zip(lhs.channels, rhs.channels).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(bytesPerPixel)
        }

        func borderRun(lineCount: Int, statsAt: (Int) -> LineStats, fromStart: Bool) -> Int {
            guard lineCount >= 6 else { return 0 }
            let edgeIndex = fromStart ? 0 : lineCount - 1
            let reference = statsAt(edgeIndex)
            guard reference.deviation <= 10 else { return 0 }
            var count = 0
            for offset in 0..<(lineCount / 2) {
                let index = fromStart ? offset : lineCount - 1 - offset
                let candidate = statsAt(index)
                guard candidate.deviation <= 13, colorDistance(candidate, reference) <= 18 else { break }
                count += 1
            }
            return count
        }

        func symmetricInsets(_ first: Int, _ second: Int, length: Int) -> (Int, Int) {
            guard first >= 2, second >= 2, first + second < length * 3 / 4 else { return (0, 0) }
            let tolerance = max(2, min(first, second) / 3)
            guard abs(first - second) <= tolerance else { return (0, 0) }
            return (first, second)
        }

        let fullXRange = 0..<sampleWidth
        let firstRows = borderRun(
            lineCount: sampleHeight,
            statsAt: { rowStats($0, xRange: fullXRange) },
            fromStart: true
        )
        let lastRows = borderRun(
            lineCount: sampleHeight,
            statsAt: { rowStats($0, xRange: fullXRange) },
            fromStart: false
        )
        let (rowInsetStart, rowInsetEnd) = symmetricInsets(firstRows, lastRows, length: sampleHeight)
        let contentYRange = rowInsetStart..<(sampleHeight - rowInsetEnd)

        let firstColumns = borderRun(
            lineCount: sampleWidth,
            statsAt: { columnStats($0, yRange: contentYRange) },
            fromStart: true
        )
        let lastColumns = borderRun(
            lineCount: sampleWidth,
            statsAt: { columnStats($0, yRange: contentYRange) },
            fromStart: false
        )
        let (columnInsetStart, columnInsetEnd) = symmetricInsets(firstColumns, lastColumns, length: sampleWidth)

        let scaleX = CGFloat(sourceWidth) / CGFloat(sampleWidth)
        let scaleY = CGFloat(sourceHeight) / CGFloat(sampleHeight)
        return CGRect(
            x: CGFloat(columnInsetStart) * scaleX,
            y: CGFloat(rowInsetStart) * scaleY,
            width: CGFloat(sampleWidth - columnInsetStart - columnInsetEnd) * scaleX,
            height: CGFloat(sampleHeight - rowInsetStart - rowInsetEnd) * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
    }
}

struct CroppedRemoteArtwork<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: (_ isLoading: Bool) -> Placeholder

    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            placeholder(isLoading)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: url) {
            image = nil
            isLoading = true
            defer { isLoading = false }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                  let cropped = ArtworkCropping.squareImage(from: data) else { return }
            image = cropped
        }
    }
}
