import XCTest
import AppKit
@testable import jiraBar

/// Covers the async section headers (TODO, PRs Without Tickets) and the rendezvous that fills
/// them in. The bug these pin down: both sections greyed out on a manual refresh and stayed
/// greyed until some later refresh happened to win a race against AppKit's enabling pass.
final class MenuSectionHeaderTests: XCTestCase {

    // MARK: - The AppKit behaviour the fix works around

    /// Pins the platform behaviour that caused the bug, so this stops being a mystery if it ever
    /// changes: NSMenu's automatic enabling *latches*. A bare item — no action, no submenu — is
    /// disabled by the first enabling pass, and attaching a submenu afterwards never brings it
    /// back. If this test starts failing, `makeSectionHeader`'s placeholder submenu is no longer
    /// load-bearing.
    func testBareItemStaysDisabledEvenAfterASubmenuIsAttached() {
        let menu = NSMenu()
        XCTAssertTrue(menu.autoenablesItems, "the workaround only matters while autoenabling is on")

        let item = NSMenuItem(title: "TODO", action: nil, keyEquivalent: "")
        menu.addItem(item)

        // The enabling pass AppKit runs when the menu is opened.
        menu.update()
        XCTAssertFalse(item.isEnabled, "a bare section header is disabled on the first enabling pass")

        // Data lands and the section is filled in — too late.
        item.submenu = menuWithOneRow()
        menu.update()
        XCTAssertFalse(item.isEnabled, "attaching a submenu does not undo the latch")
    }

    // MARK: - makeSectionHeader

    func testSectionHeaderStaysEnabledAcrossEnablingPasses() {
        let menu = NSMenu()
        let header = AppDelegate.makeSectionHeader(title: "TODO", symbolName: "checklist.unchecked")
        menu.addItem(header)

        menu.update()
        XCTAssertTrue(header.isEnabled)
        menu.update()
        XCTAssertTrue(header.isEnabled, "still enabled after a second pass — no latch to trip")
    }

    func testSectionHeaderSaysItIsWaitingUntilItsDataArrives() {
        let header = AppDelegate.makeSectionHeader(title: "TODO", symbolName: "checklist.unchecked")
        XCTAssertEqual(header.submenu?.items.count, 1)
        XCTAssertEqual(header.submenu?.items.first?.title, "Waiting on data…")
        XCTAssertEqual(header.submenu?.items.first?.isEnabled, false, "the placeholder isn't clickable")
    }

    /// The placeholder is a plain text row on purpose. A custom `NSMenuItem.view` — which is what
    /// hosting a real spinner would need — doesn't pick up standard menu row metrics or
    /// highlighting, so it would sit visibly wrong next to the rows that replace it. And
    /// NSProgressIndicator doesn't animate inside a menu's modal tracking run loop anyway; see
    /// makeSectionHeader's note for the measurements.
    func testSectionHeaderPlaceholderIsAPlainRowNotACustomView() {
        let header = AppDelegate.makeSectionHeader(title: "TODO", symbolName: "checklist.unchecked")
        XCTAssertNil(header.submenu?.items.first?.view)
    }

    /// The real render path: the section replaces its submenu wholesale once the fetch returns,
    /// which has to survive the enabling pass the way the placeholder did.
    func testSectionHeaderStaysEnabledAfterItsSubmenuIsReplaced() {
        let menu = NSMenu()
        let header = AppDelegate.makeSectionHeader(title: "PRs Without Tickets", symbolName: "arrow.triangle.pull")
        menu.addItem(header)
        menu.update()

        header.submenu = menuWithOneRow()
        menu.update()
        XCTAssertTrue(header.isEnabled)
        XCTAssertEqual(header.submenu?.items.first?.title, "PROJ-1")
    }

    func testSectionHeaderCarriesItsSymbol() {
        let header = AppDelegate.makeSectionHeader(title: "TODO", symbolName: "checklist.unchecked")
        XCTAssertEqual(header.title, "TODO")
        XCTAssertNotNil(header.image)
    }

    // MARK: - PendingSection

    func testPendingSectionRendersWhenDataArrivesAfterTheRenderer() {
        let pending = PendingSection<[String]>()
        var rendered: [String]?
        pending.onReady { rendered = $0 }
        XCTAssertNil(rendered, "nothing to render yet")

        pending.deliver(["PROJ-1"])
        XCTAssertEqual(rendered, ["PROJ-1"])
    }

    /// The other half of the race: the TODO search now starts before its menu item exists, so the
    /// data can be sitting there by the time the renderer registers.
    func testPendingSectionRendersImmediatelyWhenDataArrivedFirst() {
        let pending = PendingSection<[String]>()
        pending.deliver(["PROJ-1"])

        var rendered: [String]?
        pending.onReady { rendered = $0 }
        XCTAssertEqual(rendered, ["PROJ-1"], "renderer runs at once against the data already held")
    }

    func testPendingSectionRendersOnlyOnce() {
        let pending = PendingSection<[String]>()
        var renderCount = 0
        pending.onReady { _ in renderCount += 1 }

        pending.deliver(["PROJ-1"])
        pending.deliver(["PROJ-2"])
        XCTAssertEqual(renderCount, 1, "a late second delivery must not re-render the section")
    }

    func testPendingSectionIgnoresASecondRegistration() {
        let pending = PendingSection<[String]>()
        pending.deliver(["PROJ-1"])

        var first: [String]?
        var second: [String]?
        pending.onReady { first = $0 }
        pending.onReady { second = $0 }

        XCTAssertEqual(first, ["PROJ-1"])
        XCTAssertNil(second, "the data is consumed by the first renderer")
    }

    // MARK: - Helpers

    private func menuWithOneRow() -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "PROJ-1", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return submenu
    }
}
