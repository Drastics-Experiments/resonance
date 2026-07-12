import AppKit
import Combine
import CryptoKit
import Foundation

struct MacUpdateManifest: Codable, Equatable {
    let version: String
    let build: String
    let url: URL
    let sha256: String
}

enum MacUpdateVersion {
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

    @Published private(set) var status = "GitHub Releases"
    @Published private(set) var availableVersion: String?
    @Published private(set) var isBusy = false
    @Published private(set) var downloadedArchive: URL?
    @Published private(set) var errorMessage: String?

    private let manifestURL: URL
    private let session: URLSession
    private var manifest: MacUpdateManifest?
    private var hasAutomaticallyChecked = false

    init(manifestURL: URL = UpdateManager.defaultManifestURL, session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    var canInstall: Bool { downloadedArchive != nil && manifest != nil && !isBusy }
    var hasUpdate: Bool { availableVersion != nil }

    func automaticCheck() async {
        guard !hasAutomaticallyChecked else { return }
        hasAutomaticallyChecked = true
        try? await Task.sleep(for: .seconds(2))
        await checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        if !silent { status = "Checking for updates…" }
        defer { isBusy = false }

        do {
            let (data, response) = try await session.data(from: manifestURL)
            try Self.validate(response: response)
            let candidate = try JSONDecoder().decode(MacUpdateManifest.self, from: data)
            try Self.validate(candidate)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            if MacUpdateVersion.compare(current, candidate.version) == .orderedAscending {
                manifest = candidate
                availableVersion = candidate.version
                status = "Version \(candidate.version) available"
            } else {
                manifest = nil
                availableVersion = nil
                downloadedArchive = nil
                status = "Resonance is up to date"
            }
        } catch {
            errorMessage = error.localizedDescription
            if !silent { status = "Update check failed" }
        }
    }

    func downloadUpdate() async {
        guard let manifest, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        status = "Downloading \(manifest.version)…"
        defer { isBusy = false }

        do {
            let (temporary, response) = try await session.download(from: manifest.url)
            try Self.validate(response: response)
            let digest = try Self.sha256(of: temporary)
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let updateDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
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

    func installAndRestart() {
        guard let archive = downloadedArchive, let version = manifest?.version else { return }
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
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ manifest: MacUpdateManifest) throws {
        guard !manifest.version.isEmpty, !manifest.build.isEmpty else { throw UpdateError.invalidManifest }
        guard manifest.url.scheme == "https", manifest.url.host?.lowercased() == "github.com" else {
            throw UpdateError.untrustedDownload
        }
        guard manifest.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw UpdateError.invalidManifest
        }
    }

    private static func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }
    }
}

private enum UpdateError: LocalizedError {
    case checksumMismatch
    case installLocationNotWritable
    case invalidManifest
    case invalidResponse
    case missingInstaller
    case notPackagedApplication
    case untrustedDownload

    var errorDescription: String? {
        switch self {
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
