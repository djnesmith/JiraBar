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

    /// Transition names JiraBar has actually seen, accumulated from the per-issue transitions the menu
    /// build already fetches. Read only by Preferences, to spot a prompt name that is a near-miss for a
    /// real one.
    ///
    /// Not a workflow listing — Jira returns only what is reachable from each issue's current status —
    /// so absence from this list proves nothing. See `unknownTransitionNameWarning`.
    ///
    /// Deliberately NOT included in settings backup/restore: it is an observation of one machine against
    /// one Jira instance, and importing another's sightings would produce confident wrong suggestions.
    static let seenTransitionNames = Key<[String]>("seenTransitionNames", default: [])

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

    /// Path to the JSON file mapping Jira accountIds to GitHub logins. See JiraGithubUserMap
    /// for the schema. Empty disables the GitHub PR reviewer/assignee integration entirely.
    /// Stored for display only — actual reads use the security-scoped bookmark below so the
    /// sandbox permits reading files outside the container across app launches.
    static let jiraGithubUserMapPath = Key<String>("jiraGithubUserMapPath", default: "")

    /// Security-scoped bookmark data for the same file. Populated when the user picks the file
    /// via NSOpenPanel; empty otherwise. `JiraGithubUserMap.load` resolves this to a URL and
    /// wraps the read in `startAccessingSecurityScopedResource` so the sandbox lets it through.
    static let jiraGithubUserMapBookmark = Key<Data>("jiraGithubUserMapBookmark", default: Data())

    /// The Jira custom-field id whose user value(s) should be mirrored as GitHub PR requested
    /// reviewers. Empty disables the mirror. Configurable per install — most orgs use a custom
    /// "Reviewers" user-picker field; the exact id varies per Jira instance.
    static let githubPRReviewerJiraFieldId = Key<String>("githubPRReviewerJiraFieldId", default: "")

    /// Optional JQL for the TODO section — a "what would I pick up next" backlog view, which
    /// the main JQL typically can't show because it's scoped to the current user. When non-empty
    /// a TODO entry appears in the menu whose submenu lists the matching tickets, each with the
    /// same submenu a ticket gets in the main list. Empty disables the section.
    static let todoJQL = Key<String>("todoJQL", default: "")

    /// Cap on tickets listed in the TODO submenu. Separate from `maxResults` because a backlog
    /// view usually wants a different depth than the main ticket list.
    static let todoMaxResults = Key<String>("todoMaxResults", default: "15")

    /// JQL for the Recently Closed section. Empty switches the section off.
    ///
    /// `statusCategoryChangedDate` rather than `resolutiondate`: verified against a live instance, where
    /// resolutions are not set by these transitions, so a third of the rows came back with
    /// `resolutiondate = None` — and NULLs sort first under DESC, crowding out the genuinely recent
    /// tickets. `statusCategoryChangedDate` is the field that means "when did this become Done" and is
    /// populated where the other is not.
    ///
    /// Deliberately not scoped to any project: `statusCategory = Done` means different things in different
    /// workflows — one instance had a "General Availability" status counting as Done — so a multi-project
    /// query can surface tickets nobody would call closed. Narrow it with `AND project in (…)` for your
    /// own projects; that belongs in your settings, not in this default.
    static let recentlyClosedJQL = Key<String>(
        "recentlyClosedJQL",
        default: "assignee = currentUser() AND statusCategory = Done ORDER BY statusCategoryChangedDate DESC"
    )
    static let recentlyClosedMaxResults = Key<String>("recentlyClosedMaxResults", default: "10")

    /// How many recently-approved PRs to list. The section is scoped by GitHub Search Orgs, the same
    /// setting PRs Without Tickets uses, so it needs no query of its own.
    static let recentlyApprovedMaxResults = Key<String>("recentlyApprovedMaxResults", default: "10")
    /// Whether to show the Recently Approved section at all.
    static let showRecentlyApprovedSection = Key<Bool>("showRecentlyApprovedSection", default: true)

    /// Shows the "PRs Without Tickets" menu section: open GitHub PRs the user authored, is
    /// assigned to, or has been asked to review, minus any associated with a Jira ticket.
    /// Default on — the section is already gated on a GitHub token and hides itself when empty,
    /// so it costs nothing for users who haven't configured GitHub. Scoped by
    /// `githubSearchOrgs` when set.
    ///
    /// The key name predates the section's rename from "My PRs" and is deliberately unchanged:
    /// renaming it would orphan the stored value and silently reset the user's preference.
    static let showMyPRsSection = Key<Bool>("showMyPRsSection", default: true)
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
