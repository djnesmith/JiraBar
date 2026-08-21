import XCTest
@testable import jiraBar

final class JiraClientParsingTests: XCTestCase {

    // MARK: - extractIssueExtras

    private let rankFieldId = "customfield_11111"

    private let searchJSON = Data("""
    {
      "issues": [
        {"key": "PROJ-1", "fields": {"summary": "a", "customfield_11111": "0|hzzzzz:"}},
        {"key": "PROJ-2", "fields": {"summary": "b", "customfield_11111": "0|hzzzza:"}},
        {"key": "PROJ-3", "fields": {"summary": "c"}}
      ]
    }
    """.utf8)

    func testExtractRanks() {
        let extras = JiraClient.extractIssueExtras(from: searchJSON, rankFieldId: rankFieldId, flagFieldId: "")
        XCTAssertEqual(extras.ranks, ["PROJ-1": "0|hzzzzz:", "PROJ-2": "0|hzzzza:"])
    }

    func testExtractRanksEmptyFieldIdShortCircuits() {
        let extras = JiraClient.extractIssueExtras(from: searchJSON, rankFieldId: "", flagFieldId: "")
        XCTAssertEqual(extras.ranks, [:])
    }

    func testExtractRanksMalformedData() {
        let extras = JiraClient.extractIssueExtras(
            from: Data("nope".utf8), rankFieldId: rankFieldId, flagFieldId: ""
        )
        XCTAssertEqual(extras.ranks, [:])
    }

    // MARK: - extractErrorMessage

    func testExtractErrorMessagePrefersErrorMessages() {
        let data = Data(#"{"errorMessages": ["Transition is not valid"], "errors": {}}"#.utf8)
        XCTAssertEqual(JiraClient.extractErrorMessage(from: data), "Transition is not valid")
    }

    func testExtractErrorMessageFallsBackToErrorsDict() {
        let data = Data(#"{"errorMessages": [], "errors": {"resolution": "Field required"}}"#.utf8)
        XCTAssertEqual(JiraClient.extractErrorMessage(from: data), "resolution: Field required")
    }

    func testExtractErrorMessageNilCases() {
        XCTAssertNil(JiraClient.extractErrorMessage(from: nil))
        XCTAssertNil(JiraClient.extractErrorMessage(from: Data("{}".utf8)))
        XCTAssertNil(JiraClient.extractErrorMessage(from: Data("not json".utf8)))
    }
}

/// The flag is a three-state answer — flagged, not flagged, unknown — and the whole design rests on
/// unknown staying distinct from not-flagged, so it is pinned here rather than reasoned about.
///
/// Field ids and option ids below are invented. The live Cloud shape they follow is a `null` for an
/// unflagged issue and a one-element array of option objects for a flagged one.
final class FlagStateParsingTests: XCTestCase {

    private let flagFieldId = "customfield_99999"

    private func fields(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    // MARK: - isFlagged

    func testFlaggedIssueReadsTrue() {
        let f = fields(#"{"customfield_99999": [{"value": "Impediment", "id": "10019"}]}"#)
        XCTAssertEqual(JiraClient.isFlagged(fields: f, fieldId: flagFieldId), true)
    }

    func testExplicitNullIsAKnownNotFlagged() {
        let f = fields(#"{"customfield_99999": null}"#)
        XCTAssertEqual(JiraClient.isFlagged(fields: f, fieldId: flagFieldId), false,
                       "Jira's own shape for an unflagged issue — a real answer, not an absence")
    }

    func testEmptyArrayIsAKnownNotFlagged() {
        let f = fields(#"{"customfield_99999": []}"#)
        XCTAssertEqual(JiraClient.isFlagged(fields: f, fieldId: flagFieldId), false)
    }

    /// The one that matters: a field Jira never mentioned cannot be reported as unflagged, or the
    /// menu offers "Add Flag" on a ticket that already carries one.
    func testFieldAbsentIsUnknown() {
        XCTAssertNil(JiraClient.isFlagged(fields: fields(#"{"summary": "a"}"#), fieldId: flagFieldId))
    }

    /// A bare option object is what a single-select field would answer with. Unknown rather than
    /// flagged, because `flagFieldPayload` only writes arrays — reading it as flagged would offer a
    /// "Remove Flag" whose write that field cannot take.
    func testBareOptionObjectIsUnknown() {
        let f = fields(#"{"customfield_99999": {"value": "Impediment", "id": "10019"}}"#)
        XCTAssertNil(JiraClient.isFlagged(fields: f, fieldId: flagFieldId))
    }

    func testUnrecognisedShapeIsUnknown() {
        XCTAssertNil(JiraClient.isFlagged(fields: fields(#"{"customfield_99999": "Impediment"}"#),
                                          fieldId: flagFieldId))
    }

    // MARK: - extractIssueExtras, flag half

    private let searchJSON = Data("""
    {
      "issues": [
        {"key": "PROJ-1", "fields": {"customfield_99999": [{"value": "Impediment", "id": "10019"}]}},
        {"key": "PROJ-2", "fields": {"customfield_99999": null}},
        {"key": "PROJ-3", "fields": {"summary": "not on this issue's screen"}}
      ]
    }
    """.utf8)

    func testOnlyKnownAnswersAreRecorded() {
        let extras = JiraClient.extractIssueExtras(from: searchJSON, rankFieldId: "", flagFieldId: flagFieldId)
        XCTAssertEqual(extras.flags, ["PROJ-1": true, "PROJ-2": false])
        XCTAssertNil(extras.flags["PROJ-3"], "absent, so unknown — and unknown is not a dictionary entry")
    }

    func testNoFlagFieldConfiguredYieldsNoAnswers() {
        let extras = JiraClient.extractIssueExtras(from: searchJSON, rankFieldId: "", flagFieldId: "")
        XCTAssertEqual(extras.flags, [:])
    }

    func testMalformedDataYieldsNoAnswers() {
        let extras = JiraClient.extractIssueExtras(
            from: Data("nope".utf8), rankFieldId: "", flagFieldId: flagFieldId
        )
        XCTAssertEqual(extras.flags, [:])
    }

    func testRankAndFlagComeOutOfTheSamePass() {
        let data = Data("""
        {"issues": [{"key": "PROJ-1", "fields": {
          "customfield_11111": "0|hzzzzz:",
          "customfield_99999": [{"value": "Impediment", "id": "10019"}]
        }}]}
        """.utf8)
        let extras = JiraClient.extractIssueExtras(
            from: data, rankFieldId: "customfield_11111", flagFieldId: flagFieldId
        )
        XCTAssertEqual(extras.ranks, ["PROJ-1": "0|hzzzzz:"])
        XCTAssertEqual(extras.flags, ["PROJ-1": true])
    }

    // MARK: - flagFieldPayload

    func testPayloadRaisesOneOption() {
        XCTAssertEqual(
            JiraClient.flagFieldPayload(flagged: true, optionValue: "Impediment"),
            [["value": "Impediment"]]
        )
    }

    func testPayloadClearsWithAnEmptyArray() {
        XCTAssertEqual(JiraClient.flagFieldPayload(flagged: false, optionValue: "Impediment"), [])
    }

    // MARK: - the read-back verdict

    func testWriteLandedWhenTheReadBackAgrees() {
        XCTAssertTrue(JiraClient.flagWriteLanded(readBack: true, wanted: true))
        XCTAssertTrue(JiraClient.flagWriteLanded(readBack: false, wanted: false))
    }

    /// The bug this guard exists for: Jira answers 2xx, discards the value, and the app says it
    /// worked. A read-back that disagrees is the only evidence available, and it wins.
    func testDiscardedWriteIsNotSuccess() {
        XCTAssertFalse(JiraClient.flagWriteLanded(readBack: false, wanted: true),
                       "asked to flag, still unflagged — accepted but not applied")
        XCTAssertFalse(JiraClient.flagWriteLanded(readBack: true, wanted: false),
                       "asked to clear, still flagged")
    }

    func testUnreadableFieldIsNotTreatedAsAFailure() {
        XCTAssertTrue(JiraClient.flagWriteLanded(readBack: nil, wanted: true),
                      "no answer is not evidence the write was dropped")
        XCTAssertTrue(JiraClient.flagWriteLanded(readBack: nil, wanted: false))
    }

    // MARK: - the menu label

    func testMenuLabelFollowsTheState() {
        XCTAssertEqual(AppDelegate.flagItemTitle(flagged: true), "Remove Flag")
        XCTAssertEqual(AppDelegate.flagItemTitle(flagged: false), "Add Flag")
        XCTAssertEqual(AppDelegate.flagItemTitle(flagged: nil), "Add Flag",
                       "unknown leaves the label as it has always been rather than guessing")
    }
}

/// `requiredFieldIds` decides fail-closed for the whole required-field gate, so the nil-vs-empty-set
/// distinction is pinned here rather than reasoned about.
final class RequiredFieldIdsParsingTests: XCTestCase {

    func testReadsRequiredFlags() {
        let ids = JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"41","fields":{
          "customfield_10030":{"required":false,"name":"Testers"},
          "resolution":{"required":true,"name":"Resolution"}
        }}]}
        """.utf8), transitionId: "41")
        XCTAssertEqual(ids, ["resolution"], "only the flagged one, and required:false is not required")
    }

    /// The live shape that motivated the manual override: the transition rejects for a missing
    /// tester while reporting the field as not required.
    func testTestersReportedNotRequiredYieldsAnEmptySetNotNil() {
        let ids = JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"41","fields":{"customfield_10030":{"required":false,"name":"Testers"}}}]}
        """.utf8), transitionId: "41")
        XCTAssertEqual(ids, [], "a known answer: Jira says nothing is required here")
    }

    func testTransitionPresentWithNoFieldsIsAKnownEmptyAnswer() {
        XCTAssertEqual(JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"81","fields":{}}]}
        """.utf8), transitionId: "81"), [])

        XCTAssertEqual(JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"81"}]}
        """.utf8), transitionId: "81"), [], "no fields key at all is still an answer")
    }

    // MARK: - everything below must be nil: unknown, so the caller fails closed

    func testAbsentTransitionIsUnknownNotEmpty() {
        XCTAssertNil(
            JiraClient.requiredFieldIds(from: Data("""
            {"transitions":[{"id":"21","fields":{}}]}
            """.utf8), transitionId: "41"),
            "the transition we asked about is gone — that is not a statement about its fields"
        )
    }

    func testMalformedPayloadsAreUnknown() {
        XCTAssertNil(JiraClient.requiredFieldIds(from: Data("not json".utf8), transitionId: "41"))
        XCTAssertNil(JiraClient.requiredFieldIds(from: Data("{}".utf8), transitionId: "41"))
        XCTAssertNil(JiraClient.requiredFieldIds(from: Data(#"{"transitions":{}}"#.utf8), transitionId: "41"))
        XCTAssertNil(JiraClient.requiredFieldIds(from: nil, transitionId: "41"))
    }

    /// A shape we don't understand must not read as "not required".
    func testNonBooleanRequiredIsUnknown() {
        XCTAssertNil(JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"41","fields":{"resolution":{"required":"true"}}}]}
        """.utf8), transitionId: "41"))

        XCTAssertNil(JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"41","fields":{"resolution":"nonsense"}}]}
        """.utf8), transitionId: "41"))
    }

    /// Jira omitting `required` is documented as false, and that is an answer.
    func testAbsentRequiredKeyIsTreatedAsNotRequired() {
        XCTAssertEqual(JiraClient.requiredFieldIds(from: Data("""
        {"transitions":[{"id":"41","fields":{"resolution":{"name":"Resolution"}}}]}
        """.utf8), transitionId: "41"), [])
    }
}

/// The mapping that turns a read into a gate. `finish(nil)` is the fail-closed entry point.
final class TransitionFieldRequirementsTests: XCTestCase {

    func testFailedFetchIsUnknownAndFlagged() {
        let requirements = TransitionFieldRequirements()
        XCTAssertTrue(requirements.loading)

        requirements.finish(nil)
        XCTAssertFalse(requirements.loading)
        XCTAssertTrue(requirements.fetchFailed, "the dialog fails closed off this flag")
        XCTAssertTrue(requirements.requiredFieldIds.isEmpty)
    }

    /// Empty is not unknown: a successful read saying "nothing required" must not block.
    func testEmptySetIsASuccessfulAnswer() {
        let requirements = TransitionFieldRequirements()
        requirements.finish([])
        XCTAssertFalse(requirements.loading)
        XCTAssertFalse(requirements.fetchFailed)
        XCTAssertTrue(requirements.requiredFieldIds.isEmpty)
    }

    func testRequiredIdsAreKept() {
        let requirements = TransitionFieldRequirements()
        requirements.finish(["resolution", "customfield_99002"])
        XCTAssertFalse(requirements.fetchFailed)
        XCTAssertEqual(requirements.requiredFieldIds, ["resolution", "customfield_99002"])
    }
}

/// Reading a user-picker field's current value. The distinction that matters is unknown vs empty: only a
/// field that is present and holds nobody may be reported as empty, because "empty" is what makes the
/// menu offer to add someone and what makes a picker safe to submit.
final class FieldUsersParsingTests: XCTestCase {

    private let alice: [String: Any] = ["displayName": "Alice Example", "accountId": "a1"]

    /// Jira omits the key entirely for a field that is not on the issue's screen — verified live. That is
    /// unknown, not empty.
    func testAbsentFieldIsUnknown() {
        XCTAssertNil(JiraClient.fieldUsers(from: [:], fieldId: "customfield_99001"))
        XCTAssertNil(
            JiraClient.fieldUsers(from: ["customfield_other": [alice]], fieldId: "customfield_99001"),
            "another field being present says nothing about this one"
        )
    }

    /// An explicit null is a real answer: the field exists and holds nobody.
    func testExplicitNullIsEmpty() {
        XCTAssertEqual(JiraClient.fieldUsers(from: ["f": NSNull()], fieldId: "f")?.count, 0)
    }

    func testEmptyArrayIsEmpty() {
        XCTAssertEqual(JiraClient.fieldUsers(from: ["f": [[String: Any]]()], fieldId: "f")?.count, 0)
    }

    func testMultiUserFieldReturnsEveryUser() {
        let bob: [String: Any] = ["displayName": "Bob Example", "accountId": "b1"]
        let users = JiraClient.fieldUsers(from: ["f": [alice, bob]], fieldId: "f")
        XCTAssertEqual(users?.map(\.displayName), ["Alice Example", "Bob Example"])
    }

    /// A single-user field such as assignee arrives as an object rather than an array.
    func testSingleUserFieldReturnsOneUser() {
        let users = JiraClient.fieldUsers(from: ["assignee": alice], fieldId: "assignee")
        XCTAssertEqual(users?.map(\.displayName), ["Alice Example"])
    }

    /// A shape we don't understand is unknown, not empty — the same rule as the absent key.
    func testUnrecognisedShapeIsUnknown() {
        XCTAssertNil(JiraClient.fieldUsers(from: ["f": "a string"], fieldId: "f"))
        XCTAssertNil(JiraClient.fieldUsers(from: ["f": 42], fieldId: "f"))
    }
}

/// Parsing the two reviewer connections. A missing connection is unknown; a Team reviewer is a reviewer.
final class ReviewerConnectionParsingTests: XCTestCase {

    func testAbsentConnectionIsUnknown() {
        XCTAssertNil(GithubClient.pendingReviewers(fromConnection: nil))
        XCTAssertNil(GithubClient.reviews(fromConnection: nil))
        XCTAssertNil(GithubClient.pendingReviewers(fromConnection: ["unexpected": 1]))
    }

    func testEmptyConnectionIsAKnownEmptyAnswer() {
        XCTAssertEqual(GithubClient.pendingReviewers(fromConnection: ["nodes": [[String: Any]]()])?.count, 0)
        XCTAssertEqual(GithubClient.reviews(fromConnection: ["nodes": [[String: Any]]()])?.count, 0)
    }

    func testUserReviewerReadsItsLogin() {
        let connection: [String: Any] = ["nodes": [["requestedReviewer": ["login": "jdoe"]]]]
        XCTAssertEqual(GithubClient.pendingReviewers(fromConnection: connection), ["jdoe"])
    }

    /// A requested reviewer can be a Team, which has a name and no login. Dropping it made the row claim
    /// "no reviewers" for a PR that has one.
    func testTeamReviewerReadsItsName() {
        let connection: [String: Any] = ["nodes": [["requestedReviewer": ["name": "data-platform"]]]]
        XCTAssertEqual(GithubClient.pendingReviewers(fromConnection: connection), ["data-platform"])
    }

    func testReviewerNodeWithNeitherIsSkipped() {
        let connection: [String: Any] = ["nodes": [["requestedReviewer": [String: Any]()]]]
        XCTAssertEqual(GithubClient.pendingReviewers(fromConnection: connection), [])
    }

    func testReviewsReadAuthorAndState() {
        let connection: [String: Any] = [
            "nodes": [
                ["state": "APPROVED", "author": ["login": "jdoe"]],
                ["state": "CHANGES_REQUESTED", "author": ["login": "alice"]],
            ]
        ]
        let reviews = GithubClient.reviews(fromConnection: connection)
        XCTAssertEqual(reviews?.map(\.login), ["jdoe", "alice"])
        XCTAssertEqual(reviews?.map(\.state), ["APPROVED", "CHANGES_REQUESTED"])
    }

    /// A review from a deleted account has a null author and cannot be attributed.
    func testReviewWithoutAnAuthorIsSkipped() {
        let connection: [String: Any] = ["nodes": [["state": "APPROVED"]]]
        XCTAssertEqual(GithubClient.reviews(fromConnection: connection)?.count, 0)
    }
}
