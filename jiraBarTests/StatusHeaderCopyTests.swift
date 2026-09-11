import XCTest
import AppKit
@testable import jiraBar

/// Clicking a status header copies every key under it. Two things have to hold for that, and neither
/// is covered by testing the string helper on its own:
///
/// 1. the row is ENABLED once the menu opens — it was a bare `action: nil` item before this, and
///    `MenuSectionHeaderTests` shows what NSMenu's enabling latch does to those;
/// 2. the keys come out in the order the rows are drawn in, which is board order, not key order.
///
/// Reachable from a test for the same reason `makeIssueRow` is — see `LazySectionSubmenuTests`.
///
/// **What this does not cover.** `statusGroup` hands back the header and the rows as one value so
/// the two cannot be built from different orders, and `testTheHeaderCopiesExactlyTheRowsItHeads`
/// pins that they agree. What no test here reaches is the menu builder's own `for` loop, which
/// lives inside the `getIssuesByJql` completion in `refreshMenu` with no seam to drive it from —
/// `JiraClient` is constructed inline rather than injected. A loop that drew its rows from the
/// pre-sort array while adding `group.header` would still pass this file. Verified by mutation:
/// swapping `group.issues` for `issuess` in that loop leaves the suite green. That
/// one line is checked by eye against a live instance, not by a test.
final class StatusHeaderCopyTests: XCTestCase {

    private let base = "https://example.atlassian.net"

    /// Decoded rather than constructed — Issue/Fields expose no memberwise init.
    private func issue(_ key: String) throws -> Issue {
        let json = """
        {"id":"10001","key":"\(key)","fields":{"summary":"A ticket",
         "status":{"name":"QA"},"issuetype":{"name":"Task"},"project":{"name":"P"}}}
        """
        return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
    }

    private func issues(_ keys: [String]) throws -> [Issue] {
        try keys.map { try issue($0) }
    }

    private func payload(_ item: NSMenuItem) -> AppDelegate.StatusCopyPayload? {
        item.representedObject as? AppDelegate.StatusCopyPayload
    }

    // MARK: the row survives the enabling latch

    /// The whole reason the row has an action. Run through a real `NSMenu.update()`, which is what
    /// AppKit does when the menu opens, because that is the pass that used to disable it.
    func testTheHeaderIsEnabledAfterTheMenuUpdates() throws {
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(["DEV-1", "DEV-2"]), color: .systemGreen, baseUrl: base
        )
        let menu = NSMenu()
        menu.addItem(header)
        XCTAssertTrue(menu.autoenablesItems, "the latch only bites while AppKit is auto-enabling")
        menu.update()
        XCTAssertTrue(header.isEnabled, "a status header that greys out cannot be clicked")
    }

    /// A rebuild is how every refresh works (`refreshMenu` starts from `removeAllItems`), so the row
    /// has to come back enabled each time rather than only on the first build.
    func testTheHeaderIsStillEnabledAfterRepeatedRebuilds() throws {
        let menu = NSMenu()
        for refresh in 1...3 {
            menu.removeAllItems()
            let header = AppDelegate.makeStatusHeader(
                status: "QA", issues: try issues(["DEV-1"]), color: .systemGreen, baseUrl: base
            )
            menu.addItem(header)
            menu.update()
            menu.update()
            XCTAssertTrue(header.isEnabled, "greyed out on refresh #\(refresh)")
        }
    }

    // MARK: what a click copies

    func testTheHeaderCarriesEveryKeyUnderIt() throws {
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(["DEV-1", "DEV-2", "DEV-3"]), color: nil, baseUrl: base
        )
        XCTAssertEqual(payload(header)?.keys, ["DEV-1", "DEV-2", "DEV-3"])
    }

    /// The payload follows the array it was handed, which is the array the rows are drawn from. A
    /// header that re-sorted would copy something other than what the user is looking at.
    func testTheKeysAreInTheOrderTheRowsAreDrawn() throws {
        let boardOrder = ["DEV-30", "DEV-2", "DEV-11"]
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(boardOrder), color: nil, baseUrl: base
        )
        XCTAssertEqual(payload(header)?.keys, ["DEV-30", "DEV-2", "DEV-11"])
    }

    /// `copyStatusList` reads `representedObject as? StatusCopyPayload`, so the type is part of the
    /// contract — anything else here would leave the clipboard untouched and the click do nothing.
    func testThePayloadIsTheTypeTheActionReads() throws {
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(["DEV-1"]), color: nil, baseUrl: base
        )
        XCTAssertEqual(header.action, #selector(AppDelegate.copyStatusList(_:)))
        XCTAssertNotNil(payload(header), "copyStatusList reads a StatusCopyPayload and nothing else")
    }

    // MARK: the title is unchanged

    /// The colour and the text are the part of the row that was explicitly not to change.
    func testTheColouredTitleIsPreserved() throws {
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(["DEV-1"]), color: .systemGreen, baseUrl: base
        )
        XCTAssertEqual(header.attributedTitle?.string, "QA")
        let color = header.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        XCTAssertEqual(color as? NSColor, .systemGreen)
    }

    /// A status with no colour configured keeps a plain title — `nsColor` is optional precisely so
    /// "no colour set" stays distinguishable, and inventing one here would override that.
    ///
    /// The *title* is unchanged; how it draws is not. An uncoloured header was disabled before and
    /// drew dimmed, and now draws at full strength. That is inherent to making the row clickable and
    /// applies to every status until the user configures colours.
    func testAStatusWithNoColourKeepsAPlainTitle() throws {
        let header = AppDelegate.makeStatusHeader(
            status: "QA", issues: try issues(["DEV-1"]), color: nil, baseUrl: base
        )
        XCTAssertNil(header.attributedTitle)
        XCTAssertEqual(header.title, "QA")
    }

    // MARK: the guard

    /// Grouping cannot produce an empty status, so this is unreachable from the menu. Pinned anyway
    /// because it is what stops a click that would clear the clipboard and paste nothing.
    func testAnEmptyGroupGetsNoClickAction() throws {
        let header = AppDelegate.makeStatusHeader(status: "QA", issues: [], color: .systemGreen, baseUrl: base)
        XCTAssertNil(header.action, "an empty status must not offer a copy")
        XCTAssertNil(header.toolTip)
    }

    // MARK: header and rows cannot drift apart

    /// The feature's actual claim: what a click copies is what the menu is showing. `statusGroup`
    /// returns the header and the rows together so the menu builder cannot render one order and copy
    /// another — this pins that they always agree, whatever the ranks do to the order.
    func testTheHeaderCopiesExactlyTheRowsItHeads() throws {
        let rankings: [[String: String]] = [
            ["DEV-1": "0|c", "DEV-2": "0|a", "DEV-3": "0|b"],   // fully ranked, reorders the group
            ["DEV-2": "0|b"],                                    // partly ranked, unranked sink
            [:],                                                 // nothing ranked, tiebreaker only
        ]
        for ranks in rankings {
            let group = AppDelegate.statusGroup(
                status: "QA", issues: try issues(["DEV-1", "DEV-2", "DEV-3"]), ranks: ranks,
                color: nil, baseUrl: base
            )
            XCTAssertEqual(
                payload(group.header)?.keys,
                group.issues.map(\.key),
                "the copied keys drifted from the rows drawn under them"
            )
        }
    }

    /// And the group really is ordered — the invariant above would also hold if both sides were
    /// unsorted, so the ordering is pinned here too.
    func testTheGroupsRowsAreInBoardOrder() throws {
        let group = AppDelegate.statusGroup(
            status: "QA",
            issues: try issues(["DEV-1", "DEV-2", "DEV-3"]),
            ranks: ["DEV-1": "0|c", "DEV-2": "0|a", "DEV-3": "0|b"],
            color: nil,
            baseUrl: base
        )
        XCTAssertEqual(group.issues.map(\.key), ["DEV-2", "DEV-3", "DEV-1"])
        XCTAssertEqual(payload(group.header)?.keys, ["DEV-2", "DEV-3", "DEV-1"])
    }

}
