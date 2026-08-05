import XCTest
import AppKit
@testable import jiraBar

final class AppDelegateHelpersTests: XCTestCase {

    // MARK: - branchName

    func testBranchNameSlugsTitle() {
        XCTAssertEqual(
            AppDelegate.branchName(forKey: "PROJ-1234", title: "Fix flaky login!"),
            "PROJ-1234-fix-flaky-login"
        )
    }

    func testBranchNameCollapsesAndTrimsHyphens() {
        XCTAssertEqual(
            AppDelegate.branchName(forKey: "PROJ-1", title: "  [Spike] -- weird   title??  "),
            "PROJ-1-spike-weird-title"
        )
    }

    func testBranchNameCapsSlugLength() {
        let title = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 40)
        let name = AppDelegate.branchName(forKey: "PROJ-1", title: title, maxSlugLength: 50)
        XCTAssertEqual(name, "PROJ-1-" + String(repeating: "a", count: 40) + "-" + String(repeating: "b", count: 9))
    }

    func testBranchNameFallsBackToKeyWhenSlugEmpty() {
        XCTAssertEqual(AppDelegate.branchName(forKey: "PROJ-1", title: "!!!"), "PROJ-1")
    }

    // MARK: - prNumber / repoBaseURL

    func testPRNumber() {
        XCTAssertEqual(AppDelegate.prNumber(from: "https://github.com/o/r/pull/269"), "269")
        XCTAssertNil(AppDelegate.prNumber(from: "https://github.com/o/r"))
        XCTAssertNil(AppDelegate.prNumber(from: "https://github.com/o/r/pull/xyz"))
    }

    func testRepoBaseURL() {
        XCTAssertEqual(
            AppDelegate.repoBaseURL(from: "https://github.com/o/r/pull/269"),
            "https://github.com/o/r"
        )
        XCTAssertNil(AppDelegate.repoBaseURL(from: "https://github.com"))
    }

    // MARK: - targetURL

    func testTargetURLModifierRouting() {
        let pr = "https://github.com/o/r/pull/42"
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: []), pr)
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .command), "https://github.com/o/r/releases/new")
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .option), "https://github.com/o/r/actions")
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .control), "https://github.com/o/r")
    }

    func testTargetURLFallsBackToPRWhenUnparseable() {
        XCTAssertEqual(AppDelegate.targetURL(forPR: "garbage", modifiers: .command), "garbage")
    }

    // MARK: - containsIssueKey (PRs Without Tickets exclusion)

    func testContainsIssueKeyMatches() {
        XCTAssertTrue(AppDelegate.containsIssueKey("[ABC-123] fix the thing"))
        XCTAssertTrue(AppDelegate.containsIssueKey("ABC-123-fix-the-thing"))       // branch style
        XCTAssertTrue(AppDelegate.containsIssueKey("feature/AB2-9-short"))
    }

    func testContainsIssueKeyRejects() {
        XCTAssertFalse(AppDelegate.containsIssueKey("fix the thing"))
        XCTAssertFalse(AppDelegate.containsIssueKey("abc-123 lowercase is not a jira key"))
        XCTAssertFalse(AppDelegate.containsIssueKey("A-1 single-letter prefix"))
        XCTAssertFalse(AppDelegate.containsIssueKey("v1-2 version-ish"))
        XCTAssertFalse(AppDelegate.containsIssueKey(""))
    }

    // MARK: - prStateLabel (draft / CI-error precedence)

    private func ghStatus(ciState: String? = nil, isDraft: Bool = false) -> GithubPRStatus {
        GithubPRStatus(
            reviewDecision: nil, unresolvedThreads: 0, totalThreads: 0, ciState: ciState,
            isMerged: false, mergedAt: nil, latestReleasePublishedAt: nil,
            defaultBranchCIState: nil, viewerLatestReviewState: nil, assignees: [],
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            headRefName: nil, isDraft: isDraft
        )
    }

    func testPRStateLabelPlainOpen() {
        let state = AppDelegate.prStateLabel(status: "OPEN", ghStatus: ghStatus())
        XCTAssertEqual(state.text, "open")
        XCTAssertEqual(state.colorHex, "#DAA520")
    }

    func testPRStateLabelMarksDraft() {
        let state = AppDelegate.prStateLabel(status: "OPEN", ghStatus: ghStatus(isDraft: true))
        XCTAssertEqual(state.text, "draft")
        XCTAssertEqual(state.colorHex, "#DAA520")
    }

    func testPRStateLabelCIFailureOutranksDraft() {
        let state = AppDelegate.prStateLabel(status: "OPEN", ghStatus: ghStatus(ciState: "FAILURE", isDraft: true))
        XCTAssertEqual(state.text, "error")
        XCTAssertEqual(state.colorHex, "#CF222E")
    }

    /// Jira's dev-status can report DRAFT directly, with no GitHub enrichment available.
    func testPRStateLabelJiraReportedDraftWithoutEnrichment() {
        let state = AppDelegate.prStateLabel(status: "DRAFT", ghStatus: nil)
        XCTAssertEqual(state.text, "draft")
        XCTAssertEqual(state.colorHex, "#DAA520")
    }

    func testPRStateLabelMergedIgnoresDraftFlag() {
        let state = AppDelegate.prStateLabel(status: "MERGED", ghStatus: ghStatus(isDraft: true))
        XCTAssertEqual(state.text, "merged")
        XCTAssertEqual(state.colorHex, "#2DA44E")
    }

    // MARK: - prStatusColorHex

    func testPRStatusColors() {
        XCTAssertEqual(AppDelegate.prStatusColorHex("MERGED"), "#2DA44E")
        XCTAssertEqual(AppDelegate.prStatusColorHex("open"), "#DAA520")
        XCTAssertEqual(AppDelegate.prStatusColorHex("DECLINED"), "#CF222E")
        XCTAssertEqual(AppDelegate.prStatusColorHex("DRAFT"), "#DAA520")
        XCTAssertEqual(AppDelegate.prStatusColorHex("SOMETHING"), "#888888")
    }
}
