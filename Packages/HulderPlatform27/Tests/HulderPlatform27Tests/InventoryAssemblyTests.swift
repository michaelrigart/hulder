import CoreGraphics
import Testing
import HulderCore
@testable import HulderPlatform27

private let appA = ItemOwner.app(AppID("com.example.a"), name: "A")
private let appH = ItemOwner.app(AppID("com.example.h"), name: "H")
private let agent = ItemOwner.app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent")

private func group(_ pid: pid_t, x: Double) -> DrawnGroup {
    DrawnGroup(pid: pid, frame: CGRect(x: x, y: 0, width: 30, height: 24))
}

private func scans(
    groups: [DrawnGroup] = [],
    indicator: Double? = nil,
    owners: [pid_t: ItemOwner] = [:],
    listings: [pid_t: [RawItem]] = [:],
    entries: [String: Double]? = [:],
    concealed: Set<AppID> = [],
    own: AppID? = nil,
    previous: [ItemOwner] = []
) -> [AppScan] {
    InventoryAssembly.scans(
        snapshot: BarSnapshot(groups: groups, overflowIndicatorX: indicator),
        owners: owners, listings: listings, entries: entries, concealed: concealed, own: own, previousOwners: previous
    )
}

private func complete(_ scan: AppScan) -> [MenuBarItem] {
    guard case .complete(let items) = scan.result else { return [] }
    return items
}

@Test func barSnapshotSortsByXAndKeepsTiesInReadOrder() {
    let snapshot = BarSnapshot(groups: [group(1, x: 50), group(2, x: 10), group(3, x: 10), group(4, x: 10)], overflowIndicatorX: nil)
    #expect(snapshot.groups.map(\.pid) == [2, 3, 4, 1])
}

@Test func drawnOwnerIsComplete() {
    let result = scans(groups: [group(10, x: 100)], owners: [10: appA])
    #expect(result == [AppScan(owner: appA, result: .complete([
        MenuBarItem(key: ItemKey(raw: "status:com.example.a::Item-0"), owner: appA, barPosition: 100),
    ]))])
}

@Test func overflowedItemIsStillDrawn() throws {
    let result = scans(groups: [group(10, x: 10)], indicator: 31, owners: [10: appA])
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.barPosition) == [10])
}

@Test func hiddenOwnerComesFromEntries() throws {
    let result = scans(
        owners: [99: appH],
        entries: ["status:com.example.h::Item-0": 50, "status:com.example.gone::Item-0": 70],
        concealed: [AppID("com.example.h")]
    )
    try #require(result.count == 1)
    #expect(result[0].owner == appH)
    let items = complete(result[0])
    #expect(items.map(\.key.raw) == ["status:com.example.h::Item-0"])
    #expect(items.map(\.barPosition) == [nil])
}

// Catches phantom items: an app with order entries whose icon is off, in its own preferences or in System
// Settings, would show in Layout with items that exist nowhere.
@Test func aRunningAppThatTheConcealmentDoesNotHideHasNoItemsFromEntries() {
    let entries: [String: Double] = ["status:com.example.h::Item-0": 50]
    #expect(scans(owners: [99: appH], entries: entries, concealed: []).isEmpty)
    #expect(scans(owners: [99: appH], entries: entries, concealed: [AppID("com.example.other")]).isEmpty)
    #expect(scans(owners: [99: appH], entries: entries, concealed: [AppID("com.example.h")]).count == 1)
}

@Test func aConcealedAppThatIsStillDrawnKeepsItsDrawnItems() throws {
    let result = scans(
        groups: [group(99, x: 100)], owners: [99: appH],
        entries: ["status:com.example.h::Item-0": 50], concealed: [AppID("com.example.h")]
    )
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.barPosition) == [100])
}

@Test func hiddenOwnerWithoutAKnownNameFallsBackToItsBundleIdentifier() {
    let result = scans(entries: ["status:com.example.h::Item-0": 50], concealed: [AppID("com.example.h")])
    #expect(result.map(\.owner) == [.app(AppID("com.example.h"), name: "com.example.h")])
}

@Test func missingSnapshotTimesOutKnownOwners() {
    let result = InventoryAssembly.scans(
        snapshot: nil, owners: [:], listings: [:], entries: nil, concealed: [], previousOwners: [appA, appH]
    )
    #expect(result == [AppScan(owner: appA, result: .timedOut), AppScan(owner: appH, result: .timedOut)])
}

@Test func listingDescriptionsAreZippedOnlyOnEqualCounts() throws {
    func raw(_ index: Int, _ text: String, x: Double) -> RawItem {
        RawItem(identifier: nil, description: text, title: "title \(text)", frame: CGRect(x: x, y: 0, width: 30, height: 24), index: index)
    }
    let groups = [group(10, x: 100), group(10, x: 200)]
    let matching = scans(groups: groups, owners: [10: appA], listings: [10: [raw(0, "one", x: 100), raw(1, "two", x: 200)]])
    try #require(matching.count == 1)
    #expect(complete(matching[0]).map(\.description) == ["one", "two"])
    #expect(complete(matching[0]).map(\.title) == ["title one", "title two"])

    let tooMany = scans(groups: groups, owners: [10: appA], listings: [10: [raw(0, "one", x: 100), raw(1, "two", x: 200), raw(2, "three", x: 300)]])
    try #require(tooMany.count == 1)
    #expect(complete(tooMany[0]).map(\.description) == [nil, nil])
    #expect(complete(tooMany[0]).map(\.title) == [nil, nil])
}

@Test func listingIsMatchedLeftToRightWhateverItsReadOrder() throws {
    func raw(_ index: Int, _ text: String, x: Double) -> RawItem {
        RawItem(identifier: nil, description: text, title: nil, frame: CGRect(x: x, y: 0, width: 30, height: 24), index: index)
    }
    let result = scans(
        groups: [group(10, x: 100), group(10, x: 200)], owners: [10: appA],
        listings: [10: [raw(0, "right", x: 200), raw(1, "left", x: 100)]]
    )
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.description) == ["left", "right"])
}

@Test func appleOwnersAreManagedByMacOS() throws {
    let apple = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.controlcenter"]
    for (offset, bundleID) in apple.enumerated() {
        let owner = ItemOwner.app(AppID(bundleID), name: bundleID)
        let result = scans(groups: [group(Int32(offset), x: 10)], owners: [Int32(offset): owner])
        try #require(result.count == 1)
        let managed = complete(result[0]).map(\.isManagedByMacOS)
        #expect(managed == [true], "\(bundleID)")
    }
    let other = scans(groups: [group(10, x: 10)], owners: [10: appA])
    try #require(other.count == 1)
    #expect(complete(other[0]).map(\.isManagedByMacOS) == [false])
}

@Test func agentGroupsGetModuleKeys() throws {
    let result = scans(
        groups: [group(5, x: 10), group(5, x: 40), group(10, x: 70)],
        owners: [5: agent, 10: appA],
        entries: ["module:Clock": 0, "module:WiFi": 40]
    )
    try #require(result.count == 2)
    #expect(result.map(\.owner) == [agent, appA])
    #expect(complete(result[0]).map(\.key.raw) == ["module:WiFi", "module:Clock"])
    #expect(complete(result[0]).map(\.barPosition) == [10, 40])
}

@Test func oneOwnerAcrossProcessesIsOneScan() throws {
    let result = scans(groups: [group(10, x: 100), group(11, x: 50)], owners: [10: appA, 11: appA])
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.barPosition) == [50, 100])
}

@Test func groupsWithoutAnOwnerAreSkipped() throws {
    let result = scans(groups: [group(10, x: 100), group(77, x: 120)], owners: [10: appA])
    try #require(result.count == 1)
    #expect(result.map(\.owner) == [appA])
    #expect(complete(result[0]).count == 1)
}

@Test func ownItemIsTheLeftmostItemOfHulder() {
    let own = AppID("com.michaelrigart.hulder")
    let owner = ItemOwner.app(own, name: "Hulder")
    let snapshot = InventorySnapshot(items: [
        MenuBarItem(key: ItemKey(raw: "status:a"), owner: appA, barPosition: 10),
        MenuBarItem(key: ItemKey(raw: "status:hidden"), owner: owner, barPosition: nil),
        MenuBarItem(key: ItemKey(raw: "status:right"), owner: owner, barPosition: 300),
        MenuBarItem(key: ItemKey(raw: "status:left"), owner: owner, barPosition: 200),
    ], stale: [])
    #expect(InventoryAssembly.ownItemKey(in: snapshot, ownAppID: own) == ItemKey(raw: "status:left"))
    #expect(InventoryAssembly.ownItemKey(in: .empty, ownAppID: own) == nil)
}

private let hulderID = AppID("com.michaelrigart.hulder")
private let hulder = ItemOwner.app(hulderID, name: "Hulder")

// Catches the divider key taken from a stale `Item-0` the probe left in the order file, which sorts ahead of
// the real `HulderDivider` entry and sent every move to an item that is not on the bar.
@Test func hulderDrawnItemIsNamedByItsAutosaveNameNotByAStaleEntry() throws {
    let entries = [
        "status:com.michaelrigart.hulder::Item-0": 900.0,
        "status:com.michaelrigart.hulder::HulderDivider": 400.0,
    ]
    let result = scans(groups: [group(10, x: 100)], owners: [10: hulder], entries: entries, own: hulderID)
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.key.raw) == ["status:com.michaelrigart.hulder::HulderDivider"])
    let snapshot = InventorySnapshot(items: complete(result[0]), stale: [])
    #expect(InventoryAssembly.ownItemKey(in: snapshot, ownAppID: hulderID) == ItemKey(raw: "status:com.michaelrigart.hulder::HulderDivider"))
}

@Test func hulderDrawnItemIsNamedByItsAutosaveNameBeforeTheOrderFileHasAnEntry() throws {
    let result = scans(groups: [group(10, x: 100)], owners: [10: hulder], entries: [:], own: hulderID)
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.key.raw) == ["status:com.michaelrigart.hulder::HulderDivider"])
}

// Catches an undrawn Hulder that still gets items from its order entries: the divider would then be a
// stale position and every move would be planned against it, instead of answering "Hulder's icon isn't on the bar".
@Test func anUndrawnHulderHasNoItemsAndNoDivider() {
    let entries = [
        "status:com.michaelrigart.hulder::Item-0": 900.0,
        "status:com.michaelrigart.hulder::HulderDivider": 400.0,
    ]
    let result = scans(owners: [10: hulder], entries: entries, concealed: [hulderID], own: hulderID)
    #expect(result.isEmpty)
    let snapshot = InventorySnapshot(items: result.flatMap(complete), stale: [])
    #expect(InventoryAssembly.ownItemKey(in: snapshot, ownAppID: hulderID) == nil)
}

@Test func otherAppsAreNotNamedByHulderAutosaveName() throws {
    let result = scans(groups: [group(10, x: 100)], owners: [10: appA], entries: [:], own: hulderID)
    try #require(result.count == 1)
    #expect(complete(result[0]).map(\.key.raw) == ["status:com.example.a::Item-0"])
}

@Test func unresolvedOwnersTakeTheWholeExecutableName() {
    #expect(OwnerResolver27.executableName(path: "/Applications/Some Tray.app/Contents/MacOS/some-tray-with-a-long-name") == "some-tray-with-a-long-name")
    #expect(OwnerResolver27.executableName(path: "") == nil)
}
