#if DEBUG
import AppKit
import HulderCore
import Synchronization

/// Plans and comparisons of the `order-*` subcommands. Pure.
enum ProbeOrderLog {
    /// Puts `key` immediately left of `anchor`. Nil when either is missing or the key is already there.
    static func move(_ key: ItemKey, before anchor: ItemKey, in order: BarOrder) -> OrderChange? {
        guard key != anchor, order.keys.contains(key), order.keys.contains(anchor) else { return nil }
        var target = order.keys.filter { $0 != key }
        guard let index = target.firstIndex(of: anchor) else { return nil }
        target.insert(key, at: index)
        guard target != order.keys else { return nil }
        return OrderChange(target: target, moved: [key])
    }

    /// Keys that appeared, disappeared or changed place relative to the keys both orders hold, and pinned keys that changed.
    static func diff(old: BarOrder, new: BarOrder) -> [String] {
        let oldKeys = Set(old.keys)
        let newKeys = Set(new.keys)
        var changes: [String] = []
        for key in new.keys where !oldKeys.contains(key) { changes.append("added \(key.raw)") }
        for key in old.keys where !newKeys.contains(key) { changes.append("removed \(key.raw)") }
        let before = old.keys.filter(newKeys.contains)
        let after = new.keys.filter(oldKeys.contains)
        for (index, key) in after.enumerated() where before.firstIndex(of: key) != index {
            changes.append("moved \(key.raw) from index \(before.firstIndex(of: key) ?? -1) to \(index)")
        }
        for key in old.pinned.symmetricDifference(new.pinned).sorted(by: { $0.raw < $1.raw }) {
            changes.append(new.pinned.contains(key) ? "pinned \(key.raw)" : "unpinned \(key.raw)")
        }
        return changes
    }

    /// Value differences between two readings of the positions, leaving out `excluded`.
    static func diff(old: [String: Double], new: [String: Double], excluding excluded: String? = nil) -> [String] {
        var changes: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where key != excluded {
            switch (old[key], new[key]) {
            case let (was?, now?) where was != now: changes.append("changed \(key) \(was) -> \(now)")
            case let (nil, now?): changes.append("added \(key) \(now)")
            case let (was?, nil): changes.append("removed \(key) \(was)")
            default: break
            }
        }
        return changes
    }
}

/// Writes the positions it is given, except that one key can be forced to an exact value. It lets `order-stress`
/// make a write that changes nothing but a hair of one item, through `OrderStore27.write` and its checks.
private final class StressBackend: PositionsBackend {
    private let inner: any PositionsBackend
    private let forced = Mutex<(key: String, value: Double)?>(nil)

    init(_ inner: any PositionsBackend) {
        self.inner = inner
    }

    func force(_ key: String, to value: Double) {
        forced.withLock { $0 = (key, value) }
    }

    var availability: Availability { inner.availability }

    func copyPositions() -> Any? {
        inner.copyPositions()
    }

    func setPositions(_ positions: [String: NSNumber]) -> Bool {
        var positions = positions
        if let forced = forced.withLock({ $0 }) { positions[forced.key] = NSNumber(value: forced.value) }
        return inner.setPositions(positions)
    }
}

extension ProbeRunner {
    private static func relativeToHome(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// The store once an evaluation has finished, or nil after logging why reordering is unavailable.
    private func orderStore(label: String) async -> OrderStore27? {
        if let store = await platform.orderFile.availableStore() { return store }
        if case .unavailable(let reason)? = await first(of: platform.orderFile.reorderingChanges()) {
            note("\(label): reordering is unavailable: \(reason)")
        } else {
            note("\(label): reordering is unavailable; run order-pick first")
        }
        return nil
    }

    // MARK: order-pick

    func orderPick() async {
        guard let access = platform.orderAccess else {
            note("order-pick: this platform has no order access")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = access.suggestedLocation.deletingLastPathComponent()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Select the com.apple.MenuBar folder, then click Allow."
        openPanel.prompt = "Allow"
        NSApp.activate()
        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            note("order-pick: cancelled")
            return
        }
        note("order-pick: chose", private: " \(Self.relativeToHome(url))")
        do {
            try await access.grant(pickedURL: url)
            note("order-pick: granted")
        } catch {
            note("order-pick: grant failed", private: " (\(error))")
        }
        if let reordering = await first(of: platform.orderFile.reorderingChanges()) {
            note("order-pick: reordering \(reordering)")
        }
    }

    // MARK: order-dump

    func orderDump() async {
        guard let store = await orderStore(label: "order-dump") else { return }
        do {
            let order = try await store.read()
            let entries = store.entries
            let drawn = await store.drawnKeys()
            note("order-dump: \(order.keys.count) keys, left to right; pinned \(order.pinned.map(\.raw).sorted()); drawn \(drawn.count)")
            for (index, key) in order.keys.enumerated() {
                let value = entries[key.raw].map { "\($0)" } ?? "nil"
                note("order-dump: [\(index)] \(key.raw) value=\(value) pinned=\(order.pinned.contains(key)) drawn=\(drawn.contains(key))")
            }
            let unlisted = drawn.subtracting(order.keys).map(\.raw).sorted()
            note("order-dump: drawn keys the order does not hold: \(unlisted.isEmpty ? "none" : unlisted.joined(separator: ", "))")
        } catch {
            note("order-dump: read failed", private: " (\(error))")
        }
    }

    // MARK: order-watch

    func orderWatch() async {
        guard let store = await orderStore(label: "order-watch") else { return }
        let changes = store.changes()
        note("order-watch: watching for \(Self.watchDuration)")
        let counts = await untilWatchEnds([{ @Sendable () async -> Int in
            var previous: BarOrder?
            var count = 0
            for await order in changes {
                count += 1
                guard let last = previous else {
                    note("order-watch: initial order \(order.keys.count) keys: \(order.keys.map(\.raw).joined(separator: " "))")
                    previous = order
                    continue
                }
                let differences = ProbeOrderLog.diff(old: last, new: order)
                note("order-watch: new order \(count - 1): \(differences.count) differences")
                for change in differences { note("order-watch:   \(change)") }
                previous = order
            }
            return count
        }])
        note("order-watch: finished after \(max(0, counts.reduce(0, +) - 1)) changes")
    }

    // MARK: order-move

    func orderMove(_ key: String, anchor: String) async {
        guard let store = await orderStore(label: "order-move") else { return }
        let (moved, anchorKey) = (ItemKey(raw: key), ItemKey(raw: anchor))
        guard let before = try? await store.read(), before.keys.contains(moved), before.keys.contains(anchorKey) else {
            note("order-move: missing key: \(key) or \(anchor) is not in the order")
            return
        }
        let controller = OrderController(store: store, clock: clock)
        let outcome = await controller.perform { ProbeOrderLog.move(moved, before: anchorKey, in: $0) }
        note("order-move: \(key) before \(anchor): outcome \(outcome)")
        await logOrderChange("order-move", store: store, since: before)
        await panel.wait("Did the icon move next to the anchor? Did anything flicker or reflow? Note the answer, then click Continue.")
    }

    // MARK: order-restore

    func orderRestore() async {
        guard let store = await orderStore(label: "order-restore") else { return }
        let before = try? await store.read()
        let controller = OrderController(store: store, clock: clock)
        let outcome = await controller.restore()
        note("order-restore: outcome \(outcome)")
        if let before { await logOrderChange("order-restore", store: store, since: before) }
        await panel.wait("Is the original order back? Click Continue.")
    }

    private func logOrderChange(_ label: String, store: OrderStore27, since before: BarOrder) async {
        guard let after = try? await store.read() else {
            note("\(label): the order could not be read afterwards")
            return
        }
        let changes = ProbeOrderLog.diff(old: before, new: after)
        note("\(label) after:\(changes.isEmpty ? "no change" : "\(changes.count) differences")")
        for change in changes { note("\(label):   \(change)") }
    }

    // MARK: order-stress

    func orderStress(_ key: String) async {
        guard let access = platform.orderAccess as? OrderAccess27, let container = await access.container() else {
            note("order-stress: no access to the order file; run order-pick first")
            return
        }
        let backend = StressBackend(ContainerPreferences(container: container))
        let store: OrderStore27
        do {
            store = try await OrderStore27.open(
                backend: backend, container: container, backups: Platform27.orderBackups, drawnKeys: { _ in [] }
            )
            try await store.backup()
        } catch {
            note("order-stress: could not open the order file or back it up", private: " (\(error))")
            return
        }
        guard let original = store.entries[key] else {
            note("order-stress: \(key) is not in the order file")
            return
        }
        note("order-stress: \(key) starts at \(original), \(store.entries.count) keys; backed up")
        await panel.wait("Click Continue, then ⌘-drag any icon other than \(key) to a new place within 20 seconds and leave it there.")

        _ = try? await store.read()
        let before = store.entries
        let base = before[key] ?? original
        let moved = ItemKey(raw: key)
        let deadline = ContinuousClock.now + .seconds(20)
        var (writes, stale, failures) = (0, 0, 0)
        while ContinuousClock.now < deadline {
            do {
                let order = try await store.read()
                backend.force(key, to: writes.isMultiple(of: 2) ? base + 0.001 : base - 0.001)
                try await store.write(OrderChange(target: order.keys, moved: [moved]), expecting: order)
                writes += 1
            } catch OrderStoreError.stale {
                stale += 1
            } catch {
                failures += 1
                note("order-stress: write failed", private: " (\(error))")
            }
            try? await clock.sleep(for: .milliseconds(50))
        }

        var finalWrite = "written"
        var finalWriteError = ""
        do {
            let order = try await store.read()
            backend.force(key, to: base)
            try await store.write(OrderChange(target: order.keys, moved: [moved]), expecting: order)
        } catch {
            finalWrite = "failed"
            finalWriteError = " (\(error))"
        }
        note("order-stress: \(writes) writes, \(stale) stale, \(failures) failed; final write of \(key)=\(base) \(finalWrite)", private: finalWriteError)

        _ = try? await store.read()
        let after = store.entries
        let changes = ProbeOrderLog.diff(old: before, new: after, excluding: key)
        note("order-stress: vs before the loop, excluding \(key): \(changes.isEmpty ? "no difference" : "\(changes.count) differences"); \(key)=\(after[key].map { "\($0)" } ?? "nil")")
        for change in changes { note("order-stress: \(change)") }

        await panel.wait("Is the icon you dragged still where you left it? Click Continue.")
    }
}
#endif
