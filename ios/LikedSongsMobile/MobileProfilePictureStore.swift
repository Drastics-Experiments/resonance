import CryptoKit
import Foundation
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

enum MobileProfilePictureStore {
    static let maximumSourceBytes = 32 * 1_024 * 1_024
    static let maximumPixelSize: CGFloat = 512

    static func load(serverURL: String, profileID: String) -> Data? {
        try? Data(contentsOf: fileURL(serverURL: serverURL, profileID: profileID))
    }

    static func save(_ sourceData: Data, serverURL: String, profileID: String) throws -> Data {
        guard sourceData.count <= maximumSourceBytes,
              let sourceImage = UIImage(data: sourceData),
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
            .appendingPathComponent("LikedSongsMobile", isDirectory: true)
            .appendingPathComponent("Profile Pictures", isDirectory: true)
    }

    private static func fileURL(serverURL: String, profileID: String) -> URL {
        profilePicturesDirectory.appendingPathComponent(
            MobileProfilePictureScope.filename(serverURL: serverURL, profileID: profileID),
            isDirectory: false
        )
    }
}
