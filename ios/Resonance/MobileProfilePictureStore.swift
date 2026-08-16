import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

enum MobileProfilePictureScope {
    static func contextKey(serverURL: String, profileID: String) -> String {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = URL(string: trimmedServer)
            .flatMap(MobileServerEndpointPolicy.normalizedOrigin(of:)) ?? trimmedServer
        let profile = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedServer)#profile=\(profile.isEmpty ? "default" : profile)"
    }

    static func filename(serverURL: String, profileID: String) -> String {
        let digest = SHA256.hash(data: Data(contextKey(serverURL: serverURL, profileID: profileID).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).jpg"
    }
}

enum MobileArtworkURLPolicy {
    private static let providerRoots = [
        "scdn.co",
        "spotifycdn.com",
        "ytimg.com",
        "ggpht.com",
        "googleusercontent.com",
        "sndcdn.com",
    ]
    private static let approvedServerHosts = [
        "resonance-core.blithe-haven-9710.chatgpt.site",
        "music.unblocked.mov",
    ]

    static func validated(_ url: URL, allowedOrigin: URL? = nil) -> URL? {
        guard MobileDurableURLPolicy.accepts(url) else { return nil }
        if let allowedOrigin {
            guard MobileDurableURLPolicy.accepts(allowedOrigin),
                  isPublicHTTPS(allowedOrigin),
                  let resolved = url.scheme == nil
                    ? URL(string: url.relativeString, relativeTo: allowedOrigin)?.absoluteURL
                    : url,
                  isPublicHTTPS(resolved),
                  MobileDurableURLPolicy.accepts(resolved),
                  MobileSameOriginPolicy.matches(resolved, allowedOrigin) else {
                return nil
            }
            return resolved
        }
        guard isPublicHTTPS(url), let host = url.host?.lowercased() else { return nil }
        guard isApprovedProviderHost(host) || approvedServerHosts.contains(host) else { return nil }
        return url
    }

    static func isApprovedProviderHost(_ host: String) -> Bool {
        providerRoots.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Catalog rows are decoded before the configured server origin is
    /// available. Keep only a credential-free public HTTPS candidate here;
    /// callers must still validate it against that server origin before use.
    static func validatedCatalogURL(_ url: URL) -> URL? {
        guard MobileDurableURLPolicy.accepts(url),
              url.scheme == nil || isPublicHTTPS(url) else { return nil }
        return url
    }

    static func redirectAllowed(_ url: URL, initialURL: URL, allowedOrigin: URL? = nil) -> Bool {
        guard let validatedURL = validated(url, allowedOrigin: allowedOrigin) else { return false }
        if let allowedOrigin {
            return MobileSameOriginPolicy.matches(validatedURL, allowedOrigin)
        }
        guard let initialHost = initialURL.host?.lowercased(),
              let redirectHost = validatedURL.host?.lowercased() else { return false }
        return isApprovedProviderHost(initialHost)
            ? isApprovedProviderHost(redirectHost)
            : initialHost == redirectHost
    }

    private static func isPublicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !host.contains(":"),
              !isPrivateOrLocalHost(host) else { return false }
        return true
    }

    private static func isPrivateOrLocalHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "broadcasthost" {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        let first = octets[0]
        let second = octets[1]
        switch first {
        case 0, 10, 127, 224...255:
            return true
        case 100 where (64...127).contains(second):
            return true
        case 169 where second == 254:
            return true
        case 172 where (16...31).contains(second):
            return true
        case 192 where second == 0 || second == 168:
            return true
        case 198 where (18...19).contains(second)
            || (second == 51 && octets[2] == 100):
            return true
        case 203 where second == 0 && octets[2] == 113:
            return true
        default:
            return false
        }
    }

    static func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = request.url,
              validated(requestURL) != nil else {
            throw URLError(.dataNotAllowed)
        }
        let delegate = MobileArtworkRedirectDelegate(initialURL: requestURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let responseURL = response.url,
              redirectAllowed(responseURL, initialURL: requestURL) else {
            throw URLError(.dataNotAllowed)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw MobileSensitiveResponseError.tooLarge(limit: maximumBytes)
        }
        var body = Data()
        body.reserveCapacity(min(maximumBytes, max(Int(response.expectedContentLength), 0)))
        for try await byte in bytes {
            guard MobileBoundedResponsePolicy.accepts(
                currentCount: body.count,
                adding: 1,
                maximum: maximumBytes
            ) else {
                throw MobileSensitiveResponseError.tooLarge(limit: maximumBytes)
            }
            body.append(byte)
        }
        return (body, response)
    }
}

private final class MobileArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let initialURL: URL

    init(initialURL: URL) {
        self.initialURL = initialURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              MobileArtworkURLPolicy.redirectAllowed(redirectURL, initialURL: initialURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum MobileArtworkImagePolicy {
    static let maximumPixelCount = 16_000_000
    static let maximumDimension = 4_096
    static let thumbnailPixelSize = 1_024

    static func image(from data: Data, maximumSourceBytes: Int = MobileArtworkURLPolicyMaximums.sourceBytes) -> UIImage? {
        guard data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixelCount / max(height, 1) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }

    static func jpegData(from data: Data, maximumSourceBytes: Int = MobileArtworkURLPolicyMaximums.sourceBytes) -> Data? {
        image(from: data, maximumSourceBytes: maximumSourceBytes)?.jpegData(compressionQuality: 0.9)
    }
}

private enum MobileArtworkURLPolicyMaximums {
    static let sourceBytes = 10 * 1_024 * 1_024
}

struct MobileSafeArtworkImage<Content: View>: View {
    let url: URL
    let allowedOrigin: URL?
    private let content: (Image) -> Content
    @StateObject private var loader: MobileSafeArtworkLoader

    init(
        url: URL,
        allowedOrigin: URL? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.allowedOrigin = allowedOrigin
        self.content = content
        _loader = StateObject(wrappedValue: MobileSafeArtworkLoader(url: url, allowedOrigin: allowedOrigin))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            }
        }
        .task(id: "\(url.absoluteString)|\(allowedOrigin?.absoluteString ?? "")") {
            await loader.load(url: url, allowedOrigin: allowedOrigin)
        }
    }
}

@MainActor
private final class MobileSafeArtworkLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    init(url: URL, allowedOrigin: URL?) {}

    func load(url: URL, allowedOrigin: URL?) async {
        image = nil
        guard let safeURL = MobileArtworkURLPolicy.validated(url, allowedOrigin: allowedOrigin) else {
            return
        }
        var request = URLRequest(url: safeURL)
        request.setValue("image/avif,image/webp,image/png,image/jpeg", forHTTPHeaderField: "Accept")
        do {
            let (data, response): (Data, HTTPURLResponse)
            if let allowedOrigin {
                (data, response) = try await MobileSensitiveNetworkPolicy.data(
                    for: request,
                    origin: allowedOrigin,
                    maximumBytes: MobileBoundedResponsePolicy.artworkMaximumBytes
                )
            } else {
                (data, response) = try await MobileArtworkURLPolicy.data(
                    for: request,
                    maximumBytes: MobileBoundedResponsePolicy.artworkMaximumBytes
                )
            }
            guard (200..<300).contains(response.statusCode),
                  response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
                  let decoded = MobileArtworkImagePolicy.image(from: data) else {
                image = nil
                return
            }
            image = decoded
        } catch {
            image = nil
        }
    }
}

enum MobileProfilePictureStore {
    static let maximumSourceBytes = 32 * 1_024 * 1_024
    static let maximumPixelSize: CGFloat = 512

    static func load(serverURL: String, profileID: String) -> Data? {
        try? Data(contentsOf: fileURL(serverURL: serverURL, profileID: profileID))
    }

    static func save(_ sourceData: Data, serverURL: String, profileID: String) throws -> Data {
        guard sourceData.count <= maximumSourceBytes,
              let sourceImage = MobileArtworkImagePolicy.image(
                  from: sourceData,
                  maximumSourceBytes: maximumSourceBytes
              ),
              sourceImage.size.width > 0,
              sourceImage.size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = min(sourceImage.size.width, sourceImage.size.height)
        let sourceRect = CGRect(
            x: (sourceImage.size.width - side) / 2,
            y: (sourceImage.size.height - side) / 2,
            width: side,
            height: side
        )
        let target = min(side, maximumPixelSize)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target))
        let rendered = renderer.image { _ in
            sourceImage.draw(
                in: CGRect(
                    x: -sourceRect.minX * target / side,
                    y: -sourceRect.minY * target / side,
                    width: sourceImage.size.width * target / side,
                    height: sourceImage.size.height * target / side
                )
            )
        }
        guard let jpegData = rendered.jpegData(compressionQuality: 0.88) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = profilePicturesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpegData.write(
            to: fileURL(serverURL: serverURL, profileID: profileID),
            options: .atomic
        )
        return jpegData
    }

    static func remove(serverURL: String, profileID: String) throws {
        let url = fileURL(serverURL: serverURL, profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static var profilePicturesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
            .appendingPathComponent("Profile Pictures", isDirectory: true)
    }

    private static func fileURL(serverURL: String, profileID: String) -> URL {
        profilePicturesDirectory.appendingPathComponent(
            MobileProfilePictureScope.filename(serverURL: serverURL, profileID: profileID),
            isDirectory: false
        )
    }
}
