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
    /// Two ticks, matched to the measured distribution rather than padded past it: every observed
    /// miss cleared under 1.7s except a single 11.2s outlier, so the first tick catches the cluster
    /// and the second catches the outlier. Ticks at 5, 10 and 30 were tried and dropped — they
    /// covered nothing that was ever observed.
    ///
    /// The first tick is 3s rather than 2s for headroom, and the headroom is the point. The slowest
    /// non-outlier miss measured 1630ms, so a 2s tick clears it by 370ms while 3s clears it by
    /// ~1.4s — about four times the margin for the same three rebuilds. The failure that matters is
    /// a miss landing *between* the two ticks, because then nothing corrects it until 20s; widening
    /// the first tick is what makes falling into that gap unlikely. A middle tick at ~8s would
    /// shrink the gap further and was considered, but it costs a third more requests (see below) to
    /// cover a region no measurement has ever put a miss in.
    ///
    /// The count is load-bearing on the cost side, which is why it is not padded "just in case".
    /// Each tick is a full menu rebuild, and a rebuild spends 3 *uncached* GitHub search requests
    /// on `searchMyPRs` against a 30/minute authenticated budget (the per-project PR searches are
    /// cached by `GithubPRIndex`, so those do not multiply). At three rebuilds per write that is 9
    /// requests; at six it was 18 inside 30 seconds, and a burst of ten writes reached roughly 45
    /// in 45 seconds — over budget, where GitHub answers 403 and "PRs Without Tickets" renders
    /// empty with nothing said. Adding ticks trades a section of the menu for coverage of a tail
    /// nobody has measured.
    static let defaultDelays: [TimeInterval] = [3, 20]

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
    /// which matches `RefreshDebouncer.poke`. Every caller is on main: the in-app write sites from
    /// Alamofire's default response queue, and the external notify path from a work item already
    /// hopped there.
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
