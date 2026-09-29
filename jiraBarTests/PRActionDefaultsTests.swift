import XCTest
@testable import jiraBar

/// What the "Approve linked open PRs" and "Sync Jira Assignee to PR" boxes start as, in the single and
/// bulk transition dialogs.
final class PRActionDefaultsTests: XCTestCase {

    private func linked(
        _ number: Int, assignees: [String], isMerged: Bool = false, statesKnown: Bool = true
    ) -> PRActionsStatus.LinkedPR {
        PRActionsStatus.LinkedPR(
            url: "https://github.com/org/repo/pull/\(number)", label: "org/repo #\(number)",
            isMerged: isMerged, viewerApproved: false, viewerRequestedChanges: false, isDraft: false,
            unresolvedThreads: 0, mergeStateStatus: nil, statesKnown: statesKnown, assignees: assignees,
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true
        )
    }

    private func jiraPR(_ number: Int, status: String = "OPEN", host: String = "github.com") -> JiraPullRequest {
        JiraPullRequest(
            id: "#\(number)", name: "ABC-1 change \(number)",
            url: "https://\(host)/org/repo/pull/\(number)", status: status, reviewers: nil
        )
    }

    private func ghStatus(assignees: [String], isMerged: Bool = false) -> GithubPRStatus {
        GithubPRStatus(
            reviewDecision: nil, unresolvedThreads: 0, totalThreads: 0, ciState: nil,
            isMerged: isMerged, mergedAt: nil, latestReleasePublishedAt: nil,
            defaultBranchCIState: nil, viewerLatestReviewState: nil, assignees: assignees,
            pendingReviewers: [], reviews: [],
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            headRefName: nil, isDraft: false
        )
    }

    // MARK: - Review box

    func testApproveAlwaysStartsUnchecked() {
        XCTAssertFalse(PRActionDefaults.reviewStartsChecked(.approve))
        XCTAssertFalse(PRActionDefaults.reviewStartsChecked(.none))
    }

    func testRequestChangesKeepsItsCheckedDefault() {
        XCTAssertTrue(PRActionDefaults.reviewStartsChecked(.requestChanges))
    }

    // MARK: - Sync box

    func testSyncStartsUncheckedWhenEveryPRIsAssigned() {
        XCTAssertFalse(PRActionDefaults.syncAssigneeStartsChecked(openPRsAssigned: [true, true]))
    }

    func testSyncKeepsCheckedDefaultWhenOnePRIsUnassigned() {
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRsAssigned: [true, false]))
    }

    /// Still loading, or GitHub failed for a PR: unknown is not "all assigned".
    func testSyncKeepsCheckedDefaultWhileAnyPRIsUnknown() {
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRsAssigned: [true, nil]))
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRsAssigned: []))
    }

    func testSingleDialogIgnoresMergedPRsAndTreatsFailedEnrichmentAsUnknown() {
        let prs = [
            linked(1, assignees: ["jdoe"]),
            linked(2, assignees: [], isMerged: true),
            linked(3, assignees: [], statesKnown: false),
        ]
        XCTAssertEqual(PRActionDefaults.openPRsAssigned(prs), [true, nil])
        XCTAssertEqual(PRActionDefaults.openPRsAssigned(Array(prs.prefix(2))), [true])
    }

    // MARK: - Bulk dialog

    /// Only PRs the batch would sync count: open in Jira, on GitHub, not merged on GitHub.
    func testBulkAssignmentCountsOnlyThePRsTheBatchActsOn() {
        let prs = [
            jiraPR(1), jiraPR(2), jiraPR(3, status: "MERGED"), jiraPR(4, host: "bitbucket.org"), jiraPR(5), jiraPR(6),
        ]
        let statusByURL = [
            prs[0].url: ghStatus(assignees: ["jdoe"]),
            prs[1].url: ghStatus(assignees: []),
            prs[4].url: ghStatus(assignees: [], isMerged: true),
        ]
        XCTAssertEqual(BulkMoveDialog.openPRsAssigned(prs: prs, statusByURL: statusByURL), [true, false, nil])
    }

    func testBulkTicketNotYetAnsweredForReadsAsUnknown() {
        let store = BulkPRLineStore()
        store.record([], assigned: [true], for: "ABC-1")
        store.record([], assigned: [], for: "ABC-2")
        XCTAssertFalse(PRActionDefaults.syncAssigneeStartsChecked(
            openPRsAssigned: store.openPRsAssigned(for: ["ABC-1", "ABC-2"])
        ))
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(
            openPRsAssigned: store.openPRsAssigned(for: ["ABC-1", "ABC-3"])
        ))
    }
}
