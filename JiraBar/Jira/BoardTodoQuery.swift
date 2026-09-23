import Foundation

/// Builds the TODO section's query from the agile board the Dashboard URL points at, so the list
/// is the board's own To Do column rather than a JQL kept in step with it by hand. A team moving
/// to another board then only means changing the Dashboard URL — the hand-kept JQL went on showing
/// the old board's column, which is how the TODO once led with a ticket the new board filters out.
///
/// The query is composed from what the board is made of, the way Jira itself evaluates a board
/// view: its saved filter, a kanban board's sub-filter, the statuses mapped to its To Do column,
/// and every quick filter in the URL (Jira ANDs selected quick filters together). Ordered by Rank,
/// which is what the board orders by. Run as a plain search rather than through
/// `/rest/agile/1.0/board/{id}/issue`, so the rows come back through the same path — flags, ranks,
/// the over-fetch — as a hand-written TODO JQL.
enum BoardTodoQuery {

    /// A board and the quick filters selected in its URL.
    struct BoardRef: Equatable {
        let boardId: Int
        let quickFilterIds: [Int]
    }

    /// The board a Dashboard URL shows, or nil when it isn't a board URL — a Jira dashboard, a
    /// filter, a search. Accepts Cloud's `/jira/software/c/projects/KEY/boards/N` and the
    /// older `/secure/RapidBoard.jspa?rapidView=N` Server shape. A path-only URL is fine, since
    /// only the path and query are read.
    static func boardRef(fromDashboardURL raw: String) -> BoardRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        let items = components.queryItems ?? []
        let quickFilters = items
            .filter { $0.name == "quickFilter" }
            .compactMap { $0.value.flatMap { Int($0) } }

        let parts = components.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "boards"), index + 1 < parts.count,
           let boardId = Int(parts[index + 1]) {
            return BoardRef(boardId: boardId, quickFilterIds: quickFilters)
        }
        if parts.last == "RapidBoard.jspa",
           let value = items.first(where: { $0.name == "rapidView" })?.value,
           let boardId = Int(value) {
            return BoardRef(boardId: boardId, quickFilterIds: quickFilters)
        }
        return nil
    }

    /// The pieces of `/rest/agile/1.0/board/{id}/configuration` the query needs.
    struct BoardConfig: Equatable {
        let filterId: String
        let subQuery: String?
        let todoStatusIds: [String]
    }

    /// Parses a board configuration response. The To Do column is the one named "To Do"; a board
    /// without one yields nil rather than a guess at which column means "next up", and the caller
    /// falls back to the TODO JQL setting.
    static func boardConfig(from data: Data) -> BoardConfig? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filter = json["filter"] as? [String: Any],
            let filterId = (filter["id"] as? String) ?? (filter["id"] as? Int).map(String.init),
            let columnConfig = json["columnConfig"] as? [String: Any],
            let columns = columnConfig["columns"] as? [[String: Any]],
            let todo = columns.first(where: {
                ($0["name"] as? String)?.caseInsensitiveCompare("To Do") == .orderedSame
            }),
            let statuses = todo["statuses"] as? [[String: Any]]
        else { return nil }
        let statusIds = statuses.compactMap { ($0["id"] as? String) ?? ($0["id"] as? Int).map(String.init) }
        guard !statusIds.isEmpty else { return nil }
        let sub = ((json["subQuery"] as? [String: Any])?["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BoardConfig(
            filterId: filterId,
            subQuery: (sub?.isEmpty ?? true) ? nil : sub,
            todoStatusIds: statusIds
        )
    }

    /// The `jql` of a `/rest/agile/1.0/board/{id}/quickfilter/{qf}` response.
    static func quickFilterJQL(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let jql = (json["jql"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !jql.isEmpty
        else { return nil }
        return jql
    }

    /// Every clause is parenthesised: a quick filter's JQL is often an OR, and unwrapped it would
    /// bind looser than the ANDs around it.
    static func jql(config: BoardConfig, quickFilterJQLs: [String]) -> String {
        var clauses = ["filter = \(config.filterId)"]
        if let sub = config.subQuery { clauses.append("(\(sub))") }
        clauses.append("status in (\(config.todoStatusIds.joined(separator: ", ")))")
        clauses += quickFilterJQLs.map { "(\($0))" }
        return clauses.joined(separator: " AND ") + " ORDER BY Rank ASC"
    }
}
