import XCTest
@testable import jiraBar

/// Records notifications instead of delivering them, and puts the real sink back afterwards.
///
/// The app under test is its own test host, so an un-injected notification call reaches the
/// developer's actual Notification Center — banner, badge and sound. Substituting the sink is both
/// what stops that and what lets these tests assert the exact text, which is what the
/// failure-reporting behaviour actually needs pinned.
final class RecordingNotice {
    private(set) var recorded: [String] = []
    private let previous: (String) -> Void

    init() {
        previous = UserNotice.deliver
        UserNotice.deliver = { [weak self] body in self?.recorded.append(body) }
    }

    func restore() {
        UserNotice.deliver = previous
    }

    /// Safety net for a test class that forgets `restore()`. Without it the recorder deallocs, the
    /// seam keeps pointing at a closure whose `self` is nil, and every later notification in the
    /// process vanishes silently — with nothing failing, because nothing else asserts on them.
    deinit {
        restore()
    }
}

final class UserNoticeInjectionTests: XCTestCase {

    private var notice: RecordingNotice!

    override func setUp() {
        super.setUp()
        notice = RecordingNotice()
    }

    override func tearDown() {
        notice.restore()
        notice = nil
        super.tearDown()
    }

    func testSendNotificationGoesThroughTheSeam() {
        sendNotification(body: "hello")
        sendNotification(body: "again")

        XCTAssertEqual(notice.recorded, ["hello", "again"], "nothing reached the real notification centre")
    }

    /// The summary a PR-actions batch posts, asserted as delivered text rather than by reading the
    /// function. This is requirement 1's contract: a failure is never silent, and never phrased as
    /// a skip.
    func testFailedBatchDeliversAFailureLeadingSummary() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2
        tally.reviewFailed = ["acme/api #2"]

        sendNotification(body: AppDelegate.prActionsSummaryBody(
            issueKey: "JB-7",
            actions: PRActionChoices(
                review: .requestChanges, reviewComment: "needs a test",
                merge: false, mergeMethod: "rebase", syncAssignee: false
            ),
            candidateCount: 3,
            reviewTargetCount: 3,
            tally: tally
        ))

        XCTAssertEqual(notice.recorded.count, 1, "one summary per batch, not one per PR")
        let body = notice.recorded[0]
        XCTAssertTrue(body.hasPrefix("PR actions for JB-7: 1 FAILED"), body)
        XCTAssertTrue(body.contains("requested changes on 2/3"), body)
    }

    func testCleanBatchDeliversNoFailureWording() {
        var tally = AppDelegate.PRActionTally()
        tally.reviewOK = 2

        sendNotification(body: AppDelegate.prActionsSummaryBody(
            issueKey: "JB-7",
            actions: PRActionChoices(
                review: .requestChanges, reviewComment: "needs a test",
                merge: false, mergeMethod: "rebase", syncAssignee: false
            ),
            candidateCount: 2,
            reviewTargetCount: 2,
            tally: tally
        ))

        XCTAssertEqual(notice.recorded.count, 1)
        XCTAssertFalse(notice.recorded[0].contains("FAILED"), notice.recorded[0])
    }
}

/// An unconfigured instance is why the test host used to post a real DNS-failure banner on every
/// run: it searched `https://.atlassian.net`, failed, and notified.
///
/// Asserted against the pure `isConfigured` rather than a live `JiraClient`. Instantiating the client
/// reads the running machine's own preferences — on this machine the debug domain already carries a
/// `jiraHost`, so a client-based test would pass or fail depending on which instance type happened to
/// be selected, and under Self-Hosted it would fire a real authenticated request. That is the same
/// "a test reached a process-global" defect this commit exists to remove, one layer down.
final class UnconfiguredInstanceTests: XCTestCase {

    func testCloudNeedsAnOrg() {
        XCTAssertFalse(JiraClient.isConfigured(instanceType: .cloud, orgName: "", jiraHost: ""))
        XCTAssertFalse(
            JiraClient.isConfigured(instanceType: .cloud, orgName: "   ", jiraHost: ""),
            "whitespace still builds https://.atlassian.net"
        )
        XCTAssertTrue(JiraClient.isConfigured(instanceType: .cloud, orgName: "acme", jiraHost: ""))
    }

    /// A host configured for the *other* instance type must not count as configured — the shape that
    /// would have made this suite fire a live request.
    func testCloudIgnoresAServerHost() {
        XCTAssertFalse(
            JiraClient.isConfigured(instanceType: .cloud, orgName: "", jiraHost: "https://jira.example.com")
        )
    }

    func testServerNeedsAHost() {
        XCTAssertFalse(JiraClient.isConfigured(instanceType: .server, orgName: "acme", jiraHost: ""))
        XCTAssertFalse(JiraClient.isConfigured(instanceType: .server, orgName: "acme", jiraHost: "  "))
        XCTAssertTrue(
            JiraClient.isConfigured(instanceType: .server, orgName: "", jiraHost: "https://jira.example.com")
        )
    }
}
