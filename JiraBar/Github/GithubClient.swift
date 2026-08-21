//
//  GithubClient.swift
//  jiraBar
//
//  Created by Pavel Makhov on 2023-10-29.
//

import Foundation
import Alamofire

/// One completed review: who left it and what it said.
struct PRReview {
    let login: String
    /// "APPROVED" / "CHANGES_REQUESTED" / "COMMENTED" / "DISMISSED".
    let state: String
}

/// Enriched pull request data pulled from GitHub's GraphQL API, layered on top of Jira's
/// (often stale) dev-status view. All fields are optional / defaulted so a partial response
/// still renders something useful.
struct GithubPRStatus {
    /// "APPROVED" / "CHANGES_REQUESTED" / "REVIEW_REQUIRED" — nil if GitHub hasn't computed one.
    var reviewDecision: String?
    var unresolvedThreads: Int
    var totalThreads: Int
    /// "SUCCESS" / "FAILURE" / "PENDING" / "ERROR" / "EXPECTED" — nil if there are no checks.
    var ciState: String?
    /// Whether the PR has been merged. Drives whether the merged-PR release indicators apply.
    var isMerged: Bool
    /// ISO-8601 timestamp of the merge. Compared lexicographically against release timestamps.
    var mergedAt: String?
    /// ISO-8601 timestamp of the repo's most recent published release, or nil if none.
    var latestReleasePublishedAt: String?
    /// Status of checks on the default branch's HEAD commit — proxy for "is a release workflow
    /// currently running on main?" when the state is PENDING.
    var defaultBranchCIState: String?
    /// State of the viewer's latest review — "APPROVED" / "CHANGES_REQUESTED" / "COMMENTED" /
    /// "DISMISSED" / "PENDING". Nil if the viewer hasn't reviewed. Used by the "you've already
    /// approved" indicator in the transition dialog.
    var viewerLatestReviewState: String?
    /// GitHub logins currently assigned to the PR.
    var assignees: [String]
    /// Logins (or team names) asked for a review who haven't left one yet. nil when the connection was
    /// absent from the response — unknown, which must not render as "nobody was asked".
    var pendingReviewers: [String]?
    /// Reviews actually left, one per reviewer. Distinct from `pendingReviewers`: "asked jdoe" and
    /// "jdoe requested changes" are different facts. nil when absent, as above.
    var reviews: [PRReview]?
    /// Merge methods the repo permits. Used by the auto-merge flow to skip PRs whose repo
    /// disallows the chosen method.
    var mergeCommitAllowed: Bool
    var squashMergeAllowed: Bool
    var rebaseMergeAllowed: Bool
    /// The PR's head branch name. Used by the "PRs Without Tickets" section to detect a Jira issue key in
    /// the branch when the title doesn't carry one.
    var headRefName: String?
    /// "CLEAN" / "BLOCKED" / "BEHIND" / "DIRTY" / "DRAFT" / "UNSTABLE" / "UNKNOWN". Read after a merge
    /// has failed, to name the blocker.
    var mergeStateStatus: String?
    /// Whether the PR is a draft. GitHub treats drafts as open, so they arrive through the
    /// normal open-PR paths with nothing to distinguish them — this is what marks the row.
    var isDraft: Bool
}

public class GithubClient {

    /// Standard REST-API headers shared by every endpoint. `json: true` adds the JSON
    /// content type for calls that send a body.
    private func apiHeaders(token: String, json: Bool = false) -> HTTPHeaders {
        var headers: HTTPHeaders = [
            .authorization(bearerToken: token),
            .accept("application/vnd.github+json"),
            .userAgent("JiraBar")
        ]
        if json { headers.add(.contentType("application/json")) }
        return headers
    }

    /// GraphQL wants plain JSON both ways, unlike the REST endpoints above.
    private func graphqlHeaders(token: String) -> HTTPHeaders {
        [
            .authorization(bearerToken: token),
            .accept("application/json"),
            .contentType("application/json"),
            .userAgent("JiraBar")
        ]
    }

    func getLatestRelease(completion:@escaping (((LatestRelease?) -> Void))) -> Void {
             let headers: HTTPHeaders = [
                 .contentType("application/json"),
                 .accept("application/json")
             ]
             AF.request("https://api.github.com/repos/menubar-apps/JiraBar/releases/latest",
                        method: .get,
                        encoding: JSONEncoding.default,
                        headers: headers)
                 .validate(statusCode: 200..<300)
                 .responseDecodable(of: LatestRelease.self) { response in
                     switch response.result {
                     case .success(let latestRelease):
                         completion(latestRelease)
                     case .failure(let error):
                         completion(nil)
                         sendNotification(body: error.localizedDescription)
                     }
                 }
         }

    /// One GraphQL call per PR: fetches reviewDecision, unresolved-thread count, and the
    /// latest commit's CI rollup state. Falls back to nil on any parse / auth failure so
    /// callers can degrade to just the Jira dev-status view.
    func fetchPRStatus(url urlString: String, token: String, completion: @escaping (GithubPRStatus?) -> Void) {
        guard !token.isEmpty,
              let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(nil)
            return
        }

        // Parameterized query — passing owner/repo/number as variables (rather than interpolating
        // into the query text) avoids any GraphQL-injection risk from a hostile PR URL that
        // slipped through path validation.
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            mergeCommitAllowed
            squashMergeAllowed
            rebaseMergeAllowed
            pullRequest(number: $number) {
              reviewDecision
              mergeStateStatus
              merged
              mergedAt
              headRefName
              isDraft
              viewerLatestReview { state }
              assignees(first: 10) { nodes { login } }
              reviewRequests(first: 20) {
                nodes { requestedReviewer { ... on User { login } ... on Team { name } } }
              }
              latestReviews(first: 20) { nodes { state author { login } } }
              reviewThreads(first: 100) { nodes { isResolved } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
            latestRelease { publishedAt }
            defaultBranchRef {
              target {
                ... on Commit { statusCheckRollup { state } }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": [
                "owner": owner,
                "name": repo,
                "number": number
            ]
        ]
        AF.request("https://api.github.com/graphql",
                   method: .post,
                   parameters: body,
                   encoding: JSONEncoding.default,
                   headers: graphqlHeaders(token: token))
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    guard
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let dataDict = json["data"] as? [String: Any],
                        let repoDict = dataDict["repository"] as? [String: Any],
                        let prDict = repoDict["pullRequest"] as? [String: Any]
                    else {
                        completion(nil)
                        return
                    }

                    let reviewDecision = prDict["reviewDecision"] as? String

                    let threadNodes = ((prDict["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    let unresolved = threadNodes.reduce(0) { acc, node in
                        let resolved = (node["isResolved"] as? Bool) ?? false
                        return acc + (resolved ? 0 : 1)
                    }

                    let commitNodes = ((prDict["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    let ciState = commitNodes.last
                        .flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }?["state"] as? String

                    let isMerged = (prDict["merged"] as? Bool) ?? false
                    let mergedAt = prDict["mergedAt"] as? String
                    let latestReleasePublishedAt = (repoDict["latestRelease"] as? [String: Any])?["publishedAt"] as? String
                    let defaultBranchCIState = ((repoDict["defaultBranchRef"] as? [String: Any])?["target"] as? [String: Any])
                        .flatMap { $0["statusCheckRollup"] as? [String: Any] }?["state"] as? String
                    let viewerLatestReviewState = (prDict["viewerLatestReview"] as? [String: Any])?["state"] as? String
                    let assigneeNodes = ((prDict["assignees"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    let assignees = assigneeNodes.compactMap { $0["login"] as? String }
                    let pendingReviewers = GithubClient.pendingReviewers(fromConnection: prDict["reviewRequests"])
                    let reviews = GithubClient.reviews(fromConnection: prDict["latestReviews"])
                    let mergeCommitAllowed = (repoDict["mergeCommitAllowed"] as? Bool) ?? false
                    let squashMergeAllowed = (repoDict["squashMergeAllowed"] as? Bool) ?? false
                    let rebaseMergeAllowed = (repoDict["rebaseMergeAllowed"] as? Bool) ?? false
                    let headRefName = prDict["headRefName"] as? String
                    let isDraft = (prDict["isDraft"] as? Bool) ?? false
                    let mergeStateStatus = prDict["mergeStateStatus"] as? String

                    completion(GithubPRStatus(
                        reviewDecision: reviewDecision,
                        unresolvedThreads: unresolved,
                        totalThreads: threadNodes.count,
                        ciState: ciState,
                        isMerged: isMerged,
                        mergedAt: mergedAt,
                        latestReleasePublishedAt: latestReleasePublishedAt,
                        defaultBranchCIState: defaultBranchCIState,
                        viewerLatestReviewState: viewerLatestReviewState,
                        assignees: assignees,
                        pendingReviewers: pendingReviewers,
                        reviews: reviews,
                        mergeCommitAllowed: mergeCommitAllowed,
                        squashMergeAllowed: squashMergeAllowed,
                        rebaseMergeAllowed: rebaseMergeAllowed,
                        headRefName: headRefName,
                        mergeStateStatus: mergeStateStatus,
                        isDraft: isDraft
                    ))
                case .failure(let error):
                    print("github graphql: \(error)")
                    completion(nil)
                }
            }
    }

    /// Fallback lookup used when Jira's dev-status API returns no PRs for an issue — searches
    /// GitHub for PRs whose title contains the exact issue key, scoped to the caller-supplied
    /// orgs. Reconstructs `JiraPullRequest` values so the renderer path stays unchanged.
    func searchPRsForIssueKey(
        _ key: String,
        orgs: [String],
        token: String,
        completion: @escaping ([JiraPullRequest]) -> Void
    ) {
        let trimmedOrgs = orgs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !token.isEmpty, !trimmedOrgs.isEmpty, !key.isEmpty else {
            completion([])
            return
        }

        // GitHub's search tokenizes on hyphen even inside quotes, so searching for a key like
        // "PROJ-42" will happily return a PR titled "OTHER-42 …" — it matches on the numeric
        // half. We still ask GitHub to narrow (quotes reduce false positives and cost quota)
        // but the returned titles are re-verified below with an exact case-insensitive
        // substring check on the full key.
        let orgTerms = trimmedOrgs.map { "org:\($0)" }.joined(separator: " ")
        let q = "\"\(key)\" in:title is:pr \(orgTerms)"
        let normalizedKey = key.lowercased()

        let headers = apiHeaders(token: token)

        AF.request(
            "https://api.github.com/search/issues",
            method: .get,
            parameters: ["q": q, "per_page": 20],
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .responseData { response in
            switch response.result {
            case .success(let data):
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let items = json["items"] as? [[String: Any]]
                else {
                    completion([])
                    return
                }
                let prs: [JiraPullRequest] = items.compactMap { item in
                    guard
                        let htmlURL = item["html_url"] as? String,
                        let number = item["number"] as? Int,
                        let title = item["title"] as? String
                    else { return nil }
                    // Exact-key substring check — drops false positives that share the numeric
                    // half of the key (see the tokenization note where the query is built).
                    guard title.lowercased().contains(normalizedKey) else { return nil }
                    let state = (item["state"] as? String)?.lowercased() ?? "open"
                    let mergedAt = (item["pull_request"] as? [String: Any])?["merged_at"] as? String
                    let status: String
                    if state == "open" {
                        status = "OPEN"
                    } else if mergedAt != nil {
                        status = "MERGED"
                    } else {
                        status = "DECLINED"
                    }
                    return JiraPullRequest(
                        id: "#\(number)",
                        name: title,
                        url: htmlURL,
                        status: status,
                        reviewers: nil
                    )
                }
                completion(prs)
            case .failure(let error):
                print("github search: \(error)")
                completion([])
            }
        }
    }

    /// Searches GitHub for open PRs relevant to the token's user — ones they authored, ones
    /// assigned to them, and ones with their review requested — the candidate pool that the
    /// "PRs Without Tickets" menu section then filters down.
    ///
    /// Three search calls, because GitHub's search has no OR across qualifiers, deduped by URL.
    /// `author:@me` is not redundant with the other two: opening a PR does not assign it to you
    /// or request your review, so a PR you wrote and haven't handed to anyone matches only the
    /// author term — which is exactly the case that was silently missing before.
    ///
    /// Scoped to `orgs` when non-empty; `@me` resolves server-side from the token, so no
    /// identity lookup is needed.
    func searchMyPRs(orgs: [String], token: String, completion: @escaping ([JiraPullRequest]) -> Void) {
        guard !token.isEmpty else {
            completion([])
            return
        }
        let queries = GithubClient.myPRsQueries(orgs: orgs)

        let headers = apiHeaders(token: token)

        let group = DispatchGroup()
        let syncQueue = DispatchQueue(label: "githubMyPRs.sync")
        var hitsByURL: [String: MyPRHit] = [:]
        // Preserves first-seen order so the rendered list doesn't reshuffle between refreshes.
        var order: [String] = []

        for (relation, q) in queries {
            group.enter()
            AF.request(
                "https://api.github.com/search/issues",
                method: .get,
                parameters: ["q": q, "per_page": 50],
                headers: headers
            )
            .validate(statusCode: 200..<300)
            .responseData { response in
                var parsed: [(pr: JiraPullRequest, assignees: [String])] = []
                switch response.result {
                case .success(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = json["items"] as? [[String: Any]] {
                        parsed = items.compactMap { item in
                            guard
                                let htmlURL = item["html_url"] as? String,
                                let number = item["number"] as? Int,
                                let title = item["title"] as? String
                            else { return nil }
                            let assignees = ((item["assignees"] as? [[String: Any]]) ?? [])
                                .compactMap { $0["login"] as? String }
                            return (
                                JiraPullRequest(
                                    id: "#\(number)",
                                    name: title,
                                    url: htmlURL,
                                    status: "OPEN",
                                    reviewers: nil
                                ),
                                assignees
                            )
                        }
                    }
                case .failure(let error):
                    print("github searchMyPRs: \(error)")
                }
                syncQueue.async {
                    for (pr, assignees) in parsed {
                        if var existing = hitsByURL[pr.url] {
                            // A PR can match several relations; ownership from any one sticks.
                            existing.ownedByMe = existing.ownedByMe || relation.impliesOwnership
                            if existing.assigneeLogins.isEmpty { existing.assigneeLogins = assignees }
                            hitsByURL[pr.url] = existing
                        } else {
                            hitsByURL[pr.url] = MyPRHit(
                                pr: pr,
                                ownedByMe: relation.impliesOwnership,
                                assigneeLogins: assignees
                            )
                            order.append(pr.url)
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(GithubClient.retainingOwnPRs(order.compactMap { hitsByURL[$0] }))
        }
    }

    /// Search behind the "Recently Approved PRs" section: PRs the user has reviewed, newest-updated first.
    ///
    /// `reviewed-by` rather than an approved-only qualifier because GitHub has none — `review:approved` is
    /// the PR's overall decision, not the viewer's own review. The approval filter therefore happens after
    /// enrichment, on `viewerLatestReviewState`; see `approvedByViewer`.
    ///
    /// Sorted on the **updated** timestamp, which is what was asked for: a PR approved days ago and pushed
    /// to this morning belongs at the top, and `created` or `merged` would both bury it.
    static func recentlyApprovedQuery(orgs: [String]) -> String {
        let orgTerms = orgs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "org:\($0)" }
            .joined(separator: " ")
        return "is:pr reviewed-by:@me sort:updated-desc \(orgTerms)"
            .trimmingCharacters(in: .whitespaces)
    }

    /// Keeps only the PRs whose *latest* review from the viewer is an approval, in the order given.
    ///
    /// Latest is the right reading of "PRs I approved": a PR he requested changes on and then approved
    /// counts, and one he approved and later left a comment on does not — his standing review there is a
    /// comment. Measured against the real org, this drops roughly one PR in fourteen from `reviewed-by`.
    static func approvedByViewer(
        _ prs: [JiraPullRequest],
        statusByURL: [String: GithubPRStatus]
    ) -> [JiraPullRequest] {
        prs.filter { statusByURL[$0.url]?.viewerLatestReviewState == "APPROVED" }
    }

    /// One search hit as a PR row. Unlike the PRs-Without-Tickets search this one is not `is:open`, so the
    /// state has to come from the payload: a merged PR is the interesting artifact here, and hardcoding
    /// OPEN would render every row as though it were still in flight.
    static func searchHitAsPR(_ item: [String: Any]) -> JiraPullRequest? {
        guard
            let htmlURL = item["html_url"] as? String,
            let number = item["number"] as? Int,
            let title = item["title"] as? String
        else { return nil }
        let merged = ((item["pull_request"] as? [String: Any])?["merged_at"] as? String) != nil
        let closed = (item["state"] as? String)?.lowercased() == "closed"
        let status = merged ? "MERGED" : (closed ? "DECLINED" : "OPEN")
        return JiraPullRequest(id: "#\(number)", name: title, url: htmlURL, status: status, reviewers: nil)
    }

    func searchReviewedByMe(
        orgs: [String],
        token: String,
        limit: Int,
        completion: @escaping ([JiraPullRequest]) -> Void
    ) {
        guard !token.isEmpty else {
            completion([])
            return
        }
        AF.request(
            "https://api.github.com/search/issues",
            method: .get,
            parameters: ["q": GithubClient.recentlyApprovedQuery(orgs: orgs), "per_page": limit],
            headers: apiHeaders(token: token)
        )
        .validate(statusCode: 200..<300)
        .responseData { response in
            switch response.result {
            case .success(let data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]]
                else {
                    completion([])
                    return
                }
                completion(items.compactMap { GithubClient.searchHitAsPR($0) })
            case .failure(let error):
                print("github searchReviewedByMe: \(error)")
                completion([])
            }
        }
    }

    /// How a PR came to be in the search results. GitHub's search can't OR these
    /// together, so each is its own query.
    enum MyPRsRelation: String, CaseIterable {
        case author = "author:@me"
        case assignee = "assignee:@me"
        case reviewRequested = "review-requested:@me"

        /// Whether matching this relation alone means the PR is still the user's to act on.
        /// Authorship doesn't: once you assign your PR to someone else, it's handed off and
        /// stops being your problem. Being the assignee or the requested reviewer does.
        var impliesOwnership: Bool { self != .author }
    }

    /// The search queries behind the "PRs Without Tickets" section, one per relation. Extracted so the set
    /// of qualifiers is under test — dropping one silently hides a whole category of PRs
    /// rather than failing loudly.
    static func myPRsQueries(orgs: [String]) -> [(relation: MyPRsRelation, query: String)] {
        let orgTerms = orgs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "org:\($0)" }
            .joined(separator: " ")
        return MyPRsRelation.allCases.map { relation in
            (relation, "is:pr is:open \(relation.rawValue) \(orgTerms)".trimmingCharacters(in: .whitespaces))
        }
    }

    /// A deduped search hit, carrying the provenance needed to spot handed-off work.
    struct MyPRHit {
        let pr: JiraPullRequest
        /// True when at least one query that claims ownership (assignee / review-requested)
        /// returned this PR.
        var ownedByMe: Bool
        /// Assignee logins straight from the search payload — no extra request needed.
        var assigneeLogins: [String]
    }

    /// Drops handed-off work: PRs the user authored but assigned to someone else.
    ///
    /// This needs no knowledge of the user's own login. If they were an assignee or a requested
    /// reviewer, the `assignee:@me` or `review-requested:@me` query would have returned the PR
    /// and set `ownedByMe`. So a hit that only ever matched `author:@me` yet carries assignees
    /// must be assigned to somebody else. An authored PR with no assignees at all is still
    /// theirs and stays.
    static func retainingOwnPRs(_ hits: [MyPRHit]) -> [JiraPullRequest] {
        hits.filter { $0.ownedByMe || $0.assigneeLogins.isEmpty }.map(\.pr)
    }

    /// The reviews API documents `body` as required for these events — see
    /// `PRReviewAction.requiresComment`. Keyed by the API's own event strings, so it covers
    /// COMMENT too even though nothing submits one yet.
    static let reviewEventsRequiringBody: Set<String> = ["REQUEST_CHANGES", "COMMENT"]

    /// Whether the reviews API would accept this (event, body) pair. False for the events whose
    /// body is required when nothing but whitespace was supplied.
    static func reviewIsSubmittable(event: String, body: String) -> Bool {
        guard reviewEventsRequiringBody.contains(event.uppercased()) else { return true }
        return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Submits a review on a PR — e.g. `event: "APPROVE"` with an optional body — via the
    /// pull-request reviews endpoint. Ignores non-github.com URLs.
    ///
    /// `body` is only optional for APPROVE; a bodyless REQUEST_CHANGES or COMMENT is refused here
    /// rather than sent to fail validation. Callers shouldn't rely on that — the dialog and
    /// `PRActionChoices.reviewEvent` keep the case from reaching this far.
    func submitPRReview(
        url urlString: String,
        event: String,
        body: String,
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString),
            GithubClient.reviewIsSubmittable(event: event, body: body)
        else {
            completion(false)
            return
        }
        let headers = apiHeaders(token: token, json: true)
        // Normalise here rather than trusting callers: the submittability check above is
        // case-insensitive, so accepting "request_changes" and then posting it verbatim would
        // bless a call the API rejects. Same for the body — validated trimmed, so send it trimmed,
        // otherwise a whitespace-only APPROVE comment posts as a review body of spaces.
        var payload: [String: Any] = ["event": event.uppercased()]
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty { payload["body"] = trimmedBody }
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/reviews",
            method: .post,
            parameters: payload,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .response { response in
            switch response.result {
            case .success:
                completion(true)
            case .failure(let error):
                print("github submitPRReview: \(error)")
                completion(false)
            }
        }
    }

    /// Merges a PR using the caller-chosen method ("merge", "squash", or "rebase"). GitHub
    /// returns 405 when the method isn't allowed on that repo — the caller should have already
    /// consulted `GithubPRStatus.{merge|squash|rebase}MergeAllowed` and skipped the call in
    /// that case. Ignores non-github.com URLs.
    /// One unresolved review thread: its node id, and who opened it.
    struct ReviewThread {
        let id: String
        let author: String
    }

    /// Every unresolved review thread on the PR, following `pageInfo` to the end. nil on any failure —
    /// resolving a partial set would leave the merge blocked by whatever was missed, which is the
    /// failure this exists to remove.
    func fetchUnresolvedReviewThreads(
        url urlString: String,
        token: String,
        completion: @escaping ([ReviewThread]?) -> Void
    ) {
        guard !token.isEmpty, let (owner, repo, number) = GithubClient.parsePRURL(urlString) else {
            completion(nil)
            return
        }
        var collected: [ReviewThread] = []

        func page(after cursor: String?) {
            let query = """
            query($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  reviewThreads(first: 100, after: $after) {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      id
                      isResolved
                      comments(first: 1) { nodes { author { login } } }
                    }
                  }
                }
              }
            }
            """
            var variables: [String: Any] = ["owner": owner, "name": repo, "number": number]
            if let cursor { variables["after"] = cursor }
            AF.request(
                "https://api.github.com/graphql",
                method: .post,
                parameters: ["query": query, "variables": variables],
                encoding: JSONEncoding.default,
                headers: graphqlHeaders(token: token)
            )
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    guard
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let dataDict = json["data"] as? [String: Any],
                        let repoDict = dataDict["repository"] as? [String: Any],
                        let prDict = repoDict["pullRequest"] as? [String: Any],
                        let threads = prDict["reviewThreads"] as? [String: Any],
                        let nodes = threads["nodes"] as? [[String: Any]]
                    else {
                        completion(nil)
                        return
                    }
                    collected.append(contentsOf: GithubClient.unresolvedThreads(fromNodes: nodes))
                    let info = threads["pageInfo"] as? [String: Any]
                    if (info?["hasNextPage"] as? Bool) == true, let next = info?["endCursor"] as? String {
                        page(after: next)
                    } else {
                        completion(collected)
                    }
                case .failure(let error):
                    print("github fetchUnresolvedReviewThreads: \(error)")
                    completion(nil)
                }
            }
        }
        page(after: nil)
    }

    /// Who has been asked for a review and hasn't left one, or nil when the connection is missing —
    /// unknown, since a caller that rendered "nobody was asked" from that would be asserting a fact the
    /// response does not contain.
    ///
    /// A requested reviewer is a union: a Team arrives with `name` rather than `login`, and dropping it
    /// would leave a PR that has a reviewer claiming it has none.
    static func pendingReviewers(fromConnection connection: Any?) -> [String]? {
        guard let nodes = (connection as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        return nodes.compactMap { node in
            guard let reviewer = node["requestedReviewer"] as? [String: Any] else { return nil }
            return (reviewer["login"] as? String) ?? (reviewer["name"] as? String)
        }
    }

    /// Reviews actually left, or nil when the connection is missing.
    static func reviews(fromConnection connection: Any?) -> [PRReview]? {
        guard let nodes = (connection as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        return nodes.compactMap { node in
            guard let login = (node["author"] as? [String: Any])?["login"] as? String,
                  let state = node["state"] as? String
            else { return nil }
            return PRReview(login: login, state: state)
        }
    }

    /// Picks the unresolved threads out of one page of nodes. Split out so the shape-handling is
    /// testable: a thread with no readable author still has to be resolvable.
    static func unresolvedThreads(fromNodes nodes: [[String: Any]]) -> [ReviewThread] {
        nodes.compactMap { node in
            guard (node["isResolved"] as? Bool) == false, let id = node["id"] as? String else { return nil }
            let comments = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]
            let author = (comments?.first?["author"] as? [String: Any])?["login"] as? String
            return ReviewThread(id: id, author: author ?? "unknown")
        }
    }

    /// Marks one review thread resolved. Reports success only when GitHub echoes the flipped flag, since
    /// a GraphQL error arrives as a 200 with an `errors` array.
    func resolveReviewThread(id: String, token: String, completion: @escaping (Bool) -> Void) {
        guard !token.isEmpty, !id.isEmpty else {
            completion(false)
            return
        }
        let query = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
        }
        """
        AF.request(
            "https://api.github.com/graphql",
            method: .post,
            parameters: ["query": query, "variables": ["threadId": id]],
            encoding: JSONEncoding.default,
            headers: graphqlHeaders(token: token)
        )
        .validate(statusCode: 200..<300)
        .responseData { response in
            switch response.result {
            case .success(let data):
                // A 200 carrying `errors` is still a failed mutation; only the flipped flag counts.
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let payload = (json?["data"] as? [String: Any])?["resolveReviewThread"] as? [String: Any]
                let thread = payload?["thread"] as? [String: Any]
                completion((thread?["isResolved"] as? Bool) ?? false)
            case .failure(let error):
                print("github resolveReviewThread: \(error)")
                completion(false)
            }
        }
    }

    /// Why a merge was refused, phrased for the transition window, or nil when the status says nothing
    /// useful. `BLOCKED` is the ambiguous one and the reason this exists: an approved, conflict-free PR
    /// reports it both for unresolved conversations and for an out-of-date branch.
    static func mergeBlockReason(mergeStateStatus: String?, unresolvedThreads: Int) -> String? {
        switch mergeStateStatus?.uppercased() {
        case "DIRTY":
            return "it conflicts with the base branch"
        case "DRAFT":
            return "it is still a draft"
        case "BEHIND":
            return "the branch is out of date with the base branch"
        case "UNKNOWN":
            return "GitHub hadn't finished computing mergeability — it may work shortly"
        case "BLOCKED":
            if unresolvedThreads > 0 {
                return "\(unresolvedThreads) unresolved conversation\(unresolvedThreads == 1 ? "" : "s")"
            }
            return "branch protection refused it — the branch may be out of date with the base branch, "
                + "or a required review or check is missing"
        default:
            return nil
        }
    }

    func mergePR(
        url urlString: String,
        method: String,
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(false)
            return
        }
        let headers = apiHeaders(token: token, json: true)
        let payload: [String: Any] = ["merge_method": method]
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/merge",
            method: .put,
            parameters: payload,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .response { response in
            switch response.result {
            case .success:
                completion(true)
            case .failure(let error):
                print("github mergePR: \(error)")
                completion(false)
            }
        }
    }

    /// Adds to the "Assignees" list on a PR (a PR is an Issue under the hood, so the issues API
    /// owns this field). Additive — anyone already assigned stays; the PATCH-with-full-list
    /// variant this replaced silently dropped existing assignees. Ignores non-github.com URLs.
    func addPRAssignees(
        url urlString: String,
        assignees: [String],
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(false)
            return
        }
        let headers = apiHeaders(token: token, json: true)
        let body: [String: Any] = ["assignees": assignees]
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)/assignees",
            method: .post,
            parameters: body,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .response { response in
            switch response.result {
            case .success:
                completion(true)
            case .failure(let error):
                print("github addPRAssignees: \(error)")
                completion(false)
            }
        }
    }

    /// Returns the current requested-reviewer logins on a PR, or nil when the state couldn't
    /// be read (auth/network failure, non-github URL). Callers must not treat nil as "no
    /// reviewers" — the mirror flow diffs against this list and removes people.
    func getPRRequestedReviewers(
        url urlString: String,
        token: String,
        completion: @escaping ([String]?) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(nil)
            return
        }
        let headers = apiHeaders(token: token)
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/requested_reviewers",
            method: .get,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .responseData { response in
            switch response.result {
            case .success(let data):
                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let users = json["users"] as? [[String: Any]]
                else {
                    // 2xx but an unexpected shape — a genuinely empty reviewer list still
                    // parses, so treat this as unreadable rather than empty.
                    completion(nil)
                    return
                }
                completion(users.compactMap { $0["login"] as? String })
            case .failure(let error):
                print("github getPRRequestedReviewers: \(error)")
                completion(nil)
            }
        }
    }

    /// Removes the named users from a PR's requested-reviewers list. Empty input is a no-op success.
    func removePRReviewers(
        url urlString: String,
        reviewers: [String],
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(false)
            return
        }
        guard !reviewers.isEmpty else {
            completion(true)
            return
        }
        let headers = apiHeaders(token: token, json: true)
        let body: [String: Any] = ["reviewers": reviewers]
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/requested_reviewers",
            method: .delete,
            parameters: body,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .response { response in
            switch response.result {
            case .success:
                completion(true)
            case .failure(let error):
                print("github removePRReviewers: \(error)")
                completion(false)
            }
        }
    }

    /// Adds reviewers to a PR's requested-reviewers list. Additive — does not clear anyone
    /// already requested. Empty list is a no-op success. Ignores non-github.com URLs.
    func requestPRReviewers(
        url urlString: String,
        reviewers: [String],
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            !token.isEmpty,
            let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(false)
            return
        }
        guard !reviewers.isEmpty else {
            completion(true)
            return
        }
        let headers = apiHeaders(token: token, json: true)
        let body: [String: Any] = ["reviewers": reviewers]
        AF.request(
            "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/requested_reviewers",
            method: .post,
            parameters: body,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .validate(statusCode: 200..<300)
        .response { response in
            switch response.result {
            case .success:
                completion(true)
            case .failure(let error):
                print("github requestPRReviewers: \(error)")
                completion(false)
            }
        }
    }

    /// Extracts (owner, repo, number) from a github.com PR URL. Returns nil for anything else
    /// (e.g. Bitbucket, GitLab) so the caller can skip the API call.
    private static func parsePRURL(_ raw: String) -> (String, String, Int)? {
        guard let parsed = ForgePRURL(raw), parsed.isGithub, let number = parsed.pullNumber else { return nil }
        return (parsed.owner, parsed.repo, number)
    }
}
