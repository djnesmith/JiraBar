import XCTest
import AppKit
@testable import jiraBar

/// What a click on a status header copies, by modifier held. Four combinations, and the rule that
/// the plain click is the one the others build on.
final class StatusCopyFormatTests: XCTestCase {

    private let payload = AppDelegate.StatusCopyPayload(
        keys: ["DEV-1", "DEV-2", "DEV-3"],
        baseUrl: "https://example.atlassian.net"
    )

    private func copied(_ modifiers: NSEvent.ModifierFlags) -> String {
        AppDelegate.statusCopyText(payload, modifiers: modifiers)
    }

    // MARK: the four cases

    func testNoModifiersCopiesKeysSeparatedBySpaces() {
        XCTAssertEqual(copied([]), "DEV-1 DEV-2 DEV-3")
    }

    func testCommandCopiesKeysOnePerLine() {
        XCTAssertEqual(copied([.command]), "DEV-1\nDEV-2\nDEV-3")
    }

    func testOptionCopiesURLsSeparatedBySpaces() {
        XCTAssertEqual(
            copied([.option]),
            "https://example.atlassian.net/browse/DEV-1"
                + " https://example.atlassian.net/browse/DEV-2"
                + " https://example.atlassian.net/browse/DEV-3"
        )
    }

    func testOptionAndCommandCopiesURLsOnePerLine() {
        XCTAssertEqual(
            copied([.option, .command]),
            "https://example.atlassian.net/browse/DEV-1\n"
                + "https://example.atlassian.net/browse/DEV-2\n"
                + "https://example.atlassian.net/browse/DEV-3"
        )
    }

    /// The four are genuinely distinct — a mapping that collapsed two of them would still pass each
    /// case above if the expectation were wrong in the same way.
    func testTheFourCombinationsAllDiffer() {
        let all = [copied([]), copied([.command]), copied([.option]), copied([.option, .command])]
        XCTAssertEqual(Set(all).count, 4)
    }

    // MARK: the rules behind them

    /// Command picks the separator and nothing else; option picks the content and nothing else.
    func testCommandChangesOnlyTheSeparatorAndOptionOnlyTheContent() {
        XCTAssertEqual(copied([.command]), copied([]).replacingOccurrences(of: " ", with: "\n"))
        XCTAssertFalse(copied([.command]).contains("http"), "command alone must not switch to URLs")
        XCTAssertFalse(copied([.option]).contains("\n"), "option alone must not switch to lines")
    }

    /// A modifier outside the matrix must not swallow the click — shift or control held by accident
    /// still copies the plain form rather than nothing.
    func testUnrelatedModifiersAreIgnored() {
        XCTAssertEqual(copied([.shift]), copied([]))
        XCTAssertEqual(copied([.control]), copied([]))
        XCTAssertEqual(copied([.capsLock]), copied([]))
        XCTAssertEqual(copied([.shift, .command]), copied([.command]))
        XCTAssertEqual(copied([.control, .option]), copied([.option]))
    }

    // MARK: URLs

    /// URLs come from the one builder, so a Server instance's base URL is honoured rather than a
    /// hard-coded atlassian.net.
    func testURLsAreBuiltFromTheConfiguredBaseUrl() {
        let server = AppDelegate.StatusCopyPayload(
            keys: ["DEV-1"], baseUrl: "https://jira.internal.example.com"
        )
        XCTAssertEqual(
            AppDelegate.statusCopyText(server, modifiers: [.option]),
            "https://jira.internal.example.com/browse/DEV-1"
        )
    }

    func testTheURLBuilderProducesABrowseURL() {
        XCTAssertEqual(
            AppDelegate.browseURL(forKey: "DEV-1", baseUrl: "https://example.atlassian.net"),
            "https://example.atlassian.net/browse/DEV-1"
        )
    }

    /// One key, so there is nothing to separate — no trailing separator in any of the four.
    func testASingleIssueHasNoSeparatorInAnyFormat() {
        let one = AppDelegate.StatusCopyPayload(keys: ["DEV-1"], baseUrl: "https://example.atlassian.net")
        XCTAssertEqual(AppDelegate.statusCopyText(one, modifiers: []), "DEV-1")
        XCTAssertEqual(AppDelegate.statusCopyText(one, modifiers: [.command]), "DEV-1")
        XCTAssertEqual(
            AppDelegate.statusCopyText(one, modifiers: [.option]),
            "https://example.atlassian.net/browse/DEV-1"
        )
    }

    /// The guard the deleted `CopyableKeyListTests` carried, kept because it is the one thing
    /// separating this from `issueKeyList`, which names issues for a notification and trades the tail
    /// for "+N more" past three (`namedIssueKeyLimit`). A clipboard has no display to clip, so a copy
    /// that dropped tickets would be silent data loss. Twelve keys is well past that limit.
    func testALongGroupIsCopiedInFullWithNoCollapsing() {
        let many = (1...12).map { "DEV-\($0)" }
        let long = AppDelegate.StatusCopyPayload(keys: many, baseUrl: "https://example.atlassian.net")

        let spaced = AppDelegate.statusCopyText(long, modifiers: [])
        XCTAssertEqual(spaced, many.joined(separator: " "))
        XCTAssertFalse(spaced.contains("more"), "issueKeyList would have collapsed this")

        let lined = AppDelegate.statusCopyText(long, modifiers: [.command])
        XCTAssertEqual(lined.components(separatedBy: "\n").count, 12)

        let urls = AppDelegate.statusCopyText(long, modifiers: [.option, .command])
        XCTAssertEqual(urls.components(separatedBy: "\n").count, 12)
        XCTAssertTrue(urls.hasSuffix("/browse/DEV-12"), "the tail of a long group must survive")
    }

    // MARK: the guard

    /// A status row only exists because it has issues, so this is unreachable from the menu — but an
    /// empty payload must not put an empty string on the clipboard in any of the four shapes.
    func testAnEmptyGroupCopiesNothingInEveryFormat() {
        let empty = AppDelegate.StatusCopyPayload(keys: [], baseUrl: "https://example.atlassian.net")
        for modifiers: NSEvent.ModifierFlags in [[], [.command], [.option], [.option, .command]] {
            XCTAssertEqual(AppDelegate.statusCopyText(empty, modifiers: modifiers), "")
        }
    }

    /// The order the rows are drawn in survives every format — the reason URLs are derived from the
    /// keys rather than carried as a second list.
    func testEveryFormatKeepsTheGroupsOrder() {
        let boardOrder = AppDelegate.StatusCopyPayload(
            keys: ["DEV-30", "DEV-2", "DEV-11"], baseUrl: "https://example.atlassian.net"
        )
        XCTAssertEqual(AppDelegate.statusCopyText(boardOrder, modifiers: []), "DEV-30 DEV-2 DEV-11")
        XCTAssertEqual(
            AppDelegate.statusCopyText(boardOrder, modifiers: [.option, .command])
                .components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: "https://example.atlassian.net/browse/", with: "") },
            ["DEV-30", "DEV-2", "DEV-11"]
        )
    }

}
