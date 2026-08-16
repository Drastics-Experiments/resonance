import AppKit
import Foundation
import ImageIO
import SwiftUI

enum MacArtworkURLPolicy {
    static let maximumURLBytes = 8_192
    private static let providerHosts = [
        "scdn.co",
        "spotifycdn.com",
        "ytimg.com",
        "ggpht.com",
        "sndcdn.com",
    ]

    static func allowedURL(_ url: URL, serverOrigin: URL? = nil) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= maximumURLBytes,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              url.port == nil || url.port == 443,
              !isPrivateHost(host) else { return nil }

        if isProviderHost(host) || sameOrigin(url, serverOrigin) {
            return url
        }
        return nil
    }

    /// Profile images may be hosted by an external identity provider. Keep
    /// that surface limited to credential-free public HTTPS origins; callers
    /// still validate the image response and decoded dimensions separately.
    static func allowedPublicURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= maximumURLBytes,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              url.port == nil || url.port == 443,
              !isPrivateHost(host) else { return nil }
        return url
    }

    static func isWithinDecodedPixelBounds(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= 4_096, height <= 4_096 else { return false }
        return Int64(width) * Int64(height) <= 16_777_216
    }

    private static func isProviderHost(_ host: String) -> Bool {
        providerHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs,
              rhs.scheme?.lowercased() == "https",
              rhs.user == nil,
              rhs.password == nil,
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else { return false }
        let lhsPort = lhs.port ?? 443
        let rhsPort = rhs.port ?? 443
        return lhsHost == rhsHost && lhsPort == rhsPort
    }

    /// Reject destinations that are commonly used for loopback, link-local,
    /// RFC1918, carrier-grade NAT, or other local-only services. This is a
    /// lexical check; the redirect delegate also re-evaluates every hop.
    static func isPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa") {
            return true
        }

        func isPrivateIPv4(_ value: String) -> Bool {
            let octets = value.split(separator: ".", omittingEmptySubsequences: false)
            let values = octets.compactMap { Int($0) }
            guard octets.count == 4,
                  values.count == 4,
                  octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  values.allSatisfy({ (0...255).contains($0) }) else { return false }
            let first = values[0]
            let second = values[1]
            if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
            if first == 100, (64...127).contains(second) { return true }
            if first == 169, second == 254 { return true }
            if first == 172, (16...31).contains(second) { return true }
            if first == 192, second == 0 { return true }
            if first == 192, second == 168 { return true }
            if first == 198, (18...19).contains(second) { return true }
            return false
        }
        if isPrivateIPv4(host) {
            return true
        }
        if host.allSatisfy(\.isNumber), !host.isEmpty {
            // Decimal-only hostnames can be parsed by URL clients as a
            // 32-bit IPv4 address (for example, 2130706433 == 127.0.0.1).
            return true
        }
        if host.contains(":"),
           let embeddedIPv4 = host.split(separator: ":").last,
           isPrivateIPv4(String(embeddedIPv4)) {
            return true
        }

        if host == "::" || host == "::1"
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || host.hasPrefix("fe8")
            || host.hasPrefix("fe9")
            || host.hasPrefix("fea")
            || host.hasPrefix("feb")
            || host.hasPrefix("ff") {
            return true
        }
        return false
    }
}

private final class MacArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validator: @Sendable (URL) -> Bool

    init(validator: @escaping @Sendable (URL) -> Bool) {
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(validator) == true ? request : nil)
    }
}

enum ArtworkCropping {
    static let maxRemoteBytes = 10 * 1_024 * 1_024
    private static let imageCache = NSCache<NSData, NSImage>()

    static func squareImage(from data: Data) -> NSImage? {
        guard let image = validatedImage(from: data) else { return nil }
        let key = data as NSData
        if let cached = imageCache.object(forKey: key) { return cached }
        let cropped = squareImage(image)
        imageCache.setObject(cropped, forKey: key)
        return cropped
    }

    static func validatedImage(from data: Data) -> NSImage? {
        guard data.count <= maxRemoteBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              MacArtworkURLPolicy.isWithinDecodedPixelBounds(width: width, height: height),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: decoded, size: NSSize(width: width, height: height))
    }

    static func remoteImageData(
        from url: URL,
        serverOrigin: URL? = nil,
        allowPublicHost: Bool = false
    ) async -> Data? {
        let validate: @Sendable (URL) -> URL? = { candidate in
            if allowPublicHost {
                return MacArtworkURLPolicy.allowedPublicURL(candidate)
            }
            return MacArtworkURLPolicy.allowedURL(candidate, serverOrigin: serverOrigin)
        }
        guard let initialURL = validate(url) else {
            return nil
        }
        let delegate = MacArtworkRedirectDelegate { candidate in
            validate(candidate) != nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: initialURL)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let response = rawResponse as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let finalURL = response.url,
                  validate(finalURL) != nil,
                  response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true else {
                return nil
            }
            if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared > maxRemoteBytes {
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(maxRemoteBytes, 256 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxRemoteBytes else { return nil }
                data.append(byte)
            }
            return data
        } catch {
            return nil
        }
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
    let serverOrigin: URL?
    @ViewBuilder let placeholder: (_ isLoading: Bool) -> Placeholder

    @State private var image: NSImage?
    @State private var isLoading = true

    init(
        url: URL,
        serverOrigin: URL? = nil,
        @ViewBuilder placeholder: @escaping (_ isLoading: Bool) -> Placeholder
    ) {
        self.url = url
        self.serverOrigin = serverOrigin
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            placeholder(isLoading)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: url.absoluteString + (serverOrigin?.absoluteString ?? "")) {
            image = nil
            isLoading = true
            defer { isLoading = false }
            guard let data = await ArtworkCropping.remoteImageData(from: url, serverOrigin: serverOrigin),
                  !Task.isCancelled,
                  let cropped = ArtworkCropping.squareImage(from: data) else { return }
            image = cropped
        }
    }
}
