import XCTest
@testable import jiraBar

final class BoardTodoQueryTests: XCTestCase {

    // MARK: boardRef

    func testCloudBoardURLWithQuickFilter() {
        let ref = BoardTodoQuery.boardRef(
            fromDashboardURL: "https://example.atlassian.net/jira/software/c/projects/ABC/boards/12?quickFilter=34"
        )
        XCTAssertEqual(ref, .init(boardId: 12, quickFilterIds: [34]))
    }

    func testRepeatedQuickFiltersKeepOrderAndIgnoreOtherParams() {
        let ref = BoardTodoQuery.boardRef(
            fromDashboardURL: "/jira/software/c/projects/ABC/boards/12?assignee=acct-me&quickFilter=34&quickFilter=56"
        )
        XCTAssertEqual(ref, .init(boardId: 12, quickFilterIds: [34, 56]))
    }

    func testServerRapidBoardURL() {
        let ref = BoardTodoQuery.boardRef(
            fromDashboardURL: "https://jira.example.com/secure/RapidBoard.jspa?rapidView=19&quickFilter=5"
        )
        XCTAssertEqual(ref, .init(boardId: 19, quickFilterIds: [5]))
    }

    func testNonBoardURLsAreNil() {
        XCTAssertNil(BoardTodoQuery.boardRef(fromDashboardURL: ""))
        XCTAssertNil(BoardTodoQuery.boardRef(fromDashboardURL: "https://example.atlassian.net/jira/dashboards/10001"))
        XCTAssertNil(BoardTodoQuery.boardRef(fromDashboardURL: "/issues/?filter=10500"))
        XCTAssertNil(BoardTodoQuery.boardRef(fromDashboardURL: "/jira/software/c/projects/ABC/boards"))
    }

    // MARK: boardConfig

    /// Shaped like a Cloud kanban board's `/configuration`: Backlog precedes To Do, and the To Do
    /// column maps two statuses.
    private let kanbanConfig = """
    {"id":12,"name":"Team Board","type":"kanban",
     "filter":{"id":"10500","self":"x"},
     "subQuery":{"query":"fixVersion in unreleasedVersions() OR fixVersion is EMPTY"},
     "columnConfig":{"columns":[
       {"name":"Backlog","statuses":[{"id":"1","self":"x"}]},
       {"name":"To Do","statuses":[{"id":"4","self":"x"},{"id":"10000","self":"x"}]},
       {"name":"In Progress","statuses":[{"id":"3","self":"x"}]}]},
     "ranking":{"rankCustomFieldId":10100}}
    """

    func testKanbanConfigPicksToDoColumnAndSubQuery() {
        let config = BoardTodoQuery.boardConfig(from: Data(kanbanConfig.utf8))
        XCTAssertEqual(config, .init(
            filterId: "10500",
            subQuery: "fixVersion in unreleasedVersions() OR fixVersion is EMPTY",
            todoStatusIds: ["4", "10000"]
        ))
    }

    func testBoardWithoutToDoColumnIsNil() {
        let json = """
        {"filter":{"id":"1"},"columnConfig":{"columns":[{"name":"Open","statuses":[{"id":"1"}]}]}}
        """
        XCTAssertNil(BoardTodoQuery.boardConfig(from: Data(json.utf8)))
    }

    func testScrumConfigHasNoSubQuery() {
        let json = """
        {"filter":{"id":"7"},"columnConfig":{"columns":[{"name":"to do","statuses":[{"id":"10000"}]}]}}
        """
        XCTAssertEqual(
            BoardTodoQuery.boardConfig(from: Data(json.utf8)),
            .init(filterId: "7", subQuery: nil, todoStatusIds: ["10000"])
        )
    }

    // MARK: jql

    /// Same shape as a query checked against a live Cloud board: it returned the same keys in the
    /// same order as `/rest/agile/1.0/board/{id}/issue` for the To Do statuses under the quick filter.
    func testComposedJQLParenthesisesEachClause() {
        let config = BoardTodoQuery.boardConfig(from: Data(kanbanConfig.utf8))!
        let jql = BoardTodoQuery.jql(
            config: config,
            quickFilterJQLs: [#""Team[Select List (multiple choices)]" = "Data" OR labels = "data""#]
        )
        XCTAssertEqual(jql, #"filter = 10500 AND (fixVersion in unreleasedVersions() OR fixVersion is EMPTY) AND status in (4, 10000) AND ("Team[Select List (multiple choices)]" = "Data" OR labels = "data") ORDER BY Rank ASC"#)
    }

    func testQuickFilterJQL() {
        XCTAssertEqual(BoardTodoQuery.quickFilterJQL(from: Data(#"{"id":82,"jql":"labels = data"}"#.utf8)), "labels = data")
        XCTAssertNil(BoardTodoQuery.quickFilterJQL(from: Data(#"{"id":82,"jql":"  "}"#.utf8)))
    }

    // MARK: fallback

    func testBoardFailureDoesNotFallBackToTodoJQL() {
        XCTAssertEqual(AppDelegate.todoQuery(boardResult: .success("board"), fallback: "setting"), "board")
        XCTAssertEqual(AppDelegate.todoQuery(boardResult: .notApplicable, fallback: "setting"), "setting")
        XCTAssertNil(AppDelegate.todoQuery(boardResult: .failure, fallback: "setting"))
    }
}
