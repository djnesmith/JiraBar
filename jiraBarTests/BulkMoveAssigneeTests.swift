import XCTest
@testable import jiraBar

/// The assignee on a bulk-move row's key line: `DATA-1777  David NeSmith  PR#43 open`. The name
/// comes from the same search response the dialog's candidates are built from, and a ticket with no
/// assignee shows nothing there rather than the menu row's "Unassigned".
final class BulkMoveAssigneeTests: XCTestCase {

    func testAssignedIssueShowsTheDisplayName() {
        XCTAssertEqual(BulkMoveDialog.assigneeLabel(displayName: "David NeSmith"), "David NeSmith")
    }

    func testUnassignedIssueShowsNothing() {
        XCTAssertNil(BulkMoveDialog.assigneeLabel(displayName: nil))
    }

    /// A display name that is only whitespace would render as a gap the reader can't explain.
    func testBlankDisplayNameCountsAsUnassigned() {
        XCTAssertNil(BulkMoveDialog.assigneeLabel(displayName: "   "))
    }

    func testPaddedDisplayNameIsTrimmed() {
        XCTAssertEqual(BulkMoveDialog.assigneeLabel(displayName: "  David NeSmith  "), "David NeSmith")
    }
}
