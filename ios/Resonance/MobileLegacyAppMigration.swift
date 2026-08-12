import Foundation

enum MobileAppCompatibility {
    static let legacyApplicationSupportName = ["Liked", "SongsMobile"].joined()
}

enum MobileApplicationSupport {
    static func root(fileManager: FileManager = .default) -> URL {
        if let resolved = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return resolved
        }
        return fallbackRoot(
            discoveredRoot: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }

    static func fallbackRoot(discoveredRoot: URL?, homeDirectory: URL) -> URL {
        discoveredRoot ?? homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }
}

enum MobileLegacyAppMigration {
    static let applicationSupportName = "Resonance"

    @discardableResult
    static func run(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil
    ) -> Bool {
        let support = applicationSupportRoot ?? MobileApplicationSupport.root(fileManager: fileManager)
        let storageMigrated = migrateDirectory(
            from: support.appendingPathComponent(
                MobileAppCompatibility.legacyApplicationSupportName,
                isDirectory: true
            ),
            to: support.appendingPathComponent(applicationSupportName, isDirectory: true),
            fileManager: fileManager
        )
        return storageMigrated
    }

    private static func migrateDirectory(
        from legacyRoot: URL,
        to resonanceRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return true }
        do {
            if !fileManager.fileExists(atPath: resonanceRoot.path) {
                try fileManager.moveItem(at: legacyRoot, to: resonanceRoot)
                return true
            }
            try mergeDirectory(
                from: legacyRoot,
                to: resonanceRoot,
                recoveryRoot: resonanceRoot.appendingPathComponent("Legacy Recovery", isDirectory: true),
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: legacyRoot.path) {
                try fileManager.removeItem(at: legacyRoot)
            }
            return true
        } catch {
            return false
        }
    }

    private static func mergeDirectory(
        from source: URL,
        to destination: URL,
        recoveryRoot: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard fileManager.fileExists(atPath: target.path) else {
                try fileManager.moveItem(at: item, to: target)
                continue
            }
            let sourceIsDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let targetIsDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if sourceIsDirectory && targetIsDirectory {
                try mergeDirectory(
                    from: item,
                    to: target,
                    recoveryRoot: recoveryRoot,
                    fileManager: fileManager
                )
                if fileManager.fileExists(atPath: item.path) {
                    try fileManager.removeItem(at: item)
                }
            } else if !sourceIsDirectory && !targetIsDirectory
                        && fileManager.contentsEqual(atPath: item.path, andPath: target.path) {
                try fileManager.removeItem(at: item)
            } else {
                try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
                try fileManager.moveItem(
                    at: item,
                    to: uniqueRecoveryURL(
                        for: item.lastPathComponent,
                        in: recoveryRoot,
                        fileManager: fileManager
                    )
                )
            }
        }
    }

    private static func uniqueRecoveryURL(
        for name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name).\(counter)")
            counter += 1
        }
        return candidate
    }
}

struct MobileFileCredentialStore {
    let storeURL: URL

    private struct StoredCredentials: Codable {
        var values: [String: String] = [:]
    }

    func read(key: String) -> String? {
        (try? load())?.values[key]
    }

    func save(_ value: String, key: String) throws {
        if value.isEmpty {
            try delete(key: key)
        } else {
            try update(values: [key: value])
        }
    }

    func delete(key: String) throws {
        try update(deleting: [key])
    }

    func update(
        values: [String: String] = [:],
        deleting keys: Set<String> = []
    ) throws {
        for value in values.values where value.contains("\n") || value.contains("\r") {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        var stored = try load(recoveringCorruptFile: true)
        let previous = stored
        for key in keys {
            stored.values.removeValue(forKey: key)
        }
        for (key, value) in values {
            if value.isEmpty {
                stored.values.removeValue(forKey: key)
            } else {
                stored.values[key] = value
            }
        }
        guard stored.values != previous.values else { return }
        if stored.values.isEmpty {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.removeItem(at: storeURL)
            }
            return
        }
        try persist(stored)
    }

    private func load(recoveringCorruptFile: Bool = false) throws -> StoredCredentials {
        try hardenExistingPermissions()
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return StoredCredentials()
        }
        let data = try Data(contentsOf: storeURL)
        do {
            return try JSONDecoder().decode(StoredCredentials.self, from: data)
        } catch {
            guard recoveringCorruptFile else { throw error }
            try quarantineCorruptFile()
            return StoredCredentials()
        }
    }

    private func quarantineCorruptFile() throws {
        let directory = storeURL.deletingLastPathComponent()
        let stem = storeURL.deletingPathExtension().lastPathComponent
        let pathExtension = storeURL.pathExtension
        let backupName = "\(stem).corrupt-\(UUID().uuidString.lowercased())"
            + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
        let backupURL = directory.appendingPathComponent(backupName)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: directory.path
        )
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: storeURL.path
        )
        try FileManager.default.moveItem(at: storeURL, to: backupURL)
    }

    private func hardenExistingPermissions() throws {
        let directory = storeURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: directory.path
            )
        }
        if FileManager.default.fileExists(atPath: storeURL.path) {
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: storeURL.path
            )
        }
    }

    private func persist(_ stored: StoredCredentials) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: directory.path
        )
        try JSONEncoder().encode(stored).write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: storeURL.path
        )
    }
}
