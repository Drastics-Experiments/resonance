import Foundation
import Security

protocol ServerCredentialStoring {
    func read(account: String) -> String?
    @discardableResult func save(_ token: String, account: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

enum CredentialStorePolicy {
    static let previewBundleIdentifier = "com.gavindietrich.ResonancePreview"

    static func usesPlaintextStore(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == previewBundleIdentifier
    }
}

struct KeychainServerCredentialStore: ServerCredentialStoring {
    let service: String

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func save(_ token: String, account: String) -> Bool {
        guard !token.isEmpty else { return delete(account: account) }
        guard !token.contains("\n"), !token.contains("\r"),
              let data = token.data(using: .utf8) else { return false }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct LocalServerCredentialStore: ServerCredentialStoring {
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
