import XCTest
@testable import jiraBar

/// Guards the request budget behind the per-issue PR fallback — see `GithubPRIndex` for the
/// constraint these numbers come from. The count assertions are the regression test: they fail if
/// the per-ticket fan-out ever comes back.
final class GithubPRIndexTests: XCTestCase {

    /// Records every search asked of it and replies from a script, so the index's caching,
    /// coalescing and failure handling are observable without a network.
    private final class FakeSearcher: PRSearching {
        /// One entry per request, in order.
        private(set) var requests: [(query: String, page: Int)] = []
        /// Answer for page 1, page 2, … Reused for every page past the end of the array.
        var pages: [Result<GithubClient.PRSearchPage, GithubClient.SearchFailure>]
        /// Replies on the caller's thread when nil; otherwise hops to this queue first, which is
        /// what lets a test line up several callers against one in-flight fetch.
        var replyOn: DispatchQueue?

        init(pages: [Result<GithubClient.PRSearchPage, GithubClient.SearchFailure>]) {
            self.pages = pages
        }

        func searchPRs(
            query: String,
            page: Int,
            perPage: Int,
            token: String,
            completion: @escaping (Result<GithubClient.PRSearchPage, GithubClient.SearchFailure>) -> Void
        ) {
            requests.append((query, page))
            let answer = pages.indices.contains(page - 1) ? pages[page - 1] : pages.last!
            if let replyOn {
                replyOn.async { completion(answer) }
            } else {
                completion(answer)
            }
        }
    }

    private func pr(_ number: Int, _ title: String, status: String = "OPEN") -> JiraPullRequest {
        JiraPullRequest(
            id: "#\(number)",
            name: title,
            url: "https://github.com/acme/repo/pull/\(number)",
            status: status,
            reviewers: nil
        )
    }

    private func page(
        _ prs: [JiraPullRequest],
        items: Int? = nil,
        total: Int? = nil
    ) -> GithubClient.PRSearchPage {
        GithubClient.PRSearchPage(
            prs: prs,
            itemCount: items ?? prs.count,
            totalCount: total ?? prs.count
        )
    }

    private func lookup(
        _ index: GithubPRIndex,
        _ key: String,
        orgs: [String] = ["Acme"],
        token: String = "t"
    ) -> [JiraPullRequest] {
        var result: [JiraPullRequest] = []
        let done = expectation(description: "lookup \(key)")
        index.prs(forIssueKey: key, orgs: orgs, token: token) { prs in
            result = prs
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return result
    }

    private func fullPage(project: String = "PROJ") -> [JiraPullRequest] {
        (1...GithubPRIndex.perPage).map { pr($0, "[\(project)-\($0)] filler") }
    }

    // MARK: - The request budget

    func testManyTicketsInOneProjectCostOneSearch() {
        let searcher = FakeSearcher(pages: [.success(page([
            pr(710, "[PROJ-1747] Reject a blank key column"),
            pr(10, "[PROJ-1762] Bump the components library", status: "MERGED")
        ]))])
        let index = GithubPRIndex(searcher: searcher)

        for n in 1740...1770 {
            _ = lookup(index, "PROJ-\(n)")
        }

        XCTAssertEqual(searcher.requests.count, 1, "31 tickets must not cost 31 searches")
        XCTAssertEqual(searcher.requests.first?.page, 1)
    }

    func testEachProjectCostsItsOwnSearch() {
        let searcher = FakeSearcher(pages: [.success(page([]))])
        let index = GithubPRIndex(searcher: searcher)

        _ = lookup(index, "PROJ-1")
        _ = lookup(index, "OPS-1")
        _ = lookup(index, "PROJ-2")

        XCTAssertEqual(searcher.requests.count, 2)
        XCTAssertEqual(searcher.requests.map(\.query).filter { $0.hasPrefix("PROJ ") }.count, 1)
        XCTAssertEqual(searcher.requests.map(\.query).filter { $0.hasPrefix("OPS ") }.count, 1)
    }

    /// Changing the configured orgs has to change the answer, so it cannot ride the old snapshot.
    func testChangingOrgsRefetches() {
        let searcher = FakeSearcher(pages: [.success(page([]))])
        let index = GithubPRIndex(searcher: searcher)

        _ = lookup(index, "PROJ-1", orgs: ["Acme"])
        _ = lookup(index, "PROJ-1", orgs: ["Acme", "Other"])

        XCTAssertEqual(searcher.requests.count, 2)
    }

    /// A different token can see different orgs, so it must not be answered from the old snapshot.
    func testChangingTokenRefetches() {
        let searcher = FakeSearcher(pages: [.success(page([]))])
        let index = GithubPRIndex(searcher: searcher)

        _ = lookup(index, "PROJ-1", token: "first")
        _ = lookup(index, "PROJ-1", token: "second")

        XCTAssertEqual(searcher.requests.count, 2)
    }

    func testExpiredSnapshotRefetches() {
        let searcher = FakeSearcher(pages: [.success(page([]))])
        let index = GithubPRIndex(searcher: searcher, ttl: 0)

        _ = lookup(index, "PROJ-1")
        _ = lookup(index, "PROJ-1")

        XCTAssertEqual(searcher.requests.count, 2)
    }

    /// The burst case the refresh hook produces: several rows want the same project before the
    /// first search has answered. They must ride that one search, not start their own.
    func testConcurrentCallersRideOneSearch() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "[PROJ-1] a")]))])
        searcher.replyOn = DispatchQueue(label: "fake.reply")
        let index = GithubPRIndex(searcher: searcher)

        let done = expectation(description: "all")
        done.expectedFulfillmentCount = 5
        var counts: [Int] = []
        let sync = DispatchQueue(label: "counts")
        for _ in 0..<5 {
            index.prs(forIssueKey: "PROJ-1", orgs: ["Acme"], token: "t") { prs in
                sync.sync { counts.append(prs.count) }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(searcher.requests.count, 1)
        XCTAssertEqual(counts, [1, 1, 1, 1, 1], "every parked caller gets the shared answer")
    }

    // MARK: - Paging

    func testFullFirstPageFetchesTheSecond() {
        let searcher = FakeSearcher(pages: [
            .success(page(fullPage(), total: 250)),
            .success(page([pr(999, "[PROJ-1747] the one we want")], total: 250))
        ])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#999"])
        XCTAssertEqual(searcher.requests.map(\.page), [1, 2])
    }

    func testPagingStopsAtMaxPages() {
        let searcher = FakeSearcher(pages: [.success(page(fullPage(), total: 10_000))])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        _ = lookup(index, "PROJ-1")

        XCTAssertEqual(searcher.requests.map(\.page), [1, 2], "the cap is what keeps the budget bounded")
    }

    func testShortPageStopsPaging() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "[PROJ-1] a")], total: 1))])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        _ = lookup(index, "PROJ-1")

        XCTAssertEqual(searcher.requests.map(\.page), [1])
    }

    /// An unparseable hit still fills a slot on the page. Deciding fullness on the parsed count
    /// would treat a full page as short and drop the next hundred PRs.
    func testUnparseableHitDoesNotLookLikeAShortPage() {
        let almost = Array(fullPage().dropLast())
        let searcher = FakeSearcher(pages: [
            .success(page(almost, items: GithubPRIndex.perPage, total: 250)),
            .success(page([pr(999, "[PROJ-1747] on the second page")], total: 250))
        ])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#999"])
    }

    // MARK: - A refusal is not an absence

    /// The core of the bug: a rate-limited search must not be cached as "no PRs", and must not
    /// wipe out the answer already in hand.
    func testRateLimitKeepsThePreviousAnswer() {
        let searcher = FakeSearcher(pages: [.success(page([pr(710, "[PROJ-1747] Reject a blank key")]))])
        let index = GithubPRIndex(searcher: searcher, ttl: 0, rateLimitCooldown: 0)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#710"])

        searcher.pages = [.failure(.rateLimited)]
        XCTAssertEqual(
            lookup(index, "PROJ-1747").map(\.id), ["#710"],
            "a rate-limited refresh must keep the PR, not clear it"
        )
    }

    func testRateLimitIsNotCachedSoTheNextTryRetries() {
        let searcher = FakeSearcher(pages: [.failure(.rateLimited)])
        let index = GithubPRIndex(searcher: searcher, rateLimitCooldown: 0)

        XCTAssertEqual(lookup(index, "PROJ-1747"), [])
        searcher.pages = [.success(page([pr(710, "[PROJ-1747] Reject a blank key")]))]

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#710"])
        XCTAssertEqual(searcher.requests.count, 2, "a failure must not stand in as a fresh snapshot")
    }

    /// Retrying immediately is what keeps the limit tripped, so a rate-limited project stops being
    /// searched for the cooldown and serves what it already had.
    func testRateLimitCooldownStopsFurtherSearches() {
        let searcher = FakeSearcher(pages: [.success(page([pr(710, "[PROJ-1747] a")]))])
        let index = GithubPRIndex(searcher: searcher, ttl: 0, rateLimitCooldown: 600)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#710"])
        searcher.pages = [.failure(.rateLimited)]
        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#710"])
        XCTAssertEqual(searcher.requests.count, 2)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#710"])
        XCTAssertEqual(lookup(index, "PROJ-1748"), [])
        XCTAssertEqual(searcher.requests.count, 2, "no more requests while the cooldown stands")
    }

    /// A page-2 failure leaves page 1's PRs in place: some PRs missing beats all PRs missing.
    func testLatePageFailureKeepsTheEarlierPage() {
        let searcher = FakeSearcher(pages: [
            .success(page(fullPage(), total: 250)),
            .failure(.rateLimited)
        ])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        XCTAssertEqual(lookup(index, "PROJ-42").map(\.id), ["#42"])
    }

    /// …but a partial answer must not displace a fuller one, or the fix reintroduces the symptom:
    /// the tickets matched only by page 2 would lose their PR row for a whole TTL.
    func testPartialRefetchDoesNotDisplaceAFullerSnapshot() {
        let onlyOnPageTwo = pr(999, "[PROJ-1747] only on page two")
        let searcher = FakeSearcher(pages: [
            .success(page(fullPage(), total: 200)),
            .success(page([onlyOnPageTwo], total: 200))
        ])
        let index = GithubPRIndex(searcher: searcher, ttl: 0, rateLimitCooldown: 0, maxPages: 2)

        XCTAssertEqual(lookup(index, "PROJ-1747").map(\.id), ["#999"])

        // Second pass: page 1 succeeds, page 2 is refused.
        searcher.pages = [.success(page(fullPage(), total: 200)), .failure(.rateLimited)]
        XCTAssertEqual(
            lookup(index, "PROJ-1747").map(\.id), ["#999"],
            "the page-2 PR must survive a page-2 rate limit"
        )
    }

    /// With nothing cached yet, a partial answer is better than none.
    func testLatePageFailureWithNoPreviousSnapshotServesThePartial() {
        let searcher = FakeSearcher(pages: [
            .success(page(fullPage(), total: 250)),
            .failure(.other)
        ])
        let index = GithubPRIndex(searcher: searcher, maxPages: 2)

        XCTAssertEqual(lookup(index, "PROJ-42").map(\.id), ["#42"])
    }

    // MARK: - Local matching

    /// GitHub tokenizes on the hyphen, so no query can separate these two — the local match must.
    func testDoesNotMatchAnotherProjectsSameNumber() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "[OTHER-42] not this one")]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-42"), [])
    }

    func testDoesNotMatchALongerKeyThatStartsTheSame() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "[PROJ-420] a later ticket")]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-42"), [], "PROJ-42 must not claim PROJ-420's PR")
    }

    /// The left edge stays permissive: a branch-style title must keep matching.
    func testMatchesKeyRunTogetherWithAPrefix() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "fix/PROJ-42 blank key")]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-42").map(\.id), ["#1"])
    }

    func testMatchesRegardlessOfCase() {
        let searcher = FakeSearcher(pages: [.success(page([pr(1, "proj-42 lowercase title")]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-42").map(\.id), ["#1"])
    }

    func testKeepsMergedAndClosedPRs() {
        let searcher = FakeSearcher(pages: [.success(page([
            pr(1, "[PROJ-1] merged", status: "MERGED"),
            pr(2, "[PROJ-1] declined", status: "DECLINED")
        ]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-1").map(\.status), ["MERGED", "DECLINED"])
    }

    func testNoSearchWithoutTokenOrgsOrAKey() {
        let searcher = FakeSearcher(pages: [.success(page([]))])
        let index = GithubPRIndex(searcher: searcher)

        XCTAssertEqual(lookup(index, "PROJ-1", orgs: []), [])
        XCTAssertEqual(lookup(index, "PROJ-1", token: ""), [])
        XCTAssertEqual(lookup(index, "PROJ-1", token: "   "), [])
        XCTAssertEqual(lookup(index, "not-a-key"), [])
        XCTAssertEqual(searcher.requests.count, 0)
    }

    // MARK: - Snapshot

    func testSnapshotRecordsWhetherTheWindowWasInPlay() {
        XCTAssertFalse(ProjectPRSnapshot(prs: [], truncated: false).truncated)
        XCTAssertTrue(ProjectPRSnapshot(prs: [], truncated: true).truncated)
    }

    func testSnapshotFreshness() {
        let snapshot = ProjectPRSnapshot(prs: [], truncated: false)
        XCTAssertTrue(snapshot.isFresh(ttl: 60))
        XCTAssertFalse(snapshot.isFresh(ttl: 0))
    }

    // MARK: - Key and query shapes

    func testProjectKeyExtraction() {
        XCTAssertEqual(GithubPRIndex.projectKey(ofIssueKey: "PROJ-1747"), "PROJ")
        XCTAssertEqual(GithubPRIndex.projectKey(ofIssueKey: " proj-1747 "), "PROJ")
        XCTAssertEqual(GithubPRIndex.projectKey(ofIssueKey: "AB2-9"), "AB2")
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "PROJ"))
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "-1747"))
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "PROJ-"))
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: ""))
        // A malformed key would otherwise spend one of thirty searches a minute matching nothing.
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "not-a-key"))
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "P-1"))
        XCTAssertNil(GithubPRIndex.projectKey(ofIssueKey: "PROJ-17a"))
    }

    func testProjectQueryShape() {
        XCTAssertEqual(
            GithubClient.projectPRsQuery(projectKey: "PROJ", orgs: [" Acme ", "", "Other"]),
            "PROJ in:title is:pr sort:updated-desc org:Acme org:Other"
        )
        XCTAssertEqual(
            GithubClient.projectPRsQuery(projectKey: "PROJ", orgs: []),
            "PROJ in:title is:pr sort:updated-desc"
        )
    }

    /// `is:open` would hide the merged PR that is the whole point of a closed ticket's row.
    func testProjectQueryIsNotRestrictedToOpenPRs() {
        XCTAssertFalse(
            GithubClient.projectPRsQuery(projectKey: "PROJ", orgs: ["Acme"]).contains("is:open")
        )
    }

    // MARK: - Telling a refusal from an absence

    private func response(_ code: Int, _ headers: [String: String]) -> HTTPURLResponse? {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/search/issues")!,
            statusCode: code,
            httpVersion: nil,
            headerFields: headers
        )
    }

    func testRateLimitClassification() {
        XCTAssertEqual(
            GithubClient.searchFailure(from: response(403, ["x-ratelimit-remaining": "0"])),
            .rateLimited
        )
        XCTAssertEqual(
            GithubClient.searchFailure(from: response(429, ["retry-after": "60"])),
            .rateLimited
        )
        // A 403 with budget left is a permission problem, not a rate limit.
        XCTAssertEqual(
            GithubClient.searchFailure(from: response(403, ["x-ratelimit-remaining": "12"])),
            .other
        )
        XCTAssertEqual(GithubClient.searchFailure(from: response(422, [:])), .other)
        XCTAssertEqual(GithubClient.searchFailure(from: nil), .other)
    }
}
