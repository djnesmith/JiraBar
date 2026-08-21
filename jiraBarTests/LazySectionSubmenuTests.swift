import XCTest
import AppKit
@testable import jiraBar

/// Every lazy section (TODO, Recently Closed, Recently Seen) hangs the full per-issue submenu off
/// its rows, and `attachIssueSubmenu` only attaches it once the transitions request comes back — so
/// a row sits in an open menu with no submenu at all for a moment. That was a new state for the two
/// history sections: the finished-ticket builder they used to share attached its submenu
/// synchronously.
///
/// It matters because of the latch `MenuSectionHeaderTests` documents: an item AppKit disables on
/// the first enabling pass never comes back, no matter what is attached afterwards. Ticket rows
/// escape it only because `makeIssueRow` gives them an action of their own, so they are enabled on
/// that first pass with or without a submenu.
///
/// **What this does not cover.** These tests pin the *precondition* the change leans on, not the
/// wiring itself — nothing here fails if a section goes back to a reduced submenu builder. The
/// section builders and `attachIssueSubmenu` are private and network-first, and `JiraClient` is
/// constructed inline rather than injected, so there is no seam to drive them from a test without
/// restructuring how the delegate gets its client. The wiring is verified by hand against a live
/// instance instead.
final class LazySectionSubmenuTests: XCTestCase {

    /// `AppDelegate`'s `statusBarItem` is a stored property, so merely constructing one puts a real
    /// item in the system menu bar. Held here and removed in `tearDown` so the suite doesn't leave
    /// orphans behind it.
    private var delegate: AppDelegate!

    override func setUp() {
        super.setUp()
        delegate = AppDelegate()
    }

    override func tearDown() {
        NSStatusBar.system.removeStatusItem(delegate.statusBarItem)
        delegate = nil
        super.tearDown()
    }

    /// Decoded rather than constructed — Issue/Fields expose no memberwise init.
    private func issue(_ key: String) throws -> Issue {
        let json = """
        {"id":"10001","key":"\(key)","fields":{"summary":"A handed-off ticket",
         "status":{"name":"Ready for Release"},"issuetype":{"name":"Task"},
         "project":{"name":"P"},"assignee":{"accountId":"acct-other","displayName":"Other Person"}}}
        """
        return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
    }

    /// The production fact everything below rests on. `makeIssueRow` attaches `openLink` so the row
    /// is clickable in its own right; without an action it would be a bare item, and
    /// `MenuSectionHeaderTests.testBareItemStaysDisabledEvenAfterASubmenuIsAttached` shows what
    /// AppKit does to those. Status-independent, so one row proves it for every section.
    func testIssueRowCarriesItsOwnActionSoItIsNeverABareItem() throws {
        let row = delegate.makeIssueRow(for: try issue("PROJ-1"), showStatus: true)
        XCTAssertNotNil(row.action, "a row with no action latches disabled before its submenu lands")
    }

    /// The behaviour the change rests on, run against the real row. Compare with
    /// `MenuSectionHeaderTests.testBareItemStaysDisabledEvenAfterASubmenuIsAttached`: the only
    /// difference is the action, and it is the whole difference.
    func testRealRowSurvivesTheEnablingPassAndAcceptsALateSubmenu() throws {
        let sectionMenu = NSMenu()
        XCTAssertTrue(sectionMenu.autoenablesItems, "the latch only exists while autoenabling is on")

        // Two rows, because a section holds several and their transitions requests land
        // independently — one row's submenu arriving must not depend on its neighbour's.
        let rows = try [issue("PROJ-1"), issue("PROJ-2")].map {
            delegate.makeIssueRow(for: $0, showStatus: true)
        }
        rows.forEach { sectionMenu.addItem($0) }

        // The pass AppKit runs when the user opens the section — both transitions requests are
        // still in flight, so neither row has anything hanging off it.
        sectionMenu.update()
        XCTAssertTrue(rows.allSatisfy { $0.submenu == nil })
        XCTAssertTrue(rows.allSatisfy(\.isEnabled), "a row with an action is enabled without a submenu")

        // The first row's transitions land and `attachIssueSubmenu` hangs the real submenu off it.
        rows[0].submenu = submenuWithATransition()
        sectionMenu.update()

        XCTAssertTrue(rows[0].isEnabled, "still enabled, so the late submenu is reachable")
        XCTAssertEqual(rows[0].submenu?.items.count, 1)
        XCTAssertTrue(rows[1].isEnabled, "the row still waiting is not disabled by its neighbour")
        XCTAssertNil(rows[1].submenu)
    }

    private func submenuWithATransition() -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Close", action: nil, keyEquivalent: ""))
        return submenu
    }
}
