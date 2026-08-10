import Foundation
import Testing
@testable import Resonance

@Suite(.serialized)
struct LegacyAppMigrationTests {
    @Test
    func migratesDefaultsStorageAndPersistedFileURLsThenRemovesLegacyArtifacts() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let suiteName = "ResonanceMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyKey = MacAppCompatibility.legacyDefaultsPrefix + ".library.v2"
        defaults.set(Data("library".utf8), forKey: legacyKey)

        let legacyRoot = temporaryRoot.appendingPathComponent(
            MacAppCompatibility.legacyApplicationSupportName,
            isDirectory: true
        )
        let legacyMedia = legacyRoot
            .appendingPathComponent("LocalImports", isDirectory: true)
            .appendingPathComponent("song.m4a")
        try fileManager.createDirectory(
            at: legacyMedia.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("media".utf8).write(to: legacyMedia)

        let result = LegacyAppMigration.run(
            defaults: defaults,
            fileManager: fileManager,
            applicationSupportRoot: temporaryRoot
        )

        #expect(result.completed)
        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(defaults.data(forKey: "Resonance.library.v2") == Data("library".utf8))
        #expect(!fileManager.fileExists(atPath: legacyRoot.path))
        let migratedMedia = try #require(result.migratedFileURL(legacyMedia, fileManager: fileManager))
        #expect(fileManager.fileExists(atPath: migratedMedia.path))
        #expect(try Data(contentsOf: migratedMedia) == Data("media".utf8))
    }

    @Test
    func preservesConflictingLegacyFilesInRecoveryBeforeDeletingTheOldDirectory() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-migration-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let legacyRoot = temporaryRoot.appendingPathComponent(
            MacAppCompatibility.legacyApplicationSupportName,
            isDirectory: true
        )
        let resonanceRoot = temporaryRoot.appendingPathComponent("Resonance", isDirectory: true)
        try fileManager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resonanceRoot, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("library.json"))
        try Data("current".utf8).write(to: resonanceRoot.appendingPathComponent("library.json"))

        let result = LegacyAppMigration.run(
            defaults: try #require(UserDefaults(suiteName: "ResonanceMigrationConflict.\(UUID().uuidString)")),
            fileManager: fileManager,
            applicationSupportRoot: temporaryRoot
        )

        #expect(result.completed)
        #expect(!fileManager.fileExists(atPath: legacyRoot.path))
        #expect(try Data(contentsOf: resonanceRoot.appendingPathComponent("library.json")) == Data("current".utf8))
        #expect(try Data(contentsOf: resonanceRoot
            .appendingPathComponent("Legacy Recovery", isDirectory: true)
            .appendingPathComponent("library.json")) == Data("legacy".utf8))
    }
}
