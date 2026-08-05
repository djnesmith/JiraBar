import XCTest
@testable import jiraBar

/// Guards the "PRs Without Tickets" search qualifiers and the handed-off filter. A missing
/// qualifier hides an entire category of PRs with no error anywhere — which is exactly how
/// authored PRs went missing: opening a PR neither assigns it to you nor requests your
/// review, so it matched only `author:@me`.
final class MyPRsQueryTests: XCTestCase {

    private func queries(_ orgs: [String] = []) -> [String] {
        GithubClient.myPRsQueries(orgs: orgs).map(\.query)
    }

    // MARK: - Qualifier coverage

    func testCoversAuthorAssigneeAndReviewRequested() {
        let qs = queries()
        XCTAssertEqual(qs.count, 3)
        XCTAssertTrue(qs.contains("is:pr is:open author:@me"))
        XCTAssertTrue(qs.contains("is:pr is:open assignee:@me"))
        XCTAssertTrue(qs.contains("is:pr is:open review-requested:@me"))
    }

    func testEveryQueryIsOpenPRsOnly() {
        for q in queries(["acme"]) {
            XCTAssertTrue(q.hasPrefix("is:pr is:open "), "missing is:pr/is:open in: \(q)")
        }
    }

    func testScopesToOrgsWhenProvided() {
        for q in queries(["acme", "acme-labs"]) {
            XCTAssertTrue(q.hasSuffix("org:acme org:acme-labs"), "bad org scoping: \(q)")
        }
    }

    /// Blank entries would otherwise produce a dangling "org:" that matches nothing.
    func testIgnoresBlankOrgEntries() {
        for q in queries(["  ", "", " acme "]) {
            XCTAssertTrue(q.hasSuffix("org:acme"), "bad org scoping: \(q)")
            XCTAssertFalse(q.contains("org: "), "dangling org term in: \(q)")
        }
    }

    func testNoTrailingSpaceWhenUnscoped() {
        for q in queries() {
            XCTAssertEqual(q, q.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Ownership semantics

    func testOnlyAssigneeAndReviewerImplyOwnership() {
        XCTAssertFalse(GithubClient.MyPRsRelation.author.impliesOwnership)
        XCTAssertTrue(GithubClient.MyPRsRelation.assignee.impliesOwnership)
        XCTAssertTrue(GithubClient.MyPRsRelation.reviewRequested.impliesOwnership)
    }

    // MARK: - Handed-off filter

    private func hit(_ url: String, ownedByMe: Bool, assignees: [String]) -> GithubClient.MyPRHit {
        GithubClient.MyPRHit(
            pr: JiraPullRequest(id: "#1", name: "t", url: url, status: "OPEN", reviewers: nil),
            ownedByMe: ownedByMe,
            assigneeLogins: assignees
        )
    }

    /// The case this filter exists for: I wrote it, handed it to a colleague, and the review
    /// request went to them — it's no longer mine to act on, so it must not be listed.
    func testDropsHandedOffPRAuthoredByMeAndAssignedToSomeoneElse() {
        let hits = [hit("https://github.com/o/r/pull/1", ownedByMe: false, assignees: ["colleague"])]
        XCTAssertTrue(GithubClient.retainingOwnPRs(hits).isEmpty)
    }

    /// Authored by me and never handed to anyone — still mine.
    func testKeepsAuthoredUnassignedPR() {
        let hits = [hit("https://github.com/o/r/pull/2", ownedByMe: false, assignees: [])]
        XCTAssertEqual(GithubClient.retainingOwnPRs(hits).map(\.url), ["https://github.com/o/r/pull/2"])
    }

    /// Assigned to me, so the assignee query claimed it — whoever wrote it, and even though
    /// other people are assigned alongside me.
    func testKeepsPRAssignedToMeEvenWithCoAssignees() {
        let hits = [hit("https://github.com/o/r/pull/3", ownedByMe: true, assignees: ["me", "colleague"])]
        XCTAssertEqual(GithubClient.retainingOwnPRs(hits).map(\.url), ["https://github.com/o/r/pull/3"])
    }

    /// Someone else's PR awaiting my review: assigned to them, but the review-requested query
    /// claimed it, so it stays.
    func testKeepsOthersPRAwaitingMyReview() {
        let hits = [hit("https://github.com/o/r/pull/4", ownedByMe: true, assignees: ["author"])]
        XCTAssertEqual(GithubClient.retainingOwnPRs(hits).map(\.url), ["https://github.com/o/r/pull/4"])
    }

    func testPreservesOrderOfSurvivors() {
        let hits = [
            hit("https://github.com/o/r/pull/1", ownedByMe: false, assignees: []),
            hit("https://github.com/o/r/pull/2", ownedByMe: false, assignees: ["colleague"]), // dropped
            hit("https://github.com/o/r/pull/3", ownedByMe: true, assignees: ["colleague"])
        ]
        XCTAssertEqual(
            GithubClient.retainingOwnPRs(hits).map(\.url),
            ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/3"]
        )
    }

    func testEmptyInput() {
        XCTAssertTrue(GithubClient.retainingOwnPRs([]).isEmpty)
    }
}
