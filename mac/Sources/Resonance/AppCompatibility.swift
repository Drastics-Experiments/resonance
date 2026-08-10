import Foundation

enum MacAppCompatibility {
    // Auto-updates already installed in the wild require the original external
    // bundle identity. Internal targets, executable names, storage, defaults,
    // and credentials use Resonance names.
    static let productionBundleIdentifier = "com.gavindietrich."
        + ["Liked", "Songs", "Focus"].joined()
    static let legacyDefaultsPrefix = ["Liked", "Songs", "Focus"].joined()
    static let legacyApplicationSupportName = ["Liked", " Songs"].joined()
    static let legacyCredentialService = productionBundleIdentifier + ".music-server"
}
