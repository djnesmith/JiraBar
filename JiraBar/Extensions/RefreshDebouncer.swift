import Foundation

/// Coalesces a burst of pokes into one action: each poke restarts the fuse, and only the last
/// one fires. A script transitioning five tickets posts five refresh notifications; the menu
/// should rebuild once, after the burst settles, not five times.
final class RefreshDebouncer {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let action: () -> Void
    private var pending: DispatchWorkItem?

    init(interval: TimeInterval = 1.0, queue: DispatchQueue = .main, action: @escaping () -> Void) {
        self.interval = interval
        self.queue = queue
        self.action = action
    }

    /// Call only from `queue` — restarting the fuse is not synchronized against itself.
    func poke() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.action() }
        pending = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }
}
