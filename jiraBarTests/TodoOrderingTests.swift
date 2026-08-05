import XCTest
@testable import jiraBar

/// Covers the TODO section's board-order sort. Issues are decoded from JSON rather than
/// constructed, since Issue/Fields have no memberwise init exposed.
final class TodoOrderingTests: XCTestCase {

    private func issues(_ keys: [String]) throws -> [Issue] {
        let items = keys.map { key in
            """
            {"id":"1","key":"\(key)","fields":{"summary":"s","status":{"name":"To Do"},
             "issuetype":{"name":"Task"},"project":{"name":"P"}}}
            """
        }
        return try JSONDecoder().decode([Issue].self, from: Data("[\(items.joined(separator: ","))]".utf8))
    }

    func testSortsByRankAscending() throws {
        let input = try issues(["A-3", "A-1", "A-2"])
        let ranks = ["A-1": "0|a", "A-2": "0|b", "A-3": "0|c"]
        XCTAssertEqual(AppDelegate.orderedByRank(input, ranks: ranks).map(\.key), ["A-1", "A-2", "A-3"])
    }

    func testUnrankedSinkBelowRankedKeepingApiOrder() throws {
        let input = try issues(["A-1", "A-2", "A-3", "A-4"])
        let ranks = ["A-3": "0|b", "A-1": "0|a"]
        // Ranked first (by rank), then the unranked pair in the order Jira returned them.
        XCTAssertEqual(
            AppDelegate.orderedByRank(input, ranks: ranks).map(\.key),
            ["A-1", "A-3", "A-2", "A-4"]
        )
    }

    /// With no rank field configured the sort must be a no-op, so any ORDER BY in the user's
    /// TODO JQL survives.
    func testNoRanksPreservesApiOrder() throws {
        let input = try issues(["A-9", "A-2", "A-7"])
        XCTAssertEqual(AppDelegate.orderedByRank(input, ranks: [:]).map(\.key), ["A-9", "A-2", "A-7"])
    }

    func testEmptyInput() {
        XCTAssertTrue(AppDelegate.orderedByRank([], ranks: ["A-1": "0|a"]).isEmpty)
    }
}
