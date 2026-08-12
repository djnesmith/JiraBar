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
            pendingReviewers: [], reviews: [],
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

final class AssigneeSegmentTests: XCTestCase {

    private let grey = NSColor(hex: "#888888")

    func testUnassignedReadsUnassignedAndStaysGrey() {
        for highlight in [true, false] {
            let segment = AppDelegate.assigneeSegment(displayName: nil, highlightAssigned: highlight)
            XCTAssertEqual(segment.text, "Unassigned")
            XCTAssertEqual(segment.color, grey, "unassigned is never green, in either section")
        }
    }

    func testAssignedGoesGreenOnlyWhenHighlightIsOn() {
        let todo = AppDelegate.assigneeSegment(displayName: "Alice Example", highlightAssigned: true)
        XCTAssertEqual(todo.text, "Alice Example")
        XCTAssertEqual(todo.color, NSColor.systemGreen)

        let main = AppDelegate.assigneeSegment(displayName: "Alice Example", highlightAssigned: false)
        XCTAssertEqual(main.text, "Alice Example")
        XCTAssertEqual(main.color, grey, "the status-grouped rows are all the user's own tickets")
    }
}

/// The label a user-field shortcut shows once its value is known. The defect risk here is not the string
/// swap — it is that a FAILED read must not claim the field is empty.
final class UserFieldMenuLabelTests: XCTestCase {

    private func user(_ name: String) -> JiraUser { JiraUser(displayName: name) }

    // MARK: - unknown is not empty

    /// nil means the field read failed. Offering to "Add" would tell him nobody is on a ticket that may
    /// well have someone, and he would act on it.
    func testFailedReadKeepsTheConfiguredLabel() {
        XCTAssertEqual(
            AppDelegate.userFieldMenuLabel(configured: "Change Tester", users: nil),
            "Change Tester"
        )
    }

    func testSuccessfulEmptyReadOffersToAdd() {
        XCTAssertEqual(
            AppDelegate.userFieldMenuLabel(configured: "Change Tester", users: []),
            "Add Tester"
        )
    }

    func testPopulatedFieldKeepsTheConfiguredLabel() {
        XCTAssertEqual(
            AppDelegate.userFieldMenuLabel(configured: "Change Tester", users: [user("Alice Example")]),
            "Change Tester"
        )
    }

    // MARK: - deriving the "Add" form

    func testChangePrefixIsSwapped() {
        XCTAssertEqual(AppDelegate.addFormLabel("Change Tester"), "Add Tester")
        XCTAssertEqual(AppDelegate.addFormLabel("Change Assignee"), "Add Assignee")
        XCTAssertEqual(AppDelegate.addFormLabel("Change Reviewer"), "Add Reviewer")
    }

    /// Matching is case-insensitive, but the rest of the label keeps the case the user typed.
    func testPrefixMatchIsCaseInsensitiveAndPreservesTheRemainder() {
        XCTAssertEqual(AppDelegate.addFormLabel("change tester"), "Add tester")
        XCTAssertEqual(AppDelegate.addFormLabel("CHANGE Tester"), "Add Tester")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(AppDelegate.addFormLabel("  Change Tester  "), "Add Tester")
    }

    /// Labels are free text, so anything that isn't the prefix is left exactly as configured.
    func testLabelsWithoutThePrefixAreUntouched() {
        XCTAssertEqual(AppDelegate.addFormLabel("Reviewers"), "Reviewers")
        XCTAssertEqual(AppDelegate.addFormLabel("Changes"), "Changes", "no space — not the prefix")
        XCTAssertEqual(AppDelegate.addFormLabel("Exchange Tester"), "Exchange Tester")
        XCTAssertEqual(AppDelegate.addFormLabel(""), "")
    }

    /// "Change " with nothing after it would otherwise become a bare "Add ".
    func testPrefixWithNothingFollowingIsUntouched() {
        XCTAssertEqual(AppDelegate.addFormLabel("Change "), "Change ")
        XCTAssertEqual(AppDelegate.addFormLabel("Change"), "Change")
    }

    /// An unprefixed label still renders unchanged on an empty field — no invented wording.
    func testEmptyFieldWithAnUnprefixedLabelIsUnchanged() {
        XCTAssertEqual(AppDelegate.userFieldMenuLabel(configured: "Reviewers", users: []), "Reviewers")
    }
}

/// The ownership line on a "PRs Without Tickets" row — the one section with no ticket context, so the
/// only place "who owns this?" is unanswerable from the menu.
final class OwnershipPiecesTests: XCTestCase {

    private func review(_ login: String, _ state: String) -> PRReview {
        PRReview(login: login, state: state)
    }

    private func text(_ pieces: [(String, String)]) -> [String] { pieces.map(\.0) }

    // MARK: - an absent read may not claim anything

    /// nil status means the GitHub read failed or there is no token. "unassigned" would be a claim.
    func testNilStatusRendersNoLineAtAll() {
        XCTAssertTrue(AppDelegate.ownershipPieces(status: nil).isEmpty)
    }

    /// The reviewer half is withheld when the connections were missing from the response — a partial
    /// read must not turn into "no reviewers".
    func testAbsentReviewerConnectionsWithholdTheReviewerHalf() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["djnesmith"], pendingReviewers: nil, reviews: nil
        )
        XCTAssertEqual(text(pieces), ["assignee: djnesmith"], "no reviewer claim either way")
    }

    // MARK: - nobody home must be said, not omitted

    /// A blank reads as "didn't load". Only a successful read reaches this function, so it can assert.
    func testNoAssigneeSaysUnassigned() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: [], pendingReviewers: ["jgerman"], reviews: []
        )
        XCTAssertEqual(text(pieces).first, "unassigned")
    }

    func testNoReviewersSaysSo() {
        let pieces = AppDelegate.ownershipPieces(assignees: ["djnesmith"], pendingReviewers: [], reviews: [])
        XCTAssertEqual(text(pieces), ["assignee: djnesmith", "no reviewers"])
    }

    func testSingleAndMultipleAssigneesAreLabelledDifferently() {
        XCTAssertEqual(
            text(AppDelegate.ownershipPieces(assignees: ["a"], pendingReviewers: ["x"], reviews: [])).first,
            "assignee: a"
        )
        XCTAssertEqual(
            text(AppDelegate.ownershipPieces(assignees: ["a", "b"], pendingReviewers: ["x"], reviews: [])).first,
            "assignees: a, b"
        )
    }

    // MARK: - reviewed and merely-asked are different facts

    func testCompletedReviewsAndPendingRequestsBothAppear() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["djnesmith"],
            pendingReviewers: ["alice"],
            reviews: [review("jgerman", "APPROVED")]
        )
        XCTAssertEqual(text(pieces), ["assignee: djnesmith", "jgerman approved", "alice pending"])
    }

    func testEachReviewStateGetsItsOwnWording() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["d"],
            pendingReviewers: [],
            reviews: [
                review("a", "APPROVED"),
                review("b", "CHANGES_REQUESTED"),
                review("c", "COMMENTED"),
            ]
        )
        XCTAssertEqual(
            text(pieces),
            ["assignee: d", "a approved", "b requested changes", "c commented"]
        )
    }

    /// A dismissed review carries no signal, and an unknown future state must not render raw.
    func testDismissedAndUnknownStatesAreDropped() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["d"],
            pendingReviewers: ["x"],
            reviews: [review("a", "DISMISSED"), review("b", "SOMETHING_NEW")]
        )
        XCTAssertEqual(text(pieces), ["assignee: d", "x pending"])
    }

    /// Only dropped states plus no pending requests still has to say something about reviewers.
    func testAllStatesDroppedFallsBackToNoReviewers() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["d"], pendingReviewers: [], reviews: [review("a", "DISMISSED")]
        )
        XCTAssertEqual(text(pieces).last, "no reviewers", "a dismissed-only PR is not silently reviewer-less")
    }

    // MARK: - colours come from the existing palette

    func testAllEmptySaysBothThings() {
        XCTAssertEqual(
            text(AppDelegate.ownershipPieces(assignees: [], pendingReviewers: [], reviews: [])),
            ["unassigned", "no reviewers"]
        )
    }

    func testReviewStateColoursAreTheSameHexesLine3Uses() {
        let pieces = AppDelegate.ownershipPieces(
            assignees: ["d"],
            pendingReviewers: ["x"],
            reviews: [review("a", "APPROVED"), review("b", "CHANGES_REQUESTED")]
        )
        let byText = Dictionary(uniqueKeysWithValues: pieces.map { ($0.0, $0.1) })
        XCTAssertEqual(byText["a approved"], "#2DA44E")
        XCTAssertEqual(byText["b requested changes"], "#CF222E")
        XCTAssertEqual(byText["x pending"], "#888888")
        XCTAssertEqual(byText["assignee: d"], "#888888")
    }
}
