import Foundation

/// Refreshes the menu again on a fixed schedule after JiraBar writes to Jira, because the refresh
/// fired from the write's own completion usually cannot see the write yet.
///
/// Jira's search index trails a write by up to about eleven seconds, while `GET /issue/{key}` is
/// read-your-writes and reflects it immediately. The menu is built from the user's search JQL, so
/// it is the lagging half — and because that JQL matches on assignee, which the field PUT writes
/// first, the search misses the row *entirely* rather than reporting a stale status: the ticket
/// leaves its old status group, never joins the new one, and drops out of TODO too because its
/// status really did change. Nothing corrects that until the next poll, `refreshRate` *minutes*
/// later, which is why the menu stayed wrong until the user refreshed by hand.
///
/// A fixed schedule rather than a poll-until-correct loop, and that is the load-bearing decision.
/// Such a loop has to answer "should this ticket be here?", which has no cheap answer: the user's
/// JQL ends `statusCategory != Done`, so a ticket just closed is *correctly* absent forever and a
/// wait-until-present loop would run to timeout on every close. A fixed schedule never asks. The
/// two obvious things to wait on instead were both measured and both fail: `GET /issue/{key}` and a
/// `jql=key = X` probe are each read-your-writes, so each returns an instant false all-clear and
/// refreshes into the same stale menu. The commit that added this carries the measurements.
final class CatchUpRefreshSchedule {
    /// Seconds after the write to refresh again.
    ///
    /// The first tick clears the great majority of observed misses and the fourth clears the worst
    /// one; the rest are insurance either side, since the tail beyond a fourteen-sample measurement
    /// is guesswork. Each tick is a full menu rebuild — four searches plus the GitHub wave — so the
    /// count is not free, and it is the number to cut first if request volume ever bites.
    static let defaultDelays: [TimeInterval] = [2, 5, 10, 20, 30]

    private let delays: [TimeInterval]
    private let rearmInterval: TimeInterval
    private let queue: DispatchQueue
    private let isBusy: () -> Bool
    private let action: () -> Void
    private var pending: [DispatchWorkItem] = []
    private var rearm: DispatchWorkItem?

    /// - Parameter isBusy: whether a refresh is in flight right now. A tick that lands while one is
    ///   re-arms instead of running, because `refreshMenu`'s own `guard !isRefreshing` would
    ///   silently drop it — and the in-flight refresh's searches started before this tick, so its
    ///   answer is the stale one the tick exists to replace.
    init(
        delays: [TimeInterval] = CatchUpRefreshSchedule.defaultDelays,
        rearmInterval: TimeInterval = 0.4,
        queue: DispatchQueue = .main,
        isBusy: @escaping () -> Bool,
        action: @escaping () -> Void
    ) {
        self.delays = delays
        self.rearmInterval = rearmInterval
        self.queue = queue
        self.isBusy = isBusy
        self.action = action
    }

    /// Cancels any schedule already pending and starts a fresh one.
    ///
    /// Restart rather than stack: two overlapping schedules double the request volume and add no
    /// coverage, and it is the most recent write whose visibility is in question, so its clock is
    /// the one worth counting from.
    ///
    /// Call only from `queue` — replacing the pending items is not synchronized against itself,
    /// which matches `RefreshDebouncer.poke` and holds for the same reason: every caller is already
    /// on main (Alamofire's default response queue).
    func restart() {
        cancel()
        pending = delays.map { delay in
            let work = DispatchWorkItem { [weak self] in self?.fire() }
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    func cancel() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        rearm?.cancel()
        rearm = nil
    }

    /// Ticks scheduled and not since cancelled. A tick that has already fired stays counted until
    /// the next `restart` or `cancel` clears the list — cancelling a finished work item is a no-op,
    /// so nothing prunes it. For tests; nothing in the app asks.
    var pendingCount: Int { pending.count }

    private func fire() {
        guard isBusy() else {
            action()
            return
        }
        // One slot, not a list: a put-off tick waits on the same condition as any other, so
        // re-arming replaces rather than accumulates.
        rearm?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        rearm = work
        queue.asyncAfter(deadline: .now() + rearmInterval, execute: work)
    }
}
