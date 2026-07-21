import Foundation
import Defaults

enum JiraInstanceType: String, Defaults.Serializable {
    case cloud
    case server
}

enum JiraServerAuthType: String, Defaults.Serializable {
    /// Basic auth: username + password. For older Jira Server (pre-8.14).
    case basic
    /// Bearer token (PAT). For Jira Server 8.14+ and Data Center.
    case pat
}

extension Defaults.Keys {
    /// Jira Cloud email. Kept under the original key name so existing users are unaffected.
    static let jiraUsername = Key<String>("jiraUsername", default: "")
    /// Username for self-hosted Jira Server / Data Center. Separate key to avoid clobbering the Cloud email.
    static let jiraServerUsername = Key<String>("jiraServerUsername", default: "")
    
    static let orgName = Key<String>("orgName", default: "")
    /// Base URL for self-hosted Jira Server / Data Center instances.
    /// Ignored when instanceType == .cloud.
    static let jiraHost = Key<String>("jiraHost", default: "https://jira.example.com")
    static let jql = Key<String>("jql", default: "")
    
    static let refreshRate = Key<Int>("refreshRate", default: 5)
    static let maxResults = Key<String>("maxResults", default: "10")
    
    /// Defaults to .cloud so existing users are unaffected.
    static let instanceType = Key<JiraInstanceType>("instanceType", default: .cloud)
    /// Auth method for self-hosted Server. Defaults to .pat (modern default).
    static let serverAuthType = Key<JiraServerAuthType>("serverAuthType", default: .pat)

    /// User-supplied display order for status groups in the menu (case-insensitive match against
    /// Jira's `status.name`). Statuses not present in this list fall to the bottom, alphabetically.
    static let statusOrder = Key<[String]>("statusOrder", default: [])

    /// Optional dashboard URL. Accepts an absolute URL or a path that's appended to the Jira base URL.
    /// When non-empty, an "Open Dashboard" entry appears under "Open Search results" in the menu.
    static let dashboardURL = Key<String>("dashboardURL", default: "")

    /// Optional second dashboard URL — e.g. a board view filtered to just the current user's work.
    /// Same shape as `dashboardURL`; an "Open My Dashboard" entry appears below the first when set.
    static let myDashboardURL = Key<String>("myDashboardURL", default: "")

    /// Jira custom field id for the Flagged field (varies by install — commonly customfield_10021 on Cloud).
    /// When non-empty, an "Add Flag" entry appears in the per-issue submenu.
    static let flagFieldId = Key<String>("flagFieldId", default: "")

    /// Jira custom field id for the Rank field (the Lexorank field that powers Scrum/Kanban order).
    /// Commonly `customfield_10019` on Cloud. When set, issues inside each status group are sorted
    /// by rank ascending to match the board.
    static let rankFieldId = Key<String>("rankFieldId", default: "")

    /// Optional secondary JQL. When non-empty, an "Open All Issues" menu entry appears beneath
    /// "Open Search results" and opens Jira with this query. Intended for a broader "everything
    /// I've worked on" view that ignores the main JQL's filters (e.g. closed issues).
    static let allIssuesJQL = Key<String>("allIssuesJQL", default: "")

    /// Comma-separated GitHub orgs to fall back to when Jira's dev-status API returns no PRs
    /// for an issue. Requires a GitHub token. Searches GitHub for PRs whose title contains the
    /// issue key inside those orgs. Empty disables the fallback.
    static let githubSearchOrgs = Key<String>("githubSearchOrgs", default: "")
}

extension KeychainKeys {
    /// API token for Jira Cloud. Kept under the original key name so existing users are unaffected.
    static let jiraToken: KeychainAccessKey = KeychainAccessKey(key: "jiraToken")
    /// Password or PAT for self-hosted Jira Server / Data Center. Separate key to avoid clobbering the Cloud token.
    static let jiraServerToken: KeychainAccessKey = KeychainAccessKey(key: "jiraServerToken")
    /// GitHub PAT (classic or fine-grained). Used to enrich PR rows with review decision,
    /// unresolved review-thread count, and CI state via GitHub's GraphQL API. Optional —
    /// when empty, PR rows fall back to whatever Jira's dev-status API returns.
    static let gitHubToken: KeychainAccessKey = KeychainAccessKey(key: "gitHubToken")
}
