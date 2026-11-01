import Darwin

/// Which apps show a menu. The `AXQueue`'s queues can finish reads of one app out of order, so a result counts
/// only when it belongs to the app's latest read.
struct MenuOpenState {
    private var latest: [pid_t: UInt64] = [:]
    private var open: Set<pid_t> = []
    private var counter: UInt64 = 0

    var anyOpen: Bool { !open.isEmpty }

    /// Starts a read of `pid` and returns its generation.
    mutating func begin(_ pid: pid_t) -> UInt64 {
        counter += 1
        latest[pid] = counter
        return counter
    }

    mutating func finish(_ pid: pid_t, generation: UInt64, isOpen: Bool) {
        guard latest[pid] == generation else { return }
        if isOpen { open.insert(pid) } else { open.remove(pid) }
    }

    /// Forgets every app but keeps the generation counter, so a read begun before the reset can't be mistaken
    /// for one begun after it.
    mutating func removeAll() {
        latest = [:]
        open = []
    }

    /// Forgets an app that quit.
    mutating func remove(_ pid: pid_t) {
        latest[pid] = nil
        open.remove(pid)
    }
}
