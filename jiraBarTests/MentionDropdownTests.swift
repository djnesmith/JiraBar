import XCTest
@testable import jiraBar

/// The dropdown's own state machine, driven the way typing drives it. No network: `apply(users:…)`
/// stands in for a lookup that has come back.
///
/// `MentionDropdown` holds no copy of the comment text — it is handed each new value and hands back
/// picks — which is what makes "dismissing leaves the text exactly as typed" structural rather than
/// something to remember.
@MainActor
final class MentionDropdownTests: XCTestCase {

    private func user(_ displayName: String, _ accountId: String) -> JiraUser {
        JiraUser(
            accountId: accountId, name: nil, key: nil, displayName: displayName,
            emailAddress: nil, active: true, accountType: "atlassian"
        )
    }

    /// Opens a dropdown on "@dan" with three Dans loaded.
    private func opened() -> MentionDropdown {
        let dropdown = MentionDropdown()
        dropdown.setFocused(true)
        dropdown.seed(text: "")
        dropdown.retrigger(text: "@dan")
        dropdown.apply(
            users: [user("Dana One", "a"), user("Dana Two", "b"), user("Dana Three", "c")],
            forQuery: "dan"
        )
        return dropdown
    }

    func testOpensOnAPartialNameWithMatches() {
        let dropdown = opened()
        XCTAssertTrue(dropdown.isOpen)
        XCTAssertEqual(dropdown.matches.count, 3)
        XCTAssertEqual(dropdown.query?.text, "dan")
    }

    /// The first row is highlighted before any arrow key, which is what makes "type three letters,
    /// hit Tab" work.
    func testFirstMatchIsHighlightedByDefault() {
        XCTAssertEqual(opened().highlight, 0)
    }

    func testWithoutFocusThereIsNoDropdown() {
        let dropdown = MentionDropdown()
        dropdown.seed(text: "")
        dropdown.retrigger(text: "@dan")
        dropdown.apply(users: [user("Dana One", "a")], forQuery: "dan")
        XCTAssertFalse(dropdown.isOpen)
    }

    func testNoMatchesMeansNoDropdown() {
        let dropdown = MentionDropdown()
        dropdown.setFocused(true)
        dropdown.seed(text: "")
        dropdown.retrigger(text: "@zzz")
        dropdown.apply(users: [], forQuery: "zzz")
        XCTAssertFalse(dropdown.isOpen)
    }

    /// Leaving the field closes the list. Without this the dropdown stayed drawn over a field that no
    /// longer had focus, and the dialogs' mirrored flag stuck — which strands Return on the submit
    /// button, or lets an invisible dropdown swallow it.
    func testLosingFocusClosesTheDropdown() {
        let dropdown = opened()
        dropdown.setFocused(false)
        XCTAssertFalse(dropdown.isOpen)
        XCTAssertNil(dropdown.query)
        XCTAssertTrue(dropdown.matches.isEmpty)
    }

    /// And coming back does not resurrect a list built for a query that was abandoned.
    func testRegainingFocusDoesNotResurrectTheOldList() {
        let dropdown = opened()
        dropdown.setFocused(false)
        dropdown.setFocused(true)
        XCTAssertFalse(dropdown.isOpen)
    }

    // MARK: - Escape nesting

    /// One Escape closes the dropdown and nothing else — and the next keystroke of the same token
    /// does not bring it back, so the dismissal sticks.
    func testEscapeClosesTheDropdownAndItStaysClosedForThatToken() {
        let dropdown = opened()
        dropdown.dismiss()
        XCTAssertFalse(dropdown.isOpen)
        XCTAssertNil(dropdown.query)

        dropdown.retrigger(text: "@dana")
        XCTAssertFalse(dropdown.isOpen, "a refused token must not spring back on the next keystroke")
    }

    /// Moving off the refused token clears the refusal, so a later `@` still works.
    func testANewTokenAfterAnEscapeStillOpens() {
        let dropdown = opened()
        dropdown.dismiss()
        dropdown.retrigger(text: "@dan and @dan")
        dropdown.apply(users: [user("Dana One", "a")], forQuery: "dan")
        XCTAssertTrue(dropdown.isOpen)
    }

    // MARK: - Highlight integrity

    /// Narrowing the list replaces the rows wholesale, so a held index would point at somebody the
    /// user never looked at — and Tab would commit them.
    func testHighlightResetsWhenTheRowSetChanges() {
        let dropdown = opened()
        dropdown.moveHighlight(by: 2)
        XCTAssertEqual(dropdown.highlight, 2)

        dropdown.apply(users: [user("Dana Nine", "z"), user("Dana Ten", "y")], forQuery: "dan")
        XCTAssertEqual(dropdown.highlight, 0)
    }

    /// A refresh that returns the same people must not throw away an arrow-key selection.
    func testHighlightSurvivesARefreshWithTheSameRows() {
        let dropdown = opened()
        dropdown.moveHighlight(by: 2)
        dropdown.apply(
            users: [user("Dana One", "a"), user("Dana Two", "b"), user("Dana Three", "c")],
            forQuery: "dan"
        )
        XCTAssertEqual(dropdown.highlight, 2)
    }

    func testHighlightClampsWhenTheListGetsShorter() {
        let dropdown = opened()
        dropdown.moveHighlight(by: 5)
        XCTAssertEqual(dropdown.highlight, 2)
    }

    /// A lookup for an earlier prefix landing late must not replace what is on screen now.
    func testALateAnswerForAnEarlierPrefixIsIgnored() {
        let dropdown = opened()
        dropdown.retrigger(text: "@danat")
        dropdown.apply(users: [user("Unrelated Person", "q")], forQuery: "xyz")
        XCTAssertFalse(dropdown.matches.contains { $0.displayName == "Unrelated Person" })
    }

    // MARK: - Committing

    func testPickHandsBackTheHighlightedUserAndCloses() {
        let dropdown = opened()
        var picked: JiraUser?
        dropdown.onCommit = { user, _ in picked = user }
        dropdown.moveHighlight(by: 1)
        dropdown.pick(dropdown.highlight)

        XCTAssertEqual(picked?.accountId, "b")
        XCTAssertFalse(dropdown.isOpen)
    }

    func testPickOutsideTheListDoesNothing() {
        let dropdown = opened()
        var called = false
        dropdown.onCommit = { _, _ in called = true }
        dropdown.pick(99)
        XCTAssertFalse(called)
        XCTAssertTrue(dropdown.isOpen)
    }
}
