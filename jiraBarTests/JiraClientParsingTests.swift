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
