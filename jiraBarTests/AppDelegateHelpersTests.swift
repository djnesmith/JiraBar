import XCTest
import Defaults
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
final class OwnershipSegmentsTests: XCTestCase {

    private func review(_ login: String, _ state: String) -> PRReview {
        PRReview(login: login, state: state)
    }

    /// The rendered line, as the menu joins it.
    private func line(_ segments: [[AppDelegate.OwnershipRun]]) -> String {
        segments.map { $0.map(\.text).joined() }.joined(separator: " · ")
    }

    private func colour(of text: String, in segments: [[AppDelegate.OwnershipRun]]) -> NSColor? {
        segments.flatMap { $0 }.first { $0.text == text }?.color
    }

    // MARK: - an absent read may not claim anything

    /// nil status means the GitHub read failed or there is no token. "unassigned" would be a claim.
    func testNilStatusRendersNoLineAtAll() {
        XCTAssertTrue(AppDelegate.ownershipSegments(status: nil).isEmpty)
    }

    /// A partial read must not turn into "no reviewers".
    func testAbsentReviewerConnectionsWithholdTheReviewerHalf() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["djnesmith"], pendingReviewers: nil, reviews: nil
        )
        XCTAssertEqual(line(segments), "assignee: djnesmith")
    }

    // MARK: - the rendered line

    /// Every segment is "label: name", so the line reads as one pattern rather than two.
    func testAssignedAndReviewedReadsAsOneLine() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["djnesmith"],
            pendingReviewers: ["alice"],
            reviews: [review("jgerman", "APPROVED")]
        )
        XCTAssertEqual(line(segments), "assignee: djnesmith · approved: jgerman · pending: alice")
    }

    /// Reviewers sharing a state are named once under it, as the assignee segment already does for two
    /// assignees.
    func testReviewersSharingAStateAreGrouped() {
        let segments = AppDelegate.ownershipSegments(
            assignees: [],
            pendingReviewers: ["bob"],
            reviews: [review("jgerman", "APPROVED"), review("alice", "APPROVED")]
        )
        XCTAssertEqual(line(segments), "unassigned · approved: jgerman, alice · pending: bob")
    }

    /// Groups keep the order their state was first seen in, so nothing reshuffles as reviews arrive.
    func testStateGroupsKeepFirstSeenOrder() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"],
            pendingReviewers: ["p"],
            reviews: [
                review("a", "CHANGES_REQUESTED"),
                review("b", "APPROVED"),
                review("c", "CHANGES_REQUESTED"),
                review("e", "COMMENTED"),
            ]
        )
        XCTAssertEqual(
            line(segments),
            "assignee: d · requested changes: a, c · approved: b · commented: e · pending: p"
        )
    }

    func testNobodyHomeIsSaidRatherThanOmitted() {
        XCTAssertEqual(
            line(AppDelegate.ownershipSegments(assignees: [], pendingReviewers: [], reviews: [])),
            "unassigned · no reviewers"
        )
    }

    func testSingleAndMultipleAssigneesAreLabelledDifferently() {
        XCTAssertEqual(
            line(AppDelegate.ownershipSegments(assignees: ["a"], pendingReviewers: [], reviews: [])),
            "assignee: a · no reviewers"
        )
        XCTAssertEqual(
            line(AppDelegate.ownershipSegments(assignees: ["a", "b"], pendingReviewers: [], reviews: [])),
            "assignees: a, b · no reviewers"
        )
    }

    func testEachReviewStateGetsItsOwnWording() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"],
            pendingReviewers: [],
            reviews: [review("a", "APPROVED"), review("b", "CHANGES_REQUESTED"), review("c", "COMMENTED")]
        )
        XCTAssertEqual(line(segments), "assignee: d · approved: a · requested changes: b · commented: c")
    }

    /// A dismissed review carries no signal, and a state GitHub adds later must not render raw.
    func testDismissedAndUnknownStatesAreDropped() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"],
            pendingReviewers: ["x"],
            reviews: [review("a", "DISMISSED"), review("b", "SOMETHING_NEW")]
        )
        XCTAssertEqual(line(segments), "assignee: d · pending: x")
    }

    /// Dropped states with nothing pending still has to say something about reviewers.
    func testAllStatesDroppedFallsBackToNoReviewers() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"], pendingReviewers: [], reviews: [review("a", "DISMISSED")]
        )
        XCTAssertEqual(line(segments), "assignee: d · no reviewers")
    }

    // MARK: - one colour per role, and adaptive

    func testAssigneeNameIsSystemGreenAndTheLabelIsNot() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["djnesmith"], pendingReviewers: [], reviews: []
        )
        XCTAssertEqual(colour(of: "djnesmith", in: segments), NSColor.systemGreen)
        XCTAssertEqual(colour(of: "assignee: ", in: segments), AppDelegate.ownershipMetadata)
    }

    func testReviewerNameIsSystemYellowWhetherTheyReviewedOrNot() {
        let segments = AppDelegate.ownershipSegments(
            assignees: [], pendingReviewers: ["alice"], reviews: [review("jgerman", "APPROVED")]
        )
        XCTAssertEqual(colour(of: "jgerman", in: segments), NSColor.systemYellow)
        XCTAssertEqual(colour(of: "alice", in: segments), NSColor.systemYellow)
    }

    /// Grouped names are one run, so the colour covers the whole list rather than only the first.
    func testGroupedNamesShareOneColouredRun() {
        let segments = AppDelegate.ownershipSegments(
            assignees: [], pendingReviewers: [], reviews: [review("a", "APPROVED"), review("b", "APPROVED")]
        )
        XCTAssertEqual(colour(of: "a, b", in: segments), NSColor.systemYellow)
    }

    func testReviewStateWordsStayMetadataGrey() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"],
            pendingReviewers: ["x"],
            reviews: [review("a", "APPROVED"), review("b", "CHANGES_REQUESTED")]
        )
        for word in ["approved: ", "requested changes: ", "pending: "] {
            XCTAssertEqual(colour(of: word, in: segments), AppDelegate.ownershipMetadata, word)
        }
    }

    /// Nobody-is-on-it keeps its amber, which is deliberately not the metadata grey and not a role colour.
    func testAbsenceIsAmberAndDistinctFromBothRoleColours() {
        let segments = AppDelegate.ownershipSegments(assignees: [], pendingReviewers: [], reviews: [])
        XCTAssertEqual(colour(of: "unassigned", in: segments), AppDelegate.ownershipAbsent)
        XCTAssertEqual(colour(of: "no reviewers", in: segments), AppDelegate.ownershipAbsent)
        XCTAssertNotEqual(AppDelegate.ownershipAbsent, AppDelegate.ownershipMetadata)
        XCTAssertNotEqual(AppDelegate.ownershipAbsent, NSColor.systemGreen)
        XCTAssertNotEqual(AppDelegate.ownershipAbsent, NSColor.systemYellow)
    }

    /// The role colours must actually resolve differently per appearance — that is the whole reason for
    /// using system colours over the hexes the rest of the row uses.
    func testRoleColoursResolveDifferentlyInLightAndDark() {
        let segments = AppDelegate.ownershipSegments(
            assignees: ["d"], pendingReviewers: ["x"], reviews: []
        )
        for name in ["d", "x"] {
            guard let color = colour(of: name, in: segments) else { return XCTFail("no colour for \(name)") }
            XCTAssertNotEqual(
                Self.srgb(color, .aqua), Self.srgb(color, .darkAqua),
                "\(name)'s colour is fixed and cannot adapt to a dark menu"
            )
        }
        // The amber is deliberately a fixed hex, so it is the control: same value in both.
        XCTAssertEqual(
            Self.srgb(AppDelegate.ownershipAbsent, .aqua),
            Self.srgb(AppDelegate.ownershipAbsent, .darkAqua)
        )
    }

    private static func srgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> [CGFloat] {
        var out: [CGFloat] = []
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let s = color.usingColorSpace(.sRGB) else { return }
            out = [s.redComponent, s.greenComponent, s.blueComponent]
        }
        return out
    }

    // MARK: - state wording

    /// A mapped state word colliding with the pending label would merge two groups into one. The grouping
    /// merges by word, so this is a safety net rather than the only defence.
    func testNoMappedStateWordCollidesWithThePendingLabel() {
        for state in ["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"] {
            XCTAssertNotEqual(AppDelegate.reviewStateWord(state), AppDelegate.pendingStateWord, state)
        }
    }

    func testReviewStateWordCoversTheStatesWorthShowing() {
        XCTAssertEqual(AppDelegate.reviewStateWord("APPROVED"), "approved")
        XCTAssertEqual(AppDelegate.reviewStateWord("changes_requested"), "requested changes")
        XCTAssertEqual(AppDelegate.reviewStateWord("COMMENTED"), "commented")
        XCTAssertNil(AppDelegate.reviewStateWord("DISMISSED"))
        XCTAssertNil(AppDelegate.reviewStateWord("PENDING"))
        XCTAssertNil(AppDelegate.reviewStateWord(""))
    }
}

/// Whether the Recently Closed section runs at all. Empty means absent, not unfiltered — a query that
/// matched every closed ticket in the instance would be worse than no section.
final class ConfiguredQueryTests: XCTestCase {

    /// Both the TODO and Recently Closed sections gate on this: blank means the section is absent, not
    /// that it runs unfiltered. Recently Closed ships with a default, so blank there is a deliberate
    /// switch-off.
    func testBlankIsOff() {
        XCTAssertNil(AppDelegate.configuredQuery(""))
        XCTAssertNil(AppDelegate.configuredQuery("  \n\t "))
    }

    /// Trimmed, never rewritten — the user's ORDER BY is what sets the chronology, so nothing may append
    /// to or reorder it.
    func testAQueryIsTrimmedAndOtherwiseUntouched() {
        let query = "assignee = currentUser() AND statusCategory = Done ORDER BY statusCategoryChangedDate DESC"
        XCTAssertEqual(AppDelegate.configuredQuery("  " + query + "  "), query)
    }
}

/// The shipped default for the Recently Closed section. Verified against a live instance, so it is worth
/// pinning against a well-meaning edit.
final class RecentlyClosedDefaultTests: XCTestCase {

    private var shipped: String { Defaults.Keys.recentlyClosedJQL.defaultValue }

    /// The section works without configuration, so it must not default to blank.
    func testTheSectionIsOnByDefault() {
        XCTAssertNotNil(AppDelegate.configuredQuery(shipped))
    }

    /// resolutiondate is unpopulated in workflows that don't set a resolution, and NULLs sort first under
    /// DESC — which put three ancient tickets at the top of a ten-row list on a real instance.
    func testItOrdersByStatusCategoryChangedDateNotResolutiondate() {
        XCTAssertTrue(shipped.contains("ORDER BY statusCategoryChangedDate DESC"), shipped)
        XCTAssertFalse(shipped.lowercased().contains("resolutiondate"), shipped)
    }

    /// statusCategory over named statuses: a workflow's closed-ish statuses are not only "Done".
    func testItMatchesOnStatusCategory() {
        XCTAssertTrue(shipped.contains("statusCategory = Done"), shipped)
    }

    /// This repo is generic — no instance's project keys or field ids belong in a shipped default.
    func testTheDefaultCarriesNoInstanceSpecificScope() {
        XCTAssertFalse(shipped.contains("project in"), shipped)
        XCTAssertFalse(shipped.contains("customfield_"), shipped)
    }
}

/// The status element on Recently Closed rows. Reads the user's own statusDisplay mapping — no second
/// palette, and no colour invented for a status they never configured.
final class StatusElementColorTests: XCTestCase {

    private var displays: [StatusDisplay] {
        [
            StatusDisplay(name: "Done", colorHex: "#00FF00"),
            StatusDisplay(name: "Ready for Release", colorHex: "#2234FF"),
        ]
    }

    func testItUsesTheConfiguredColour() {
        XCTAssertEqual(
            AppDelegate.statusElementColor(status: "Done", displays: displays),
            NSColor(hex: "#00FF00")
        )
        XCTAssertEqual(
            AppDelegate.statusElementColor(status: "Ready for Release", displays: displays),
            NSColor(hex: "#2234FF")
        )
    }

    /// Matching is case-insensitive, like every other status comparison in the app.
    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(
            AppDelegate.statusElementColor(status: "done", displays: displays),
            NSColor(hex: "#00FF00")
        )
    }

    /// An unmapped status still renders, in the metadata grey. Dropping it would lose information and
    /// picking a colour would claim a mapping that does not exist.
    func testAnUnmappedStatusFallsBackToMetadataGrey() {
        XCTAssertEqual(
            AppDelegate.statusElementColor(status: "Done - Release Not Required", displays: displays),
            AppDelegate.ownershipMetadata
        )
        XCTAssertEqual(
            AppDelegate.statusElementColor(status: "Anything", displays: []),
            AppDelegate.ownershipMetadata
        )
    }
}

/// The Recently Approved search: `reviewed-by` plus a client-side approval filter, because GitHub has no
/// qualifier for "the viewer approved it".
final class RecentlyApprovedQueryTests: XCTestCase {

    func testQueryScopesToTheOrgsAndSortsByUpdatedDescending() {
        let q = GithubClient.recentlyApprovedQuery(orgs: ["Tradeswell"])
        XCTAssertTrue(q.contains("is:pr"), q)
        XCTAssertTrue(q.contains("reviewed-by:@me"), q)
        XCTAssertTrue(q.contains("org:Tradeswell"), q)
        // updated, not created or merged: they diverge on a PR approved days ago and pushed to today.
        XCTAssertTrue(q.contains("sort:updated-desc"), q)
        XCTAssertFalse(q.contains("is:open"), "merged PRs are the point here: " + q)
    }

    func testSeveralOrgsAndBlanksDropped() {
        let q = GithubClient.recentlyApprovedQuery(orgs: [" Tradeswell ", "", "acme"])
        XCTAssertTrue(q.contains("org:Tradeswell"), q)
        XCTAssertTrue(q.contains("org:acme"), q)
    }

    // MARK: - the approval filter

    private func pr(_ url: String) -> JiraPullRequest {
        JiraPullRequest(id: "#1", name: "t", url: url, status: "MERGED", reviewers: nil)
    }
    private func status(_ state: String?) -> GithubPRStatus {
        GithubPRStatus(
            reviewDecision: nil, unresolvedThreads: 0, totalThreads: 0, ciState: nil, isMerged: true,
            mergedAt: nil, latestReleasePublishedAt: nil, defaultBranchCIState: nil,
            viewerLatestReviewState: state, assignees: [], pendingReviewers: [], reviews: [],
            mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true,
            headRefName: nil, mergeStateStatus: nil, isDraft: false
        )
    }

    /// reviewed-by includes reviews that are not approvals. Measured against the real org, one PR in
    /// fourteen was COMMENTED — data-service-amazon-dsp#13.
    func testOnlyPRsWhoseLatestViewerReviewIsAnApprovalSurvive() {
        let approved = pr("https://github.com/o/r/pull/1")
        let commented = pr("https://github.com/o/r/pull/2")
        let changesRequested = pr("https://github.com/o/r/pull/3")
        let kept = GithubClient.approvedByViewer(
            [approved, commented, changesRequested],
            statusByURL: [
                approved.url: status("APPROVED"),
                commented.url: status("COMMENTED"),
                changesRequested.url: status("CHANGES_REQUESTED"),
            ]
        )
        XCTAssertEqual(kept.map(\.url), [approved.url])
    }

    /// A PR whose enrichment failed has no review state, and unknown is not an approval.
    func testUnknownReviewStateIsNotAnApproval() {
        let unknown = pr("https://github.com/o/r/pull/9")
        XCTAssertTrue(GithubClient.approvedByViewer([unknown], statusByURL: [:]).isEmpty)
        XCTAssertTrue(
            GithubClient.approvedByViewer([unknown], statusByURL: [unknown.url: status(nil)]).isEmpty
        )
    }

    func testOrderIsPreserved() {
        let a = pr("https://github.com/o/r/pull/1")
        let b = pr("https://github.com/o/r/pull/2")
        let kept = GithubClient.approvedByViewer(
            [b, a], statusByURL: [a.url: status("APPROVED"), b.url: status("APPROVED")]
        )
        XCTAssertEqual(kept.map(\.url), [b.url, a.url], "search order is the updated-desc order")
    }

    // MARK: - search hits carry their real state

    func testMergedClosedAndOpenHitsAreDistinguished() {
        XCTAssertEqual(GithubClient.searchHitAsPR([
            "html_url": "u", "number": 1, "title": "t", "state": "closed",
            "pull_request": ["merged_at": "2026-08-12T00:00:00Z"],
        ])?.status, "MERGED")
        XCTAssertEqual(GithubClient.searchHitAsPR([
            "html_url": "u", "number": 1, "title": "t", "state": "closed", "pull_request": [String: Any](),
        ])?.status, "DECLINED")
        XCTAssertEqual(GithubClient.searchHitAsPR([
            "html_url": "u", "number": 1, "title": "t", "state": "open",
        ])?.status, "OPEN")
    }

    func testAHitMissingItsEssentialsIsSkipped() {
        XCTAssertNil(GithubClient.searchHitAsPR(["number": 1, "title": "t"]))
    }
}
