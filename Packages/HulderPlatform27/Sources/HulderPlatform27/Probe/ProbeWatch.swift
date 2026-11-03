#if DEBUG
extension ProbeRunner {
    /// `menus`: every open or closed change `MenuTracker27` reports, with its tracking state, and the number of owners
    /// each scan pass draws.
    func menus() async {
        let tracker = platform.tracker
        // The tracker covers the processes that draw an item, and those are known only to a running scanner, which
        // scans only for a `scans()` subscriber.
        let scans = platform.scans()
        note("menus: watching for \(Self.watchDuration)")
        let changes = await untilWatchEnds([
            { @Sendable () async -> Int in
                var count = 0
                for await open in tracker.values() {
                    count += 1
                    note("menus: menu \(open ? "open" : "closed")")
                }
                return count
            },
            { @Sendable () async -> Int in
                for await tracking in tracker.trackingChanges() { note("menus: tracking \(tracking)") }
                return 0
            },
            { @Sendable () async -> Int in
                var count = 0
                for await pass in scans {
                    count += 1
                    note("menus: pass \(count) drawnOwners=\(pass.drawn.map { "\($0.count)" } ?? "unread")")
                }
                return 0
            },
        ])
        note("menus: finished after \(changes.reduce(0, +)) open or closed readings")
    }
}
#endif
