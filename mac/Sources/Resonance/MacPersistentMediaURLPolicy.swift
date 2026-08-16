import Foundation

/// Provider rendition URLs are short-lived capabilities, not durable source
/// links. Keep them available for the in-memory transfer that just obtained
/// them, but never carry them into the library or recovery backup.
enum MacPersistentMediaURLPolicy {
    static let maximumURLBytes = 8_192

    static func isShortLivedProviderMedia(_ value: String?) -> Bool {
        guard let value,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              isShortLivedProviderMedia(url) else { return false }
        return true
    }

    static func isShortLivedProviderMedia(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else { return false }
        if LocalImportURL.isGoogleVideo(url) || LocalImportURL.isSoundCloudMedia(url) {
            return true
        }
        if host == "p.scdn.co" || host.hasSuffix(".p.scdn.co") {
            return true
        }
        return url.lastPathComponent.lowercased() == "videoplayback"
    }

    static func persistentString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumURLBytes,
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.fragment == nil,
              url.user == nil,
              url.password == nil,
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              !MacArtworkURLPolicy.isPrivateHost(host),
              !isShortLivedProviderMedia(url) else { return nil }
        return trimmed
    }

    static func persistentString(_ url: URL?) -> String? {
        persistentString(url?.absoluteString)
    }

    static func sanitized(_ track: Track) -> Track {
        var sanitized = track
        sanitized.artworkURL = persistentString(track.artworkURL)
        sanitized.sourceServer = persistentString(track.sourceServer)
        sanitized.sourceURL = persistentString(track.sourceURL)
        sanitized.downloadSourceURL = persistentString(track.downloadSourceURL)
        return sanitized
    }

    /// Redact provider media strings from a JSON recovery payload without
    /// retaining the raw potentially-expired capability. If the bytes are not
    /// valid JSON, no backup is produced.
    static func sanitizedRecoveryData(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let sanitized = sanitizeJSON(object)
        return try? JSONSerialization.data(withJSONObject: sanitized)
    }

    private static func sanitizeJSON(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitizeJSON)
        }
        if let array = value as? [Any] {
            return array.map(sanitizeJSON)
        }
        if let string = value as? String,
           isURLLike(string),
           persistentString(string) == nil {
            return NSNull()
        }
        return value
    }

    private static func isURLLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("://") || URLComponents(string: trimmed)?.scheme != nil
    }
}
