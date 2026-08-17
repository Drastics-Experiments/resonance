import XCTest
@testable import Resonance

final class MacListenAlongCodeInputPolicyTests: XCTestCase {
    func testNormalizationUppercasesFiltersAndBoundsRoomCodes() {
        XCTAssertEqual(MacListenAlongCodeInputPolicy.normalized(" ab cd-12! "), "ABCD-12")
        XCTAssertEqual(
            MacListenAlongCodeInputPolicy.normalized(String(repeating: "a", count: 40)).count,
            MacListenAlongCodeInputPolicy.maximumLength
        )
    }

    func testJoinabilityMatchesTheRoomCodeContract() {
        XCTAssertTrue(MacListenAlongCodeInputPolicy.isJoinable("abcd-efgh"))
        XCTAssertFalse(MacListenAlongCodeInputPolicy.isJoinable("ABCD"))
        XCTAssertFalse(MacListenAlongCodeInputPolicy.isJoinable("ABCDEFGH"))
    }
}
