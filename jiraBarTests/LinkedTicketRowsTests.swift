import XCTest
@testable import jiraBar

/// The shapes below are trimmed from live Cloud search responses, with keys swapped for placeholders.
final class LinkedTicketRowsTests: XCTestCase {

    private func decode(_ fieldsJSON: String) throws -> Issue {
        let json = """
        {"id": "1", "key": "ABC-1", "fields": {
            "summary": "s", "status": {"name": "Open"}, "issuetype": {"name": "Task"},
            "project": {"name": "P"}, "assignee": null\(fieldsJSON)
        }}
        """
        return try JSONDecoder().decode(Issue.self, from: Data(json.utf8))
    }

    func testEpicAndBlockedBy() throws {
        let issue = try decode("""
        , "parent": {"id": "9", "key": "ABC-100", "fields": {"summary": "e", "issuetype": {"name": "Epic"}}},
          "issuelinks": [{"id": "5",
            "type": {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
            "inwardIssue": {"id": "2", "key": "ABC-2", "fields": {"summary": "x"}}}]
        """)
        let rows = AppDelegate.linkedTicketRows(for: issue)
        XCTAssertEqual(rows.map(\.title), ["Epic: ABC-100", "Blocked by: ABC-2"])
        XCTAssertEqual(rows.map(\.key), ["ABC-100", "ABC-2"])
    }

    func testOutwardSideUsesOutwardWording() throws {
        let issue = try decode("""
        , "issuelinks": [
            {"type": {"inward": "is blocked by", "outward": "blocks"}, "outwardIssue": {"key": "ABC-3"}},
            {"type": {"inward": "is duplicated by", "outward": "duplicates"}, "inwardIssue": {"key": "ABC-4"}},
            {"type": {"inward": "relates to", "outward": "relates to"}, "outwardIssue": {"key": "ABC-5"}}]
        """)
        XCTAssertEqual(
            AppDelegate.linkedTicketRows(for: issue).map(\.title),
            ["Blocks: ABC-3", "Duplicated by: ABC-4", "Relates to: ABC-5"]
        )
    }

    func testSubtaskParentIsNotCalledEpic() throws {
        let issue = try decode("""
        , "parent": {"key": "ABC-7", "fields": {"issuetype": {"name": "Story"}}}
        """)
        XCTAssertEqual(AppDelegate.linkedTicketRows(for: issue).map(\.title), ["Parent: ABC-7"])
    }

    func testNoEpicNoLinksGivesNoRows() throws {
        XCTAssertTrue(AppDelegate.linkedTicketRows(for: try decode("")).isEmpty)
        XCTAssertTrue(AppDelegate.linkedTicketRows(for: try decode(", \"issuelinks\": []")).isEmpty)
    }
}
