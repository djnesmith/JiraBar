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
          "userFieldId": "customfield_10029",
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
        XCTAssertEqual(config.userFieldId, "customfield_10029")
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
