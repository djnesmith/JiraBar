import XCTest
import AppKit
@testable import jiraBar

final class AppDelegateHelpersTests: XCTestCase {

    // MARK: - branchName

    func testBranchNameSlugsTitle() {
        XCTAssertEqual(
            AppDelegate.branchName(forKey: "PROJ-1234", title: "Fix flaky login!"),
            "PROJ-1234-fix-flaky-login"
        )
    }

    func testBranchNameCollapsesAndTrimsHyphens() {
        XCTAssertEqual(
            AppDelegate.branchName(forKey: "PROJ-1", title: "  [Spike] -- weird   title??  "),
            "PROJ-1-spike-weird-title"
        )
    }

    func testBranchNameCapsSlugLength() {
        let title = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 40)
        let name = AppDelegate.branchName(forKey: "PROJ-1", title: title, maxSlugLength: 50)
        XCTAssertEqual(name, "PROJ-1-" + String(repeating: "a", count: 40) + "-" + String(repeating: "b", count: 9))
    }

    func testBranchNameFallsBackToKeyWhenSlugEmpty() {
        XCTAssertEqual(AppDelegate.branchName(forKey: "PROJ-1", title: "!!!"), "PROJ-1")
    }

    // MARK: - prNumber / repoBaseURL

    func testPRNumber() {
        XCTAssertEqual(AppDelegate.prNumber(from: "https://github.com/o/r/pull/269"), "269")
        XCTAssertNil(AppDelegate.prNumber(from: "https://github.com/o/r"))
        XCTAssertNil(AppDelegate.prNumber(from: "https://github.com/o/r/pull/xyz"))
    }

    func testRepoBaseURL() {
        XCTAssertEqual(
            AppDelegate.repoBaseURL(from: "https://github.com/o/r/pull/269"),
            "https://github.com/o/r"
        )
        XCTAssertNil(AppDelegate.repoBaseURL(from: "https://github.com"))
    }

    // MARK: - targetURL

    func testTargetURLModifierRouting() {
        let pr = "https://github.com/o/r/pull/42"
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: []), pr)
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .command), "https://github.com/o/r/releases/new")
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .option), "https://github.com/o/r/actions")
        XCTAssertEqual(AppDelegate.targetURL(forPR: pr, modifiers: .control), "https://github.com/o/r")
    }

    func testTargetURLFallsBackToPRWhenUnparseable() {
        XCTAssertEqual(AppDelegate.targetURL(forPR: "garbage", modifiers: .command), "garbage")
    }

    // MARK: - prStatusColorHex

    func testPRStatusColors() {
        XCTAssertEqual(AppDelegate.prStatusColorHex("MERGED"), "#2DA44E")
        XCTAssertEqual(AppDelegate.prStatusColorHex("open"), "#DAA520")
        XCTAssertEqual(AppDelegate.prStatusColorHex("DECLINED"), "#CF222E")
        XCTAssertEqual(AppDelegate.prStatusColorHex("DRAFT"), "#DAA520")
        XCTAssertEqual(AppDelegate.prStatusColorHex("SOMETHING"), "#888888")
    }
}
