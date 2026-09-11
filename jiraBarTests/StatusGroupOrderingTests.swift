import XCTest
@testable import jiraBar

/// The order tickets appear in under a status header — and, since the header copies them, the order
/// they land on the clipboard in. Board order (Lexorank), not key order.
final class StatusGroupOrderingTests: XCTestCase {

    /// Decoded rather than constructed — Issue/Fields expose no memberwise init.
    private func issues(_ keys: [String]) throws -> [Issue] {
        try keys.map { key in
            let json = """
            {"id":"10001","key":"\(key)","fields":{"summary":"A ticket",
             "status":{"name":"QA"},"issuetype":{"name":"Task"},"project":{"name":"P"}}}
            """
            return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
        }
    }

    private func keys(_ ordered: [Issue]) -> [String] { ordered.map(\.key) }

    /// The point of the whole thing: the board's order, which has nothing to do with the key numbers.
    func testRankedIssuesComeOutInLexorankOrder() throws {
        let ordered = AppDelegate.orderedInStatusGroup(
            try issues(["DEV-1", "DEV-2", "DEV-3"]),
            ranks: ["DEV-1": "0|c", "DEV-2": "0|a", "DEV-3": "0|b"]
        )
        XCTAssertEqual(keys(ordered), ["DEV-2", "DEV-3", "DEV-1"])
    }

    func testUnrankedIssuesSinkBelowRankedOnes() throws {
        let ordered = AppDelegate.orderedInStatusGroup(
            try issues(["DEV-1", "DEV-2", "DEV-3"]),
            ranks: ["DEV-2": "0|b"]
        )
        XCTAssertEqual(keys(ordered), ["DEV-2", "DEV-1", "DEV-3"])
    }

    /// With no rank field configured at all, nothing is ranked. Without a tiebreaker the group would
    /// come back in whatever order the search returned and reshuffle between refreshes.
    func testWithNoRanksAtAllTheOrderIsStableRunToRun() throws {
        let unordered = try issues(["DEV-30", "DEV-2", "DEV-11", "DEV-4"])
        let ordered = AppDelegate.orderedInStatusGroup(unordered, ranks: [:])
        // The literal, not just "both orders agree" — the weaker form passes under any
        // stable-but-wrong scheme, as IssueKeyListTests spells out.
        XCTAssertEqual(keys(ordered), ["DEV-11", "DEV-2", "DEV-30", "DEV-4"])
        XCTAssertEqual(
            keys(AppDelegate.orderedInStatusGroup(unordered.reversed(), ranks: [:])),
            keys(ordered),
            "the same group must not order differently run to run"
        )
    }

    /// Pins existing behaviour rather than endorsing it. The tiebreaker is
    /// `localizedCaseInsensitiveCompare`, which is lexicographic — DEV-11 sorts ahead of DEV-2 —
    /// whereas `issueKeyList` uses `localizedStandardCompare` and sorts them naturally. Moving this
    /// sort into its own function did not change it; the mismatch predates the status header. It
    /// shows whenever two issues in a group are unranked — every issue when no rank field is set,
    /// but also a null rank or a rank field missing from an issue's screen, since
    /// `JiraClient.extractIssueExtras` only records a rank the cast succeeds on. Asserted so the
    /// difference is recorded rather than rediscovered, and so changing it takes a deliberate edit.
    func testTheTiebreakerIsLexicographicNotNatural() throws {
        let ordered = AppDelegate.orderedInStatusGroup(try issues(["DEV-11", "DEV-2"]), ranks: [:])
        XCTAssertEqual(keys(ordered), ["DEV-11", "DEV-2"])
    }

    func testAnEmptyGroupStaysEmpty() throws {
        XCTAssertEqual(AppDelegate.orderedInStatusGroup([], ranks: [:]).count, 0)
    }

}
