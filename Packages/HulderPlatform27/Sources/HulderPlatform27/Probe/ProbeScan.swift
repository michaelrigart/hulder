#if DEBUG
import AppKit
import HulderCore

/// How `scan` and `items-watch` describe and compare readings of the bar. Pure.
enum ProbeScanLog {
    static func describe(_ item: MenuBarItem) -> String {
        "key=\(item.key.raw) barPosition=\(position(item.barPosition)) managedByMacOS=\(item.isManagedByMacOS) desc=\(item.description ?? "nil") title=\(item.title ?? "nil")"
    }

    static func position(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "nil"
    }

    /// One line per item and per owner that could not be read, in the order the scans give them.
    static func lines(_ scans: [AppScan]) -> [String] {
        scans.flatMap { scan -> [String] in
            switch scan.result {
            case .complete(let items): items.map { "owner=\(scan.owner.id) \(describe($0))" }
            case .timedOut: ["owner=\(scan.owner.id) timed out"]
            case .failed: ["owner=\(scan.owner.id) failed"]
            }
        }
    }

    /// What changed between two passes: items that appeared, disappeared or moved, and owners whose reading failed.
    static func diff(old: [AppScan], new: [AppScan]) -> [String] {
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
        for owner in after.readings.keys.sorted() where before.readings[owner] != after.readings[owner] {
            changes.append("owner \(owner) \(before.readings[owner] ?? "absent") -> \(after.readings[owner] ?? "absent")")
        }
        return changes
    }

    private struct State {
        var items: [String: (owner: String, position: Double?)] = [:]
        var readings: [String: String] = [:]
    }

    private static func state(of scans: [AppScan]) -> State {
        var state = State()
        for scan in scans {
            switch scan.result {
            case .complete(let items):
                state.readings[scan.owner.id] = "complete"
                for item in items { state.items[item.key.raw] = (scan.owner.id, item.barPosition) }
            case .timedOut: state.readings[scan.owner.id] = "timedOut"
            case .failed: state.readings[scan.owner.id] = "failed"
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
        let scans: [AppScan]
        let owners: [pid_t: ItemOwner]
        /// What the extras listing returned for each process the bar draws, MenuBarAgent excepted.
        let listings: [pid_t: RawScan]
        let entries: [String: Double]?
        let readDuration: Duration
        let duration: Duration

        func items(ownedBy bundleID: String) -> [MenuBarItem] {
            scans.flatMap { scan -> [MenuBarItem] in
                guard scan.owner.appID?.bundleID == bundleID, case .complete(let items) = scan.result else { return [] }
                return items
            }
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
        let scans = InventoryAssembly.scans(
            snapshot: reading.snapshot, owners: reading.owners, listings: reading.listedItems,
            entries: entries, concealed: concealed, own: ownAppID, previousOwners: []
        )
        return ScanReport(
            snapshot: reading.snapshot, scans: scans, owners: reading.owners, listings: reading.listings, entries: entries,
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
        for line in ProbeScanLog.lines(report.scans) { note("\(label): \(line)") }
        logListings(report, label: label)
        let items = report.scans.reduce(0) { total, scan in
            if case .complete(let items) = scan.result { return total + items.count }
            return total
        }
        note("\(label) done: owners=\(report.scans.count) items=\(items) durationMs=\(Self.milliseconds(report.duration))")
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
        for item in owned { note("\(label): \(ProbeScanLog.describe(item))") }
    }

    // MARK: items-watch

    func itemsWatch() async {
        let scans = platform.scans()
        note("items-watch: watching for \(Self.watchDuration)")
        let passes = await untilWatchEnds([{ @Sendable () async -> Int in
            var previous: [AppScan]?
            var count = 0
            for await current in scans {
                count += 1
                let items = current.reduce(0) { total, scan in
                    if case .complete(let items) = scan.result { return total + items.count }
                    return total
                }
                note("items-watch: pass \(count) owners=\(current.count) items=\(items)")
                for line in ProbeScanLog.lines(current) { note("items-watch: pass \(count) \(line)") }
                if let previous {
                    let changes = ProbeScanLog.diff(old: previous, new: current)
                    note("items-watch: pass \(count) \(changes.isEmpty ? "no change" : "\(changes.count) changes")")
                    for change in changes { note("items-watch:   \(change)") }
                }
                previous = current
            }
            return count
        }])
        note("items-watch: finished after \(passes.reduce(0, +)) passes")
    }
}
#endif
