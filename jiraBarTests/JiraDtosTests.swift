import XCTest
@testable import jiraBar

final class JiraDtosTests: XCTestCase {

    private func pr(id: String = "#42",
                    url: String = "https://github.com/o/r/pull/42",
                    reviewers: [JiraPRReviewer]? = nil) -> JiraPullRequest {
        JiraPullRequest(id: id, name: "title", url: url, status: "OPEN", reviewers: reviewers)
    }

    func testRepoSlug() {
        XCTAssertEqual(pr().repoSlug, "o/r")
        XCTAssertEqual(pr(url: "https://bitbucket.org/team/proj/pull-requests/7").repoSlug, "team/proj")
        XCTAssertEqual(pr(url: "garbage").repoSlug, "")
    }

    func testNumberOnlyStripsHash() {
        XCTAssertEqual(pr(id: "#42").numberOnly, "42")
        XCTAssertEqual(pr(id: "42").numberOnly, "42")
    }

    func testIsApproved() {
        XCTAssertFalse(pr(reviewers: nil).isApproved)
        XCTAssertFalse(pr(reviewers: [JiraPRReviewer(name: "a", approved: false)]).isApproved)
        XCTAssertTrue(pr(reviewers: [
            JiraPRReviewer(name: "a", approved: false),
            JiraPRReviewer(name: "b", approved: true)
        ]).isApproved)
    }
}
