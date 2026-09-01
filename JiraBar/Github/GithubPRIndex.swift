//
//  GithubPRIndex.swift
//  jiraBar
//

import Foundation

/// The one call `GithubPRIndex` makes, behind a protocol so its caching, coalescing and
/// rate-limit handling are testable without a network.
protocol PRSearching {
    func searchPRs(
        query: String,
        page: Int,
        perPage: Int,
        token: String,
        completion: @escaping (Result<GithubClient.PRSearchPage, GithubClient.SearchFailure>) -> Void
    )
}

extension GithubClient: PRSearching {}

/// The PRs one project-wide GitHub search returned, held so every ticket in the menu can be
/// answered from memory rather than from a search request of its own.
struct ProjectPRSnapshot {
    let fetchedAt = Date()
    /// Each hit with its lowercased title alongside, because the per-ticket match is a
    /// case-insensitive substring test on the full issue key — see `prs(forIssueKey:)`.
    let hits: [(pr: JiraPullRequest, lowercasedTitle: String)]
    /// True when GitHub had more matches than we fetched, or when a later page failed. A ticket
    /// whose only PR fell outside the window then reads as "no PRs", so this is logged where it
    /// is set.
    let truncated: Bool

    init(prs: [JiraPullRequest], truncated: Bool) {
        self.hits = prs.map { ($0, $0.name.lowercased()) }
        self.truncated = truncated
    }

    /// The PRs whose title carries this exact issue key, case-insensitively.
    func prs(forIssueKey key: String) -> [JiraPullRequest] {
        let needle = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return hits.filter { ProjectPRSnapshot.title($0.lowercasedTitle, carries: needle) }.map(\.pr)
    }

    /// Whether an already-lowercased title carries an already-lowercased issue key.
    ///
    /// Matched on the **full** key. GitHub's search tokenizes on the hyphen, so no query can tell
    /// `PROJ-42` from `OTHER-42` — it matches on the numeric half — and searching a whole project
    /// widens that further. This check is the only thing keeping one ticket's PRs off another's row.
    ///
    /// A substring test, except that the key may not be followed by another digit: a key can be a
    /// prefix of a longer key in the same project, and a plain `contains` hung `PROJ-42`'s row off
    /// `PROJ-420`'s PR. Left-permissive on purpose — a branch-style title like `fix/PROJ-42` still
    /// matches, and tightening that end would silently drop PRs.
    static func title(_ lowercasedTitle: String, carries lowercasedKey: String) -> Bool {
        var from = lowercasedTitle.startIndex
        while let found = lowercasedTitle.range(
            of: lowercasedKey, range: from..<lowercasedTitle.endIndex
        ) {
            if found.upperBound == lowercasedTitle.endIndex
                || !lowercasedTitle[found.upperBound].isNumber {
                return true
            }
            from = lowercasedTitle.index(after: found.lowerBound)
        }
        return false
    }

    func isFresh(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(fetchedAt) < ttl
    }
}

/// Answers "which GitHub PRs mention this ticket?" with a bounded number of search requests per
/// refresh instead of one per ticket.
///
/// **The constraint.** GitHub's search endpoint allows 30 requests per minute — two orders of
/// magnitude tighter than core's 5000/hour, and the only GitHub budget this app can realistically
/// exhaust. The menu asks this question for every row it builds: each ticket in the main list on
/// every rebuild, plus each TODO / Recently Closed / Recently Seen row as its submenu opens. Asked
/// per ticket that empties the budget in one pass over the menu, and GitHub answers the rest with a
/// 403 that used to render identically to "this ticket has no PRs" — PRs that appear and then
/// vanish. Everything here follows from that: one search per *project*, cached for `ttl`, matched
/// locally, and a refusal never cached as an absence.
final class GithubPRIndex {
    static let shared = GithubPRIndex()

    /// How long a project's snapshot stands, in seconds.
    ///
    /// Sixty is picked against the two limits it sits between. The refresh hook fires on every
    /// ticket transition (Darwin notification, debounced 1s in `RefreshDebouncer`), so a burst of
    /// refreshes has to cost one search between them — and 60s is the window the search budget
    /// resets on, so at worst a project asks for one slot of thirty. Against that, a PR opened
    /// right now should show up without a long wait, which rules out holding it longer. The
    /// trade-off: a manual Refresh inside that window re-uses the snapshot rather than re-querying
    /// GitHub, which is the point — three refreshes in a minute costing three searches is the bug.
    let ttl: TimeInterval

    /// How long to stop searching a project after GitHub says the budget is gone.
    ///
    /// Without this, a rate-limited project caches nothing (a refusal is not an absence), so every
    /// rebuild and every hover would re-ask and keep the limit tripped — which is also how the
    /// secondary limits get triggered. One window is enough for the primary limit to reset.
    let rateLimitCooldown: TimeInterval

    /// How many pages of `perPage` to fetch per project, so a project costs at most this many
    /// requests per `ttl` however many tickets ask.
    ///
    /// Two is not every PR a large org ever opened. When a project has more matches than that,
    /// `sort:updated-desc` decides which are kept, so what drops out is the PRs with no recent
    /// activity — and `truncated` records that the window was in play. The deliberate failure mode
    /// is *some* PRs missing, never all of them.
    let maxPages: Int
    static let perPage = 100

    private let searcher: PRSearching
    private let queue = DispatchQueue(label: "githubPRIndex")
    private var snapshots: [String: ProjectPRSnapshot] = [:]
    /// The token each snapshot was fetched with. A different token can see different orgs, so its
    /// arrival has to invalidate rather than ride the old answer. Held apart from the cache key,
    /// which is logged.
    private var snapshotTokens: [String: String] = [:]
    /// When each rate-limited project may be searched again.
    private var searchableAgainAt: [String: Date] = [:]
    /// Completions parked while a project's fetch is in flight, so a burst of rows all wanting the
    /// same project rides on one search instead of racing to start their own.
    private var waiting: [String: [(ProjectPRSnapshot?) -> Void]] = [:]

    init(
        searcher: PRSearching = GithubClient(),
        ttl: TimeInterval = 60,
        rateLimitCooldown: TimeInterval = 60,
        maxPages: Int = 2
    ) {
        self.searcher = searcher
        self.ttl = ttl
        self.rateLimitCooldown = rateLimitCooldown
        self.maxPages = maxPages
    }

    /// The project half of an issue key — everything before the hyphen. Jira project keys cannot
    /// contain a hyphen, so the first one is the separator.
    ///
    /// Nil for anything not shaped like a key (`PROJECT-NUMBER`, project at least two characters),
    /// which is how the caller learns there is nothing to search for. Rejecting the malformed
    /// matters more than it looks: a search built from a non-key spends one of thirty requests a
    /// minute to match nothing.
    static func projectKey(ofIssueKey key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard let hyphen = trimmed.firstIndex(of: "-") else { return nil }
        let project = trimmed[trimmed.startIndex..<hyphen]
        let number = trimmed[trimmed.index(after: hyphen)...]
        guard
            project.count >= 2,
            project.first?.isLetter == true,
            project.allSatisfy({ $0.isLetter || $0.isNumber }),
            !number.isEmpty,
            number.allSatisfy(\.isNumber)
        else { return nil }
        return project.uppercased()
    }

    /// The PRs mentioning `issueKey`, from cache when a fresh snapshot for its project exists —
    /// which, after the first ticket of a refresh, is every remaining ticket.
    ///
    /// Completes on the main queue, as the per-issue search it replaced did.
    func prs(
        forIssueKey issueKey: String,
        orgs: [String],
        token: String,
        completion: @escaping ([JiraPullRequest]) -> Void
    ) {
        let key = issueKey.trimmingCharacters(in: .whitespaces)
        let trimmedToken = token.trimmingCharacters(in: .whitespaces)
        let trimmedOrgs = orgs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard
            !trimmedToken.isEmpty,
            !trimmedOrgs.isEmpty,
            let project = GithubPRIndex.projectKey(ofIssueKey: key)
        else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        snapshot(forProject: project, orgs: trimmedOrgs, token: trimmedToken) { snapshot in
            DispatchQueue.main.async { completion(snapshot?.prs(forIssueKey: key) ?? []) }
        }
    }

    private func snapshot(
        forProject project: String,
        orgs: [String],
        token: String,
        completion: @escaping (ProjectPRSnapshot?) -> Void
    ) {
        // The org list is part of a snapshot's identity, not just of the request that built it:
        // changing "GitHub Search Orgs" in Preferences changes the answer. The token is not in the
        // key because this string is logged — it is compared separately.
        let cacheKey = "\(project)|\(orgs.joined(separator: ","))"

        enum Next {
            case serve(ProjectPRSnapshot?)
            case waitOnFetchInFlight
            case fetch
        }

        let next: Next = queue.sync {
            let cached = snapshotTokens[cacheKey] == token ? snapshots[cacheKey] : nil
            if let cached, cached.isFresh(ttl: ttl) { return .serve(cached) }
            if waiting[cacheKey] != nil {
                waiting[cacheKey]?.append(completion)
                return .waitOnFetchInFlight
            }
            // Still inside the cooldown a rate-limit response opened: serve the last good answer
            // rather than spending a request to be refused again.
            if let until = searchableAgainAt[cacheKey], until > Date() { return .serve(cached) }
            waiting[cacheKey] = [completion]
            return .fetch
        }

        switch next {
        case .serve(let snapshot): completion(snapshot)
        case .waitOnFetchInFlight: break
        case .fetch: fetch(cacheKey: cacheKey, project: project, orgs: orgs, token: token)
        }
    }

    private func fetch(cacheKey: String, project: String, orgs: [String], token: String) {
        let query = GithubClient.projectPRsQuery(projectKey: project, orgs: orgs)
        // Pages run one after the other — page n+1 only starts from page n's completion — so these
        // need no further guarding.
        var collected: [JiraPullRequest] = []
        var totalCount = 0
        var failure: GithubClient.SearchFailure?

        func finish() {
            var result: ProjectPRSnapshot?
            var waiters: [(ProjectPRSnapshot?) -> Void] = []
            queue.sync {
                let previous = snapshotTokens[cacheKey] == token ? snapshots[cacheKey] : nil
                if let failure {
                    if failure == .rateLimited {
                        searchableAgainAt[cacheKey] = Date().addingTimeInterval(rateLimitCooldown)
                    }
                    // A refusal is not an absence, and a partial answer must not displace a fuller
                    // one. Nothing is cached either way, so the next ask retries once the budget is
                    // back and the last good answer keeps rendering meanwhile — the same
                    // distinction the menubar's ✕ draws for a failed Jira fetch.
                    let servingPrevious = previous != nil
                        && previous!.hits.count >= collected.count
                    NSLog("github PR index %@: search %@ after %d PRs — serving %@",
                          cacheKey,
                          failure == .rateLimited ? "rate-limited" : "failed",
                          collected.count,
                          servingPrevious ? "the previous snapshot" : "this partial result")
                    result = servingPrevious
                        ? previous
                        : ProjectPRSnapshot(prs: collected, truncated: true)
                } else {
                    let snapshot = ProjectPRSnapshot(
                        prs: collected,
                        truncated: totalCount > collected.count
                    )
                    snapshots[cacheKey] = snapshot
                    snapshotTokens[cacheKey] = token
                    searchableAgainAt[cacheKey] = nil
                    result = snapshot
                    if snapshot.truncated {
                        NSLog("github PR index %@: kept %d of %d matching PRs — a ticket whose only PR has no recent activity may show none",
                              cacheKey, collected.count, totalCount)
                    }
                }
                waiters = waiting.removeValue(forKey: cacheKey) ?? []
            }
            for waiter in waiters { waiter(result) }
        }

        func page(_ number: Int) {
            searcher.searchPRs(
                query: query,
                page: number,
                perPage: GithubPRIndex.perPage,
                token: token
            ) { result in
                switch result {
                case .success(let fetched):
                    collected += fetched.prs
                    totalCount = fetched.totalCount
                    // On `itemCount`, not `prs.count`: a hit this app can't parse still fills a
                    // slot on the page, and treating the page as short would drop the next hundred.
                    let wantsMore = fetched.itemCount == GithubPRIndex.perPage
                        && number * GithubPRIndex.perPage < fetched.totalCount
                        && number < self.maxPages
                    if wantsMore { page(number + 1) } else { finish() }
                case .failure(let searchFailure):
                    failure = searchFailure
                    finish()
                }
            }
        }
        page(1)
    }
}
