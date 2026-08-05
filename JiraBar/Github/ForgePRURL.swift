import Foundation

/// Parsed pieces of a forge (GitHub / Bitbucket / GitLab) PR or repo URL. Lenient on host so
/// non-GitHub slugs still parse for display; `pullNumber` is only set for the
/// /owner/repo/pull/<n> path shape. Callers that need github.com specifically (the REST /
/// GraphQL clients) check `isGithub`.
struct ForgePRURL {
    let scheme: String
    let host: String
    let owner: String
    let repo: String
    /// Set only when the path is /owner/repo/pull/<n>.
    let pullNumber: Int?

    init?(_ raw: String) {
        guard let url = URL(string: raw),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        // ["/", "owner", "repo", ...] — anything shallower isn't a repo path.
        let parts = url.pathComponents
        guard parts.count >= 3 else { return nil }
        self.scheme = scheme
        self.host = host
        self.owner = parts[1]
        self.repo = parts[2]
        if parts.count >= 5, parts[3] == "pull", let number = Int(parts[4]) {
            self.pullNumber = number
        } else {
            self.pullNumber = nil
        }
    }

    /// "owner/repo"
    var slug: String { "\(owner)/\(repo)" }

    /// "https://host/owner/repo"
    var repoBase: String { "\(scheme)://\(host)/\(owner)/\(repo)" }

    var isGithub: Bool { host.contains("github.com") }
}
