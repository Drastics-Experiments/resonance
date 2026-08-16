import Foundation

/// Runtime metadata required for a production update to be installable.
///
/// The values are embedded in the signed app's Info.plist by
/// `mac/scripts/build-release.sh`. A production build never treats a merely
/// valid, ad-hoc, or differently-published Apple signature as sufficient.
struct MacUpdateAuthenticityPolicy: Equatable, Sendable {
    enum Mode: String, Sendable {
        case production
        case development
    }

    static let modeKey = "ResonanceUpdateAuthenticity"
    static let teamIdentifierKey = "ResonanceUpdateTeamIdentifier"
    static let designatedRequirementKey = "ResonanceUpdateDesignatedRequirement"

    let mode: Mode
    let teamIdentifier: String?
    let designatedRequirement: String?

    var isProductionConfigured: Bool {
        mode == .production
            && Self.isValidTeamIdentifier(teamIdentifier)
            && !(designatedRequirement?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    #if DEBUG
    func allowsDevelopmentOverride(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["RESONANCE_ALLOW_UNVERIFIED_UPDATES"] == "1"
    }
    #else
    func allowsDevelopmentOverride(environment: [String: String] = [:]) -> Bool { false }
    #endif

    func allowsAutomaticChecks(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isProductionConfigured || (mode == .development && allowsDevelopmentOverride(environment: environment))
    }

    static func current(
        bundle: Bundle = .main
    ) -> MacUpdateAuthenticityPolicy {
        let mode = Mode(rawValue: bundle.object(forInfoDictionaryKey: modeKey) as? String ?? "")
            ?? .development
        let teamIdentifier = (bundle.object(forInfoDictionaryKey: teamIdentifierKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let designatedRequirement = (bundle.object(forInfoDictionaryKey: designatedRequirementKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MacUpdateAuthenticityPolicy(
            mode: mode,
            teamIdentifier: teamIdentifier,
            designatedRequirement: designatedRequirement
        )
    }

    static func isValidTeamIdentifier(_ value: String?) -> Bool {
        guard let value,
              value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }
}
