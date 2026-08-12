import XCTest
@testable import jiraBar

final class JiraClientParsingTests: XCTestCase {

    // MARK: - extractRanks

    private let searchJSON = Data("""
    {
      "issues": [
        {"key": "PROJ-1", "fields": {"summary": "a", "customfield_10019": "0|hzzzzz:"}},
        {"key": "PROJ-2", "fields": {"summary": "b", "customfield_10019": "0|hzzzza:"}},
        {"key": "PROJ-3", "fields": {"summary": "c"}}
      ]
    }
    """.utf8)

    func testExtractRanks() {
        let ranks = JiraClient.extractRanks(from: searchJSON, fieldId: "customfield_10019")
        XCTAssertEqual(ranks, ["PROJ-1": "0|hzzzzz:", "PROJ-2": "0|hzzzza:"])
    }

    func testExtractRanksEmptyFieldIdShortCircuits() {
        XCTAssertEqual(JiraClient.extractRanks(from: searchJSON, fieldId: ""), [:])
    }

    func testExtractRanksMalformedData() {
        XCTAssertEqual(JiraClient.extractRanks(from: Data("nope".utf8), fieldId: "customfield_10019"), [:])
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
