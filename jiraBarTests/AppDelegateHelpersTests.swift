import XCTest
import Defaults
import AppKit
import SwiftUI
@testable import jiraBar

/// Every run of `coloringIssueKeys` output paired with the colour it carries.
private func colorRuns(_ text: String, truncatedTo length: Int? = nil) -> [(String, NSColor?)] {
    let attributed = AppDelegate.coloringIssueKeys(
        text, base: AppDelegate.ownershipMetadata, truncatedTo: length
    )
    var out: [(String, NSColor?)] = []
    attributed.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
        out.append(((attributed.string as NSString).substring(with: range), value as? NSColor))
    }
    return out
}

/// Just the substrings painted in the issue-key colour.
private func coloredKeyRuns(_ text: String, truncatedTo length: Int? = nil) -> [String] {
    colorRuns(text, truncatedTo: length).filter { $0.1 == AppDelegate.issueKeyColor }.map(\.0)
}

/// A colour's sRGB components as resolved under one appearance. Empty when it cannot be converted,
/// which callers must treat as a failure rather than indexing into.
private func srgbComponents(_ color: NSColor, _ appearance: NSAppearance.Name) -> [CGFloat] {
    var out: [CGFloat] = []
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        guard let s = color.usingColorSpace(.sRGB) else { return }
        out = [s.redComponent, s.greenComponent, s.blueComponent]
    }
    return out
}

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
                srgbComponents(color, .aqua), srgbComponents(color, .darkAqua),
                "\(name)'s colour is fixed and cannot adapt to a dark menu"
            )
        }
        // The amber is deliberately a fixed hex, so it is the control: same value in both.
        XCTAssertEqual(
            srgbComponents(AppDelegate.ownershipAbsent, .aqua),
            srgbComponents(AppDelegate.ownershipAbsent, .darkAqua)
        )
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

/// Issue keys render blue wherever a key appears. See `AppDelegate.coloringIssueKeys` for why matching
/// runs before truncation and why the colour is `linkColor`.
final class IssueKeyColoringTests: XCTestCase {

    /// These cover the unconfigured install, where every project's keys colour. The project filter has
    /// its own class. Pinned rather than assumed: the setting is real `Defaults`, so on a machine that
    /// has a filter configured these would otherwise read it and fail.
    private var savedSetting = ""

    override func setUp() {
        super.setUp()
        savedSetting = Defaults[.highlightedProjectKeys]
        Defaults[.highlightedProjectKeys] = ""
    }

    override func tearDown() {
        Defaults[.highlightedProjectKeys] = savedSetting
        super.tearDown()
    }

    private func runs(_ text: String, truncatedTo length: Int? = nil) -> [(String, NSColor?)] {
        colorRuns(text, truncatedTo: length)
    }

    private func keyRuns(_ text: String, truncatedTo length: Int? = nil) -> [String] {
        coloredKeyRuns(text, truncatedTo: length)
    }

    // MARK: - which text gets colored

    /// Any number of digits, which is what was asked for.
    func testKeysOfAnyDigitLengthAreColored() {
        for key in ["ABC-1", "ABC-42", "ABC-1717", "ABC-12345"] {
            XCTAssertEqual(keyRuns("[\(key)] a title"), [key], key)
        }
    }

    /// The key is colored and the punctuation around it is not, which is what makes it read as a key
    /// rather than a highlighted phrase.
    func testOnlyTheKeyIsColoredNotItsBrackets() {
        let segments = runs("[ABC-1697] rewrite the parser")
        XCTAssertEqual(segments.first?.0, "[")
        XCTAssertEqual(segments.first?.1, AppDelegate.ownershipMetadata)
        XCTAssertEqual(keyRuns("[ABC-1697] rewrite the parser"), ["ABC-1697"])
    }

    func testSeveralKeysInOneTitleAreAllColored() {
        XCTAssertEqual(keyRuns("ABC-1 and PROJ-22 together"), ["ABC-1", "PROJ-22"])
    }

    /// With nothing configured the generic pattern applies, so every project's keys color.
    func testAnyProjectKeyColorsWhenNoFilterIsSet() {
        XCTAssertEqual(keyRuns("[ZZ9-3384] something"), ["ZZ9-3384"])
    }

    func testTextWithNoKeyIsLeftEntirelyInTheBaseColor() {
        let segments = runs("no key in this title")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.1, AppDelegate.ownershipMetadata)
    }

    func testLowercaseIsNotAKey() {
        XCTAssertTrue(keyRuns("abc-1717 lowercase").isEmpty)
    }

    // MARK: - truncation

    func testAKeySlicedByTheCutIsNotColored() {
        // 35 leading characters put ABC-1717 across the 50-char cut, leaving the stump "ABC-171".
        let title = String(repeating: "a", count: 35) + " revert ABC-1717 rollout"
        XCTAssertEqual(keyRuns(title), ["ABC-1717"], "untruncated, the whole key colors")

        let cut = runs(title, truncatedTo: 50)
        XCTAssertTrue(cut.map(\.0).joined().hasSuffix("ABC-171…"), "the stump is what's on screen")
        XCTAssertTrue(keyRuns(title, truncatedTo: 50).isEmpty, "and none of it is colored as a key")
    }

    /// One character shorter and the key ends exactly on the cut — it is whole, so it colors. This is
    /// the off-by-one the survivor test above would not catch on its own.
    func testAKeyEndingExactlyOnTheCutSurvives() {
        let title = String(repeating: "a", count: 34) + " revert ABC-1717 rollout"
        XCTAssertEqual(keyRuns(title, truncatedTo: 50), ["ABC-1717"])
    }

    func testAKeyThatSurvivesTheCutIntactStaysColored() {
        let title = "[ABC-1717] a title long enough to be cut somewhere after the key"
        XCTAssertEqual(keyRuns(title, truncatedTo: 50), ["ABC-1717"])
    }

    /// The cut counts characters but the match offsets are UTF-16, so a title with astral-plane
    /// characters is where the two disagree. Swapping the length check to `body.count` passes every
    /// other test here and fails this one.
    func testTheCutIsMeasuredConsistentlyWithTheMatchOffsets() {
        let title = "🎉🎉🎉🎉 ABC-1717 x"
        XCTAssertEqual(keyRuns(title, truncatedTo: 13), ["ABC-1717"], "key ends exactly on the cut")
        XCTAssertTrue(keyRuns(title, truncatedTo: 11).isEmpty, "key crosses the cut")
    }

    func testTextShorterThanTheCutIsNotEllipsised() {
        XCTAssertEqual(runs("[ABC-1] short", truncatedTo: 50).map(\.0).joined(), "[ABC-1] short")
    }

    func testWithoutALengthNothingIsCut() {
        XCTAssertEqual(runs("ABC-1717").map(\.0).joined(), "ABC-1717")
        XCTAssertEqual(keyRuns("ABC-1717"), ["ABC-1717"])
    }

    func testEmptyTextIsHandled() {
        XCTAssertEqual(runs("", truncatedTo: 50).map(\.0).joined(), "")
    }

    // MARK: - the SwiftUI dialogs

    private func attributedKeyRuns(_ text: String) -> [String] {
        let attributed = AppDelegate.attributedColoringIssueKeys(text)
        return attributed.runs
            .filter { $0.foregroundColor == Color.issueKey }
            .map { String(attributed[$0.range].characters) }
    }

    func testTheDialogColorerPicksOutTheSameKeys() {
        XCTAssertEqual(attributedKeyRuns("Transitioning 2 of 5: ABC-1717"), ["ABC-1717"])
        XCTAssertEqual(attributedKeyRuns("follow-up to ABC-1 and PROJ-22"), ["ABC-1", "PROJ-22"])
        XCTAssertTrue(attributedKeyRuns("no key here").isEmpty)
        XCTAssertTrue(attributedKeyRuns("").isEmpty)
    }

    /// The text has to survive intact — a colourer that drops or reorders the runs between matches
    /// would still pass the assertions above.
    func testTheDialogColorerPreservesTheWholeString() {
        for text in ["Transitioning 2 of 5: ABC-1717", "ABC-1 leading", "trailing ABC-1", "", "none"] {
            XCTAssertEqual(String(AppDelegate.attributedColoringIssueKeys(text).characters), text, text)
        }
    }

    /// Only the key is coloured; the surrounding text carries no colour of its own, so the dialog's
    /// own styling still applies to it.
    func testTheDialogColorerLeavesOtherRunsUnstyled() {
        let attributed = AppDelegate.attributedColoringIssueKeys("done ABC-1 ok")
        let uncolored = attributed.runs.filter { $0.foregroundColor == nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(uncolored, ["done ", " ok"])
    }

    // MARK: - the color itself

    /// Blue is the actual request, so pin blueness rather than the identity of the constant — every
    /// other test here still passes if the colour is changed to pink.
    func testTheKeyColorIsBlueInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rgb = srgbComponents(AppDelegate.issueKeyColor, appearance)
            guard rgb.count == 3 else { return XCTFail("\(appearance.rawValue) did not resolve") }
            XCTAssertGreaterThan(rgb[2], rgb[0], "blue over red in \(appearance.rawValue)")
            XCTAssertGreaterThan(rgb[2], rgb[1], "blue over green in \(appearance.rawValue)")
        }
    }

    func testTheKeyColorAdaptsToTheAppearance() {
        XCTAssertNotEqual(
            srgbComponents(AppDelegate.issueKeyColor, .aqua),
            srgbComponents(AppDelegate.issueKeyColor, .darkAqua),
            "a key colour that cannot adapt would be a fixed sRGB value"
        )
    }

    /// It has to be distinguishable from the grey it replaces, or the change accomplishes nothing.
    func testItIsNotTheMetadataGrey() {
        XCTAssertNotEqual(AppDelegate.issueKeyColor, AppDelegate.ownershipMetadata)
    }

    /// The SwiftUI dialogs colour through `Color.issueKey`. It has to be the same blue as the menu's,
    /// which is only guaranteed while it is derived from the one constant rather than restated.
    func testTheDialogColorIsTheSameBlueAsTheMenus() {
        XCTAssertEqual(NSColor(Color.issueKey), AppDelegate.issueKeyColor)
    }

    /// Bridging through `Color` must not resolve the dynamic colour to a single value on the way, which
    /// would freeze the dialogs at whichever appearance was current when the constant was first touched.
    func testTheDialogColorStillAdaptsAfterBridging() {
        XCTAssertNotEqual(
            srgbComponents(NSColor(Color.issueKey), .aqua),
            srgbComponents(NSColor(Color.issueKey), .darkAqua)
        )
    }
}

/// The project filter — which keys turn blue. Colouring only: `containsIssueKey`, and so which PRs
/// count as tied to a ticket, deliberately stays on the generic pattern whatever this is set to.
///
/// A generic key stands in for a real project throughout. The behaviour is identical and the repo is
/// open source, so no one's actual project keys belong in it.
final class HighlightedProjectFilterTests: XCTestCase {

    private var savedSetting = ""

    override func setUp() {
        super.setUp()
        savedSetting = Defaults[.highlightedProjectKeys]
    }

    override func tearDown() {
        Defaults[.highlightedProjectKeys] = savedSetting
        super.tearDown()
    }

    private func keyRuns(_ text: String) -> [String] { coloredKeyRuns(text) }

    // MARK: - parsing the setting

    func testTheSettingIsSplitTrimmedAndCompacted() {
        XCTAssertEqual(AppDelegate.highlightedProjects(from: "ABC, XY2"), ["ABC", "XY2"])
        XCTAssertEqual(AppDelegate.highlightedProjects(from: "  ABC  "), ["ABC"])
        XCTAssertEqual(AppDelegate.highlightedProjects(from: "ABC,,XY2"), ["ABC", "XY2"])
        XCTAssertEqual(AppDelegate.highlightedProjects(from: " , , "), [])
        XCTAssertEqual(AppDelegate.highlightedProjects(from: ""), [])
    }

    // MARK: - what the configured project matches

    func testTheProjectMatchesInAnyCase() {
        Defaults[.highlightedProjectKeys] = "ABC"
        for key in ["ABC-1717", "abc-1717", "Abc-1717", "aBc-1717"] {
            XCTAssertEqual(keyRuns("[\(key)] a title"), [key], key)
        }
    }

    /// Configuring it in lowercase has to work the same — the match is on the project, not on how the
    /// user happened to type the setting.
    func testTheSettingItselfIsCaseInsensitive() {
        Defaults[.highlightedProjectKeys] = "abc"
        XCTAssertEqual(keyRuns("[ABC-1717] a title"), ["ABC-1717"])
    }

    func testTheSuffixMayBeLettersDigitsOrBoth() {
        Defaults[.highlightedProjectKeys] = "ABC"
        for key in ["ABC-1717", "ABC-XYZ", "ABC-XDFD2453", "ABC-abc123", "ABC-7"] {
            XCTAssertEqual(keyRuns("see \(key) here"), [key], key)
        }
    }

    func testSeveralConfiguredProjectsAllColor() {
        Defaults[.highlightedProjectKeys] = "ABC, XY2"
        XCTAssertEqual(keyRuns("ABC-1 and XY2-22 together"), ["ABC-1", "XY2-22"])
    }

    // MARK: - what it must no longer color

    /// The behaviour this change removes: before the filter, every project's keys were blue.
    func testOtherProjectsAreNoLongerColored() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertTrue(keyRuns("[OTH-201] nope").isEmpty)
        XCTAssertTrue(keyRuns("[ZZ9-3384] nope").isEmpty)
        XCTAssertTrue(keyRuns("ABCD-1 is a different project").isEmpty)
    }

    /// A second dash kills the whole match rather than shortening it. Without the lookahead this
    /// colours "ABC-dfs", because there is a word boundary between "s" and "-".
    func testASecondDashKillsTheMatchRatherThanShorteningIt() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertTrue(keyRuns("ABC-dfs-3js").isEmpty)
        XCTAssertTrue(keyRuns("abc-service-vendor").isEmpty)
        XCTAssertTrue(keyRuns("feature/ABC-1717-do-the-thing").isEmpty)
    }

    func testADashWithNothingAfterItIsNotAKey() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertTrue(keyRuns("ABC- and then words").isEmpty)
        XCTAssertTrue(keyRuns("ABC-").isEmpty)
        XCTAssertTrue(keyRuns("ABC_1717").isEmpty)
    }

    /// A dash *before* the project is left matching: "revert-ABC-123" is a real ticket reference, unlike
    /// the trailing-dash case where "ABC-dfs-3js" is a different identifier entirely.
    func testALeadingDashStillMatches() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertEqual(keyRuns("revert-ABC-123"), ["ABC-123"])
    }

    /// The setting is user input and goes into a pattern, so it has to be escaped.
    func testRegexMetacharactersInTheSettingAreEscaped() {
        Defaults[.highlightedProjectKeys] = "A.C"
        XCTAssertTrue(keyRuns("ABC-1717 should not match a dot wildcard").isEmpty)
        XCTAssertEqual(keyRuns("A.C-1717 is the literal one"), ["A.C-1717"])
    }

    // MARK: - the empty setting keeps the old behaviour

    func testAnEmptySettingColorsEveryProject() {
        Defaults[.highlightedProjectKeys] = ""
        XCTAssertEqual(keyRuns("[OTH-201] yes"), ["OTH-201"])
        XCTAssertEqual(keyRuns("[ZZ9-3384] yes"), ["ZZ9-3384"])
    }

    /// Ordered alternation: a shorter configured key must not shadow a longer one it prefixes, in
    /// either listing order. Sorting or deduping the list later would break this silently.
    func testAConfiguredKeyThatPrefixesAnotherDoesNotShadowIt() {
        for setting in ["AB, ABC", "ABC, AB"] {
            Defaults[.highlightedProjectKeys] = setting
            XCTAssertEqual(keyRuns("ABC-1 here"), ["ABC-1"], setting)
            XCTAssertEqual(keyRuns("AB-9 here"), ["AB-9"], setting)
        }
    }

    // MARK: - the ticket row's own key

    func testTheTicketRowKeyFollowsTheFilter() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertTrue(AppDelegate.isHighlightedKey("ABC-1717"))
        XCTAssertTrue(AppDelegate.isHighlightedKey("abc-1717"))
        XCTAssertFalse(AppDelegate.isHighlightedKey("OTH-201"))
        XCTAssertFalse(AppDelegate.isHighlightedKey("ABC-dfs-3js"), "not a key under this rule")
        XCTAssertFalse(AppDelegate.isHighlightedKey("[ABC-1717]"), "the element holds a bare key")
        XCTAssertFalse(AppDelegate.isHighlightedKey(""))
    }

    /// An unconfigured install must not re-decide whether Jira's own key is a key. Jira DC lets an
    /// admin set the project-key pattern, so shapes the generic pattern rejects — a single-letter
    /// project, a non-ASCII one — still have to come back blue, exactly as they did before the
    /// setting existed.
    func testEveryTicketRowKeyIsHighlightedWhenNothingIsConfigured() {
        Defaults[.highlightedProjectKeys] = ""
        for key in ["OTH-201", "ABC-1717", "X-1", "ÄBC-1", "ABC-dfs-3js"] {
            XCTAssertTrue(AppDelegate.isHighlightedKey(key), key)
        }
    }

    /// The dialogs are opened from a ticket row, so their key has to follow the same filter — otherwise
    /// a row whose key is grey opens a dialog whose key is blue.
    func testTheDialogKeyColorFollowsTheFilter() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertEqual(Color.forIssueKey("ABC-1717"), .issueKey)
        XCTAssertEqual(Color.forIssueKey("OTH-201"), .secondary)

        Defaults[.highlightedProjectKeys] = ""
        XCTAssertEqual(Color.forIssueKey("OTH-201"), .issueKey)
    }

    // MARK: - the filter must not move rows between sections

    /// `containsIssueKey` decides which PRs are "without tickets". Narrowing what turns blue must not
    /// touch it, or configuring a filter would silently repopulate that section.
    func testTheFilterDoesNotChangeWhichPRsCountAsTicketed() {
        for setting in ["", "ABC", "ZZZ"] {
            Defaults[.highlightedProjectKeys] = setting
            XCTAssertTrue(AppDelegate.containsIssueKey("[OTH-201] fix"), "setting: \(setting)")
            XCTAssertTrue(AppDelegate.containsIssueKey("ZZ9-3384-branch"), "setting: \(setting)")
            XCTAssertFalse(AppDelegate.containsIssueKey("no key here"), "setting: \(setting)")
        }
    }

    // MARK: - changing the setting takes effect

    /// The compiled pattern is cached, so a stale cache would keep colouring the old project.
    func testChangingTheSettingRebuildsTheMatcher() {
        Defaults[.highlightedProjectKeys] = "ABC"
        XCTAssertEqual(keyRuns("ABC-1 and XY2-2"), ["ABC-1"])
        Defaults[.highlightedProjectKeys] = "XY2"
        XCTAssertEqual(keyRuns("ABC-1 and XY2-2"), ["XY2-2"])
    }

    /// The SwiftUI dialogs go through the same matcher, so the filter has to reach them too.
    func testTheDialogColorerFollowsTheFilter() {
        Defaults[.highlightedProjectKeys] = "ABC"
        let colored = AppDelegate.attributedColoringIssueKeys("ABC-1 and OTH-201")
        let keys = colored.runs.filter { $0.foregroundColor == Color.issueKey }
            .map { String(colored[$0.range].characters) }
        XCTAssertEqual(keys, ["ABC-1"])
    }
}
