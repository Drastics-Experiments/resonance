import Foundation

struct LocalServerCredentialStore {
    let storeURL: URL

    private struct StoredCredentials: Codable {
        var values: [String: String] = [:]
    }

    private struct LegacyCredentials: Codable {
        var clientToken = ""
        var adminToken = ""
    }

    func read(account: String) -> String? {
        load().values[account]
    }

    @discardableResult
    func save(_ token: String, account: String) -> Bool {
        guard !token.isEmpty else { return delete(account: account) }
        guard !token.contains("\n"), !token.contains("\r") else { return false }
        var stored = load()
        guard stored.values[account] != token else { return true }
        stored.values[account] = token
        return persist(stored)
    }

    @discardableResult
    func delete(account: String) -> Bool {
        var stored = load()
        guard stored.values.removeValue(forKey: account) != nil else { return true }
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
