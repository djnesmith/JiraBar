import Foundation
//
// MARK: issues
//
struct JiraResponse: Codable {
    /// Present in Jira Cloud responses only; absent in Server/Data Center.
    var isLast: Bool?
    var issues: [Issue]?
}

struct Issue: Codable {
    /// Numeric internal id (returned as a string by the search API). Needed for the dev-status
    /// endpoint, which accepts issueId but not issueKey.
    var id: String
    var key: String
    var fields: Fields

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case fields
    }
}

struct Fields: Codable {
    var summary: String
    var status: IssueStatus
    var issuetype: IssueType
    var project: Project
    var assignee: JiraUser?
    
    enum CodingKeys: String, CodingKey {
        case summary
        case status
        case issuetype
        case project
        case assignee
    }
}

struct IssueStatus: Codable {
    var name: String
    var iconUrl: URL?
    
    enum CodingKeys: String, CodingKey {
        case name
        case iconUrl
    }
}

struct IssueType: Codable {
    var name: String
    
    enum CodingKeys: String, CodingKey {
        case name
    }
}

struct Project: Codable {
    var name: String
    
    enum CodingKeys: String, CodingKey {
        case name
    }
}

//
// MARK: users
//
struct JiraUser: Codable, Identifiable, Hashable {
    /// Stable identifier for SwiftUI lists. Prefers accountId (Cloud) and falls back to name/key (Server).
    var id: String {
        if let accountId, !accountId.isEmpty { return "cloud:\(accountId)" }
        if let name, !name.isEmpty { return "name:\(name)" }
        if let key, !key.isEmpty { return "key:\(key)" }
        return "display:\(displayName)"
    }

    /// Cloud-only stable identifier. A search response's assignee carries this and omits `name`
    /// entirely on Cloud, so it is the only field that identifies the assignee there.
    var accountId: String?
    /// Server/Data Center username.
    var name: String?
    /// Older Server "key" identifier, retained for compatibility.
    var key: String?
    var displayName: String
    var emailAddress: String?
    var active: Bool?

    enum CodingKeys: String, CodingKey {
        case accountId
        case name
        case key
        case displayName
        case emailAddress
        case active
    }

    /// Whether this is the same person as `other`. Cloud identifies by accountId, Server/DC by
    /// username and older installs by key — deliberately not displayName, which is not unique and
    /// would confuse a namesake for the user.
    func isSame(as other: JiraUser?) -> Bool {
        guard let other else { return false }
        if let x = accountId, let y = other.accountId, !x.isEmpty, !y.isEmpty { return x == y }
        if let x = name, let y = other.name, !x.isEmpty, !y.isEmpty { return x == y }
        if let x = key, let y = other.key, !x.isEmpty, !y.isEmpty { return x == y }
        return false
    }
}

//
// MARK: transitions
//
struct TransitionsResponse: Codable {
    var transitions: [Transition]
    
    enum CodingKeys: String, CodingKey {
        case transitions
    }
}

struct Transition: Codable {
    var name: String
    var id: String

    enum CodingKeys: String, CodingKey {
        case name
        case id
    }
}

//
// MARK: dev-status (linked PRs)
//
struct JiraDevStatusResponse: Codable {
    var detail: [JiraDevStatusDetail]
}

struct JiraDevStatusDetail: Codable {
    var pullRequests: [JiraPullRequest]
}

struct JiraPullRequest: Codable, Hashable {
    /// e.g. "#42" or "42" depending on the application. Render with the leading # stripped.
    var id: String
    /// PR title.
    var name: String
    /// Full PR URL on the source forge (e.g. github.com).
    var url: String
    /// "OPEN" / "MERGED" / "DECLINED" — useful for filtering or coloring.
    var status: String
    /// Per-reviewer approval flags reported by the source forge (present when the integration
    /// includes reviews). Absent on branches / commits, and on integrations that don't surface it.
    var reviewers: [JiraPRReviewer]?

    /// "owner/repo" parsed from the URL path, or empty if the URL doesn't look like a forge PR.
    var repoSlug: String {
        ForgePRURL(url)?.slug ?? ""
    }

    /// "42" — leading # stripped.
    var numberOnly: String {
        id.hasPrefix("#") ? String(id.dropFirst()) : id
    }

    /// `true` when at least one reviewer has approved.
    var isApproved: Bool {
        (reviewers ?? []).contains { $0.approved == true }
    }
}

struct JiraPRReviewer: Codable, Hashable {
    var name: String?
    var approved: Bool?
}
