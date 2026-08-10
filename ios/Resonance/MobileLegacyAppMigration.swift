import Foundation
import Security

enum MobileAppCompatibility {
    static let legacyApplicationSupportName = ["Liked", "SongsMobile"].joined()
    static let legacyKeychainService = "com.gavindietrich." + legacyApplicationSupportName
}

enum MobileLegacyAppMigration {
    static let applicationSupportName = "Resonance"
    static let keychainService = "com.gavindietrich.Resonance"
    private static let credentialAccounts = ["client", "admin", "account-session-v1"]

    @discardableResult
    static func run(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil,
        migrateCredentials: Bool = true
    ) -> Bool {
        let support = applicationSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storageMigrated = migrateDirectory(
            from: support.appendingPathComponent(
                MobileAppCompatibility.legacyApplicationSupportName,
                isDirectory: true
            ),
            to: support.appendingPathComponent(applicationSupportName, isDirectory: true),
            fileManager: fileManager
        )
        if migrateCredentials { migrateKeychainCredentials() }
        return storageMigrated
    }

    private static func migrateKeychainCredentials() {
        for account in credentialAccounts {
            guard let legacyData = readKeychainData(
                service: MobileAppCompatibility.legacyKeychainService,
                account: account
            ) else { continue }
            let currentData = readKeychainData(service: keychainService, account: account)
            if currentData != nil
                || (saveKeychainData(legacyData, service: keychainService, account: account)
                    && readKeychainData(service: keychainService, account: account) == legacyData) {
                deleteKeychainData(
                    service: MobileAppCompatibility.legacyKeychainService,
                    account: account
                )
            }
        }
    }

    private static func readKeychainData(service: String, account: String) -> Data? {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func saveKeychainData(_ data: Data, service: String, account: String) -> Bool {
        var query = keychainQuery(service: service, account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    private static func deleteKeychainData(service: String, account: String) {
        SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
    }

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
