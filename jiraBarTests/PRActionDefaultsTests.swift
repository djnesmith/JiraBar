import XCTest
@testable import jiraBar

/// What the "Approve linked open PRs" and "Sync Jira Assignee to PR" boxes start as, in the single and
/// bulk transition dialogs.
final class PRActionDefaultsTests: XCTestCase {

    private typealias OpenPR = PRActionDefaults.OpenPR

    private func linked(
        _ number: Int, assignees: [String] = [], reviews: [PRReview]? = [],
        isMerged: Bool = false, statesKnown: Bool = true
    ) -> PRActionsStatus.LinkedPR {
        PRActionsStatus.LinkedPR(
            url: "https://github.com/org/repo/pull/\(number)", label: "org/repo #\(number)",
            isMerged: isMerged, viewerApproved: false, viewerRequestedChanges: false, isDraft: false,
            unresolvedThreads: 0, mergeStateStatus: nil, statesKnown: statesKnown, assignees: assignees,
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            reviews: reviews
        )
    }

    private func jiraPR(_ number: Int, status: String = "OPEN", host: String = "github.com") -> JiraPullRequest {
        JiraPullRequest(
            id: "#\(number)", name: "ABC-1 change \(number)",
            url: "https://\(host)/org/repo/pull/\(number)", status: status, reviewers: nil
        )
    }

    private func ghStatus(
        assignees: [String] = [], reviews: [PRReview]? = [], isMerged: Bool = false
    ) -> GithubPRStatus {
        GithubPRStatus(
            reviewDecision: nil, unresolvedThreads: 0, totalThreads: 0, ciState: nil,
            isMerged: isMerged, mergedAt: nil, latestReleasePublishedAt: nil,
            defaultBranchCIState: nil, viewerLatestReviewState: nil, assignees: assignees,
            pendingReviewers: [], reviews: reviews,
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            headRefName: nil, isDraft: false
        )
    }

    private let approval = [PRReview(login: "jdoe", state: "APPROVED")]

    // MARK: - Approved

    func testApprovedByAnyReviewer() {
        XCTAssertEqual(PRActionDefaults.approved([
            PRReview(login: "alice", state: "COMMENTED"), PRReview(login: "jdoe", state: "APPROVED"),
        ]), true)
        XCTAssertEqual(PRActionDefaults.approved([]), false)
        XCTAssertNil(PRActionDefaults.approved(nil))
    }

    func testChangesRequestedAfterAnApprovalFromTheSameReviewerIsNotApproved() {
        XCTAssertEqual(PRActionDefaults.approved([
            PRReview(login: "jdoe", state: "APPROVED"), PRReview(login: "jdoe", state: "CHANGES_REQUESTED"),
        ]), false)
        XCTAssertEqual(PRActionDefaults.approved([PRReview(login: "jdoe", state: "DISMISSED")]), false)
    }

    // MARK: - Review box

    func testApproveStartsUncheckedWhenEveryPRIsApproved() {
        let prs = [OpenPR(assigned: false, approved: true), OpenPR(assigned: nil, approved: true)]
        XCTAssertFalse(PRActionDefaults.reviewStartsChecked(.approve, openPRs: prs))
    }

    func testApproveStartsCheckedWhenOnePRIsNotApproved() {
        let prs = [OpenPR(assigned: true, approved: true), OpenPR(assigned: true, approved: false)]
        XCTAssertTrue(PRActionDefaults.reviewStartsChecked(.approve, openPRs: prs))
    }

    /// Still loading, GitHub failed, or no PRs: unknown is not "all approved".
    func testApproveStartsCheckedWhileAnyPRIsUnknown() {
        XCTAssertTrue(PRActionDefaults.reviewStartsChecked(.approve, openPRs: [OpenPR(assigned: true, approved: true), .unknown]))
        XCTAssertTrue(PRActionDefaults.reviewStartsChecked(.approve, openPRs: []))
    }

    func testRequestChangesStartsCheckedEvenWhenEveryPRIsApproved() {
        XCTAssertTrue(PRActionDefaults.reviewStartsChecked(.requestChanges, openPRs: [OpenPR(assigned: true, approved: true)]))
    }

    // MARK: - Sync box

    func testSyncStartsUncheckedWhenEveryPRIsAssigned() {
        let prs = [OpenPR(assigned: true, approved: false), OpenPR(assigned: true, approved: nil)]
        XCTAssertFalse(PRActionDefaults.syncAssigneeStartsChecked(openPRs: prs))
    }

    func testSyncStartsCheckedWhenOnePRIsUnassigned() {
        let prs = [OpenPR(assigned: true, approved: true), OpenPR(assigned: false, approved: true)]
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRs: prs))
    }

    func testSyncStartsCheckedWhileAnyPRIsUnknown() {
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRs: [OpenPR(assigned: true, approved: true), .unknown]))
        XCTAssertTrue(PRActionDefaults.syncAssigneeStartsChecked(openPRs: []))
    }

    // MARK: - Where the facts come from

    func testSingleDialogIgnoresMergedPRsAndTreatsFailedEnrichmentAsUnknown() {
        let prs = [
            linked(1, assignees: ["jdoe"], reviews: approval),
            linked(2, isMerged: true),
            linked(3, statesKnown: false),
            linked(4, reviews: nil),
        ]
        XCTAssertEqual(PRActionDefaults.openPRs(prs), [
            OpenPR(assigned: true, approved: true), .unknown, OpenPR(assigned: false, approved: nil),
        ])
    }

    /// Only PRs the batch would act on count: open in Jira, on GitHub, not merged on GitHub.
    func testBulkCountsOnlyThePRsTheBatchActsOn() {
        let prs = [
            jiraPR(1), jiraPR(2), jiraPR(3, status: "MERGED"), jiraPR(4, host: "bitbucket.org"), jiraPR(5), jiraPR(6),
        ]
        let statusByURL = [
            prs[0].url: ghStatus(assignees: ["jdoe"], reviews: approval),
            prs[1].url: ghStatus(),
            prs[4].url: ghStatus(isMerged: true),
        ]
        XCTAssertEqual(BulkMoveDialog.openPRs(prs: prs, statusByURL: statusByURL), [
            OpenPR(assigned: true, approved: true), OpenPR(assigned: false, approved: false), .unknown,
        ])
    }

    func testBulkTicketNotYetAnsweredForReadsAsUnknown() {
        let store = BulkPRLineStore()
        store.record([], openPRs: [OpenPR(assigned: true, approved: true)], for: "ABC-1")
        store.record([], openPRs: [], for: "ABC-2")
        XCTAssertEqual(store.openPRs(for: ["ABC-1", "ABC-2"]), [OpenPR(assigned: true, approved: true)])
        XCTAssertTrue(store.openPRs(for: ["ABC-1", "ABC-3"]).contains(.unknown))
    }
}
