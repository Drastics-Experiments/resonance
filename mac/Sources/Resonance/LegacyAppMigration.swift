import Foundation

struct LegacyApplicationSupportMigration: Sendable {
    let legacyRoot: URL
    let resonanceRoot: URL
    let completed: Bool

    func migratedFileURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        guard completed, url.isFileURL else { return nil }
        let legacyPath = legacyRoot.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path
        guard sourcePath == legacyPath || sourcePath.hasPrefix(legacyPath + "/") else { return nil }
        let suffix = sourcePath.dropFirst(legacyPath.count).drop(while: { $0 == "/" })
        let destination = suffix.isEmpty
            ? resonanceRoot
            : resonanceRoot.appendingPathComponent(String(suffix), isDirectory: false)
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }
}

enum LegacyAppMigration {
    static let defaultsPrefix = "Resonance"
    static let applicationSupportName = "Resonance"

    @discardableResult
    static func run(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil
    ) -> LegacyApplicationSupportMigration {
        migrateDefaults(defaults)

        let support = applicationSupportRoot
            ?? ResonanceApplicationSupport.root(fileManager: fileManager)
        let legacyRoot = support.appendingPathComponent(
            MacAppCompatibility.legacyApplicationSupportName,
            isDirectory: true
        )
        let resonanceRoot = support.appendingPathComponent(applicationSupportName, isDirectory: true)
        let completed = migrateDirectory(
            from: legacyRoot,
            to: resonanceRoot,
            fileManager: fileManager
        )
        return LegacyApplicationSupportMigration(
            legacyRoot: legacyRoot,
            resonanceRoot: resonanceRoot,
            completed: completed
        )
    }

    static func migrateDefaults(_ defaults: UserDefaults) {
        let legacyPrefix = MacAppCompatibility.legacyDefaultsPrefix + "."
        let currentPrefix = defaultsPrefix + "."
        let legacyKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(legacyPrefix) }
            .sorted()

        for legacyKey in legacyKeys {
            let suffix = legacyKey.dropFirst(legacyPrefix.count)
            let currentKey = currentPrefix + suffix
            if defaults.object(forKey: currentKey) == nil,
               let value = defaults.object(forKey: legacyKey) {
                defaults.set(value, forKey: currentKey)
            }
            if defaults.object(forKey: currentKey) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
        }
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
                let recoveryURL = uniqueRecoveryURL(
                    for: item.lastPathComponent,
                    in: recoveryRoot,
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: item, to: recoveryURL)
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
