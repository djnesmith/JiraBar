import XCTest
@testable import jiraBar

/// Naming the issues a notification is about. The reason this collapses rather than listing
/// everything: macOS clips a notification body, and a clipped run of keys loses both the keys it
/// cuts and any sense of how many there were.
final class IssueKeyListTests: XCTestCase {

    func testASingleKeyIsJustTheKey() {
        XCTAssertEqual(AppDelegate.issueKeyList(["DEV-1"]), "DEV-1")
    }

    func testAShortListIsGivenInFull() {
        XCTAssertEqual(AppDelegate.issueKeyList(["DEV-1", "DEV-2", "DEV-3"]), "DEV-1, DEV-2, DEV-3")
    }

    /// Past the limit the tail is traded for a count, so the reader still knows the size.
    func testALongListCollapsesToACount() {
        XCTAssertEqual(
            AppDelegate.issueKeyList(["DEV-1", "DEV-2", "DEV-3", "DEV-4", "DEV-5"]),
            "DEV-1, DEV-2, DEV-3 +2 more"
        )
    }

    /// One over the limit still collapses — "+1 more" is shorter than the key it replaces, and the
    /// alternative is a boundary case that reads differently from every other long list.
    func testOneOverTheLimitCollapses() {
        XCTAssertEqual(
            AppDelegate.issueKeyList(["DEV-1", "DEV-2", "DEV-3", "DEV-4"]),
            "DEV-1, DEV-2, DEV-3 +1 more"
        )
    }

    /// The caller's keys come out of a `Set`, so without sorting the same batch would name a
    /// different three tickets each time it ran. Asserted as the literal string, not just as
    /// "both orders agree" — that weaker form passes under any stable-but-wrong scheme, and the
    /// scheme this replaced put DEV-11 and DEV-30 ahead of DEV-2.
    func testKeysAreSortedNaturallyAndTheSameBatchReadsTheSame() {
        let unordered = ["DEV-30", "DEV-2", "DEV-11", "DEV-4"]
        XCTAssertEqual(AppDelegate.issueKeyList(unordered), "DEV-2, DEV-4, DEV-11 +1 more")
        XCTAssertEqual(
            AppDelegate.issueKeyList(unordered.reversed()),
            AppDelegate.issueKeyList(unordered)
        )
    }

    func testNoKeysIsEmpty() {
        XCTAssertEqual(AppDelegate.issueKeyList([]), "")
    }

}
