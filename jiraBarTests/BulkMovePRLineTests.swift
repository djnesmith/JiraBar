import XCTest
@testable import jiraBar

/// The PR line on a bulk-move row: `PR#43 open, PR#7 approved, PR#345 merged`, coloured as the
/// menu's PR rows are. The wording and colours come from `AppDelegate.prStateLabel`; what is tested
/// here is the shape of each segment and the one rule this line adds — approval replaces `open`.
final class BulkMovePRLineTests: XCTestCase {

    private func pr(_ number: Int, status: String, approvedInJira: Bool = false) -> JiraPullRequest {
        JiraPullRequest(
            id: "#\(number)",
            name: "ABC-1 change \(number)",
            url: "https://github.com/org/repo/pull/\(number)",
            status: status,
            reviewers: approvedInJira ? [JiraPRReviewer(name: "r", approved: true)] : nil
        )
    }

    private func ghStatus(
        reviewDecision: String? = nil, ciState: String? = nil, isDraft: Bool = false
    ) -> GithubPRStatus {
        GithubPRStatus(
            reviewDecision: reviewDecision, unresolvedThreads: 0, totalThreads: 0, ciState: ciState,
            isMerged: false, mergedAt: nil, latestReleasePublishedAt: nil,
            defaultBranchCIState: nil, viewerLatestReviewState: nil, assignees: [],
            pendingReviewers: [], reviews: [],
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            headRefName: nil, isDraft: isDraft
        )
    }

    /// The example the feature was asked for by, in the order the PRs arrive.
    func testSegmentsNameEachPRWithItsState() {
        let prs = [pr(43, status: "OPEN"), pr(7, status: "OPEN"), pr(345, status: "MERGED")]
        let segments = BulkMoveDialog.prLineSegments(
            prs: prs,
            statusByURL: [prs[1].url: ghStatus(reviewDecision: "APPROVED")]
        )
        XCTAssertEqual(segments.map(\.text), ["PR#43 open", "PR#7 approved", "PR#345 merged"])
    }

    func testColoursMatchTheMenuPalette() {
        let prs = [pr(1, status: "OPEN"), pr(2, status: "OPEN"), pr(3, status: "MERGED"), pr(4, status: "DECLINED")]
        let segments = BulkMoveDialog.prLineSegments(
            prs: prs,
            statusByURL: [prs[1].url: ghStatus(reviewDecision: "APPROVED")]
        )
        XCTAssertEqual(segments.map(\.colorHex), [
            AppDelegate.prStatusColorHex("OPEN"),
            AppDelegate.prApprovedColorHex,
            AppDelegate.prStatusColorHex("MERGED"),
            AppDelegate.prStatusColorHex("DECLINED"),
        ])
    }

    /// Jira's reviewer flags stand in for approval only when GitHub has not answered — the same
    /// precedence the menu row uses.
    func testJiraApprovalCountsOnlyWithoutGithubData() {
        let flagged = pr(5, status: "OPEN", approvedInJira: true)
        XCTAssertEqual(
            BulkMoveDialog.prLineSegments(prs: [flagged], statusByURL: [:]).map(\.text),
            ["PR#5 approved"]
        )
        XCTAssertEqual(
            BulkMoveDialog.prLineSegments(
                prs: [flagged], statusByURL: [flagged.url: ghStatus(reviewDecision: "REVIEW_REQUIRED")]
            ).map(\.text),
            ["PR#5 open"]
        )
    }

    /// A draft and a failed CI run keep the menu's word even when approved: the menu shows them
    /// that way, and a bulk row must not read better than the row it summarises.
    func testDraftAndCIFailureOutrankApproval() {
        let draft = pr(6, status: "OPEN")
        let failing = pr(7, status: "OPEN")
        let segments = BulkMoveDialog.prLineSegments(
            prs: [draft, failing],
            statusByURL: [
                draft.url: ghStatus(reviewDecision: "APPROVED", isDraft: true),
                failing.url: ghStatus(reviewDecision: "APPROVED", ciState: "FAILURE"),
            ]
        )
        XCTAssertEqual(segments.map(\.text), ["PR#6 draft", "PR#7 error"])
    }

    func testNoPRsMeansNoSegments() {
        XCTAssertEqual(BulkMoveDialog.prLineSegments(prs: [], statusByURL: [:]), [])
    }
}

/// Which candidates the dialog still has to fetch for at open.
final class BulkPRLineStoreTests: XCTestCase {

    private func issue(_ key: String) -> Issue {
        Issue(
            id: key, key: key,
            fields: Fields(
                summary: "", status: IssueStatus(name: "To Do"), issuetype: IssueType(name: "Task"),
                project: Project(name: "Example"), assignee: nil
            )
        )
    }

    /// A ticket the menu answered "no PRs" for is answered — re-asking on every open is the cost
    /// this store exists to avoid.
    func testRecordedEmptyLineCountsAsKnown() {
        let store = BulkPRLineStore()
        store.record([], for: "ABC-1")
        store.record([BulkPRLineSegment(text: "PR#1 open", colorHex: "#DAA520")], for: "ABC-2")
        let missing = store.issuesWithoutLine([issue("ABC-1"), issue("ABC-2"), issue("ABC-3")])
        XCTAssertEqual(missing.map(\.key), ["ABC-3"])
    }
}
