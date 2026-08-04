import XCTest
@testable import jiraBar

final class ForgePRURLTests: XCTestCase {

    func testGithubPRURL() throws {
        let parsed = try XCTUnwrap(ForgePRURL("https://github.com/menubar-apps/JiraBar/pull/269"))
        XCTAssertEqual(parsed.scheme, "https")
        XCTAssertEqual(parsed.host, "github.com")
        XCTAssertEqual(parsed.owner, "menubar-apps")
        XCTAssertEqual(parsed.repo, "JiraBar")
        XCTAssertEqual(parsed.pullNumber, 269)
        XCTAssertEqual(parsed.slug, "menubar-apps/JiraBar")
        XCTAssertEqual(parsed.repoBase, "https://github.com/menubar-apps/JiraBar")
        XCTAssertTrue(parsed.isGithub)
    }

    func testRepoURLWithoutPullPath() throws {
        let parsed = try XCTUnwrap(ForgePRURL("https://github.com/owner/repo"))
        XCTAssertEqual(parsed.slug, "owner/repo")
        XCTAssertNil(parsed.pullNumber)
    }

    func testTrailingSegmentsAfterPullNumber() throws {
        let parsed = try XCTUnwrap(ForgePRURL("https://github.com/owner/repo/pull/42/files"))
        XCTAssertEqual(parsed.pullNumber, 42)
    }

    func testNonGithubHostStillParsesSlug() throws {
        // Bitbucket uses /pull-requests/<n> — slug parses, pullNumber does not.
        let parsed = try XCTUnwrap(ForgePRURL("https://bitbucket.org/team/proj/pull-requests/7"))
        XCTAssertEqual(parsed.slug, "team/proj")
        XCTAssertNil(parsed.pullNumber)
        XCTAssertFalse(parsed.isGithub)
    }

    func testGarbageInputs() {
        XCTAssertNil(ForgePRURL(""))
        XCTAssertNil(ForgePRURL("not a url"))
        XCTAssertNil(ForgePRURL("owner/repo/pull/1"))            // no scheme/host
        XCTAssertNil(ForgePRURL("https://github.com"))           // no path
        XCTAssertNil(ForgePRURL("https://github.com/owner"))     // one segment
    }

    func testNonNumericPullSegment() throws {
        let parsed = try XCTUnwrap(ForgePRURL("https://github.com/owner/repo/pull/abc"))
        XCTAssertNil(parsed.pullNumber)
    }
}
