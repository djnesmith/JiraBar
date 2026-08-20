import XCTest
@testable import jiraBar

/// A 2xx from Jira means the string was accepted, not that anybody was mentioned — the same lesson
/// as the assignee write that returned 204 and discarded its value. These pin the read-back that
/// tells the two apart.
///
/// The ADF below is the shape a real Cloud instance returned after posting `[~accountid:<id>]`
/// through the v2 comment endpoint: the id becomes a `mention` node's `attrs.id`, while an
/// unrecognised `@Name` in the same paragraph stays a plain `text` node. Ids and names are invented.
final class MentionVerificationTests: XCTestCase {

    private let resolvedComment = Data("""
    {
      "id": "10001",
      "body": {
        "type": "doc",
        "version": 1,
        "content": [
          {
            "type": "paragraph",
            "content": [
              {"type": "text", "text": "heads up "},
              {"type": "mention", "attrs": {"id": "acct-a", "text": "@Ada Byron", "accessLevel": ""}},
              {"type": "text", "text": " and a literal @Ada Byron for contrast."}
            ]
          }
        ]
      }
    }
    """.utf8)

    private func body(of data: Data) -> Any? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["body"]
    }

    // MARK: - Reading mentions out of ADF

    func testFindsTheMentionNodesAccountId() {
        XCTAssertEqual(JiraClient.mentionIds(inADF: body(of: resolvedComment)), ["acct-a"])
    }

    /// The distinction the whole feature rests on: the literal "@Ada Byron" in that same paragraph
    /// contributes nothing, because plain text notifies nobody.
    func testPlainTextNamesAreNotMentions() {
        let plain = Data("""
        {"body": {"type": "doc", "content": [
          {"type": "paragraph", "content": [{"type": "text", "text": "@Ada Byron please look"}]}
        ]}}
        """.utf8)
        XCTAssertTrue(JiraClient.mentionIds(inADF: body(of: plain)).isEmpty)
    }

    func testFindsMentionsNestedDeeply() {
        let nested = Data("""
        {"body": {"type": "doc", "content": [
          {"type": "bulletList", "content": [
            {"type": "listItem", "content": [
              {"type": "paragraph", "content": [
                {"type": "mention", "attrs": {"id": "acct-deep"}}
              ]}
            ]}
          ]}
        ]}}
        """.utf8)
        XCTAssertEqual(JiraClient.mentionIds(inADF: body(of: nested)), ["acct-deep"])
    }

    func testMentionWalkToleratesJunk() {
        XCTAssertTrue(JiraClient.mentionIds(inADF: nil).isEmpty)
        XCTAssertTrue(JiraClient.mentionIds(inADF: "a wiki string").isEmpty)
        XCTAssertTrue(JiraClient.mentionIds(inADF: ["type": "mention"]).isEmpty)
        XCTAssertTrue(JiraClient.mentionIds(inADF: ["type": "mention", "attrs": ["id": ""]]).isEmpty)
    }

    // MARK: - Deciding whether the write landed

    func testNothingUnresolvedWhenEveryMentionCameBack() {
        XCTAssertTrue(JiraClient.unresolvedMentionIds(expected: ["acct-a"], found: ["acct-a"]).isEmpty)
    }

    func testReportsTheMentionsJiraDidNotResolve() {
        XCTAssertEqual(
            JiraClient.unresolvedMentionIds(expected: ["acct-a", "acct-b"], found: ["acct-a"]),
            ["acct-b"]
        )
    }

    func testUnresolvedIdsAreDeduplicatedAndInAskedOrder() {
        XCTAssertEqual(
            JiraClient.unresolvedMentionIds(expected: ["acct-b", "acct-a", "acct-b", ""], found: []),
            ["acct-b", "acct-a"]
        )
    }

    /// End to end over the pieces the network sits between: what the dialog would send, and what
    /// reading it back proves.
    func testExpectedIdsComeFromTheBodyThatWasActuallySent() {
        let mentions = [MentionText.Mention(token: "@Ada Byron", reference: "[~accountid:acct-a]")]
        let sent = MentionText.wikiBody(text: "heads up @Ada Byron", mentions: mentions)
        XCTAssertEqual(sent, "heads up [~accountid:acct-a]")

        let expected = MentionText.mentionedAccountIds(inWiki: sent)
        let found = JiraClient.mentionIds(inADF: body(of: resolvedComment))
        XCTAssertTrue(JiraClient.unresolvedMentionIds(expected: expected, found: found).isEmpty)
    }

    func testAMentionStoredAsPlainTextIsReportedUnresolved() {
        let plain = Data("""
        {"body": {"type": "doc", "content": [
          {"type": "paragraph", "content": [{"type": "text", "text": "[~accountid:acct-a]"}]}
        ]}}
        """.utf8)
        XCTAssertEqual(
            JiraClient.unresolvedMentionIds(
                expected: ["acct-a"], found: JiraClient.mentionIds(inADF: body(of: plain))
            ),
            ["acct-a"]
        )
    }
}

/// `/user/search` is not a directory of colleagues — on a live Cloud instance a one-letter query
/// returned 31 accounts of which 4 were people. The fixture mirrors that mix.
final class MentionableUsersTests: XCTestCase {

    private let searchResults = Data("""
    [
      {"accountId": "acct-1", "displayName": "Ada Byron", "emailAddress": "ada@example.invalid",
       "active": true, "accountType": "atlassian"},
      {"accountId": "acct-2", "displayName": "Automation for Jira", "active": true, "accountType": "app"},
      {"accountId": "acct-3", "displayName": "buyer@customer.invalid", "active": true, "accountType": "customer"},
      {"accountId": "acct-4", "displayName": "Alan Turing", "active": false, "accountType": "atlassian"},
      {"name": "aturing", "displayName": "Alan Turing", "active": true},
      {"name": "ghopper", "displayName": "Grace Hopper"}
    ]
    """.utf8)

    private func decoded() throws -> [JiraUser] {
        try JSONDecoder().decode([JiraUser].self, from: searchResults)
    }

    func testDecodesAccountType() throws {
        XCTAssertEqual(try decoded().map(\.accountType),
                       ["atlassian", "app", "customer", "atlassian", nil, nil])
    }

    func testKeepsPeopleAndDropsAppsCustomersAndDeactivatedAccounts() throws {
        let kept = JiraClient.mentionableUsers(try decoded())
        XCTAssertEqual(kept.map(\.displayName), ["Ada Byron", "Alan Turing", "Grace Hopper"])
    }

    /// Server/DC sends neither field. Absent has to mean "a real, active user", or a Server install
    /// would show an empty dropdown for everyone.
    func testMissingAccountTypeAndMissingActiveAreBothKept() throws {
        let serverRow = try decoded().last
        XCTAssertNil(serverRow?.accountType)
        XCTAssertNil(serverRow?.active)
        XCTAssertEqual(JiraClient.mentionableUsers([serverRow!]).map(\.name), ["ghopper"])
    }

    func testTypingAPrefixNarrowsToTheRealPerson() throws {
        let kept = JiraClient.mentionableUsers(try decoded())
        XCTAssertEqual(MentionText.ranked(kept, query: "byr").map(\.displayName), ["Ada Byron"])
    }
}
