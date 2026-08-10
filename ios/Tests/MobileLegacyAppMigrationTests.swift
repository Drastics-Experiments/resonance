import Foundation
import XCTest
@testable import Resonance

final class MobileLegacyAppMigrationTests: XCTestCase {
    func testMovesLegacyStorageAndRemovesTheOldDirectory() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-mobile-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let legacyRoot = temporaryRoot.appendingPathComponent(
            MobileAppCompatibility.legacyApplicationSupportName,
            isDirectory: true
        )
        let legacySong = legacyRoot
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("song.m4a")
        try fileManager.createDirectory(
            at: legacySong.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("media".utf8).write(to: legacySong)

        XCTAssertTrue(MobileLegacyAppMigration.run(
            fileManager: fileManager,
            applicationSupportRoot: temporaryRoot,
            migrateCredentials: false
        ))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyRoot.path))
        let migratedSong = temporaryRoot
            .appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("song.m4a")
        XCTAssertEqual(try Data(contentsOf: migratedSong), Data("media".utf8))
    }

    func testPreservesConflictsInRecoveryBeforeRemovingLegacyStorage() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-mobile-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let legacyRoot = temporaryRoot.appendingPathComponent(
            MobileAppCompatibility.legacyApplicationSupportName,
            isDirectory: true
        )
        let resonanceRoot = temporaryRoot.appendingPathComponent("Resonance", isDirectory: true)
        try fileManager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resonanceRoot, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("library.json"))
        try Data("current".utf8).write(to: resonanceRoot.appendingPathComponent("library.json"))

        XCTAssertTrue(MobileLegacyAppMigration.run(
            fileManager: fileManager,
            applicationSupportRoot: temporaryRoot,
            migrateCredentials: false
        ))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(
            try Data(contentsOf: resonanceRoot.appendingPathComponent("library.json")),
            Data("current".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: resonanceRoot
                .appendingPathComponent("Legacy Recovery", isDirectory: true)
                .appendingPathComponent("library.json")),
            Data("legacy".utf8)
        )
    }
}
