import AppKit
import CryptoKit
import Foundation

enum ProfilePictureScope {
    static func contextKey(serverURL: String, profileID: String) -> String {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = ServerSongIdentity.normalizedOrigin(trimmedServer) ?? trimmedServer
        let normalizedProfile = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedServer)#profile=\(normalizedProfile.isEmpty ? "default" : normalizedProfile)"
    }

    static func filename(serverURL: String, profileID: String) -> String {
        let digest = SHA256.hash(data: Data(contextKey(serverURL: serverURL, profileID: profileID).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).jpg"
    }
}

enum MacProfilePictureStore {
    static let maximumPixelSize = 512
    static let maximumSourceBytes = 32 * 1_024 * 1_024

    static func load(serverURL: String, profileID: String) -> Data? {
        try? Data(contentsOf: fileURL(serverURL: serverURL, profileID: profileID))
    }

    static func save(sourceURL: URL, serverURL: String, profileID: String) throws -> Data {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let jpegData = try normalizedJPEGData(sourceData)
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

    static func normalizedJPEGData(_ sourceData: Data) throws -> Data {
        guard sourceData.count <= maximumSourceBytes,
              let sourceImage = NSImage(data: sourceData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var proposedRect = CGRect(origin: .zero, size: sourceImage.size)
        guard let source = sourceImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = min(source.width, source.height)
        guard side > 0,
              let cropped = source.cropping(to: CGRect(
                x: (source.width - side) / 2,
                y: (source.height - side) / 2,
                width: side,
                height: side
              )) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let targetSize = min(side, maximumPixelSize)
        guard let context = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        guard let rendered = context.makeImage(),
              let output = NSBitmapImageRep(cgImage: rendered)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output
    }

    private static var profilePicturesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liked Songs", isDirectory: true)
            .appendingPathComponent("Profile Pictures", isDirectory: true)
    }

    private static func fileURL(serverURL: String, profileID: String) -> URL {
        profilePicturesDirectory.appendingPathComponent(
            ProfilePictureScope.filename(serverURL: serverURL, profileID: profileID),
            isDirectory: false
        )
    }
}
