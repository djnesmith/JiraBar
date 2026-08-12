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

    // MARK: - Required fields

    private func gated(label: String = "Testers", manualRequired: Bool) -> TransitionPromptConfig {
        var config = TransitionPromptConfig()
        config.userFieldId = "customfield_99002"
        config.userFieldLabel = label
        config.userFieldAllowsMultiple = true
        config.userFieldRequired = manualRequired
        return config
    }

    func testHasGatableFieldIsFalseForACommentOnlyPrompt() {
        var config = TransitionPromptConfig()
        config.includeComment = true
        XCTAssertFalse(config.hasGatableField, "nothing to require, so unknown requiredness can't block")

        config.userFieldId = "customfield_99002"
        XCTAssertTrue(config.hasGatableField)
    }

    /// The two sources are OR'd, not one falling back to the other. Jira's flag can't express a
    /// workflow-validator rule and the manual flag can't know about screen changes.
    func testFieldIsRequiredTakesEitherSource() {
        let config = gated(manualRequired: false)

        XCTAssertFalse(config.fieldIsRequired("customfield_99002", manualFlag: false, jiraRequiredFieldIds: []))
        XCTAssertTrue(config.fieldIsRequired("customfield_99002", manualFlag: true, jiraRequiredFieldIds: []))
        XCTAssertTrue(config.fieldIsRequired("customfield_99002", manualFlag: false, jiraRequiredFieldIds: ["customfield_99002"]))
        XCTAssertTrue(config.fieldIsRequired("customfield_99002", manualFlag: true, jiraRequiredFieldIds: ["customfield_99002"]))
        XCTAssertFalse(
            config.fieldIsRequired("customfield_99002", manualFlag: false, jiraRequiredFieldIds: ["somethingelse"]),
            "another field being required says nothing about this one"
        )
    }

    /// Field ids are typed or pasted by hand and `fieldUpdates` trims them before posting, so the
    /// requiredness comparison has to trim too — otherwise a stored trailing space renders the field
    /// and silently never matches Jira's flag for it.
    func testStoredFieldIdIsTrimmedBeforeMatchingJirasIds() {
        var config = TransitionPromptConfig()
        config.userFieldId = " customfield_99002 "
        config.userFieldLabel = "Testers"

        XCTAssertTrue(config.hasUserField, "a padded id still renders the field")
        XCTAssertTrue(
            config.fieldIsRequired(config.userFieldId, manualFlag: false, jiraRequiredFieldIds: ["customfield_99002"])
        )
        XCTAssertEqual(
            config.missingRequirements(
                selectedUserCount: 0, textValue: "", selectValue: "",
                jiraRequiredFieldIds: ["customfield_99002"]
            ).count,
            1,
            "a padded id must still match Jira's flag"
        )
    }

    /// Case is not folded: these are distinct fields to Jira, and matching them would invent a
    /// requirement that does not exist.
    func testFieldIdMatchingIsCaseSensitive() {
        var config = TransitionPromptConfig()
        config.userFieldId = "customfield_99002"
        XCTAssertFalse(
            config.fieldIsRequired(config.userFieldId, manualFlag: false, jiraRequiredFieldIds: ["CUSTOMFIELD_99002"])
        )
    }

    /// "At least one tester" is a COUNT. An empty multi-user picker satisfies presence and must
    /// still fail — that is the whole rule.
    func testRequiredUserFieldNeedsAtLeastOneSelection() {
        let config = gated(manualRequired: true)

        let missing = config.missingRequirements(
            selectedUserCount: 0, textValue: "", selectValue: "", jiraRequiredFieldIds: []
        )
        XCTAssertEqual(missing.count, 1)
        XCTAssertTrue(missing[0].contains("Testers"), missing[0])
        XCTAssertTrue(
            config.missingRequirements(selectedUserCount: 1, textValue: "", selectValue: "", jiraRequiredFieldIds: []).isEmpty,
            "one is enough"
        )
        XCTAssertTrue(
            config.missingRequirements(selectedUserCount: 3, textValue: "", selectValue: "", jiraRequiredFieldIds: []).isEmpty
        )
    }

    func testUnrequiredUserFieldAllowsAnEmptySelection() {
        let config = gated(manualRequired: false)
        XCTAssertTrue(
            config.missingRequirements(selectedUserCount: 0, textValue: "", selectValue: "", jiraRequiredFieldIds: []).isEmpty
        )
    }

    /// Jira's flag alone is enough — this is the `resolution`-on-Force-Close shape, where nothing
    /// was ticked locally.
    func testJiraRequiredFlagAloneGates() {
        var config = TransitionPromptConfig()
        config.selectFieldId = "resolution"
        config.selectFieldLabel = "Resolution"
        config.selectOptions = [TransitionSelectOption(label: "Done", value: "10000")]

        XCTAssertEqual(
            config.missingRequirements(
                selectedUserCount: 0, textValue: "", selectValue: "", jiraRequiredFieldIds: ["resolution"]
            ),
            ["Choose a Resolution — it is required."]
        )
        XCTAssertTrue(
            config.missingRequirements(
                selectedUserCount: 0, textValue: "", selectValue: "10000", jiraRequiredFieldIds: ["resolution"]
            ).isEmpty
        )
    }

    /// Everything missing, not the first problem — he shouldn't fix one to discover the next.
    func testMissingRequirementsListsEveryOutstandingField() {
        var config = gated(manualRequired: true)
        config.textFieldId = "customfield_99003"
        config.textFieldLabel = "QA Notes"
        config.textFieldRequired = true
        config.selectFieldId = "resolution"
        config.selectFieldLabel = "Resolution"
        config.selectOptions = [TransitionSelectOption(label: "Done", value: "10000")]

        let missing = config.missingRequirements(
            selectedUserCount: 0, textValue: "   ", selectValue: "", jiraRequiredFieldIds: ["resolution"]
        )

        XCTAssertEqual(missing.count, 3, "all three, in field order: \(missing)")
        XCTAssertEqual(missing, [
            "Testers is required — select at least one.",
            "Fill in QA Notes — it is required.",
            "Choose a Resolution — it is required.",
        ])
    }

    /// A required select field with no options renders no picker, so nothing in the dialog can
    /// satisfy it. It must block with a pointer rather than pass silently into a Jira refusal.
    func testRequiredSelectFieldWithNoOptionsBlocksWithAPointer() {
        var config = TransitionPromptConfig()
        config.selectFieldId = "resolution"
        config.selectFieldLabel = "Resolution"
        config.selectFieldRequired = true

        XCTAssertFalse(config.hasSelectField, "no options means no picker is rendered")
        XCTAssertEqual(
            config.missingRequirements(selectedUserCount: 0, textValue: "", selectValue: "", jiraRequiredFieldIds: []),
            ["Resolution is required but has no options configured — add them in Preferences, or set the field in Jira first."]
        )
    }

    /// Whitespace is not a filled-in text field.
    func testWhitespaceDoesNotSatisfyARequiredTextField() {
        var config = TransitionPromptConfig()
        config.textFieldId = "customfield_99003"
        config.textFieldLabel = "QA Notes"
        config.textFieldRequired = true

        XCTAssertFalse(
            config.missingRequirements(selectedUserCount: 0, textValue: " \n\t ", selectValue: "", jiraRequiredFieldIds: []).isEmpty
        )
        XCTAssertTrue(
            config.missingRequirements(selectedUserCount: 0, textValue: "ran it", selectValue: "", jiraRequiredFieldIds: []).isEmpty
        )
    }

    /// A required flag on a field this prompt doesn't render can't block the dialog — there would be
    /// nothing to fill in.
    func testRequirementsOnlyCoverFieldsThePromptRenders() {
        let config = TransitionPromptConfig()
        XCTAssertTrue(
            config.missingRequirements(
                selectedUserCount: 0, textValue: "", selectValue: "",
                jiraRequiredFieldIds: ["customfield_99002", "resolution"]
            ).isEmpty
        )
    }

    func testRequiredFlagsDefaultOffAndSurviveARoundTrip() throws {
        var config = gated(manualRequired: true)
        config.transitionName = "Ready for QA"

        let decoded = try JSONDecoder().decode(
            TransitionPromptConfig.self, from: try JSONEncoder().encode(config)
        )
        XCTAssertTrue(decoded.userFieldRequired)
        XCTAssertFalse(decoded.textFieldRequired)
        XCTAssertFalse(decoded.selectFieldRequired)

        // Settings written before these keys existed must decode with every flag off.
        let old = try decode("""
        { "transitionName": "Reopen", "userFieldId": "customfield_99002" }
        """)
        XCTAssertFalse(old.userFieldRequired)
        XCTAssertFalse(old.textFieldRequired)
        XCTAssertFalse(old.selectFieldRequired)
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
            isDraft: false,
            statesKnown: true,
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

    private func linked(_ n: Int) -> PRActionsStatus.LinkedPR {
        PRActionsStatus.LinkedPR(
            url: "https://github.com/o/r/pull/\(n)", label: "o/r #\(n)", isMerged: false,
            viewerApproved: false, viewerRequestedChanges: false, isDraft: false, statesKnown: true,
            assignees: [], mergeCommitAllowed: true, squashMergeAllowed: true, rebaseMergeAllowed: true
        )
    }

    private func plan(
        submit: [(Int, String)] = [],
        alreadyApproved: [Int] = [],
        stateUnknown: [Int] = [],
        skippedByChoice: [Int] = [],
        withheld: [Int] = []
    ) -> PRActionsStatus.ReviewPlan {
        var p = PRActionsStatus.ReviewPlan()
        p.submit = submit.map { PRActionsStatus.PlannedReview(pr: linked($0.0), event: $0.1) }
        p.alreadyApproved = alreadyApproved.map(linked)
        p.stateUnknown = stateUnknown.map(linked)
        p.skippedByChoice = skippedByChoice.map(linked)
        p.withheldForBlankComment = withheld.map(linked)
        return p
    }

    private func body(
        _ actions: PRActionChoices,
        candidates: Int,
        plan: PRActionsStatus.ReviewPlan,
        tally: AppDelegate.PRActionTally
    ) -> String {
        AppDelegate.prActionsSummaryBody(
            issueKey: "JB-1", actions: actions, candidateCount: candidates, plan: plan, tally: tally
        )
    }

    private func requestChanges(comment: String = "needs a test") -> PRActionChoices {
        PRActionChoices(
            review: .requestChanges, reviewComment: comment,
            merge: false, mergeMethod: "rebase", syncAssignee: false
        )
    }

    // MARK: - failures lead, skips are never called failures

    func testTotalReviewFailureLeadsWithFailed() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewFailed = ["o/r #1", "o/r #2", "o/r #3"]
        let text = body(
            requestChanges(), candidates: 3,
            plan: plan(submit: [(1, "REQUEST_CHANGES"), (2, "REQUEST_CHANGES"), (3, "REQUEST_CHANGES")]),
            tally: tally
        )
        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 3 FAILED"), text)
        XCTAssertTrue(text.contains("requested changes on 0/3"), text)
    }

    func testPartialFailureReportsBothSides() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        tally.reviewFailed = ["o/r #2"]
        let text = body(
            requestChanges(), candidates: 3,
            plan: plan(submit: [(1, "REQUEST_CHANGES"), (2, "REQUEST_CHANGES"), (3, "REQUEST_CHANGES")]),
            tally: tally
        )
        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 1 FAILED"), text)
        XCTAssertTrue(text.contains("requested changes on 2/3"), text)
        XCTAssertTrue(text.contains("1 review failed"), text)
    }

    func testCleanRunNeverSaysFailed() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        let text = body(
            requestChanges(), candidates: 2,
            plan: plan(submit: [(1, "REQUEST_CHANGES"), (2, "REQUEST_CHANGES")]), tally: tally
        )
        XCTAssertEqual(text, "PR actions for JB-1: requested changes on 2/2.")
    }

    func testWithheldReviewIsASkipNotAFailure() {
        let text = body(
            requestChanges(comment: "   "), candidates: 2,
            plan: plan(withheld: [1, 2]), tally: AppDelegate.PRActionTally()
        )
        XCTAssertTrue(text.contains("request changes skipped: a comment is required"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
    }

    // MARK: - the per-PR buckets must not be reported as each other

    /// The conflation this redesign removes: a PR skipped by choice, or for an unreadable state, used to
    /// be announced as "already approved" because the count was inferred by subtraction.
    func testEachSkipReasonIsReportedAsItself() {
        let text = body(
            requestChanges(), candidates: 4,
            plan: plan(submit: [(1, "REQUEST_CHANGES")], alreadyApproved: [2], stateUnknown: [3], skippedByChoice: [4]),
            tally: { var t = AppDelegate.PRActionTally(); t.reviewOK = 1; return t }()
        )
        XCTAssertTrue(text.contains("requested changes on 1/1"), text)
        XCTAssertTrue(text.contains("1 already approved"), text)
        XCTAssertTrue(text.contains("1 skipped: review state unreadable"), text)
        XCTAssertTrue(text.contains("1 skipped"), text)
        XCTAssertFalse(text.contains("3 already approved"), text)
    }

    /// A mixed batch reports each verb, rather than filing a REQUEST_CHANGES under "approved".
    func testMixedActionsReportBothVerbs() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        let text = body(
            PRActionChoices(
                review: .approve, reviewComment: "why", merge: false, mergeMethod: "rebase",
                syncAssignee: false, reviewByPRURL: ["https://github.com/o/r/pull/2": .requestChanges]
            ),
            candidates: 2,
            plan: plan(submit: [(1, "APPROVE"), (2, "REQUEST_CHANGES")]),
            tally: tally
        )
        XCTAssertTrue(text.contains("approved 1/1"), text)
        XCTAssertTrue(text.contains("requested changes on 1/1"), text)
    }

    func testNothingToReport() {
        let text = body(
            PRActionChoices.disabled, candidates: 1, plan: plan(), tally: AppDelegate.PRActionTally()
        )
        XCTAssertEqual(text, "PR actions for JB-1: no changes.")
    }

    // MARK: - non-review actions, unchanged

    func testDisallowedMergeMethodIsASkipNotAFailure() {
        var choices = PRActionChoices.disabled
        choices.merge = true
        var tally = AppDelegate.PRActionTally()
        tally.mergeSkipped = 2
        let text = body(choices, candidates: 2, plan: plan(), tally: tally)
        XCTAssertTrue(text.contains("2 skipped (method not allowed)"), text)
        XCTAssertFalse(text.contains("FAILED"), text)
    }

    func testAssigneeFailureLeadsWithFailed() {
        var choices = PRActionChoices.disabled
        choices.syncAssignee = true
        var tally = AppDelegate.PRActionTally()
        tally.assignFailed = ["o/r #1"]
        let text = body(choices, candidates: 1, plan: plan(), tally: tally)
        XCTAssertTrue(text.hasPrefix("PR actions for JB-1: 1 FAILED"), text)
        XCTAssertTrue(text.contains("1 assignee failed"), text)
    }

    func testJiraAssigneeLookupFailureIsNamedButNotAGithubFailure() {
        var choices = PRActionChoices.disabled
        choices.syncAssignee = true
        var tally = AppDelegate.PRActionTally()
        tally.assigneeLookupFailed = true
        let text = body(choices, candidates: 1, plan: plan(), tally: tally)
        XCTAssertTrue(text.contains("Jira assignee lookup failed"), text)
        XCTAssertFalse(text.contains("FAILED —"), text)
    }

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

    func testBlockedBatchReportsNothingRanRatherThanAFailure() {
        let tally = AppDelegate.PRActionTally(blockedReason: "No open linked PRs were found, so no PR action ran.")
        XCTAssertEqual(tally.report, .nothingRan(reason: "No open linked PRs were found, so no PR action ran."))
        XCTAssertTrue(tally.failureLines.isEmpty)
    }

    func testCleanBatchReportsClean() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        tally.mergeSkipped = 1
        XCTAssertEqual(tally.report, .clean, "skips alone are still a clean run")
    }

    func testFailedBatchReportsItsLines() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewFailed = ["acme/api #2"]
        XCTAssertEqual(tally.report, .failures(["Review not submitted on acme/api #2"]))
    }

    func testBlockedReasonWinsOverFailureLines() {
        var tally = AppDelegate.PRActionTally(blockedReason: "No GitHub token is set, so no PR action ran.")
        tally.reviewFailed = ["acme/api #1"]
        XCTAssertEqual(tally.report, .nothingRan(reason: "No GitHub token is set, so no PR action ran."))
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

/// What the transition window actually says. Asserted rather than read off the view body, because
/// this wording is the fix: the complaint was that a failed PR action vanished into a `print` while
/// the Jira ticket had already moved.
final class TransitionOutcomeTextTests: XCTestCase {

    /// The end-to-end sentence for the case a real GitHub rejection produces: one linked PR, the
    /// review refused, the transition already applied.
    func testSingleFailedReviewRendersTheWholeReport() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewFailed = ["Tradeswell/tw-utils #36"]

        guard case .failures(let lines) = tally.report else {
            return XCTFail("a refused review is a failure, not a skip: \(tally.report)")
        }

        XCTAssertEqual(
            TransitionOutcomeText.prActionsIncomplete(count: lines.count),
            "The Jira transition WAS applied, but 1 PR action did not:"
        )
        XCTAssertEqual(lines, ["Review not submitted on Tradeswell/tw-utils #36"])
    }

    func testPluralisesOnMoreThanOneFailure() {
        XCTAssertEqual(
            TransitionOutcomeText.prActionsIncomplete(count: 2),
            "The Jira transition WAS applied, but 2 PR actions did not:"
        )
    }

    /// A refusal must not claim nothing changed when the field PUT had already landed.
    func testJiraRefusalIsHonestAboutWhatWasPersisted() {
        XCTAssertEqual(
            TransitionOutcomeText.jiraRefused(fieldsWritten: false),
            "Jira refused the transition — nothing was changed."
        )
        XCTAssertEqual(
            TransitionOutcomeText.jiraRefused(fieldsWritten: true),
            "Jira saved the field values but refused the transition — the status did not change."
        )
    }

    /// "Nothing ran" must not borrow the failure wording, and must not repeat the reason rendered
    /// beneath it — every `blockedReason` already ends in "…so no PR action ran."
    func testNothingRanDoesNotBorrowFailureWordingOrRepeatItsReason() {
        let headline = TransitionOutcomeText.prActionsDidNotRun
        XCTAssertFalse(headline.contains("did not"), headline)
        XCTAssertFalse(headline.lowercased().contains("no pr action ran"), headline)

        let reason = AppDelegate.PRActionTally(blockedReason: "No open linked PRs were found, so no PR action ran.")
        XCTAssertEqual(reason.report, .nothingRan(reason: "No open linked PRs were found, so no PR action ran."))
    }
}

/// A prompt whose name doesn't match any real transition opens no dialog and says nothing. The guard
/// against that can only speak on POSITIVE evidence — a seen name the configured name extends —
/// because JiraBar never sees the whole workflow: Jira returns only the transitions reachable from
/// each fetched issue's current status. Warning on absence would call correct configs wrong.
final class UnknownTransitionNameWarningTests: XCTestCase {

    private func prompt(_ name: String) -> TransitionPromptConfig {
        var config = TransitionPromptConfig()
        config.transitionName = name
        return config
    }

    private let seen = ["Close", "Ready for QA", "Ready for Review", "Reopen"]

    // MARK: - the mistake it exists to catch

    /// Typing the status name instead of the transition name.
    func testStatusNameSuggestsTheTransitionName() {
        let warning = prompt("Reopened").unknownTransitionNameWarning(seenNames: seen)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("\"Reopened\""), warning!)
        XCTAssertTrue(warning!.contains("did you mean \"Reopen\"?"), warning!)
        XCTAssertTrue(warning!.contains("not the status it moves to"), warning!)
    }

    /// Among several relatives, the closest one — not whichever sorts first.
    func testSuggestsTheLongestMatchingPrefix() {
        let warning = prompt("Ready for Reviewing")
            .unknownTransitionNameWarning(seenNames: ["Ready", "Ready for Review", "Ready for QA"])
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("\"Ready for Review\""), warning!)
    }

    // MARK: - silence, which is the usual and correct answer

    func testExactMatchIsSilent() {
        XCTAssertNil(prompt("Reopen").unknownTransitionNameWarning(seenNames: seen))
    }

    func testMatchIsCaseAndWhitespaceInsensitiveJustLikeMatches() {
        XCTAssertNil(prompt("  reopen ").unknownTransitionNameWarning(seenNames: seen))
        XCTAssertNil(prompt("READY FOR QA").unknownTransitionNameWarning(seenNames: seen))
    }

    /// The drift guard: anything `matches` accepts must never be warned about, whatever `matches`
    /// later does with folding.
    func testNothingMatchesIsEverWarnedAbout() {
        for name in seen {
            let config = prompt(name)
            XCTAssertTrue(config.matches(transitionName: name))
            XCTAssertNil(config.unknownTransitionNameWarning(seenNames: seen), name)
        }
    }

    /// The whole point of the redesign: an unrecognised name is NOT evidence of a wrong one. "Reopen"
    /// out of a closed status is invisible to a JQL scoped to open work, so silence is required.
    func testUnrecognisedNameWithNoRelativeIsSilent() {
        XCTAssertNil(prompt("Force Close").unknownTransitionNameWarning(seenNames: seen))
        XCTAssertNil(prompt("Banana").unknownTransitionNameWarning(seenNames: seen))
    }

    /// A half-typed name must not accuse: nothing warns while the field is being filled in.
    func testPartiallyTypedNameIsSilent() {
        for typed in ["R", "Re", "Read", "Ready for"] {
            XCTAssertNil(
                prompt(typed).unknownTransitionNameWarning(seenNames: seen),
                "\(typed) should be silent — it is a prefix OF a seen name, not an extension of one"
            )
        }
    }

    func testEmptyHistoryIsSilent() {
        XCTAssertNil(prompt("Reopened").unknownTransitionNameWarning(seenNames: []))
    }

    /// Whitespace-only sightings are not evidence, and an empty folded name would otherwise prefix
    /// everything. Unreachable through the app; a hand-edited defaults array is not.
    func testBlankSightingsAreNotEvidence() {
        XCTAssertNil(prompt("Reopened").unknownTransitionNameWarning(seenNames: ["", "   ", "\t"]))
    }

    func testBlankConfiguredNameIsSilent() {
        XCTAssertNil(prompt("").unknownTransitionNameWarning(seenNames: seen))
        XCTAssertNil(prompt("   ").unknownTransitionNameWarning(seenNames: seen))
    }
}

final class SeenTransitionNamesTests: XCTestCase {

    func testMergeIsAUnionThatKeepsTheFirstSpelling() {
        let merged = AppDelegate.mergedTransitionNames(
            existing: ["Reopen", "Close"], adding: ["reopen", "Ready for QA", "  Close  "]
        )
        XCTAssertEqual(merged, ["Close", "Ready for QA", "Reopen"], "sorted, deduped case-insensitively")
    }

    func testBlanksAreDropped() {
        XCTAssertEqual(
            AppDelegate.mergedTransitionNames(existing: [], adding: ["", "   ", "Reopen"]),
            ["Reopen"]
        )
    }

    func testCappedSoStoredDefaultsCannotGrowUnbounded() {
        let many = (1...500).map { "Transition \($0)" }
        XCTAssertEqual(AppDelegate.mergedTransitionNames(existing: [], adding: many).count, 200)
    }

    func testMergingNothingNewIsStable() {
        let first = AppDelegate.mergedTransitionNames(existing: [], adding: ["Reopen", "Close"])
        XCTAssertEqual(AppDelegate.mergedTransitionNames(existing: first, adding: ["Close"]), first)
    }
}

/// What each PR starts at when the dialog opens. This seeding IS the feature's safety: someone who
/// hits Transition without reading the rows gets whatever this produced.
final class PerPRSeedingTests: XCTestCase {

    private func pr(
        _ n: Int,
        approved: Bool = false,
        requestedChanges: Bool = false,
        merged: Bool = false,
        draft: Bool = false,
        statesKnown: Bool = true
    ) -> PRActionsStatus.LinkedPR {
        PRActionsStatus.LinkedPR(
            url: "https://github.com/o/r/pull/\(n)",
            label: "o/r #\(n)",
            isMerged: merged,
            viewerApproved: approved,
            viewerRequestedChanges: requestedChanges,
            isDraft: draft,
            statesKnown: statesKnown,
            assignees: [],
            mergeCommitAllowed: true,
            squashMergeAllowed: true,
            rebaseMergeAllowed: true
        )
    }

    // MARK: - the agreed default: skip approved, but never drop it

    func testRequestChangesSkipsAnApprovedPRAndActsOnTheRest() {
        let prs = [pr(1, approved: true), pr(2, requestedChanges: true), pr(3)]
        let seeded = PRActionsStatus.seedActions(blanket: .requestChanges, prs: prs)

        XCTAssertEqual(seeded[prs[0].url], PRReviewAction.none, "approved earlier — skipped by default")
        XCTAssertEqual(seeded[prs[1].url], .requestChanges, "a repeat is wanted; the comment is the payload")
        XCTAssertEqual(seeded[prs[2].url], .requestChanges)
        XCTAssertEqual(seeded.count, 3, "skipped is still listed, never dropped")
    }

    /// The skip is request-changes-only. Approving a PR you already approved is handled downstream by
    /// resubmissionIsRedundant, so seeding must not double up and hide it from the row.
    func testApproveSeedsEveryKnownPRIncludingOnesYouApproved() {
        let prs = [pr(1, approved: true), pr(2)]
        let seeded = PRActionsStatus.seedActions(blanket: .approve, prs: prs)
        XCTAssertEqual(seeded[prs[0].url], .approve)
        XCTAssertEqual(seeded[prs[1].url], .approve)
    }

    // MARK: - a PR whose state we could not read must never be acted on

    /// Every flag on an unenriched PR is a default, not an observation. Seeding it with the blanket
    /// action would silently supersede a review we cannot see.
    func testUnknownStateIsSkippedEvenWhenItLooksUnreviewed() {
        let prs = [pr(1, statesKnown: false), pr(2)]
        let seeded = PRActionsStatus.seedActions(blanket: .requestChanges, prs: prs)
        XCTAssertEqual(seeded[prs[0].url], PRReviewAction.none)
        XCTAssertEqual(seeded[prs[1].url], .requestChanges)
    }

    func testMergedIsSkipped() {
        let prs = [pr(1, merged: true)]
        XCTAssertEqual(PRActionsStatus.seedActions(blanket: .approve, prs: prs)[prs[0].url], PRReviewAction.none)
    }

    func testNoReviewBlanketSeedsNothingToDo() {
        let prs = [pr(1), pr(2)]
        let seeded = PRActionsStatus.seedActions(blanket: .none, prs: prs)
        XCTAssertEqual(Set(seeded.values), [PRReviewAction.none])
    }

    // MARK: - the caveats the rows show

    /// The state that matters: default seeding has already reduced this row to Skip, so only `blanket`
    /// still says what was asked for. Reading the caveat off the resolved action showed no reason at all.
    func testSupersedeCaveatShowsInTheDefaultSkippedState() {
        XCTAssertEqual(
            PRActionsStatus.rowCaveat(blanket: .requestChanges, resolved: PRReviewAction.none, on: pr(1, approved: true)),
            "You approved this earlier — requesting changes will supersede that approval."
        )
    }

    func testSupersedeCaveatAlsoShowsWhenTheUserOptsBackIn() {
        XCTAssertEqual(
            PRActionsStatus.rowCaveat(blanket: .approve, resolved: .requestChanges, on: pr(1, approved: true)),
            "You approved this earlier — requesting changes will supersede that approval."
        )
    }

    func testNoCaveatWhenThereIsNothingToWarnAbout() {
        XCTAssertNil(PRActionsStatus.rowCaveat(blanket: .approve, resolved: .approve, on: pr(1, approved: true)))
        XCTAssertNil(PRActionsStatus.rowCaveat(blanket: .requestChanges, resolved: .requestChanges, on: pr(1)))
    }

    func testUnknownStateAndMergedCaveatsOutrankTheSupersedeOne() {
        XCTAssertEqual(
            PRActionsStatus.rowCaveat(
                blanket: .requestChanges, resolved: PRReviewAction.none, on: pr(1, approved: true, statesKnown: false)
            ),
            "Couldn't read this PR's review state — skipped unless you say otherwise."
        )
        XCTAssertEqual(
            PRActionsStatus.rowCaveat(
                blanket: .requestChanges, resolved: PRReviewAction.none, on: pr(1, approved: true, merged: true)
            ),
            "Already merged."
        )
    }

    // MARK: - the plan: unknown state must never be treated as "no review"

    func testPlanSkipsUnknownStateAndSaysSoSeparately() {
        let prs = [pr(1, statesKnown: false), pr(2, approved: true), pr(3)]
        let actions = PRActionChoices(
            review: .requestChanges, reviewComment: "why", merge: false, mergeMethod: "rebase",
            syncAssignee: false,
            reviewByPRURL: PRActionsStatus.seedActions(blanket: .requestChanges, prs: prs)
        )
        let plan = PRActionsStatus.reviewPlan(candidates: prs, actions: actions)

        XCTAssertEqual(plan.submit.map(\.pr.url), [prs[2].url], "only the unreviewed PR is acted on")
        XCTAssertEqual(plan.stateUnknown.map(\.url), [prs[0].url], "unknown is its own bucket, not 'no review'")
        XCTAssertEqual(plan.alreadyApproved.map(\.url), [prs[1].url])
        XCTAssertTrue(plan.skippedByChoice.isEmpty)
    }

    /// Forcing an unreadable PR is allowed — the row's picker is enabled — and then it is acted on.
    func testUserCanOverrideAnUnknownStatePR() {
        let target = pr(1, statesKnown: false)
        let actions = PRActionChoices(
            review: .requestChanges, reviewComment: "why", merge: false, mergeMethod: "rebase",
            syncAssignee: false, reviewByPRURL: [target.url: .requestChanges]
        )
        let plan = PRActionsStatus.reviewPlan(candidates: [target], actions: actions)
        XCTAssertEqual(plan.submit.map(\.event), ["REQUEST_CHANGES"])
        XCTAssertTrue(plan.stateUnknown.isEmpty)
    }

    /// With no overrides the plan must match what the code did before per-PR selection existed.
    func testEmptyOverridesReproduceTheBlanketBehaviour() {
        let prs = [pr(1, approved: true), pr(2)]
        let approve = PRActionChoices(
            review: .approve, reviewComment: "", merge: false, mergeMethod: "rebase", syncAssignee: false
        )
        let plan = PRActionsStatus.reviewPlan(candidates: prs, actions: approve)
        XCTAssertEqual(plan.submit.map(\.pr.url), [prs[1].url], "the approved one is redundant, as before")
        XCTAssertEqual(plan.alreadyApproved.map(\.url), [prs[0].url])
    }

    func testBlankCommentPutsARequestChangesInTheWithheldBucket() {
        let prs = [pr(1)]
        let actions = PRActionChoices(
            review: .requestChanges, reviewComment: "   ", merge: false, mergeMethod: "rebase", syncAssignee: false
        )
        let plan = PRActionsStatus.reviewPlan(candidates: prs, actions: actions)
        XCTAssertTrue(plan.submit.isEmpty)
        XCTAssertEqual(plan.withheldForBlankComment.map(\.url), [prs[0].url])
    }

    func testRowStateReportsWhatIsKnown() {
        XCTAssertEqual(PRActionsStatus.rowState(pr(1)), "open · no review from you")
        XCTAssertEqual(PRActionsStatus.rowState(pr(1, approved: true)), "open · you approved")
        XCTAssertEqual(PRActionsStatus.rowState(pr(1, requestedChanges: true)), "open · you requested changes")
        XCTAssertEqual(PRActionsStatus.rowState(pr(1, draft: true)), "open · draft · no review from you")
        XCTAssertEqual(PRActionsStatus.rowState(pr(1, statesKnown: false)), "state unknown")
    }
}

/// Resolution of per-PR overrides against the blanket action. The empty-map case must behave exactly as
/// it did before per-PR selection existed.
final class PerPRResolutionTests: XCTestCase {

    private func choices(_ review: PRReviewAction, overrides: [String: PRReviewAction] = [:]) -> PRActionChoices {
        PRActionChoices(
            review: review, reviewComment: "why", merge: false, mergeMethod: "rebase",
            syncAssignee: false, reviewByPRURL: overrides
        )
    }

    func testEmptyMapFallsBackToTheBlanketActionForEveryPR() {
        let c = choices(.requestChanges)
        XCTAssertEqual(c.review(forPRAt: "https://github.com/o/r/pull/1"), .requestChanges)
        XCTAssertEqual(c.review(forPRAt: "anything"), .requestChanges)
    }

    func testOverrideWinsForItsOwnPROnly() {
        let c = choices(.requestChanges, overrides: ["a": .none, "b": .approve])
        XCTAssertEqual(c.review(forPRAt: "a"), PRReviewAction.none)
        XCTAssertEqual(c.review(forPRAt: "b"), .approve)
        XCTAssertEqual(c.review(forPRAt: "c"), .requestChanges, "unlisted PRs still follow the blanket")
    }

    func testHasWorkSeesAnOverrideEvenWhenTheBlanketIsNone() {
        XCTAssertFalse(choices(.none).hasWork)
        XCTAssertTrue(choices(.none, overrides: ["a": .requestChanges]).hasWork)
        XCTAssertFalse(choices(.none, overrides: ["a": .none]).hasWork, "all-skip is no work")
    }

    /// The mandatory-comment guard must hold per resolved action, not only for the blanket one.
    func testBlankCommentWithholdsARequestChangesOverride() {
        var c = PRActionChoices(
            review: .approve, reviewComment: "   ", merge: false, mergeMethod: "rebase",
            syncAssignee: false, reviewByPRURL: ["a": .requestChanges]
        )
        XCTAssertEqual(c.reviewEvent(for: .approve), "APPROVE", "approve needs no body")
        XCTAssertNil(c.reviewEvent(for: .requestChanges), "and the override is withheld, not sent bodyless")

        c.reviewComment = "needs a test"
        XCTAssertEqual(c.reviewEvent(for: .requestChanges), "REQUEST_CHANGES")
    }
}
