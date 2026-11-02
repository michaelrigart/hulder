#if DEBUG
import AppKit
import HulderCore

/// How `scan` and `items-watch` describe and compare passes over the bar. Pure.
enum ProbeScanLog {
    /// A line of the log, split by what may be public. The accessibility description and title of an item are the
    /// user's own text, so they are `personal` and the rest is `text`.
    struct Line: Equatable {
        var text: String
        var personal = ""
    }

    static func describe(_ item: MenuBarItem) -> Line {
        Line(
            text: "key=\(item.key.raw) barPosition=\(position(item.barPosition)) managedByMacOS=\(item.isManagedByMacOS)",
            personal: " desc=\(item.description ?? "nil") title=\(item.title ?? "nil")")
    }

    static func position(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "nil"
    }

    /// One line per item, in the order the pass gives them: the drawn owners, then the concealed ones, which have no
    /// bar position. A concealed owner without items and an unread bar get a line of their own.
    static func lines(_ pass: ScanPass) -> [Line] {
        guard let drawn = pass.drawn else { return [Line(text: "bar unread")] }
        let drawnLines = drawn.flatMap { entry in
            entry.items.map { item -> Line in
                let line = describe(item)
                return Line(text: "owner=\(entry.owner.id) \(line.text)", personal: line.personal)
            }
        }
        let concealedLines = pass.concealed.flatMap { entry -> [Line] in
            guard !entry.items.isEmpty else { return [Line(text: "owner=\(entry.owner.id) concealed without items")] }
            return entry.items.map { item -> Line in
                let line = describe(item)
                return Line(text: "owner=\(entry.owner.id) concealed \(line.text)", personal: line.personal)
            }
        }
        return drawnLines + concealedLines
    }

    /// What changed between two passes: items that appeared, disappeared or moved, owners that went from drawn to
    /// concealed or back, and the bar becoming unreadable or readable again.
    static func diff(old: ScanPass, new: ScanPass) -> [String] {
        switch (old.drawn == nil, new.drawn == nil) {
        case (false, true): return ["bar unread"]
        case (true, false): return ["bar read"]
        case (true, true): return []
        case (false, false): break
        }
        let before = state(of: old)
        let after = state(of: new)
        var changes: [String] = []
        for key in after.items.keys.sorted() {
            guard let now = after.items[key] else { continue }
            guard let was = before.items[key] else {
                changes.append("appeared \(now.owner) \(key) at \(position(now.position))")
                continue
            }
            if !samePosition(was.position, now.position) {
                changes.append("moved \(now.owner) \(key) \(position(was.position)) -> \(position(now.position))")
            }
        }
        for key in before.items.keys.sorted() where after.items[key] == nil {
            changes.append("disappeared \(before.items[key]?.owner ?? "nil") \(key)")
        }
        for owner in Set(before.readings.keys).union(after.readings.keys).sorted()
        where before.readings[owner] != after.readings[owner] {
            changes.append("owner \(owner) \(before.readings[owner] ?? "absent") -> \(after.readings[owner] ?? "absent")")
        }
        return changes
    }

    private struct State {
        var items: [String: (owner: String, position: Double?)] = [:]
        /// "drawn" or "concealed", by owner.
        var readings: [String: String] = [:]
    }

    private static func state(of pass: ScanPass) -> State {
        var state = State()
        for (entries, reading) in [(pass.drawn ?? [], "drawn"), (pass.concealed, "concealed")] {
            for entry in entries {
                state.readings[entry.owner.id] = reading
                for item in entry.items { state.items[item.key.raw] = (entry.owner.id, item.barPosition) }
            }
        }
        return state
    }

    private static func samePosition(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs - rhs) <= 0.5
    }
}

extension ProbeRunner {
    /// One read of the bar with everything the inventory is built from.
    struct ScanReport {
        let snapshot: BarSnapshot?
        let pass: ScanPass
        let owners: [pid_t: ItemOwner]
        /// What the extras listing returned for each process the bar draws, MenuBarAgent excepted.
        let listings: [pid_t: RawScan]
        let entries: [String: Double]?
        let readDuration: Duration
        let duration: Duration

        /// The items on the bar; a concealed owner's items are not on it.
        func items(ownedBy bundleID: String) -> [MenuBarItem] {
            (pass.drawn ?? []).filter { $0.owner.appID?.bundleID == bundleID }.flatMap(\.items)
        }
    }

    /// One `BarReader.read` and the extras listing of each drawn process, assembled by `InventoryAssembly` with the
    /// order file's entries when access is granted. Logs nothing.
    func collect() async -> ScanReport {
        let start = ContinuousClock.now
        _ = await platform.orderFile.availableStore()
        let entries = platform.orderFile.entries()
        let reading = await BarReader.read(queue: queue)
        let concealed = await platform.concealedApps(among: reading.running)
        let pass = InventoryAssembly.pass(
            snapshot: reading.snapshot, owners: reading.owners, listings: reading.listedItems,
            entries: entries, concealed: concealed, own: ownAppID
        )
        return ScanReport(
            snapshot: reading.snapshot, pass: pass, owners: reading.owners, listings: reading.listings, entries: entries,
            readDuration: reading.readDuration, duration: ContinuousClock.now - start
        )
    }

    func scan(label: String) async -> ScanReport {
        let report = await collect()
        guard let snapshot = report.snapshot else {
            note("\(label): the bar could not be read, readMs=\(Self.milliseconds(report.readDuration))")
            return report
        }
        note("\(label): bar drawn groups=\(snapshot.groups.count) overflowIndicatorX=\(ProbeScanLog.position(snapshot.overflowIndicatorX)) order entries=\(report.entries.map { "\($0.count)" } ?? "unavailable") readMs=\(Self.milliseconds(report.readDuration))")
        for line in ProbeScanLog.lines(report.pass) { note("\(label): \(line.text)", private: line.personal) }
        logListings(report, label: label)
        let (drawn, concealed) = (report.pass.drawn ?? [], report.pass.concealed)
        note("""
            \(label) done: drawnOwners=\(drawn.count) drawnItems=\(drawn.reduce(0) { $0 + $1.items.count }) \
            concealedOwners=\(concealed.count) concealedItems=\(concealed.reduce(0) { $0 + $1.items.count }) \
            durationMs=\(Self.milliseconds(report.duration))
            """)
        return report
    }

    /// Per owner, how many items the bar draws against how many the extras listing has, so the gaps stay visible.
    private func logListings(_ report: ScanReport, label: String) {
        var drawn: [pid_t: Int] = [:]
        for group in report.snapshot?.groups ?? [] { drawn[group.pid, default: 0] += 1 }
        for pid in drawn.keys.sorted() {
            let owner = report.owners[pid]?.id ?? "nil"
            let listing: String
            switch report.listings[pid] {
            case .items(let listed)?:
                let described = listed.filter { $0.description != nil || $0.title != nil }.count
                listing = "listed=\(listed.count) described=\(described)"
            case .timedOut?: listing = "listing timed out"
            case .failed(let error)?: listing = "listing failed axError=\(error.rawValue)"
            case nil: listing = "not listed (MenuBarAgent)"
            }
            note("\(label): owner=\(owner) pid=\(pid) drawn=\(drawn[pid] ?? 0) \(listing)")
        }
    }

    func logTarget(_ bundleID: String, in report: ScanReport, label: String) {
        let owned = report.items(ownedBy: bundleID)
        note("\(label): \(bundleID) has \(owned.count) items on the bar")
        for item in owned {
            let line = ProbeScanLog.describe(item)
            note("\(label): \(line.text)", private: line.personal)
        }
    }

    // MARK: items-watch

    func itemsWatch() async {
        let scans = platform.scans()
        note("items-watch: watching for \(Self.watchDuration)")
        let passes = await untilWatchEnds([{ @Sendable () async -> Int in
            var previous: ScanPass?
            var count = 0
            for await pass in scans {
                count += 1
                let (drawn, concealed) = (pass.drawn ?? [], pass.concealed)
                note("""
                    items-watch: pass \(count) drawnOwners=\(drawn.count) \
                    drawnItems=\(drawn.reduce(0) { $0 + $1.items.count }) concealedOwners=\(concealed.count) \
                    concealedItems=\(concealed.reduce(0) { $0 + $1.items.count }) \
                    orderEntries=\(pass.orderEntriesAvailable)
                    """)
                for line in ProbeScanLog.lines(pass) { note("items-watch: pass \(count) \(line.text)", private: line.personal) }
                if let previous {
                    let changes = ProbeScanLog.diff(old: previous, new: pass)
                    note("items-watch: pass \(count) \(changes.isEmpty ? "no change" : "\(changes.count) changes")")
                    for change in changes { note("items-watch:   \(change)") }
                }
                previous = pass
            }
            return count
        }])
        note("items-watch: finished after \(passes.reduce(0, +)) passes")
    }
}
#endif
