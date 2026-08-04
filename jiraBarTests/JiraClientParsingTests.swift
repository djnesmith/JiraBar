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
