import Foundation
import XCTest
@testable import Resonance

final class MobileLegacyAppMigrationTests: XCTestCase {
    func testApplicationSupportFallbackStaysInsideSandboxHome() {
        let home = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/test", isDirectory: true)
        XCTAssertEqual(
            MobileApplicationSupport.fallbackRoot(discoveredRoot: nil, homeDirectory: home),
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        )
    }

    func testApplicationSupportFallbackPrefersDiscoveredDirectory() {
        let discovered = URL(fileURLWithPath: "/resolved/Application Support", isDirectory: true)
        let home = URL(fileURLWithPath: "/sandbox", isDirectory: true)
        XCTAssertEqual(
            MobileApplicationSupport.fallbackRoot(
                discoveredRoot: discovered,
                homeDirectory: home
            ),
            discovered
        )
    }

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
            applicationSupportRoot: temporaryRoot
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
            applicationSupportRoot: temporaryRoot
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

    func testCredentialFileRoundTripsAndUsesPrivatePermissions() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-mobile-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let storeURL = temporaryRoot.appendingPathComponent("server-credentials.json")
        let store = MobileFileCredentialStore(storeURL: storeURL)
        try store.save("session-value", key: "account-session-v1")

        XCTAssertEqual(store.read(key: "account-session-v1"), "session-value")
        XCTAssertEqual(
            (try fileManager.attributesOfItem(atPath: temporaryRoot.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (try fileManager.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        try store.delete(key: "account-session-v1")
        XCTAssertNil(store.read(key: "account-session-v1"))
        XCTAssertFalse(fileManager.fileExists(atPath: storeURL.path))
    }
}
