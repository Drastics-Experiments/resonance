import AppKit
import Combine
import CryptoKit
import Foundation

struct MacUpdateManifest: Codable, Equatable {
    let version: String
    let build: String
    let url: URL
    let sha256: String

    var identity: MacUpdateIdentity {
        MacUpdateIdentity(version: version, build: build)
    }
}

struct MacUpdateIdentity: Hashable {
    let version: String
    let build: String
}

enum MacUpdateVersion {
    static func isUpdateAvailable(
        currentVersion: String,
        currentBuild: String,
        candidateVersion: String,
        candidateBuild: String
    ) -> Bool {
        switch compare(candidateVersion, currentVersion) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            return compare(candidateBuild, currentBuild) == .orderedDescending
        }
    }

    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let lhs = split(left)
        let rhs = split(right)
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let l = index < lhs.core.count ? lhs.core[index] : 0
            let r = index < rhs.core.count ? rhs.core[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (l?, r?):
            return l.compare(r, options: [.numeric, .caseInsensitive])
        }
    }

    private static func split(_ value: String) -> (core: [Int], prerelease: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        return (core, parts.count > 1 ? String(parts[1]) : nil)
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    nonisolated static let defaultManifestURL = URL(string: "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json")!
    nonisolated static let maxArchiveBytes: Int64 = 512 * 1_024 * 1_024
    private static let archiveBufferBytes = 64 * 1_024
    private static let githubUpdateHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    @Published private(set) var status = "GitHub Releases"
    @Published private(set) var availableUpdate: MacUpdateIdentity?
    @Published private(set) var isBusy = false
    @Published private(set) var downloadedArchive: URL?
    @Published private(set) var errorMessage: String?

    let updatesEnabled: Bool
    private let manifestURL: URL
    private let session: URLSession
    private let updateDirectoryOverride: URL?
    private let authenticityPolicy: MacUpdateAuthenticityPolicy
    private var manifest: MacUpdateManifest?
    private var isRunningAutomaticChecks = false

    init(
        manifestURL: URL = UpdateManager.defaultManifestURL,
        session: URLSession = .shared,
        updateDirectory: URL? = nil,
        updatesEnabled: Bool? = nil,
        authenticityPolicy: MacUpdateAuthenticityPolicy? = nil
    ) {
        self.manifestURL = manifestURL
        self.session = session
        updateDirectoryOverride = updateDirectory
        let resolvedAuthenticityPolicy = authenticityPolicy ?? .current()
        self.authenticityPolicy = resolvedAuthenticityPolicy
        self.updatesEnabled = updatesEnabled
            ?? (!CredentialStorePolicy.isPreviewBundle(bundleIdentifier: Bundle.main.bundleIdentifier)
                && resolvedAuthenticityPolicy.allowsAutomaticChecks())
    }

    var canInstall: Bool { downloadedArchive != nil && manifest != nil && !isBusy }
    var availableVersion: String? { availableUpdate?.version }
    var hasUpdate: Bool { availableUpdate != nil }

    func automaticCheck() async {
        guard updatesEnabled else {
            status = "Updates are disabled in Preview builds"
            return
        }
        guard !isRunningAutomaticChecks else { return }
        isRunningAutomaticChecks = true
        defer { isRunningAutomaticChecks = false }

        do {
            try await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await checkForUpdates(silent: true)
                try await Task.sleep(for: .seconds(5 * 60))
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    func checkForUpdates(silent: Bool = false) async {
        guard updatesEnabled else {
            manifest = nil
            availableUpdate = nil
            downloadedArchive = nil
            errorMessage = nil
            status = "Updates are disabled in Preview builds"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        if !silent { status = "Checking for updates…" }
        defer { isBusy = false }

        do {
            var request = URLRequest(
                url: manifestURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let allowedManifestHosts = Self.allowedUpdateHosts(for: manifestURL)
            let (data, response) = try await MacBoundedResponse.data(
                for: session,
                request: request,
                limit: 256 * 1_024,
                rejectRedirects: false,
                redirectValidator: { candidate in
                    Self.allowsUpdateURL(candidate, allowedHosts: allowedManifestHosts)
                }
            )
            try Self.validate(
                response: response,
                allowedHosts: allowedManifestHosts
            )
            let candidate = try JSONDecoder().decode(MacUpdateManifest.self, from: data)
            try Self.validate(candidate)
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            if MacUpdateVersion.isUpdateAvailable(
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                candidateVersion: candidate.version,
                candidateBuild: candidate.build
            ) {
                manifest = candidate
                availableUpdate = candidate.identity
                downloadedArchive = validatedDownloadedArchive(for: candidate)
                status = downloadedArchive == nil
                    ? "Version \(candidate.version) available"
                    : "Version \(candidate.version) ready"
            } else {
                manifest = nil
                availableUpdate = nil
                downloadedArchive = nil
                status = "Resonance is up to date"
            }
        } catch {
            errorMessage = error.localizedDescription
            if !silent { status = "Update check failed" }
        }
    }

    func downloadUpdate() async {
        guard updatesEnabled, let manifest, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        status = "Downloading \(manifest.version)…"
        defer { isBusy = false }

        do {
            let downloaded = try await downloadArchive(from: manifest.url)
            let temporary = downloaded.url
            defer { try? FileManager.default.removeItem(at: temporary) }
            let digest = downloaded.sha256
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let updateDirectory = try updateDirectory()
            try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
            let destination = updateDirectory.appendingPathComponent("Resonance-macOS-\(manifest.version).zip")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            downloadedArchive = destination
            status = "Version \(manifest.version) ready"
        } catch {
            errorMessage = error.localizedDescription
            status = "Update download failed"
        }
    }

    func downloadAndInstall() async {
        if !canInstall {
            await downloadUpdate()
        }
        guard canInstall else { return }
        installAndRestart()
    }

    func installAndRestart() {
        guard updatesEnabled,
              authenticityPolicy.isProductionConfigured || authenticityPolicy.allowsDevelopmentOverride(),
              let archive = downloadedArchive,
              let version = manifest?.version else { return }
        do {
            let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
            guard bundleURL.pathExtension == "app" else { throw UpdateError.notPackagedApplication }
            let parent = bundleURL.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateError.installLocationNotWritable
            }
            guard let bundledHelper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
                throw UpdateError.missingInstaller
            }
            let helper = FileManager.default.temporaryDirectory
                .appendingPathComponent("resonance-update-\(UUID().uuidString).sh")
            try FileManager.default.copyItem(at: bundledHelper, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, archive.path, bundleURL.path, String(ProcessInfo.processInfo.processIdentifier), version]
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            errorMessage = error.localizedDescription
            status = "Update installation failed"
        }
    }

    static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func downloadArchive(from url: URL) async throws -> (url: URL, sha256: String) {
        let allowedHosts = Self.allowedUpdateHosts(for: url)
        guard Self.allowsUpdateURL(url, allowedHosts: allowedHosts) else {
            throw UpdateError.untrustedDownload
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, rawResponse) = try await session.bytes(
            for: request,
            delegate: MacBoundedRedirectDelegate { candidate in
                Self.allowsUpdateURL(candidate, allowedHosts: allowedHosts)
            }
        )
        guard let response = rawResponse as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        try Self.validate(response: response, allowedHosts: allowedHosts)
        if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
           declared > Self.maxArchiveBytes {
            throw UpdateError.archiveTooLarge
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-update-\(UUID().uuidString).zip")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close() }
            var hasher = SHA256()
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(Self.archiveBufferBytes)
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= Self.maxArchiveBytes else {
                    throw UpdateError.archiveTooLarge
                }
                buffer.append(byte)
                if buffer.count >= Self.archiveBufferBytes {
                    try file.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try file.write(contentsOf: buffer)
                hasher.update(data: buffer)
            }
            try file.synchronize()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (temporary, digest)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func updateDirectory() throws -> URL {
        if let updateDirectoryOverride { return updateDirectoryOverride }
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Resonance", isDirectory: true)
        .appendingPathComponent("Updates", isDirectory: true)
    }

    private func validatedDownloadedArchive(for manifest: MacUpdateManifest) -> URL? {
        guard let archive = try? updateDirectory()
            .appendingPathComponent("Resonance-macOS-\(manifest.version).zip") else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value <= Self.maxArchiveBytes else {
            try? FileManager.default.removeItem(at: archive)
            return nil
        }
        guard let digest = try? Self.sha256(of: archive),
              digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: archive)
            return nil
        }
        return archive
    }

    static func validate(_ manifest: MacUpdateManifest) throws {
        guard !manifest.version.isEmpty, !manifest.build.isEmpty else { throw UpdateError.invalidManifest }
        guard allowsUpdateURL(manifest.url, allowedHosts: ["github.com"]),
              manifest.url.fragment == nil else {
            throw UpdateError.untrustedDownload
        }
        guard manifest.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw UpdateError.invalidManifest
        }
    }

    private static func allowedUpdateHosts(for url: URL) -> Set<String> {
        guard url.host?.lowercased() == "github.com" else {
            return [url.host?.lowercased() ?? ""]
        }
        return githubUpdateHosts
    }

    nonisolated static func allowsUpdateURL(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              allowedHosts.contains(host),
              !MacArtworkURLPolicy.isPrivateHost(host) else { return false }
        return true
    }

    private static func validate(response: URLResponse, allowedHosts: Set<String>? = nil) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }
        if let allowedHosts,
           response.url.map({ !allowsUpdateURL($0, allowedHosts: allowedHosts) }) ?? true {
            throw UpdateError.invalidResponse
        }
    }
}

private enum UpdateError: LocalizedError {
    case archiveTooLarge
    case checksumMismatch
    case installLocationNotWritable
    case invalidManifest
    case invalidResponse
    case missingInstaller
    case notPackagedApplication
    case untrustedDownload

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge: "The update archive is larger than the allowed download size."
        case .checksumMismatch: "The update checksum did not match the signed release metadata."
        case .installLocationNotWritable: "Resonance cannot update this installation. Reinstall it in Applications using the macOS installer."
        case .invalidManifest: "The update manifest is invalid."
        case .invalidResponse: "GitHub returned an invalid update response."
        case .missingInstaller: "The update installer is missing from this build."
        case .notPackagedApplication: "Updates are available only in the packaged Resonance app."
        case .untrustedDownload: "The update download is not hosted by the Resonance GitHub repository."
        }
    }
}
