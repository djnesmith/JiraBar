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
    var assignee: User?
    
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

struct User: Codable {
    var name: String?
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case name
        case displayName
    }
}

//
// MARK: assignable users
//
struct JiraUser: Codable, Identifiable, Hashable {
    /// Stable identifier for SwiftUI lists. Prefers accountId (Cloud) and falls back to name/key (Server).
    var id: String {
        if let accountId, !accountId.isEmpty { return "cloud:\(accountId)" }
        if let name, !name.isEmpty { return "name:\(name)" }
        if let key, !key.isEmpty { return "key:\(key)" }
        return "display:\(displayName)"
    }

    /// Cloud-only stable identifier.
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

    /// "owner/repo" parsed from the URL path, or empty if the URL doesn't look like a forge PR.
    var repoSlug: String {
        guard let u = URL(string: url) else { return "" }
        // /<owner>/<repo>/pull/<number>  →  ["/", "owner", "repo", "pull", "<n>"]
        let parts = u.pathComponents
        guard parts.count >= 3 else { return "" }
        return "\(parts[1])/\(parts[2])"
    }

    /// "42" — leading # stripped.
    var numberOnly: String {
        id.hasPrefix("#") ? String(id.dropFirst()) : id
    }
}
