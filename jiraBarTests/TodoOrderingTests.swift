import XCTest
@testable import jiraBar

/// Covers the TODO section's board-order sort and its assigned-to-me filter. Issues are decoded
/// from JSON rather than constructed, since Issue/Fields have no memberwise init exposed.
final class TodoOrderingTests: XCTestCase {

    private func issues(_ keys: [String]) throws -> [Issue] {
        try issues(keys.map { ($0, "null") })
    }

    /// Builds issues from `(key, assignee)` pairs, where the assignee is the raw JSON Jira puts in
    /// the field: Cloud's accountId-bearing object, Server's name-bearing one, or `null`.
    private func issues(_ rows: [(String, String)]) throws -> [Issue] {
        let items = rows.map { key, assignee in
            """
            {"id":"1","key":"\(key)","fields":{"summary":"s","status":{"name":"To Do"},
             "issuetype":{"name":"Task"},"project":{"name":"P"},"assignee":\(assignee)}}
            """
        }
        return try JSONDecoder().decode([Issue].self, from: Data("[\(items.joined(separator: ","))]".utf8))
    }

    /// Cloud's search response omits `name` on the assignee entirely — accountId is all there is.
    private let cloudMe = #"{"accountId":"acct-me","displayName":"Sample User"}"#
    private let cloudOther = #"{"accountId":"acct-other","displayName":"Other Person"}"#
    private let unassigned = "null"

    private func me(accountId: String? = nil, name: String? = nil, key: String? = nil) -> JiraUser {
        var user = JiraUser(displayName: "Sample User")
        user.accountId = accountId
        user.name = name
        user.key = key
        return user
    }

    // MARK: ordering

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

    // MARK: assigned-to-me filter

    func testDropsOnlyTheRowsAssignedToMeOnCloud() throws {
        let input = try issues([
            ("A-1", cloudMe),
            ("A-2", cloudOther),
            ("A-3", unassigned),
            ("A-4", cloudMe)
        ])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(accountId: "acct-me"), limit: nil).map(\.key),
            ["A-2", "A-3"]
        )
    }

    /// Server/DC has no accountId on either side; the username is the identity.
    func testMatchesByUsernameOnServer() throws {
        let input = try issues([
            ("A-1", #"{"name":"sample.user","displayName":"Sample User"}"#),
            ("A-2", #"{"name":"other.person","displayName":"Other Person"}"#)
        ])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(name: "sample.user"), limit: nil).map(\.key),
            ["A-2"]
        )
    }

    /// Older Server installs identify users by `key` and may not send `name`.
    func testMatchesByKeyWhenThatIsAllThereIs() throws {
        let input = try issues([
            ("A-1", #"{"key":"JIRAUSER1","displayName":"Sample User"}"#),
            ("A-2", #"{"key":"JIRAUSER2","displayName":"Other Person"}"#)
        ])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(key: "JIRAUSER1"), limit: nil).map(\.key),
            ["A-2"]
        )
    }

    /// A namesake is not you. displayName is not an identifier and must never match on its own,
    /// or the filter hides someone else's ticket.
    func testDisplayNameAloneNeverMatches() throws {
        let input = try issues([("A-1", #"{"accountId":"acct-other","displayName":"Sample User"}"#)])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(accountId: "acct-me"), limit: nil).map(\.key),
            ["A-1"]
        )
    }

    /// Nothing in common to compare — a Cloud-shaped assignee against a Server-shaped identity.
    /// It must keep the row: a tier mismatch is not evidence the ticket is yours, and this is the
    /// contract a future displayName fallback would quietly break.
    func testNoSharedIdentifierKeepsTheRow() throws {
        let input = try issues([("A-1", cloudMe)])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(name: "sample.user"), limit: nil).map(\.key),
            ["A-1"]
        )
    }

    /// A failed /myself must leave the section exactly as it was before the filter existed.
    func testUnknownCurrentUserFiltersNothing() throws {
        let input = try issues([("A-1", cloudMe), ("A-2", unassigned)])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: nil, limit: nil).map(\.key),
            ["A-1", "A-2"]
        )
    }

    /// Filtering the whole result away is what drives the section's removal, so it has to be an
    /// empty list rather than a partial one.
    func testEverythingAssignedToMeYieldsNothing() throws {
        let input = try issues([("A-1", cloudMe), ("A-2", cloudMe)])
        XCTAssertTrue(AppDelegate.todoRows(input, excluding: me(accountId: "acct-me"), limit: 15).isEmpty)
    }

    /// The cap counts rows the user will see, not rows Jira returned — the whole reason the search
    /// over-fetches.
    func testCapAppliesAfterFiltering() throws {
        let input = try issues([
            ("A-1", cloudMe),
            ("A-2", unassigned),
            ("A-3", cloudMe),
            ("A-4", cloudOther),
            ("A-5", unassigned),
            ("A-6", unassigned)
        ])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(accountId: "acct-me"), limit: 3).map(\.key),
            ["A-2", "A-4", "A-5"]
        )
    }

    func testFewerRowsThanTheCapAreLeftAlone() throws {
        let input = try issues([("A-1", unassigned), ("A-2", cloudOther)])
        XCTAssertEqual(
            AppDelegate.todoRows(input, excluding: me(accountId: "acct-me"), limit: 15).map(\.key),
            ["A-1", "A-2"]
        )
    }

    /// An unparseable "Max Results" setting is passed to Jira untouched, so there is no number to
    /// trim against either.
    func testNilLimitLeavesEveryRemainingRow() throws {
        let input = try issues([("A-1", unassigned), ("A-2", unassigned), ("A-3", unassigned)])
        XCTAssertEqual(AppDelegate.todoRows(input, excluding: nil, limit: nil).count, 3)
    }

    /// Pins the order the two steps compose in, which the over-fetch made load-bearing: the cap
    /// selects from the order Jira returned (the user's ORDER BY), and rank only sorts what
    /// survives. Rank sorting first would let high-ranked tickets from the tail of the over-fetch
    /// displace the ones the user's own query chose.
    func testCapSelectsFromJirasOrderAndRankSortsOnlyTheSurvivors() throws {
        let fetched = try issues(["A-1", "A-2", "A-3", "A-4"])
        // Board order says the two Jira did *not* return first are top of the board.
        let ranks = ["A-1": "0|d", "A-2": "0|c", "A-3": "0|a", "A-4": "0|b"]

        let rows = AppDelegate.todoRows(fetched, excluding: nil, limit: 2)
        let shown = AppDelegate.orderedByRank(rows, ranks: ranks).map(\.key)

        // A-1/A-2 are Jira's first two and the only candidates; rank swaps them, and the
        // higher-ranked A-3/A-4 stay out because the cap already excluded them.
        XCTAssertEqual(shown, ["A-2", "A-1"])
    }

    // MARK: over-fetch sizing

    func testFetchSizeAddsHeadroomForTheFilter() {
        XCTAssertEqual(AppDelegate.todoFetchSize(15), "30")
        XCTAssertEqual(AppDelegate.todoFetchSize(1), "6")
        XCTAssertEqual(AppDelegate.todoFetchSize(5), "10")
    }

    /// Nothing to scale — the caller falls back to the raw setting string.
    func testFetchSizeIsNilWithoutAUsableNumber() {
        XCTAssertNil(AppDelegate.todoFetchSize(nil))
        XCTAssertNil(AppDelegate.todoFetchSize(0))
        XCTAssertNil(AppDelegate.todoFetchSize(-1))
    }

    /// "Max Results" is a free-text field, so Int.max parses out of it. Doubling that must
    /// saturate rather than trap — the crash would land on the launch refresh, leaving no way to
    /// open Preferences and take the value back out.
    func testOverFetchSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(AppDelegate.overFetchCount(Int.max), Int.max)
        XCTAssertEqual(AppDelegate.overFetchCount(Int.max / 2 + 1), Int.max)
        XCTAssertEqual(AppDelegate.overFetchCount(Int.min), Int.max)
        XCTAssertEqual(AppDelegate.todoFetchSize(Int.max), String(Int.max))
    }

    // MARK: the row cap setting

    /// The trim is the whole point of this seam: without it a pasted " 15 " parses to nil, and the
    /// section falls back to no client-side cap at all.
    func testMaxResultsSettingToleratesSurroundingWhitespace() {
        XCTAssertEqual(AppDelegate.maxResultsSetting(" 15 "), 15)
        XCTAssertEqual(AppDelegate.maxResultsSetting("15\n"), 15)
        XCTAssertEqual(AppDelegate.maxResultsSetting("15"), 15)
    }

    func testMaxResultsSettingIsNilWhenNotANumber() {
        XCTAssertNil(AppDelegate.maxResultsSetting(""))
        XCTAssertNil(AppDelegate.maxResultsSetting("   "))
        XCTAssertNil(AppDelegate.maxResultsSetting("abc"))
    }

    /// Zero and nil both mean "no cap here", matching what the section did before the filter: the
    /// raw setting goes to Jira and whatever comes back is what shows.
    func testZeroAndNilBothMeanNoClientSideCap() throws {
        let input = try issues([("A-1", unassigned), ("A-2", unassigned)])
        XCTAssertEqual(AppDelegate.todoRows(input, excluding: nil, limit: 0).count, 2)
        XCTAssertEqual(AppDelegate.todoRows(input, excluding: nil, limit: nil).count, 2)
    }
}
