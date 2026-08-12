import XCTest
@testable import jiraBar

final class TransitionPromptConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> TransitionPromptConfig {
        try JSONDecoder().decode(TransitionPromptConfig.self, from: Data(json.utf8))
    }

    // MARK: - prReviewAction

    func testReviewActionDefaultsToNone() {
        XCTAssertEqual(TransitionPromptConfig().prReviewAction, .none)
    }

    func testReviewActionReadsBackingFlags() {
        var config = TransitionPromptConfig()
        config.enablePRApprove = true
        XCTAssertEqual(config.prReviewAction, .approve)

        config.enablePRApprove = false
        config.enablePRRequestChanges = true
        XCTAssertEqual(config.prReviewAction, .requestChanges)
    }

    func testSettingReviewActionIsExclusive() {
        var config = TransitionPromptConfig()

        config.prReviewAction = .approve
        XCTAssertTrue(config.enablePRApprove)
        XCTAssertFalse(config.enablePRRequestChanges)

        config.prReviewAction = .requestChanges
        XCTAssertFalse(config.enablePRApprove)
        XCTAssertTrue(config.enablePRRequestChanges)

        config.prReviewAction = .none
        XCTAssertFalse(config.enablePRApprove)
        XCTAssertFalse(config.enablePRRequestChanges)
    }

    /// The picker can't produce both flags, but a hand-edited settings file can. Requesting
    /// changes wins: an unwanted approval is a wrong review on someone's PR.
    func testBothFlagsResolveToRequestChanges() {
        var config = TransitionPromptConfig()
        config.enablePRApprove = true
        config.enablePRRequestChanges = true
        XCTAssertEqual(config.prReviewAction, .requestChanges)
    }

    // MARK: - allowsPRMerge / hasPRActions

    func testRequestChangesWithdrawsMerge() {
        var config = TransitionPromptConfig()
        config.enablePRMerge = true
        XCTAssertTrue(config.allowsPRMerge)

        config.prReviewAction = .approve
        XCTAssertTrue(config.allowsPRMerge)

        config.prReviewAction = .requestChanges
        XCTAssertFalse(config.allowsPRMerge, "merge must be impossible in request-changes mode")
    }

    func testHasPRActions() {
        var config = TransitionPromptConfig()
        XCTAssertFalse(config.hasPRActions)

        config.prReviewAction = .approve
        XCTAssertTrue(config.hasPRActions)

        config.prReviewAction = .requestChanges
        XCTAssertTrue(config.hasPRActions)

        config.prReviewAction = .none
        config.enablePRMerge = true
        XCTAssertTrue(config.hasPRActions)

        // Merge withdrawn by request-changes still leaves the review itself to do.
        config.prReviewAction = .requestChanges
        XCTAssertTrue(config.hasPRActions)

        config = TransitionPromptConfig()
        config.enablePRAssigneeSync = true
        XCTAssertTrue(config.hasPRActions)
    }

    // MARK: - Decoding older saved settings

    /// The shape saved before any PR-action flag existed — the user's live settings file has no
    /// `enablePR*` keys at all. Every flag must default off rather than fail the decode, which
    /// would wipe the whole prompt array via Defaults' fallback path.
    func testDecodesSettingsWithNoPRKeys() throws {
        let config = try decode("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "transitionName": "Ready for Review",
          "includeComment": true,
          "userFieldId": "customfield_99001",
          "userFieldLabel": "Reviewers",
          "userFieldAllowsMultiple": true,
          "userFieldDefaultsToCurrentUser": false,
          "textFieldId": "",
          "textFieldLabel": "Notes",
          "textFieldMultiline": true,
          "selectFieldId": "",
          "selectFieldLabel": "Select…",
          "selectOptions": []
        }
        """)
        XCTAssertEqual(config.transitionName, "Ready for Review")
        XCTAssertEqual(config.userFieldId, "customfield_99001")
        XCTAssertFalse(config.enablePRApprove)
        XCTAssertFalse(config.enablePRRequestChanges)
        XCTAssertFalse(config.enablePRMerge)
        XCTAssertFalse(config.enablePRAssigneeSync)
        XCTAssertEqual(config.prReviewAction, .none)
        XCTAssertFalse(config.hasPRActions)
    }

    /// Settings saved with the approve flag but written before request-changes existed keep
    /// approving — the new key's absence must not change the configured action.
    func testDecodesApproveOnlySettings() throws {
        let config = try decode("""
        {
          "transitionName": "Ready for QA",
          "enablePRApprove": true,
          "enablePRMerge": true,
          "prMergeMethod": "squash",
          "enablePRAssigneeSync": true
        }
        """)
        XCTAssertEqual(config.prReviewAction, .approve)
        XCTAssertTrue(config.allowsPRMerge)
        XCTAssertEqual(config.prMergeMethod, "squash")
        XCTAssertTrue(config.enablePRAssigneeSync)
    }

    func testRequestChangesSurvivesRoundTrip() throws {
        var config = TransitionPromptConfig()
        config.transitionName = "Reopen"
        config.prReviewAction = .requestChanges
        config.enablePRAssigneeSync = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TransitionPromptConfig.self, from: data)

        XCTAssertEqual(decoded.transitionName, "Reopen")
        XCTAssertEqual(decoded.prReviewAction, .requestChanges)
        XCTAssertTrue(decoded.enablePRAssigneeSync)
        XCTAssertFalse(decoded.allowsPRMerge)
    }

    /// The input `allowsPRMerge` exists for: a settings file hand-edited to ask for both a
    /// request-changes review and a merge. The setter can't produce it, so only the decode path
    /// proves the invariant holds "for every input path" as documented.
    func testHandEditedRequestChangesPlusMergeStillWithdrawsMerge() throws {
        let config = try decode("""
        {
          "transitionName": "Reopen",
          "enablePRApprove": true,
          "enablePRRequestChanges": true,
          "enablePRMerge": true
        }
        """)
        XCTAssertTrue(config.enablePRMerge, "the stored flag is untouched…")
        XCTAssertEqual(config.prReviewAction, .requestChanges)
        XCTAssertFalse(config.allowsPRMerge, "…but merging is withdrawn regardless of how it got set")
        XCTAssertTrue(config.hasPRActions)
    }

    // MARK: - PRReviewAction

    func testGithubEvent() {
        XCTAssertNil(PRReviewAction.none.githubEvent)
        XCTAssertEqual(PRReviewAction.approve.githubEvent, "APPROVE")
        XCTAssertEqual(PRReviewAction.requestChanges.githubEvent, "REQUEST_CHANGES")
    }

}

final class PRActionChoicesTests: XCTestCase {

    private func choices(_ review: PRReviewAction, comment: String) -> PRActionChoices {
        PRActionChoices(
            review: review, reviewComment: comment, merge: false, mergeMethod: "rebase", syncAssignee: false
        )
    }

    // MARK: - reviewEvent

    func testNoReviewHasNoEvent() {
        XCTAssertNil(choices(.none, comment: "ignored").reviewEvent)
        XCTAssertNil(PRActionChoices.disabled.reviewEvent)
    }

    func testApproveNeedsNoComment() {
        XCTAssertEqual(choices(.approve, comment: "").reviewEvent, "APPROVE")
        XCTAssertEqual(choices(.approve, comment: "  ").reviewEvent, "APPROVE")
        XCTAssertEqual(choices(.approve, comment: "lgtm").reviewEvent, "APPROVE")
    }

    /// GitHub rejects a REQUEST_CHANGES review with no body (422), so a blank comment must
    /// resolve to no request at all rather than one that comes back failed.
    func testRequestChangesWithoutCommentYieldsNoEvent() {
        XCTAssertNil(choices(.requestChanges, comment: "").reviewEvent)
        XCTAssertNil(choices(.requestChanges, comment: "   \n\t ").reviewEvent)
    }

    func testRequestChangesWithCommentYieldsEvent() {
        XCTAssertEqual(choices(.requestChanges, comment: "needs a test").reviewEvent, "REQUEST_CHANGES")
    }

    func testTrimmedReviewCommentIsWhatGetsSent() {
        XCTAssertEqual(choices(.requestChanges, comment: "  needs a test\n").trimmedReviewComment, "needs a test")
    }

    // MARK: - reviewBlockedForEmptyComment

    func testReviewBlockedOnlyForEmptyMandatoryComment() {
        XCTAssertTrue(choices(.requestChanges, comment: " ").reviewBlockedForEmptyComment)
        XCTAssertFalse(choices(.requestChanges, comment: "why").reviewBlockedForEmptyComment)
        XCTAssertFalse(choices(.approve, comment: "").reviewBlockedForEmptyComment)
        XCTAssertFalse(choices(.none, comment: "").reviewBlockedForEmptyComment)
    }

    // MARK: - hasWork

    func testHasWork() {
        XCTAssertFalse(PRActionChoices.disabled.hasWork)
        XCTAssertTrue(choices(.approve, comment: "").hasWork)
        XCTAssertTrue(choices(.requestChanges, comment: "why").hasWork)

        var merging = PRActionChoices.disabled
        merging.merge = true
        XCTAssertTrue(merging.hasWork)

        var assigning = PRActionChoices.disabled
        assigning.syncAssignee = true
        XCTAssertTrue(assigning.hasWork)
    }
}

final class PRActionsStatusTests: XCTestCase {

    private func pr(approved: Bool = false, requestedChanges: Bool = false) -> PRActionsStatus.LinkedPR {
        PRActionsStatus.LinkedPR(
            url: "https://github.com/o/r/pull/1",
            label: "o/r #1",
            isMerged: false,
            viewerApproved: approved,
            viewerRequestedChanges: requestedChanges,
            assignees: [],
            mergeCommitAllowed: true,
            squashMergeAllowed: true,
            rebaseMergeAllowed: true
        )
    }

    /// What the dialog's status line reports. One review state must not be read as the other.
    func testViewerSubmitted() {
        let status = PRActionsStatus()

        XCTAssertTrue(status.viewerSubmitted(.approve, on: pr(approved: true)))
        XCTAssertFalse(status.viewerSubmitted(.approve, on: pr(requestedChanges: true)))

        XCTAssertTrue(status.viewerSubmitted(.requestChanges, on: pr(requestedChanges: true)))
        XCTAssertFalse(status.viewerSubmitted(.requestChanges, on: pr(approved: true)))

        XCTAssertFalse(status.viewerSubmitted(.approve, on: pr()))
        XCTAssertFalse(status.viewerSubmitted(.requestChanges, on: pr()))
        XCTAssertFalse(status.viewerSubmitted(.none, on: pr(approved: true)))
    }

    /// The skip is approvals only. Requesting changes on a PR you've already requested changes on
    /// is the second-Reopen case, and dropping it would silently discard the comment the dialog
    /// just made mandatory.
    func testOnlyApprovalsAreSkippedAsRedundant() {
        let status = PRActionsStatus()

        XCTAssertTrue(status.resubmissionIsRedundant(.approve, on: pr(approved: true)))
        XCTAssertFalse(status.resubmissionIsRedundant(.approve, on: pr()))

        XCTAssertFalse(
            status.resubmissionIsRedundant(.requestChanges, on: pr(requestedChanges: true)),
            "a repeat request-changes carries a new comment and must still be sent"
        )
        XCTAssertFalse(status.resubmissionIsRedundant(.requestChanges, on: pr()))
    }
}

/// The summary notification is the only place a PR action's outcome ever surfaces — every client
/// error path otherwise just `print`s, and the Jira transition has already succeeded by the time
/// this text is built. So these assert the one distinction that matters: a thing we chose not to
/// do must never read like a thing that failed, and vice versa.
final class PRActionsSummaryTests: XCTestCase {

    private func body(
        _ actions: PRActionChoices,
        candidates: Int,
        reviewTargets: Int,
        tally: AppDelegate.PRActionTally
    ) -> String {
        AppDelegate.prActionsSummaryBody(
            issueKey: "JB-1",
            actions: actions,
            candidateCount: candidates,
            reviewTargetCount: reviewTargets,
            tally: tally
        )
    }

    private func requestChanges(comment: String = "needs a test") -> PRActionChoices {
        PRActionChoices(
            review: .requestChanges, reviewComment: comment,
            merge: false, mergeMethod: "rebase", syncAssignee: false
        )
    }

    // MARK: - failureCount counts failures only

    func testFailureCountExcludesSkips() {
        var tally = AppDelegate.PRActionTally()
        tally.mergeSkipped = 5
        tally.assignNotTouched = 5
        tally.reviewOK = 5
        XCTAssertEqual(tally.failureCount, 0, "skipping is not failing")
        XCTAssertTrue(tally.failureLines.isEmpty)

        tally.reviewFailed = ["o/r #1"]
        tally.mergeFailed = ["o/r #2", "o/r #3"]
        tally.assignFailed = ["o/r #4", "o/r #5", "o/r #6"]
        XCTAssertEqual(tally.failureCount, 6)
    }

    // MARK: - a failure leads, and says so

    /// The DNS-outage shape: the review was attempted against GitHub and never landed, while the
    /// ticket has already moved. Banners truncate, so "FAILED" has to be at the front.
    func testTotalReviewFailureLeadsWithFailed() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewFailed = ["o/r #1", "o/r #2", "o/r #3"]
        let text = body(requestChanges(), candidates: 3, reviewTargets: 3, tally: tally)

        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 3 FAILED"), text)
        XCTAssertTrue(text.contains("ticket moved, GitHub did not"), text)
        XCTAssertTrue(text.contains("requested changes on 0/3"), text)
        XCTAssertTrue(text.contains("3 review failed"), text)
    }

    /// Three linked PRs, the second one fails. The partial success is reported as a partial
    /// success, not rounded up to done or down to broken.
    func testPartialFailureReportsBothSidesAndLeadsWithFailed() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        tally.reviewFailed = ["o/r #2"]
        let text = body(requestChanges(), candidates: 3, reviewTargets: 3, tally: tally)

        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 1 FAILED"), text)
        XCTAssertTrue(text.contains("requested changes on 2/3"), text)
        XCTAssertTrue(text.contains("1 review failed"), text)
    }

    func testAssigneeFailureAlsoLeadsWithFailed() {
        var choices = PRActionChoices.disabled
        choices.syncAssignee = true
        var tally = AppDelegate.PRActionTally()
        tally.assignFailed = ["o/r #1"]
        let text = body(choices, candidates: 1, reviewTargets: 0, tally: tally)

        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 1 FAILED"), text)
        XCTAssertTrue(text.contains("1 assignee failed"), text)
    }

    // MARK: - a skip must never read as a failure

    func testCleanRunNeverSaysFailed() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        let text = body(requestChanges(), candidates: 2, reviewTargets: 2, tally: tally)

        XCTAssertEqual(text, "PR actions for JB-1: requested changes on 2/2.")
        XCTAssertFalse(text.contains("FAILED"), text)
    }

    func testWithheldReviewIsASkipNotAFailure() {
        let text = body(requestChanges(comment: "   "), candidates: 2, reviewTargets: 0,
                        tally: AppDelegate.PRActionTally())

        XCTAssertTrue(text.contains("request changes skipped: a comment is required"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
        XCTAssertFalse(text.contains("review failed"), text)
    }

    func testDisallowedMergeMethodIsASkipNotAFailure() {
        var choices = PRActionChoices.disabled
        choices.merge = true
        var tally = AppDelegate.PRActionTally()
        tally.mergeSkipped = 2
        let text = body(choices, candidates: 2, reviewTargets: 0, tally: tally)

        XCTAssertTrue(text.contains("2 skipped (method not allowed)"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
    }

    func testAlreadyApprovedIsASkipNotAFailure() {
        var choices = PRActionChoices.disabled
        choices.review = .approve
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 1
        let text = body(choices, candidates: 3, reviewTargets: 1, tally: tally)

        XCTAssertTrue(text.contains("approved 1/1"), text)
        XCTAssertTrue(text.contains("2 already approved"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
    }

    /// A Jira-side read failure degrades assignee sync to a no-op. It is named, and it is named as
    /// a lookup failure rather than inflating the GitHub failure count.
    func testJiraAssigneeLookupFailureIsNamedButNotCountedAsAGithubFailure() {
        var choices = PRActionChoices.disabled
        choices.syncAssignee = true
        var tally = AppDelegate.PRActionTally()
        tally.assigneeLookupFailed = true
        let text = body(choices, candidates: 1, reviewTargets: 0, tally: tally)

        XCTAssertTrue(text.contains("Jira assignee lookup failed"), text)
        XCTAssertFalse(text.contains("FAILED —"), text)
    }

    // MARK: - failureLines: what the still-open dialog shows

    /// The partial case orc asked about: three linked PRs, the second one fails. The line has to
    /// name that PR, not just say "1 failed".
    func testFailureLinesNameTheFailedPR() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        tally.reviewFailed = ["acme/api #2"]

        XCTAssertEqual(tally.failureLines, ["Review not submitted on acme/api #2"])
    }

    func testFailureLinesCoverAllThreeActions() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewFailed = ["o/r #1"]
        tally.mergeFailed = ["o/r #2"]
        tally.assignFailed = ["o/r #3"]

        XCTAssertEqual(tally.failureLines, [
            "Review not submitted on o/r #1",
            "Merge failed on o/r #2",
            "Assignee not set on o/r #3",
        ])
    }

    /// A batch that never started is not a batch that failed — no failure lines — but the reason
    /// still has to reach the window rather than only the notification.
    func testBlockedBatchHasNoFailureLinesButKeepsItsReason() {
        let tally = AppDelegate.PRActionTally(blockedReason: "No GitHub token is set, so no PR action ran.")
        XCTAssertTrue(tally.failureLines.isEmpty)
        XCTAssertEqual(tally.failureCount, 0)
        XCTAssertEqual(tally.blockedReason, "No GitHub token is set, so no PR action ran.")
    }

    func testNothingToReport() {
        let text = body(PRActionChoices.disabled, candidates: 1, reviewTargets: 0,
                        tally: AppDelegate.PRActionTally())
        XCTAssertEqual(text, "PR actions for JB-1: no changes.")
    }
}

final class GithubReviewSubmittabilityTests: XCTestCase {

    /// APPROVE is the event GitHub accepts without a body.
    func testApproveNeedsNoBody() {
        XCTAssertTrue(GithubClient.reviewIsSubmittable(event: "APPROVE", body: ""))
        XCTAssertTrue(GithubClient.reviewIsSubmittable(event: "APPROVE", body: "lgtm"))
    }

    func testBodyRequiredEventsRejectBlankBodies() {
        for event in ["REQUEST_CHANGES", "COMMENT", "request_changes"] {
            XCTAssertFalse(GithubClient.reviewIsSubmittable(event: event, body: ""), event)
            XCTAssertFalse(GithubClient.reviewIsSubmittable(event: event, body: "  \n\t "), event)
            XCTAssertTrue(GithubClient.reviewIsSubmittable(event: event, body: "needs a test"), event)
        }
    }
}
