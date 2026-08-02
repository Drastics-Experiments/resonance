import Testing
@testable import LikedSongsFocus

@Suite
struct MacUpdateVersionTests {
    @Test
    func higherBuildIsAnUpdateWhenVersionMatches() {
        #expect(MacUpdateVersion.isUpdateAvailable(
            currentVersion: "1.0.9",
            currentBuild: "23",
            candidateVersion: "1.0.9",
            candidateBuild: "24"
        ))
    }

    @Test
    func equalBuildIsNotAnUpdateWhenVersionMatches() {
        #expect(!MacUpdateVersion.isUpdateAvailable(
            currentVersion: "1.0.9",
            currentBuild: "24",
            candidateVersion: "1.0.9",
            candidateBuild: "24"
        ))
    }

    @Test
    func lowerBuildIsNotAnUpdateWhenVersionMatches() {
        #expect(!MacUpdateVersion.isUpdateAvailable(
            currentVersion: "1.0.9",
            currentBuild: "24",
            candidateVersion: "1.0.9",
            candidateBuild: "23"
        ))
    }

    @Test
    func semanticVersionTakesPrecedenceOverBuildNumber() {
        #expect(MacUpdateVersion.isUpdateAvailable(
            currentVersion: "1.0.9",
            currentBuild: "999",
            candidateVersion: "1.1.0",
            candidateBuild: "1"
        ))

        #expect(!MacUpdateVersion.isUpdateAvailable(
            currentVersion: "1.0.9",
            currentBuild: "1",
            candidateVersion: "1.0.8",
            candidateBuild: "999"
        ))
    }

    @Test
    func dismissingOneBuildDoesNotSuppressANewerBuildOfTheSameVersion() {
        let dismissed = MacUpdateIdentity(version: "1.0.9", build: "24")
        let newerBuild = MacUpdateIdentity(version: "1.0.9", build: "25")

        #expect(MacUpdateAlertState.visibleUpdate(
            available: dismissed,
            dismissed: dismissed
        ) == nil)
        #expect(MacUpdateAlertState.visibleUpdate(
            available: newerBuild,
            dismissed: dismissed
        ) == newerBuild)
    }
}
