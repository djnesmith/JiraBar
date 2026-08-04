import XCTest
@testable import jiraBar

final class StatusDisplayTests: XCTestCase {

    func testValidHex() {
        XCTAssertTrue(StatusDisplay.isValidHex("#BADA55"))
        XCTAssertTrue(StatusDisplay.isValidHex("BADA55"))
        XCTAssertTrue(StatusDisplay.isValidHex(" #BADA55 "))
        XCTAssertTrue(StatusDisplay.isValidHex("bada55"))
    }

    func testInvalidHex() {
        XCTAssertFalse(StatusDisplay.isValidHex(""))
        XCTAssertFalse(StatusDisplay.isValidHex("#BAD"))
        XCTAssertFalse(StatusDisplay.isValidHex("#BADA555"))
        XCTAssertFalse(StatusDisplay.isValidHex("GGGGGG"))
    }

    func testNsColorNilWithoutOverride() {
        XCTAssertNil(StatusDisplay(name: "Review").nsColor)
        XCTAssertNotNil(StatusDisplay(name: "Review", colorHex: "#2DA44E").nsColor)
    }
}
