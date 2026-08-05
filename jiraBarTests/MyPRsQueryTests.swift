import XCTest
@testable import jiraBar

/// Guards the "My PRs" search qualifiers. A missing qualifier hides an entire category of PRs
/// with no error anywhere — which is exactly how authored PRs went missing: opening a PR
/// neither assigns it to you nor requests your review, so it matched only `author:@me`.
final class MyPRsQueryTests: XCTestCase {

    func testCoversAuthorAssigneeAndReviewRequested() {
        let queries = GithubClient.myPRsQueries(orgs: [])
        XCTAssertEqual(queries.count, 3)
        XCTAssertTrue(queries.contains("is:pr is:open author:@me"))
        XCTAssertTrue(queries.contains("is:pr is:open assignee:@me"))
        XCTAssertTrue(queries.contains("is:pr is:open review-requested:@me"))
    }

    func testEveryQueryIsOpenPRsOnly() {
        for q in GithubClient.myPRsQueries(orgs: ["acme"]) {
            XCTAssertTrue(q.hasPrefix("is:pr is:open "), "missing is:pr/is:open in: \(q)")
        }
    }

    func testScopesToOrgsWhenProvided() {
        let queries = GithubClient.myPRsQueries(orgs: ["acme", "acme-labs"])
        for q in queries {
            XCTAssertTrue(q.hasSuffix("org:acme org:acme-labs"), "bad org scoping: \(q)")
        }
    }

    /// Blank/whitespace entries would otherwise produce a dangling "org:" that matches nothing.
    func testIgnoresBlankOrgEntries() {
        let queries = GithubClient.myPRsQueries(orgs: ["  ", "", " acme "])
        for q in queries {
            XCTAssertTrue(q.hasSuffix("org:acme"), "bad org scoping: \(q)")
            XCTAssertFalse(q.contains("org: "), "dangling org term in: \(q)")
        }
    }

    func testNoTrailingSpaceWhenUnscoped() {
        for q in GithubClient.myPRsQueries(orgs: []) {
            XCTAssertEqual(q, q.trimmingCharacters(in: .whitespaces))
        }
    }
}
