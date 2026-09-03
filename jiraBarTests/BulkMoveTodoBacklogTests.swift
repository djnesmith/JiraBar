import XCTest
@testable import jiraBar

/// The TODO backlog as bulk-move candidates: the merge, the dedupe, and the auto-check rule.
///
/// The two searches these cover really do overlap — `todoRows` and `recentlySeenRows` exist because
/// a key can come back from more than one of them — so the dedupe is not defensive padding.
final class BulkMoveTodoBacklogTests: XCTestCase {

    private func issue(_ key: String, status: String = "To Do", assignee: JiraUser? = nil) -> Issue {
        Issue(
            id: key,
            key: key,
            fields: Fields(
                summary: "summary for \(key)",
                status: IssueStatus(name: status),
                issuetype: IssueType(name: "Task"),
                project: Project(name: "Example"),
                assignee: assignee
            )
        )
    }

    // MARK: - The gap this closes

    /// The whole point: the backlog rows are fetched and rendered in the menu, and before this the
    /// dialog was handed `lastIssues` alone and never saw them.
    func testBacklogIssuesBecomeCandidates() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [issue("ABC-1", status: "In Progress")],
            backlog: [issue("ABC-9"), issue("ABC-10")]
        )
        XCTAssertEqual(candidates.map(\.key), ["ABC-1", "ABC-9", "ABC-10"])
    }

    /// The main list's order is what the user just read in the menu, and it leads.
    func testMainListComesFirstAndKeepsItsOrder() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [issue("ABC-3"), issue("ABC-1"), issue("ABC-2")],
            backlog: [issue("ABC-9")]
        )
        XCTAssertEqual(candidates.map(\.key), ["ABC-3", "ABC-1", "ABC-2", "ABC-9"])
    }

    /// A backlog with nothing in it — the common case, since `todoRows` drops what is already yours.
    func testAnEmptyBacklogChangesNothing() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [issue("ABC-1"), issue("ABC-2")], backlog: []
        )
        XCTAssertEqual(candidates.map(\.key), ["ABC-1", "ABC-2"])
    }

    /// No main list at all — the main JQL returned nothing, but the backlog is still worth moving.
    func testABacklogAloneIsStillCandidates() {
        let candidates = AppDelegate.bulkMoveCandidates(main: [], backlog: [issue("ABC-9")])
        XCTAssertEqual(candidates.map(\.key), ["ABC-9"])
    }

    // MARK: - Dedupe across the two searches

    /// `todoRows` only drops tickets assigned to you when the `/myself` lookup succeeded — a nil
    /// `me` filters nothing, deliberately — and the TODO JQL is the user's own text and may be
    /// scoped wider than the main query. Two `Issue` values under one key would render two checkbox
    /// rows for one ticket and then transition it twice in the same batch.
    func testAKeyInBothSearchesAppearsOnce() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [issue("ABC-1"), issue("ABC-2")],
            backlog: [issue("ABC-2"), issue("ABC-9")]
        )
        XCTAssertEqual(candidates.map(\.key), ["ABC-1", "ABC-2", "ABC-9"])
    }

    /// The surviving copy is the main list's, not the backlog's: it is the one already on screen
    /// above, whose status grouping the user just read.
    func testTheMainListsCopyWinsACollision() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [issue("ABC-2", status: "In Progress")],
            backlog: [issue("ABC-2", status: "To Do")]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.fields.status.name, "In Progress")
    }

    /// A key repeated inside the backlog itself is also collapsed — same failure, one search.
    func testARepeatedKeyWithinTheBacklogAppearsOnce() {
        let candidates = AppDelegate.bulkMoveCandidates(
            main: [], backlog: [issue("ABC-9"), issue("ABC-9")]
        )
        XCTAssertEqual(candidates.map(\.key), ["ABC-9"])
    }

    // MARK: - Which rows are labelled backlog

    func testBacklogOnlyKeysExcludesWhatTheMainListAlreadyHas() {
        let keys = AppDelegate.backlogOnlyKeys(
            main: [issue("ABC-1"), issue("ABC-2")],
            backlog: [issue("ABC-2"), issue("ABC-9")]
        )
        XCTAssertEqual(keys, ["ABC-9"])
    }

    func testBacklogOnlyKeysIsEmptyWithNoBacklog() {
        XCTAssertTrue(AppDelegate.backlogOnlyKeys(main: [issue("ABC-1")], backlog: []).isEmpty)
    }

    // MARK: - The auto-check rule

    /// The rule the whole feature's safety rests on: looking at the status the backlog feeds,
    /// nothing is picked yet. Submit stays disabled until something is checked, because `canSubmit`
    /// requires a non-empty `checkedKeys`.
    func testAStatusFedByTheBacklogChecksNothing() {
        let inStatus = [issue("ABC-1"), issue("ABC-9"), issue("ABC-10")]
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: inStatus, backlogOnly: ["ABC-9", "ABC-10"]
        )
        XCTAssertTrue(checked.isEmpty)
    }

    /// Intended, and the part that differs from a row-by-row rule: the user's *own* tickets in that
    /// status stop auto-checking too. All of the status or none of it — a half-checked list is the
    /// state somebody submits without reading.
    func testTheUsersOwnRowsInThatStatusAreNotCheckedEither() {
        let mine = issue("ABC-1")
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: [mine, issue("ABC-9")], backlogOnly: ["ABC-9"]
        )
        XCTAssertFalse(checked.contains("ABC-1"))
    }

    /// The other half of the change, and the one that would be worse to get wrong: every status the
    /// backlog does not feed behaves exactly as it did before.
    func testEveryOtherStatusStillChecksEverything() {
        let inStatus = [
            issue("ABC-1", status: "In Progress"),
            issue("ABC-2", status: "In Progress"),
        ]
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: inStatus, backlogOnly: ["ABC-9", "ABC-10"]
        )
        XCTAssertEqual(checked, ["ABC-1", "ABC-2"])
    }

    /// The rule generalises past a one-status TODO query: what makes a status unsafe to pre-tick is
    /// containing rows the user did not put there, whatever the status is called. A TODO JQL scoped
    /// by something other than status therefore holds back every status its rows land in.
    func testAnyStatusTheBacklogFeedsIsHeldBackNotJustOne() {
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: [issue("ABC-1", status: "In Progress"), issue("ABC-9", status: "In Progress")],
            backlogOnly: ["ABC-9"]
        )
        XCTAssertTrue(checked.isEmpty)
    }

    /// No backlog at all — the pre-change behaviour, unchanged for every status.
    func testWithNoBacklogEveryStatusChecksEverything() {
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: [issue("ABC-1"), issue("ABC-2")], backlogOnly: []
        )
        XCTAssertEqual(checked, ["ABC-1", "ABC-2"])
    }

    /// A status made up entirely of backlog rows.
    func testAStatusOfNothingButBacklogChecksNothing() {
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: [issue("ABC-9")], backlogOnly: ["ABC-9"]
        )
        XCTAssertTrue(checked.isEmpty)
    }

    /// The search was still in flight, so there are no backlog rows on screen to protect against
    /// and the status auto-checks as it always did. `backlogNotice` is what says the list is short.
    func testADeferredBacklogLeavesTheAutoCheckAlone() {
        let checked = BulkMoveDialog.autoCheckedKeys(
            inStatus: [issue("ABC-1")], backlogOnly: []
        )
        XCTAssertEqual(checked, ["ABC-1"])
    }

    // MARK: - Which status the dialog opens on

    private let order = [
        "Reopened", "To Do", "In Progress", "Review and Test", "QA", "Ready for Release", "Done",
    ]

    /// The constraint: the project backlog must not drag the opening view onto the status it feeds.
    /// With backlog rows counted this would open on To Do, because To Do precedes In Progress in
    /// the order and Reopened is empty.
    func testTheBacklogDoesNotChangeWhichStatusOpens() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-1", status: "In Progress"), issue("ABC-9", status: "To Do")],
            backlogOnly: ["ABC-9"],
            order: order
        )
        XCTAssertEqual(picked, "In Progress")
    }

    /// Nothing else to show, so the backlog may decide it — opening on nothing while there are
    /// backlog rows to move is worse.
    func testAnEmptyMainListOpensOnTheBacklogsStatus() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-9", status: "To Do")], backlogOnly: ["ABC-9"], order: order
        )
        XCTAssertEqual(picked, "To Do")
    }

    /// Not suppressed: these are the user's own tickets that happen to be in To Do, so To Do is
    /// eligible and first — exactly as before. This is the case a status-name rule would break.
    func testTheUsersOwnTicketsInTheBacklogsStatusStillOpenThere() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-1", status: "To Do"), issue("ABC-2", status: "In Progress")],
            backlogOnly: [],
            order: order
        )
        XCTAssertEqual(picked, "To Do")
    }

    /// Mixed: a main-list To Do ticket keeps To Do eligible even though backlog rows share it.
    func testAMainListToDoTicketKeepsToDoEligibleAlongsideBacklogRows() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-1", status: "To Do"), issue("ABC-9", status: "To Do")],
            backlogOnly: ["ABC-9"],
            order: order
        )
        XCTAssertEqual(picked, "To Do")
    }

    func testNothingToOpenOnWithNoCandidatesAtAll() {
        XCTAssertNil(
            BulkMoveDialog.initialFromStatus(candidates: [], backlogOnly: [], order: order)
        )
    }

    /// The configured order decides, not the order the searches returned rows in.
    func testTheConfiguredOrderDecidesNotTheRowOrder() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-1", status: "QA"), issue("ABC-2", status: "In Progress")],
            backlogOnly: [],
            order: order
        )
        XCTAssertEqual(picked, "In Progress")
    }

    /// A status the user never ordered falls to the end, so an ordered one still opens.
    func testAnUnorderedStatusDoesNotWinTheOpeningPick() {
        let picked = BulkMoveDialog.initialFromStatus(
            candidates: [issue("ABC-1", status: "Blocked"), issue("ABC-2", status: "QA")],
            backlogOnly: [],
            order: order
        )
        XCTAssertEqual(picked, "QA")
    }

    /// Every candidate status is still reachable from the picker, backlog-fed ones included — the
    /// opening pick narrows what you land on, never what you can choose.
    func testThePickerStillOffersTheBacklogsStatus() {
        let offered = BulkMoveDialog.orderedStatuses(
            [issue("ABC-1", status: "In Progress"), issue("ABC-9", status: "To Do")], order: order
        )
        XCTAssertEqual(offered, ["To Do", "In Progress"])
    }

    // MARK: - TodoBacklogState: loading is not empty

    /// The distinction the dialog's notice rests on, and the reason a bool would not do: three
    /// states have no rows to show, and only `loaded` may be presented as "the backlog is empty".
    func testOnlyTheUnansweredStatesReportAGap() {
        XCTAssertEqual(TodoBacklogState.loading.gap, .searching)
        XCTAssertEqual(TodoBacklogState.failed.gap, .unreachable)
        XCTAssertNil(TodoBacklogState.loaded([]).gap)
        XCTAssertNil(TodoBacklogState.unconfigured.gap)
    }

    /// All three are row-less, which is exactly why `gap` above has to separate them.
    func testLoadingFailedAndLoadedEmptyAllHaveNoRows() {
        XCTAssertTrue(TodoBacklogState.loading.issues.isEmpty)
        XCTAssertTrue(TodoBacklogState.failed.issues.isEmpty)
        XCTAssertTrue(TodoBacklogState.loaded([]).issues.isEmpty)
    }

    // MARK: - Whether the menu offers the dialog at all

    /// A backlog that has not answered yet still counts, so the item does not blink out for the
    /// moments of a refresh.
    func testAnUnansweredBacklogStillOffersTheDialog() {
        XCTAssertTrue(AppDelegate.shouldOfferBulkMove(main: [], backlog: .loading))
        XCTAssertTrue(AppDelegate.shouldOfferBulkMove(main: [], backlog: .failed))
    }

    /// The case the gate exists for: everything answered and empty, so the dialog would open onto
    /// nothing and the item is hidden instead.
    func testNothingToOfferHidesTheDialog() {
        XCTAssertFalse(AppDelegate.shouldOfferBulkMove(main: [], backlog: .loaded([])))
        XCTAssertFalse(AppDelegate.shouldOfferBulkMove(main: [], backlog: .unconfigured))
    }

    /// Rows from either search are enough on their own.
    func testRowsFromEitherSearchOfferTheDialog() {
        XCTAssertTrue(AppDelegate.shouldOfferBulkMove(main: [issue("ABC-1")], backlog: .unconfigured))
        XCTAssertTrue(
            AppDelegate.shouldOfferBulkMove(main: [], backlog: .loaded([issue("ABC-9")]))
        )
    }

    // MARK: - The refresh-time state machine

    /// The detail that makes it usable: a refresh over rows we already have keeps them, rather than
    /// blanking the bucket on every timer tick.
    func testARefreshKeepsRowsItAlreadyHas() {
        let kept = AppDelegate.todoBacklogAtRefresh(
            searchStarted: true, current: .loaded([issue("ABC-9")])
        )
        XCTAssertEqual(kept.issues.map(\.key), ["ABC-9"])
    }

    /// A previous failure is not kept — this refresh is a fresh attempt, so `loading` is true of it.
    func testARefreshRetriesAfterAFailure() {
        XCTAssertEqual(
            AppDelegate.todoBacklogAtRefresh(searchStarted: true, current: .failed).gap, .searching
        )
    }

    /// The TODO query was cleared in Preferences, so the rows a previous refresh delivered are
    /// dropped rather than lingering as candidates for a query that no longer exists.
    func testARefreshWithNoQueryConfiguredDropsPreviousRows() {
        let state = AppDelegate.todoBacklogAtRefresh(
            searchStarted: false, current: .loaded([issue("ABC-9")])
        )
        XCTAssertTrue(state.issues.isEmpty)
        XCTAssertNil(state.gap)
    }

    func testAFirstRefreshStartsLoading() {
        XCTAssertEqual(
            AppDelegate.todoBacklogAtRefresh(searchStarted: true, current: .unconfigured).gap,
            .searching
        )
    }

    // MARK: - What a completed search leaves behind

    func testASuccessfulSearchRecordsItsRows() {
        let state = AppDelegate.todoBacklogAfterFetch(
            rows: [issue("ABC-9")], searchFailed: false, current: .loading
        )
        XCTAssertEqual(state.issues.map(\.key), ["ABC-9"])
        XCTAssertNil(state.gap)
    }

    /// An answered-but-empty backlog is a real answer, and must not be reported as a gap.
    func testASuccessfulEmptySearchIsAnAnswerNotAGap() {
        XCTAssertNil(
            AppDelegate.todoBacklogAfterFetch(rows: [], searchFailed: false, current: .loading).gap
        )
    }

    /// The hole this closes: a failed search recorded as `loaded([])` reads as "the backlog is
    /// empty", and it also empties `backlogOnlyKeys`, silently returning that status to
    /// auto-checking every row.
    func testAFailedSearchIsNotAnEmptyBacklog() {
        let state = AppDelegate.todoBacklogAfterFetch(rows: [], searchFailed: true, current: .loading)
        XCTAssertEqual(state.gap, .unreachable)
    }

    /// Stale beats absent for a backlog rollup: a failure keeps whatever rows we had.
    func testAFailedSearchKeepsRowsWeAlreadyHad() {
        let state = AppDelegate.todoBacklogAfterFetch(
            rows: [], searchFailed: true, current: .loaded([issue("ABC-9")])
        )
        XCTAssertEqual(state.issues.map(\.key), ["ABC-9"])
        XCTAssertNil(state.gap)
    }

    func testLoadedCarriesItsRowsInOrder() {
        let state = TodoBacklogState.loaded([issue("ABC-9"), issue("ABC-10")])
        XCTAssertEqual(state.issues.map(\.key), ["ABC-9", "ABC-10"])
    }
}

