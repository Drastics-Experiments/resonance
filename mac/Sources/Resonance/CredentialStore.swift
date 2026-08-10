import Foundation

protocol ServerCredentialStoring {
    func read(key: String) -> String?
    @discardableResult func save(_ token: String, key: String) -> Bool
    @discardableResult func delete(key: String) -> Bool
}

enum CredentialStorePolicy {
    static let previewBundleIdentifier = "com.gavindietrich.ResonancePreview"

    static func isPreviewBundle(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == previewBundleIdentifier
            || bundleIdentifier.hasPrefix(previewBundleIdentifier + ".worktree.")
    }
}

struct FileServerCredentialStore: ServerCredentialStoring {
    let storeURL: URL

    private struct StoredCredentials: Codable {
        var values: [String: String] = [:]
    }

    private struct LegacyCredentials: Codable {
        var clientToken = ""
        var adminToken = ""
    }

    func read(key: String) -> String? {
        load().values[key]
    }

    @discardableResult
    func save(_ token: String, key: String) -> Bool {
        guard !token.isEmpty else { return delete(key: key) }
        guard !token.contains("\n"), !token.contains("\r") else { return false }
        var stored = load()
        guard stored.values[key] != token else { return true }
        stored.values[key] = token
        return persist(stored)
    }

    @discardableResult
    func delete(key: String) -> Bool {
        var stored = load()
        guard stored.values.removeValue(forKey: key) != nil else { return true }
        if stored.values.isEmpty {
            do {
                if FileManager.default.fileExists(atPath: storeURL.path) {
                    try FileManager.default.removeItem(at: storeURL)
                }
                return true
            } catch {
                return false
            }
        }
        return persist(stored)
    }

    private func load() -> StoredCredentials {
        hardenExistingPermissions()
        guard let data = try? Data(contentsOf: storeURL) else { return StoredCredentials() }
        if let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            return stored
        }
        if let legacy = try? JSONDecoder().decode(LegacyCredentials.self, from: data) {
            var values: [String: String] = [:]
            if !legacy.clientToken.isEmpty {
                values["music-server-client-token"] = legacy.clientToken
            }
            if !legacy.adminToken.isEmpty {
                values["music-server-admin-token"] = legacy.adminToken
            }
            return StoredCredentials(values: values)
        }
        return StoredCredentials()
    }

    private func hardenExistingPermissions() {
        let directory = storeURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        }
    }

    private func persist(_ stored: StoredCredentials) -> Bool {
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
            return true
        } catch {
            return false
        }
    }
}
