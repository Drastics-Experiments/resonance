import Foundation
import Testing
@testable import Resonance

struct UnlinkedDownloadMigrationTests {
    private func track(
        remoteID: String? = "remote-song",
        sourceURL: String? = nil,
        downloadSourceURL: String? = nil,
        preservesUnlinkedImport: Bool? = nil
    ) -> Track {
        Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .midnight,
            fileURL: URL(fileURLWithPath: "/tmp/song.m4a"),
            remoteID: remoteID,
            sourceServer: remoteID == nil ? nil : "https://music.example",
            sourceURL: sourceURL,
            downloadSourceURL: downloadSourceURL,
            preservesUnlinkedImport: preservesUnlinkedImport
        )
    }

    @Test("unlinked managed downloads are selected for the update cleanup")
    func deletesUnlinkedManagedDownload() {
        let decision = UnlinkedDownloadMigrationPolicy.decision(
            for: track(),
            legacyDownloadOwned: true
        )

        #expect(decision.shouldDelete)
        #expect(decision.track.preservesUnlinkedImport == false)
    }

    @Test("either preserved source link keeps a downloaded song")
    func keepsLinkedDownloads() {
        #expect(!UnlinkedDownloadMigrationPolicy.decision(
            for: track(sourceURL: "https://source.example/song"),
            legacyDownloadOwned: true
        ).shouldDelete)
        #expect(!UnlinkedDownloadMigrationPolicy.decision(
            for: track(downloadSourceURL: "https://media.example/song.m4a"),
            legacyDownloadOwned: true
        ).shouldDelete)
    }

    @Test("the explicit import flag wins after an import gains a remote identity")
    func keepsFlaggedUnlinkedImport() {
        let decision = UnlinkedDownloadMigrationPolicy.decision(
            for: track(preservesUnlinkedImport: true),
            legacyDownloadOwned: true
        )

        #expect(!decision.shouldDelete)
        #expect(decision.track.preservesUnlinkedImport == true)
    }

    @Test("legacy files outside the download cache are migrated as protected imports")
    func protectsLegacyImport() {
        let decision = UnlinkedDownloadMigrationPolicy.decision(
            for: track(),
            legacyDownloadOwned: false
        )

        #expect(!decision.shouldDelete)
        #expect(decision.track.preservesUnlinkedImport == true)
    }

    @Test("loading the updated app deletes the managed file and its library references once")
    @MainActor
    func modelAppliesCleanupOnUpdatedLibraryLoad() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-unlinked-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let cache = root
            .appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("ServerCache", isDirectory: true)
            .appendingPathComponent("context", isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let unlinkedURL = cache.appendingPathComponent("unlinked.m4a")
        let linkedURL = cache.appendingPathComponent("linked.m4a")
        try Data("unlinked".utf8).write(to: unlinkedURL)
        try Data("linked".utf8).write(to: linkedURL)

        let suiteName = "UnlinkedDownloadMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let seed = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            serverCacheRoot: root,
            persistServerCredentials: false
        )
        let unlinked = Track(
            title: "Unlinked",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .midnight,
            fileURL: unlinkedURL,
            remoteID: "unlinked",
            sourceServer: "https://music.example",
            preservesUnlinkedImport: false
        )
        let linked = Track(
            title: "Linked",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: linkedURL,
            remoteID: "linked",
            sourceServer: "https://music.example",
            downloadSourceURL: "https://media.example/linked.m4a",
            preservesUnlinkedImport: false
        )
        seed.tracks = [unlinked, linked]
        seed.toggleFavorite(unlinked)
        seed.flushPersistence()

        let updated = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            serverCacheRoot: root,
            persistServerCredentials: false
        )
        updated.flushPersistence()

        #expect(!fileManager.fileExists(atPath: unlinkedURL.path))
        #expect(fileManager.fileExists(atPath: linkedURL.path))
        #expect(updated.tracks.map(\.id) == [linked.id])
        #expect(!updated.favorites.contains(unlinked.id))

        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            serverCacheRoot: root,
            persistServerCredentials: false
        )
        #expect(relaunched.tracks.map(\.id) == [linked.id])
    }
}
