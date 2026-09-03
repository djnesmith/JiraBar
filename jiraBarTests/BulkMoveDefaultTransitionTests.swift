import XCTest
@testable import jiraBar

/// The bulk-move "To" default.
///
/// The transition sets below are the real ones a live Jira returned for each status, and the status
/// order is a real configured one. That matters: the bug this covers was invisible to invented
/// fixtures, because it only appears when a workflow names its transitions for the action
/// ("Ready for Review") and its statuses for the state ("Review and Test") — which is the norm, and
/// which made the old name-to-name comparison fall through to an arbitrary pick every time.
final class BulkMoveDefaultTransitionTests: XCTestCase {

    private let statusOrder = [
        "Reopened", "To Do", "In Progress", "Review and Test", "QA", "Ready for Release", "Done",
    ]

    private func transition(_ id: String, _ name: String, to target: String?) -> Transition {
        Transition(name: name, id: id, to: target.map { IssueStatus(name: $0, iconUrl: nil) })
    }

    /// Available out of "To Do". Measured against a live Jira, like the sets below.
    private var fromToDo: [Transition] {
        [
            transition("11", "Start Progress", to: "In Progress"),
            transition("161", "Send to Backlog", to: "Open"),
            transition("61", "Force Close", to: "Done"),
        ]
    }

    /// Available out of "In Progress".
    private var fromInProgress: [Transition] {
        [
            transition("21", "Ready for Review", to: "Review and Test"),
            transition("81", "To Do", to: "To Do"),
            transition("61", "Force Close", to: "Done"),
        ]
    }

    /// Available out of "Review and Test".
    private var fromReviewAndTest: [Transition] {
        [
            transition("41", "Ready for QA", to: "QA"),
            transition("31", "Reopen", to: "Reopened"),
        ]
    }

    /// Available out of "Ready for Release". Measured against a live Jira.
    ///
    /// Note what is *not* here: `Force Close` is not offered from this status at all, so the
    /// alphabetical tie it would have won under the old code was never reachable here either.
    private var fromReadyForRelease: [Transition] {
        [
            transition("51", "Close", to: "Done"),
            transition("121", "Back to QA", to: "QA"),
        ]
    }

    /// Available out of "QA".
    private var fromQA: [Transition] {
        [
            transition("111", "To Release", to: "Ready for Release"),
            transition("141", "Done - Release Not Required", to: "Done"),
            transition("31", "Reopen", to: "Reopened"),
        ]
    }

    // MARK: - The forward edges, measured

    /// Every status in a real configured order, against the transition set a live Jira actually
    /// offers from it. The table is the point: the measured answer for a whole workflow rather than
    /// a claim about one edge, and it is what covers the two statuses with no test of their own.
    ///
    /// Note the Ready for Release row. `Close` targets Done, and Done *is* the next status from
    /// there — so defaulting to it is the legitimate forward move, not the failure
    /// `testNeverDefaultsToAClosingTransition` guards against. That is why the invariant is stated
    /// as "never defaults *past* the next status", not "never defaults to something that closes the
    /// ticket", and why Ready for Release is not in that test's list.
    ///
    /// To Do is the edge the TODO-backlog bulk move lands on: under the old name-matching code the
    /// fallback there was "Force Close".
    func testTheDefaultForEveryStatusInTheRealOrder() {
        let expected: [(String, [Transition], String)] = [
            ("To Do", fromToDo, "Start Progress"),
            ("In Progress", fromInProgress, "Ready for Review"),
            ("Review and Test", fromReviewAndTest, "Ready for QA"),
            ("QA", fromQA, "To Release"),
            ("Ready for Release", fromReadyForRelease, "Close"),
            ("Done", [], ""),
        ]
        for (from, available, want) in expected {
            XCTAssertEqual(
                BulkMoveDialog.defaultTransitionName(
                    fromStatus: from, statusOrder: statusOrder, available: available
                ),
                want,
                "wrong default out of \(from)"
            )
        }
    }

    /// `Force Close` is offered from To Do and In Progress, and is never what either defaults to.
    /// It is not offered at all from Ready for Release, the one status whose next entry is Done —
    /// so there is no status in this workflow from which it can be the default.
    func testForceCloseIsNeverTheDefaultFromAnyStatusThatOffersIt() {
        for (from, available) in [("To Do", fromToDo), ("In Progress", fromInProgress)] {
            XCTAssertTrue(
                available.contains { $0.name == "Force Close" },
                "fixture for \(from) no longer offers Force Close — this test has stopped testing anything"
            )
            XCTAssertNotEqual(
                BulkMoveDialog.defaultTransitionName(
                    fromStatus: from, statusOrder: statusOrder, available: available
                ),
                "Force Close",
                "defaulted to Force Close out of \(from)"
            )
        }
    }

    /// The regression this replaces. Every one of these transition names differs from the status it
    /// leads to, so a name-to-name comparison matches nothing and the old code took the
    /// alphabetically-first entry — "Force Close" out of In Progress, "Done - Release Not Required"
    /// out of QA. Both close the ticket, applied to every checked issue at once.
    func testNeverDefaultsToAClosingTransition() {
        for (from, available) in [
            ("To Do", fromToDo),
            ("In Progress", fromInProgress),
            ("Review and Test", fromReviewAndTest),
            ("QA", fromQA),
        ] {
            let picked = BulkMoveDialog.defaultTransitionName(
                fromStatus: from, statusOrder: statusOrder, available: available
            )
            let target = available.first { $0.name == picked }?.to?.name
            XCTAssertNotEqual(target, "Done", "defaulted to a Done-ward transition out of \(from)")
        }
    }

    // MARK: - Selecting nothing

    /// No transition reaches the next status, so nothing is selected. One extra click beats a bulk
    /// transition nobody chose.
    func testSelectsNothingWhenNoTransitionReachesTheNextStatus() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "In Progress",
                statusOrder: statusOrder,
                available: [transition("61", "Force Close", to: "Done")]
            ),
            ""
        )
    }

    /// Deliberately not scanned further ahead: "Done" is reachable here and is the next-but-three
    /// status, and picking it is exactly the failure being removed.
    func testDoesNotSkipAheadToALaterStatus() {
        let available = [
            transition("61", "Force Close", to: "Done"),
            transition("31", "Reopen", to: "Reopened"),
        ]
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "In Progress", statusOrder: statusOrder, available: available
            ),
            ""
        )
    }

    func testSelectsNothingWhenFromStatusIsLastInOrder() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "Done", statusOrder: statusOrder, available: fromInProgress
            ),
            ""
        )
    }

    /// A status the user has not put in their order has no "next", so there is nothing to default to.
    func testSelectsNothingWhenFromStatusIsNotInTheOrder() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "Blocked", statusOrder: statusOrder, available: fromInProgress
            ),
            ""
        )
    }

    func testSelectsNothingWithNoAvailableTransitions() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "In Progress", statusOrder: statusOrder, available: []
            ),
            ""
        )
    }

    func testSelectsNothingWithAnEmptyStatusOrder() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "In Progress", statusOrder: [], available: fromInProgress
            ),
            ""
        )
    }

    // MARK: - Matching rules

    /// Statuses are matched case-insensitively everywhere else in the app (`StatusDisplay.name`),
    /// so the from-status and the target both are here.
    func testMatchesStatusesCaseInsensitively() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "in progress",
                statusOrder: statusOrder,
                available: [transition("21", "Ready for Review", to: "REVIEW AND TEST")]
            ),
            "Ready for Review"
        )
    }

    /// A transition whose target status Jira omitted cannot be matched, and must not be guessed at
    /// from its name.
    func testATransitionWithNoTargetStatusIsNeverPicked() {
        XCTAssertEqual(
            BulkMoveDialog.defaultTransitionName(
                fromStatus: "In Progress",
                statusOrder: statusOrder,
                available: [transition("21", "Review and Test", to: nil)]
            ),
            ""
        )
    }

    /// Returns the available transition's own spelling, which is what the picker tags are built
    /// from — a differently-cased string would select nothing in the UI.
    func testReturnsTheTransitionsOwnSpelling() {
        let picked = BulkMoveDialog.defaultTransitionName(
            fromStatus: "In Progress", statusOrder: statusOrder, available: fromInProgress
        )
        XCTAssertTrue(fromInProgress.contains { $0.name == picked })
    }

    // MARK: - resolvedSelection: whose choice survives a narrowed intersection

    func testKeepsASelectionThatIsStillOffered() {
        let resolved = BulkMoveDialog.resolvedSelection(
            current: "Force Close", isDefault: false, available: fromInProgress,
            fromStatus: "In Progress", statusOrder: statusOrder
        )
        XCTAssertEqual(resolved.name, "Force Close")
        XCTAssertFalse(resolved.isDefault)
    }

    /// The user picked this and it is no longer on offer. It clears rather than being swapped for
    /// the default: Submit must go back to needing a decision, not stay armed with a transition
    /// they never chose, across every checked issue.
    func testClearsTheUsersOwnPickWhenNoLongerOffered() {
        let resolved = BulkMoveDialog.resolvedSelection(
            current: "Force Close", isDefault: false, available: fromQA,
            fromStatus: "QA", statusOrder: statusOrder
        )
        XCTAssertEqual(resolved.name, "")
        XCTAssertFalse(resolved.isDefault)
    }

    /// Nobody chose this one, so replacing it is invisible and harmless.
    func testRedefaultsAnUntouchedDefaultWhenNoLongerOffered() {
        let resolved = BulkMoveDialog.resolvedSelection(
            current: "Ready for Review", isDefault: true, available: fromQA,
            fromStatus: "QA", statusOrder: statusOrder
        )
        XCTAssertEqual(resolved.name, "To Release")
        XCTAssertTrue(resolved.isDefault)
    }

    /// Nothing selected yet is the untouched-default case, which is how a first default lands.
    func testFillsAnEmptySelectionWithTheDefault() {
        let resolved = BulkMoveDialog.resolvedSelection(
            current: "", isDefault: true, available: fromInProgress,
            fromStatus: "In Progress", statusOrder: statusOrder
        )
        XCTAssertEqual(resolved.name, "Ready for Review")
        XCTAssertTrue(resolved.isDefault)
    }

    /// Transitions not loaded yet, or no issue checked. Nothing to select, and a user's pick is
    /// still not silently substituted on the way back.
    func testClearsWhenNothingIsAvailable() {
        let asDefault = BulkMoveDialog.resolvedSelection(
            current: "Ready for Review", isDefault: true, available: [],
            fromStatus: "In Progress", statusOrder: statusOrder
        )
        XCTAssertEqual(asDefault.name, "")

        let asUserPick = BulkMoveDialog.resolvedSelection(
            current: "Ready for Review", isDefault: false, available: [],
            fromStatus: "In Progress", statusOrder: statusOrder
        )
        XCTAssertEqual(asUserPick.name, "")
        XCTAssertFalse(asUserPick.isDefault)
    }

    /// Once the user's pick has been cleared, a later recompute must not quietly default over it.
    func testAClearedUserPickIsNotLaterDefaulted() {
        let cleared = BulkMoveDialog.resolvedSelection(
            current: "Force Close", isDefault: false, available: fromQA,
            fromStatus: "QA", statusOrder: statusOrder
        )
        let again = BulkMoveDialog.resolvedSelection(
            current: cleared.name, isDefault: cleared.isDefault, available: fromQA,
            fromStatus: "QA", statusOrder: statusOrder
        )
        XCTAssertEqual(again.name, "")
        XCTAssertFalse(again.isDefault)
    }

    // MARK: - Decoding

    func testDecodesTransitionWithTargetStatus() throws {
        let json = """
        {"transitions":[{"id":"21","name":"Ready for Review","to":{"name":"Review and Test"}}]}
        """
        let decoded = try JSONDecoder().decode(TransitionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transitions.first?.to?.name, "Review and Test")
    }

    /// The target status is a convenience for picking a default. A response without it still has to
    /// yield a usable transition list, or every transition in the app stops working over a field
    /// only this feature reads.
    func testDecodesTransitionWithoutTargetStatus() throws {
        let json = """
        {"transitions":[{"id":"21","name":"Ready for Review"}]}
        """
        let decoded = try JSONDecoder().decode(TransitionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transitions.count, 1)
        XCTAssertEqual(decoded.transitions.first?.name, "Ready for Review")
        XCTAssertNil(decoded.transitions.first?.to)
    }
}
