import XCTest
@testable import jiraBar

/// The post-write catch-up schedule: Jira's search index trails a write, so the refresh fired from
/// a transition's completion often cannot see it and the menu has to be rebuilt again later.
final class CatchUpRefreshScheduleTests: XCTestCase {

    /// Five compressed delays, deliberately not the shipped two: these exercise the mechanism —
    /// fires, restarts, cancellation — at test speed and independently of how many ticks ship.
    /// `testShippedDelaysCoverTheMeasuredMisses` is what pins the shipped values.
    private let delays: [TimeInterval] = [0.05, 0.10, 0.15, 0.20, 0.25]

    private func settle(_ seconds: TimeInterval) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2.0)
    }

    // MARK: - The schedule fires

    func testEveryDelayFires() {
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: delays, queue: .main, isBusy: { false }, action: { count += 1 }
        )
        schedule.restart()
        settle(0.5)
        XCTAssertEqual(count, delays.count, "every scheduled catch-up must run")
    }

    /// The shipped offsets against the misses that were actually measured, since the schedule is
    /// only defensible in terms of them: the first tick has to clear the cluster and the last has to
    /// land past the outlier. Asserted as the two claims rather than per-miss — the list is
    /// ascending, so "some tick is later than this miss" is implied by the last one being.
    ///
    /// The count is asserted too, and deliberately. Each tick costs 3 uncached GitHub search
    /// requests against a 30/minute budget, so a tick added without a measured miss behind it
    /// spends a section of the menu on nothing — this is the test that makes that argument again.
    func testShippedDelaysCoverTheMeasuredMisses() {
        let measuredMisses: [TimeInterval] = [0.719, 0.787, 1.041, 1.099, 1.452, 1.630, 11.167]
        let shipped = CatchUpRefreshSchedule.defaultDelays
        XCTAssertEqual(shipped, [3, 20])
        XCTAssertEqual(
            measuredMisses.filter { $0 < shipped.first! }.count, 6,
            "the first tick is what makes this cheap — it must still clear the cluster"
        )
        // Headroom, not just coverage: the first tick has to clear the slowest non-outlier by a
        // real margin, or a miss slightly worse than anything measured falls into the gap before
        // the second tick and waits the whole way for it.
        XCTAssertGreaterThan(
            shipped.first! - 1.630, 1.0,
            "the first tick must clear the slowest non-outlier miss by more than a second"
        )
        XCTAssertGreaterThan(
            shipped.last!, measuredMisses.max()!,
            "the last tick must land beyond the worst measured miss"
        )
    }

    func testNothingFiresUntilStarted() {
        var count = 0
        _ = CatchUpRefreshSchedule(
            delays: delays, queue: .main, isBusy: { false }, action: { count += 1 }
        )
        settle(0.4)
        XCTAssertEqual(count, 0, "constructing a schedule must not schedule anything")
    }

    // MARK: - Restart, not stack

    /// A second transition while a schedule is running restarts it. Stacking would double the
    /// request volume for no extra coverage, and it is the newer write whose visibility is in doubt.
    ///
    /// The restart is driven from inside the first tick rather than at a wall-clock instant: an
    /// assertion about how many ticks have fired at t=0.12s fails whenever the main queue stalls
    /// past 130ms, and the test host runs a live app instance in the same process. Firing from
    /// inside tick #1 pins the same behaviour to an event no stall can reorder.
    func testASecondWriteRestartsRatherThanStacks() {
        var count = 0
        var schedule: CatchUpRefreshSchedule!
        let restarted = expectation(description: "restarted from inside the first tick")
        schedule = CatchUpRefreshSchedule(
            delays: delays, queue: .main, isBusy: { false },
            action: {
                count += 1
                if count == 1 {
                    // Four ticks of this schedule are still pending here, whatever the timing.
                    schedule.restart()
                    restarted.fulfill()
                }
            }
        )
        schedule.restart()
        wait(for: [restarted], timeout: 2.0)
        settle(0.6)
        XCTAssertEqual(
            count, 1 + delays.count,
            "the four ticks still pending at the restart must be replaced, not joined by a second set"
        )
    }

    func testRestartLeavesExactlyOneSchedulePending() {
        let schedule = CatchUpRefreshSchedule(
            delays: delays, queue: .main, isBusy: { false }, action: {}
        )
        schedule.restart()
        schedule.restart()
        schedule.restart()
        XCTAssertEqual(schedule.pendingCount, delays.count,
                       "three restarts must leave one schedule's worth of ticks, not three")
    }

    /// Two ticks deferred into the *same* busy window merge into one refresh rather than each
    /// surviving as its own. That is the property, and it is not the same as
    /// `testATickLandingDuringARefreshIsNotLost` above: this one is the only thing guarding the
    /// single `rearm` slot, so without it a deferred tick could accumulate one refresh per tick and
    /// nothing would notice. Merging is correct — both ticks want the same thing, and one rebuild
    /// after the in-flight refresh satisfies both.
    func testTicksDeferredIntoOneBusyWindowMergeIntoASingleRefresh() {
        var busy = true
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: [0.05, 0.10], rearmInterval: 0.05, queue: .main,
            isBusy: { busy }, action: { count += 1 }
        )
        schedule.restart()
        settle(0.3)
        XCTAssertEqual(count, 0, "nothing may run while the refresh is in flight")
        busy = false
        settle(0.4)
        XCTAssertEqual(count, 1, "two deferred ticks must yield one refresh, not one each")
    }

    // MARK: - Cancellation

    func testCancelStopsEverythingStillPending() {
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: delays, queue: .main, isBusy: { false }, action: { count += 1 }
        )
        schedule.restart()
        schedule.cancel()
        settle(0.5)
        XCTAssertEqual(count, 0, "a cancelled schedule must not fire")
        XCTAssertEqual(schedule.pendingCount, 0)
    }

    // MARK: - A tick must never be silently dropped

    /// `refreshMenu` opens with `guard !isRefreshing else { return }`, so a tick landing during an
    /// in-flight refresh would vanish into that guard — and the in-flight refresh's searches
    /// started before the tick, so its answer is the stale one the tick exists to replace. Dropping
    /// the first tick costs the most: it is the one that clears six of the seven measured misses.
    func testATickLandingDuringARefreshIsNotLost() {
        var busy = true
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: [0.05], rearmInterval: 0.05, queue: .main,
            isBusy: { busy }, action: { count += 1 }
        )
        schedule.restart()
        settle(0.2)
        XCTAssertEqual(count, 0, "it must not run while a refresh is in flight")
        busy = false
        settle(0.3)
        XCTAssertEqual(count, 1, "the deferred tick must run once the refresh finishes")
    }

    /// Staying busy must not accumulate re-arms — one put-off tick waits on the same condition as
    /// any other, so it replaces rather than piling up and firing several times on release.
    func testAProlongedRefreshDoesNotAccumulateRearms() {
        var busy = true
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: [0.05], rearmInterval: 0.05, queue: .main,
            isBusy: { busy }, action: { count += 1 }
        )
        schedule.restart()
        settle(0.6)   // many re-arm cycles
        busy = false
        settle(0.3)
        XCTAssertEqual(count, 1, "a long refresh must yield one catch-up, not one per re-arm")
    }

    func testCancelDuringARefreshAlsoDropsTheRearm() {
        var count = 0
        let schedule = CatchUpRefreshSchedule(
            delays: [0.05], rearmInterval: 0.05, queue: .main,
            isBusy: { true }, action: { count += 1 }
        )
        schedule.restart()
        settle(0.2)
        schedule.cancel()
        settle(0.4)
        XCTAssertEqual(count, 0, "cancelling must stop a re-armed tick too")
        XCTAssertEqual(schedule.pendingCount, 0)
    }
}
