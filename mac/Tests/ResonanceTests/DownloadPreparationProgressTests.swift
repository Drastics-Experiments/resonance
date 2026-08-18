import Testing
@testable import Resonance

@Suite("Download preparation progress")
struct DownloadPreparationProgressTests {
    @Test("a pending song is visible before its first byte")
    func pendingSongShowsIndeterminateTransfer() {
        #expect(MacServerDownloadProgressPolicy.shouldShowTransfer(
            isPendingDownload: true,
            completedBytes: 0
        ))
        #expect(MacServerDownloadProgressPolicy.presentationFraction(
            completedBytes: 0,
            totalBytes: 1_000
        ) == nil)
    }

    @Test("an idle transfer remains hidden until it is pending or receives bytes")
    func idleTransferStaysHidden() {
        #expect(!MacServerDownloadProgressPolicy.shouldShowTransfer(
            isPendingDownload: false,
            completedBytes: 0
        ))
        #expect(MacServerDownloadProgressPolicy.shouldShowTransfer(
            isPendingDownload: false,
            completedBytes: 1
        ))
    }
}
