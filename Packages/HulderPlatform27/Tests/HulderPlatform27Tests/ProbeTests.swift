#if DEBUG
import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

private func item(_ key: String, at position: Double?, owner: ItemOwner = .app(AppID("com.example.a"), name: "A")) -> MenuBarItem {
    MenuBarItem(key: ItemKey(raw: key), owner: owner, barPosition: position)
}

private func complete(_ items: [MenuBarItem], owner: ItemOwner = .app(AppID("com.example.a"), name: "A")) -> AppScan {
    AppScan(owner: owner, result: .complete(items))
}

// Catches an items-watch that misses an item appearing, going or sliding along the bar.
@Test func scanDiffReportsAppearedDisappearedAndMovedItems() {
    let old = [complete([item("a", at: 100), item("b", at: 130)])]
    let new = [complete([item("a", at: 150), item("c", at: 130)])]
    let changes = ProbeScanLog.diff(old: old, new: new)
    #expect(changes.contains { $0.hasPrefix("appeared com.example.a c") })
    #expect(changes.contains { $0.hasPrefix("disappeared com.example.a b") })
    #expect(changes.contains { $0.hasPrefix("moved com.example.a a 100.0 -> 150.0") })
    #expect(changes.count == 3)
}

@Test func scanDiffIgnoresSubPointMovesAndReportsOwnersThatStopReading() {
    let old = [complete([item("a", at: 100)])]
    #expect(ProbeScanLog.diff(old: old, new: [complete([item("a", at: 100.4)])]).isEmpty)
    let timedOut = [AppScan(owner: .app(AppID("com.example.a"), name: "A"), result: .timedOut)]
    #expect(ProbeScanLog.diff(old: old, new: timedOut).contains("owner com.example.a complete -> timedOut"))
}

@Test func moveLandsImmediatelyLeftOfTheAnchor() {
    let keys = ["a", "b", "c", "d"].map(ItemKey.init(raw:))
    let order = BarOrder(keys: keys, pinned: [])
    let change = ProbeOrderLog.move(ItemKey(raw: "d"), before: ItemKey(raw: "b"), in: order)
    #expect(change?.target.map(\.raw) == ["a", "d", "b", "c"])
    #expect(change?.moved.map(\.raw) == ["d"])
}

@Test func moveIsNilWhenNothingWouldChangeOrAKeyIsMissing() {
    let order = BarOrder(keys: ["a", "b", "c"].map(ItemKey.init(raw:)), pinned: [])
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "b"), in: order) == nil)
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "z"), in: order) == nil)
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "a"), in: order) == nil)
}

@Test func orderDiffReportsAddedRemovedAndMovedKeys() {
    let old = BarOrder(keys: ["a", "b", "c"].map(ItemKey.init(raw:)), pinned: [])
    let new = BarOrder(keys: ["c", "a", "d"].map(ItemKey.init(raw:)), pinned: [])
    let changes = ProbeOrderLog.diff(old: old, new: new)
    #expect(changes.contains("added d"))
    #expect(changes.contains("removed b"))
    #expect(changes.contains { $0.hasPrefix("moved c ") })
}

@Test func positionsDiffLeavesOutTheExcludedKey() {
    let old = ["a": 10.0, "b": 20.0, "c": 30.0]
    let new = ["a": 10.0, "b": 20.001, "c": 30.0, "d": 5.0]
    let changes = ProbeOrderLog.diff(old: old, new: new, excluding: "b")
    #expect(changes == ["added d 5.0"])
    #expect(ProbeOrderLog.diff(old: old, new: new).count == 2)
}

// Catches a probe whose maxSystemItem override or default bypasses the translation the backend ships.
@Test func backendTranslatesTheAllowListThroughItsTranslation() async {
    let seen = Mutex<AllowList?>(nil)
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: .frameworkMissing)) { list in
        seen.withLock { $0 = list }
        return ([], [])
    }
    let list = AllowList(apps: [AppID("com.example.a")])
    _ = try? await backend.prepare(list)
    #expect(seen.withLock { $0 } == list)
}
#endif
