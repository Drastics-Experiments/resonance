import Foundation
import OSLog

protocol ServerCredentialStoring {
    func read(key: String) -> String?
    @discardableResult func save(_ token: String, key: String) -> Bool
    @discardableResult func delete(key: String) -> Bool
}

enum ResonanceApplicationSupport {
    static func root(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
    }
}

enum CredentialEnvironmentBootstrap {
    @discardableResult
    static func persist(
        environment: [String: String],
        store: any ServerCredentialStoring,
        clientKey: String,
        adminKey: String,
        unset: (String) -> Void
    ) -> Bool {
        guard let client = environment["RESONANCE_CLIENT_TOKEN"],
              let admin = environment["RESONANCE_ADMIN_TOKEN"],
              !client.isEmpty, !admin.isEmpty else { return true }
        guard store.save(client, key: clientKey),
              store.save(admin, key: adminKey) else { return false }
        unset("RESONANCE_CLIENT_TOKEN")
        unset("RESONANCE_ADMIN_TOKEN")
        return true
    }
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
    private static let logger = Logger(
        subsystem: "com.gavindietrich.Resonance",
        category: "CredentialStore"
    )

    let storeURL: URL

    private struct StoredCredentials: Codable {
        var values: [String: String] = [:]
    }

    private struct LegacyCredentials: Codable {
        var clientToken = ""
        var adminToken = ""
    }

    func read(key: String) -> String? {
        load()?.values[key]
    }

    @discardableResult
    func save(_ token: String, key: String) -> Bool {
        guard !token.isEmpty else { return delete(key: key) }
        guard !token.contains("\n"), !token.contains("\r") else { return false }
        guard var stored = load(recoveringCorruptFile: true) else { return false }
        guard stored.values[key] != token else { return true }
        stored.values[key] = token
        return persist(stored)
    }

    @discardableResult
    func delete(key: String) -> Bool {
        guard var stored = load(recoveringCorruptFile: true) else { return false }
        guard stored.values.removeValue(forKey: key) != nil else { return true }
        if stored.values.isEmpty {
            do {
                if FileManager.default.fileExists(atPath: storeURL.path) {
                    try FileManager.default.removeItem(at: storeURL)
                }
                return true
            } catch {
                Self.logger.error("Could not remove the empty credential file")
                return false
            }
        }
        return persist(stored)
    }

    private func load(recoveringCorruptFile: Bool = false) -> StoredCredentials? {
        guard hardenExistingPermissions() else { return nil }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return StoredCredentials()
        }
        do {
            let data = try Data(contentsOf: storeURL)
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
            Self.logger.error("Credential file has an unsupported or corrupt format")
            guard recoveringCorruptFile, quarantineCorruptFile() else { return nil }
            return StoredCredentials()
        } catch {
            Self.logger.error("Could not read the credential file")
        }
        return nil
    }

    private func quarantineCorruptFile() -> Bool {
        let fileManager = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let stem = storeURL.deletingPathExtension().lastPathComponent
        let pathExtension = storeURL.pathExtension
        let backupName = "\(stem).corrupt-\(UUID().uuidString.lowercased())"
            + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
        let backupURL = directory.appendingPathComponent(backupName)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            try fileManager.moveItem(at: storeURL, to: backupURL)
            return true
        } catch {
            Self.logger.error("Could not preserve the corrupt credential file")
            return false
        }
    }

    private func hardenExistingPermissions() -> Bool {
        let directory = storeURL.deletingLastPathComponent()
        var succeeded = true
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch {
                Self.logger.error("Could not harden credential-directory permissions")
                succeeded = false
            }
        }
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: storeURL.path
                )
            } catch {
                Self.logger.error("Could not harden credential-file permissions")
                succeeded = false
            }
        }
        return succeeded
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
            Self.logger.error("Could not persist credentials")
            return false
        }
    }
}
