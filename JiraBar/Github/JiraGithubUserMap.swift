import Foundation

/// One row in the Jira↔GitHub user map file. `jiraDisplayName` is informational (helps a human
/// review the JSON); matching is by `jiraAccountId`.
struct JiraGithubUserMapping: Codable {
    var jiraAccountId: String
    var jiraDisplayName: String
    var githubLogin: String
}

/// File-format wrapper. `version` is present so future breaking changes can be detected without
/// misreading old files.
struct JiraGithubUserMapFile: Codable {
    var version: Int
    var mappings: [JiraGithubUserMapping]
}

/// Loads a Jira↔GitHub user map from a JSON file on disk. Path is user-configurable in
/// Preferences; the file itself is intentionally kept out of the repo since it contains
/// org-specific data. All lookups fail closed (nil / empty) so a missing or malformed file
/// just disables the GitHub-side integration without breaking Jira behavior.
struct JiraGithubUserMap {
    let mappings: [JiraGithubUserMapping]

    private let byJiraAccountId: [String: JiraGithubUserMapping]

    /// Case-folded set of all GitHub logins present in the map. Used to decide which
    /// requested-reviewer entries on a PR are "ours" to remove (anyone not in this set
    /// was added outside JiraBar and is left alone).
    let knownGithubLogins: Set<String>

    init(mappings: [JiraGithubUserMapping]) {
        self.mappings = mappings
        self.byJiraAccountId = Dictionary(
            mappings.map { ($0.jiraAccountId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.knownGithubLogins = Set(mappings.map { $0.githubLogin.lowercased() })
    }

    static let empty = JiraGithubUserMap(mappings: [])

    /// Loads a map file. Prefers a security-scoped bookmark (works from a sandboxed process
    /// across launches); falls back to reading the raw path if no bookmark is set (works when
    /// the file lives inside the sandbox container). Returns nil for empty/missing/unreadable/
    /// malformed inputs.
    static func load(fromPath path: String, bookmark: Data) -> JiraGithubUserMap? {
        if let url = resolveBookmark(bookmark) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { return decode(data) }
            return nil
        }
        // Fallback for when there's no bookmark but a raw path is set — only reads that the
        // sandbox permits will succeed (e.g. a file inside the container).
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> JiraGithubUserMap? {
        guard let decoded = try? JSONDecoder().decode(JiraGithubUserMapFile.self, from: data) else {
            return nil
        }
        return JiraGithubUserMap(mappings: decoded.mappings)
    }

    /// Resolves a stored security-scoped bookmark back to a URL. Returns nil if the bookmark
    /// is empty, stale beyond repair, or points to a file that has since been removed.
    private static func resolveBookmark(_ bookmark: Data) -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        return url
    }

    func githubLogin(forJiraAccountId accountId: String) -> String? {
        byJiraAccountId[accountId]?.githubLogin
    }
}
