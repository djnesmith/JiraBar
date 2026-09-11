import XCTest
@testable import jiraBar

/// The keys a status row puts on the clipboard. Where `issueKeyList` names issues in a notification
/// and so collapses and re-sorts, this one is a paste target: everything, in the order the menu
/// showed it.
final class CopyableKeyListTests: XCTestCase {

    func testASingleKeyIsJustTheKey() {
        XCTAssertEqual(AppDelegate.copyableKeyList(["DEV-1"]), "DEV-1")
    }

    func testKeysAreSeparatedBySpaces() {
        XCTAssertEqual(AppDelegate.copyableKeyList(["DEV-1", "DEV-2", "DEV-3"]), "DEV-1 DEV-2 DEV-3")
    }

    /// The menu orders each status group by Lexorank, not by key, and a paste that re-sorted would
    /// no longer match the rows the user was looking at when they clicked.
    func testTheCallersOrderIsKept() {
        XCTAssertEqual(
            AppDelegate.copyableKeyList(["DEV-30", "DEV-2", "DEV-11", "DEV-4"]),
            "DEV-30 DEV-2 DEV-11 DEV-4"
        )
    }

    /// Unlike `issueKeyList` this never trades the tail for a count — a clipboard has no display
    /// limit, and a paste missing tickets is a silent data loss.
    func testALongListIsGivenInFullWithNoCollapsing() {
        let keys = (1...12).map { "DEV-\($0)" }
        let copied = AppDelegate.copyableKeyList(keys)
        XCTAssertEqual(copied, keys.joined(separator: " "))
        XCTAssertFalse(copied.contains("more"), "issueKeyList would have collapsed this")
    }

    /// A status row only exists because it has issues, so this cannot happen from the menu — but an
    /// empty string is what suppresses the click action, so the value is asserted rather than assumed.
    func testNoKeysIsEmpty() {
        XCTAssertEqual(AppDelegate.copyableKeyList([]), "")
    }

}
