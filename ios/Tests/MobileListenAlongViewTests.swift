import XCTest
@testable import Resonance

final class MobileListenAlongCodeInputPolicyTests: XCTestCase {
    func testNormalizationUppercasesFiltersAndBoundsRoomCodes() {
        XCTAssertEqual(MobileListenAlongCodeInputPolicy.normalized(" ab cd-12 ! "), "ABCD-12")
        XCTAssertEqual(
            MobileListenAlongCodeInputPolicy.normalized(String(repeating: "a", count: 40)).count,
            MobileListenAlongCodeInputPolicy.maximumLength
        )
    }

    func testJoinabilityMatchesTheControllerContract() {
        XCTAssertTrue(MobileListenAlongCodeInputPolicy.isJoinable("abcd-efgh"))
        XCTAssertFalse(MobileListenAlongCodeInputPolicy.isJoinable("ABCD"))
        XCTAssertFalse(MobileListenAlongCodeInputPolicy.isJoinable("ABCDEFGH"))
    }
}
