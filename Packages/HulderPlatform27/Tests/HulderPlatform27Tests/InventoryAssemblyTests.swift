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

private func pass(
    groups: [DrawnGroup] = [],
    indicator: Double? = nil,
    owners: [pid_t: ItemOwner] = [:],
    listings: [pid_t: [RawItem]] = [:],
    entries: [String: Double]? = [:],
    concealed: Set<AppID> = [],
    concealedSystemItems: Set<SystemItemID> = [],
    own: AppID? = nil
) -> ScanPass {
    InventoryAssembly.pass(
        snapshot: BarSnapshot(groups: groups, overflowIndicatorX: indicator),
        owners: owners, listings: listings, entries: entries, concealed: concealed,
        concealedSystemItems: concealedSystemItems, own: own
    )
}

/// The drawn owners of a pass that read the bar.
private func drawn(_ pass: ScanPass) -> [OwnerItems] {
    pass.drawn ?? []
}

/// Every owner of a pass, the drawn ones first.
private func owned(
    groups: [DrawnGroup] = [],
    owners: [pid_t: ItemOwner] = [:],
    listings: [pid_t: [RawItem]] = [:],
    entries: [String: Double]? = [:],
    concealed: Set<AppID> = [],
    concealedSystemItems: Set<SystemItemID> = [],
    own: AppID? = nil
) -> [OwnerItems] {
    let result = pass(
        groups: groups, owners: owners, listings: listings, entries: entries, concealed: concealed,
        concealedSystemItems: concealedSystemItems, own: own)
    return drawn(result) + result.concealed
}

@Test func barSnapshotSortsByXAndKeepsTiesInReadOrder() {
    let snapshot = BarSnapshot(groups: [group(1, x: 50), group(2, x: 10), group(3, x: 10), group(4, x: 10)], overflowIndicatorX: nil)
    #expect(snapshot.groups.map(\.pid) == [2, 3, 4, 1])
}

@Test func drawnOwnerIsListedWithItsItems() {
    let result = pass(groups: [group(10, x: 100)], owners: [10: appA])
    #expect(result == ScanPass(
        drawn: [OwnerItems(owner: appA, items: [
            MenuBarItem(key: ItemKey(raw: "status:com.example.a::Item-0"), owner: appA, barPosition: 100),
        ])],
        concealed: [], orderEntriesAvailable: true))
}

@Test func overflowedItemIsStillDrawn() throws {
    let result = drawn(pass(groups: [group(10, x: 10)], indicator: 31, owners: [10: appA]))
    try #require(result.count == 1)
    #expect(result[0].items.map(\.barPosition) == [10])
}

@Test func hiddenOwnerComesFromEntries() throws {
    let result = pass(
        owners: [99: appH],
        entries: ["status:com.example.h::Item-0": 50, "status:com.example.gone::Item-0": 70],
        concealed: [AppID("com.example.h")]
    ).concealed
    try #require(result.count == 1)
    #expect(result[0].owner == appH)
    let items = result[0].items
    #expect(items.map(\.key.raw) == ["status:com.example.h::Item-0"])
    #expect(items.map(\.barPosition) == [nil])
}

// Catches phantom items: an app with order entries whose icon is off, in its own preferences or in System
// Settings, would show in Layout with items that exist nowhere.
@Test func aRunningAppThatTheConcealmentDoesNotHideHasNoItemsFromEntries() {
    let entries: [String: Double] = ["status:com.example.h::Item-0": 50]
    let none = pass(owners: [99: appH], entries: entries, concealed: [])
    #expect(drawn(none).isEmpty && none.concealed.isEmpty)
    let other = pass(owners: [99: appH], entries: entries, concealed: [AppID("com.example.other")])
    #expect(!other.concealed.contains { $0.owner == appH } && !drawn(other).contains { $0.owner == appH })
    #expect(pass(owners: [99: appH], entries: entries, concealed: [AppID("com.example.h")]).concealed.count == 1)
}

@Test func aConcealedAppThatIsStillDrawnKeepsItsDrawnItems() throws {
    let result = pass(
        groups: [group(99, x: 100)], owners: [99: appH],
        entries: ["status:com.example.h::Item-0": 50], concealed: [AppID("com.example.h")]
    )
    try #require(result.drawn?.count == 1)
    #expect(result.drawn?[0].items.map(\.barPosition) == [100])
    #expect(result.concealed.isEmpty)
}

@Test func hiddenOwnerWithoutAKnownNameFallsBackToItsBundleIdentifier() {
    let result = pass(entries: ["status:com.example.h::Item-0": 50], concealed: [AppID("com.example.h")])
    #expect(result.concealed.map(\.owner) == [.app(AppID("com.example.h"), name: "com.example.h")])
}

// Catches a pass that made no keys counting as one that read the order file: it would place with made-up keys.
@Test func aNilSnapshotIsAnUnreadPass() {
    for entries: [String: Double]? in [nil, [:], ["status:com.example.a::Item-0": 5]] {
        let result = InventoryAssembly.pass(
            snapshot: nil, owners: [10: appA], listings: [:], entries: entries, concealed: [AppID("com.example.h")])
        #expect(result == .unread)
        #expect(result.orderEntriesAvailable == false)
    }
}

// Catches a hidden app dropped before the core can keep its items.
@Test func aHiddenAppWithoutEntriesIsStillReported() {
    let hidden: Set<AppID> = [AppID("com.example.h")]
    #expect(pass(owners: [99: appH], entries: nil, concealed: hidden).concealed == [OwnerItems(owner: appH, items: [])])
    let otherEntries: [String: Double] = ["status:com.example.other::Item-0": 5]
    #expect(pass(owners: [99: appH], entries: otherEntries, concealed: hidden).concealed == [OwnerItems(owner: appH, items: [])])
}

@Test func thePassSaysWhetherItReadTheOrderFile() {
    #expect(pass(groups: [group(10, x: 100)], owners: [10: appA], entries: nil).orderEntriesAvailable == false)
    #expect(pass(groups: [group(10, x: 100)], owners: [10: appA], entries: [:]).orderEntriesAvailable == true)
}

@Test func listingDescriptionsAreZippedOnlyOnEqualCounts() throws {
    func raw(_ index: Int, _ text: String, x: Double) -> RawItem {
        RawItem(identifier: nil, description: text, title: "title \(text)", frame: CGRect(x: x, y: 0, width: 30, height: 24), index: index)
    }
    let groups = [group(10, x: 100), group(10, x: 200)]
    let matching = owned(groups: groups, owners: [10: appA], listings: [10: [raw(0, "one", x: 100), raw(1, "two", x: 200)]])
    try #require(matching.count == 1)
    #expect(matching[0].items.map(\.description) == ["one", "two"])
    #expect(matching[0].items.map(\.title) == ["title one", "title two"])

    let tooMany = owned(groups: groups, owners: [10: appA], listings: [10: [raw(0, "one", x: 100), raw(1, "two", x: 200), raw(2, "three", x: 300)]])
    try #require(tooMany.count == 1)
    #expect(tooMany[0].items.map(\.description) == [nil, nil])
    #expect(tooMany[0].items.map(\.title) == [nil, nil])
}

@Test func listingIsMatchedLeftToRightWhateverItsReadOrder() throws {
    func raw(_ index: Int, _ text: String, x: Double) -> RawItem {
        RawItem(identifier: nil, description: text, title: nil, frame: CGRect(x: x, y: 0, width: 30, height: 24), index: index)
    }
    let result = owned(
        groups: [group(10, x: 100), group(10, x: 200)], owners: [10: appA],
        listings: [10: [raw(0, "right", x: 200), raw(1, "left", x: 100)]]
    )
    try #require(result.count == 1)
    #expect(result[0].items.map(\.description) == ["left", "right"])
}

// Catches SystemUIServer and TextInputMenuAgent staying read-only: Siri and the Input menu must be assignable.
@Test func appleOwnersAreManagedByMacOSExceptTheAssignableOnes() throws {
    let apple = [
        "com.apple.MenuBarAgent": true, "com.apple.systemuiserver": false, "com.apple.TextInputMenuAgent": false,
        "com.apple.controlcenter": true,
    ]
    for (offset, (bundleID, isManaged)) in apple.sorted(by: { $0.key < $1.key }).enumerated() {
        let owner = ItemOwner.app(AppID(bundleID), name: bundleID)
        let result = owned(groups: [group(Int32(offset), x: 10)], owners: [Int32(offset): owner])
        try #require(result.count == 1)
        let managed = result[0].items.map(\.isManagedByMacOS)
        #expect(managed == [isManaged], "\(bundleID)")
    }
    let other = owned(groups: [group(10, x: 10)], owners: [10: appA])
    try #require(other.count == 1)
    #expect(other[0].items.map(\.isManagedByMacOS) == [false])
}

@Test func agentGroupsGetModuleKeys() throws {
    let result = owned(
        groups: [group(5, x: 10), group(5, x: 40), group(10, x: 70)],
        owners: [5: agent, 10: appA],
        entries: ["module:Clock": 0, "module:WiFi": 40]
    )
    try #require(result.count == 2)
    #expect(result.map(\.owner) == [agent, appA])
    #expect(result[0].items.map(\.key.raw) == ["module:WiFi", "module:Clock"])
    #expect(result[0].items.map(\.barPosition) == [10, 40])
}

// Catches the identifiers the reader gave the groups being dropped before the keys are built.
@Test func agentGroupsAreKeyedByTheMenuExtraTheyHost() throws {
    let wifi = DrawnGroup(pid: 5, frame: CGRect(x: 10, y: 0, width: 30, height: 24), identifier: "com.apple.menuextra.wifi")
    let clock = DrawnGroup(pid: 5, frame: CGRect(x: 40, y: 0, width: 30, height: 24), identifier: "com.apple.menuextra.clock")
    let result = owned(
        groups: [wifi, clock], owners: [5: agent],
        entries: ["module:Clock": 0, "module:Battery": 20, "module:WiFi": 40])
    try #require(result.count == 1)
    #expect(result[0].items.map(\.key.raw) == ["module:WiFi", "module:Clock"])
}

private let wifiID = SystemItemID(moduleName: "WiFi")

private func menuExtra(_ identifier: String?, x: Double) -> DrawnGroup {
    DrawnGroup(pid: 5, frame: CGRect(x: x, y: 0, width: 30, height: 24), identifier: identifier)
}

// Catches a drawn module staying unassignable: the identifier, through the table, is what makes it one.
@Test func aDrawnModuleCarriesTheSystemItemItsIdentifierNames() throws {
    let result = owned(
        groups: [menuExtra("com.apple.menuextra.wifi", x: 10), menuExtra("com.apple.menuextra.clock", x: 40)],
        owners: [5: agent], entries: ["module:Clock": 0, "module:WiFi": 40])
    try #require(result.count == 1)
    #expect(result[0].items.map(\.systemItem) == [wifiID, SystemItemID(moduleName: "Clock")])
    #expect(result[0].items.map(\.orderKeyIsCertain) == [true, true])
}

// Catches a guess by position making a module assignable: it could hide the wrong item.
@Test func aGroupWithoutAReadableIdentifierIsNotAssignable() throws {
    let result = owned(
        groups: [menuExtra(nil, x: 10), menuExtra("com.apple.menuextra.unknown", x: 40)], owners: [5: agent],
        entries: ["module:Clock": 0, "module:WiFi": 40])
    try #require(result.count == 1)
    #expect(result[0].items.map(\.systemItem) == [nil, nil])
}

// Catches Wi-Fi without an entry of its own being keyed by Battery's, which a move would then rewrite.
@Test func aDrawnModuleWithoutItsOwnEntryIsAssignableButNotMovable() throws {
    let result = owned(
        groups: [menuExtra("com.apple.menuextra.wifi", x: 10), menuExtra("com.apple.menuextra.battery", x: 40)],
        owners: [5: agent], entries: ["module:Battery": 20])
    try #require(result.count == 1)
    let items = result[0].items
    #expect(items.map(\.key.raw) == ["module:WiFi", "module:Battery"])
    #expect(items.map(\.systemItem) == [wifiID, SystemItemID(moduleName: "Battery")])
    #expect(items.map(\.orderKeyIsCertain) == [false, true])
}

// Catches a hidden module vanishing from Layout: it isn't drawn, so only the backend's set can list it.
@Test func aHiddenModuleThatIsNotDrawnIsReportedWithoutABarPosition() throws {
    let result = owned(
        groups: [menuExtra("com.apple.menuextra.clock", x: 40)], owners: [5: agent],
        entries: ["module:Clock": 0, "module:WiFi": 40], concealedSystemItems: [wifiID])
    try #require(result.count == 1)
    #expect(result[0].owner == agent)
    #expect(result[0].items.map(\.key.raw) == ["module:Clock", "module:WiFi"])
    let hidden = result[0].items[1]
    #expect(hidden.systemItem == wifiID && hidden.barPosition == nil)
    #expect(hidden.orderKeyIsCertain && hidden.isManagedByMacOS)
}

@Test func aHiddenModuleWithoutAnEntryIsReportedUncertainUnderItsOrderName() throws {
    let noFile = owned(
        groups: [menuExtra("com.apple.menuextra.clock", x: 40)], owners: [5: agent], entries: nil, concealedSystemItems: [wifiID])
    try #require(noFile.count == 1)
    let hidden = noFile[0].items[1]
    #expect(hidden.key.raw == "module:WiFi" && hidden.systemItem == wifiID)
    #expect(hidden.barPosition == nil && !hidden.orderKeyIsCertain)

    let noEntry = owned(
        groups: [menuExtra("com.apple.menuextra.clock", x: 40)], owners: [5: agent],
        entries: ["module:Clock": 0, "module:Battery": 20], concealedSystemItems: [wifiID])
    #expect(noEntry[0].items.map(\.key.raw) == ["module:Clock", "module:WiFi"])
    #expect(noEntry[0].items.map(\.orderKeyIsCertain) == [true, false])
}

// Catches a module counted twice: once drawn, once as hidden, which the over-approximating set allows.
@Test func aConcealedModuleThatIsStillDrawnIsNotReportedTwice() throws {
    let result = owned(
        groups: [menuExtra("com.apple.menuextra.wifi", x: 10)], owners: [5: agent],
        entries: ["module:WiFi": 40], concealedSystemItems: [wifiID])
    try #require(result.count == 1)
    #expect(result[0].items.map(\.key.raw) == ["module:WiFi"])
    #expect(result[0].items.map(\.barPosition) == [10])
}

// Catches the hidden module being dropped when nothing of MenuBarAgent is drawn: it is still hidden.
@Test func aHiddenModuleIsReportedEvenWhenMenuBarAgentDrawsNothing() throws {
    let result = pass(owners: [5: agent], entries: ["module:WiFi": 40], concealedSystemItems: [wifiID])
    #expect(result.concealed.map(\.owner) == [agent])
    #expect(result.concealed.first?.items.map(\.key.raw) == ["module:WiFi"])
}

@Test func oneOwnerAcrossProcessesIsOneScan() throws {
    let result = owned(groups: [group(10, x: 100), group(11, x: 50)], owners: [10: appA, 11: appA])
    try #require(result.count == 1)
    #expect(result[0].items.map(\.barPosition) == [50, 100])
}

@Test func groupsWithoutAnOwnerAreSkipped() throws {
    let result = owned(groups: [group(10, x: 100), group(77, x: 120)], owners: [10: appA])
    try #require(result.count == 1)
    #expect(result.map(\.owner) == [appA])
    #expect(result[0].items.count == 1)
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
    let result = owned(groups: [group(10, x: 100)], owners: [10: hulder], entries: entries, own: hulderID)
    try #require(result.count == 1)
    #expect(result[0].items.map(\.key.raw) == ["status:com.michaelrigart.hulder::HulderDivider"])
    let snapshot = InventorySnapshot(items: result[0].items, stale: [])
    #expect(InventoryAssembly.ownItemKey(in: snapshot, ownAppID: hulderID) == ItemKey(raw: "status:com.michaelrigart.hulder::HulderDivider"))
}

@Test func hulderDrawnItemIsNamedByItsAutosaveNameBeforeTheOrderFileHasAnEntry() throws {
    let result = owned(groups: [group(10, x: 100)], owners: [10: hulder], entries: [:], own: hulderID)
    try #require(result.count == 1)
    #expect(result[0].items.map(\.key.raw) == ["status:com.michaelrigart.hulder::HulderDivider"])
}

// Catches an undrawn Hulder that still gets items from its order entries: the divider would then be a
// stale position and every move would be planned against it, instead of answering "Hulder's icon isn't on the bar".
@Test func anUndrawnHulderHasNoItemsAndNoDivider() {
    let entries = [
        "status:com.michaelrigart.hulder::Item-0": 900.0,
        "status:com.michaelrigart.hulder::HulderDivider": 400.0,
    ]
    let result = owned(owners: [10: hulder], entries: entries, concealed: [hulderID], own: hulderID)
    #expect(result.isEmpty)
    let snapshot = InventorySnapshot(items: result.flatMap(\.items), stale: [])
    #expect(InventoryAssembly.ownItemKey(in: snapshot, ownAppID: hulderID) == nil)
}

@Test func hulderIsNeverReportedHidden() {
    let result = pass(owners: [10: hulder], entries: nil, concealed: [hulderID], own: hulderID)
    #expect(result.concealed.isEmpty)
    #expect(drawn(result).isEmpty)
}

@Test func otherAppsAreNotNamedByHulderAutosaveName() throws {
    let result = owned(groups: [group(10, x: 100)], owners: [10: appA], entries: [:], own: hulderID)
    try #require(result.count == 1)
    #expect(result[0].items.map(\.key.raw) == ["status:com.example.a::Item-0"])
}

@Test func unresolvedOwnersTakeTheWholeExecutableName() {
    #expect(OwnerResolver27.executableName(path: "/Applications/Some Tray.app/Contents/MacOS/some-tray-with-a-long-name") == "some-tray-with-a-long-name")
    #expect(OwnerResolver27.executableName(path: "") == nil)
}

// MARK: Order keys when an owner has more entries than drawn items

private let appB = ItemOwner.app(AppID("com.example.b"), name: "B")
private let appC = ItemOwner.app(AppID("com.example.c"), name: "C")
private let appD = ItemOwner.app(AppID("com.example.d"), name: "D")

private func bar(_ owners: [(pid: pid_t, owner: ItemOwner, x: Double)], _ entries: [String: Double]) -> [String: [(key: String, certain: Bool)]] {
    let result = owned(
        groups: owners.map { group($0.pid, x: $0.x) },
        owners: Dictionary(owners.map { ($0.pid, $0.owner) }, uniquingKeysWith: { first, _ in first }),
        entries: entries
    )
    var byOwner: [String: [(key: String, certain: Bool)]] = [:]
    for scan in result {
        byOwner[scan.owner.id] = scan.items.map { ($0.key.raw, $0.orderKeyIsCertain) }
    }
    return byOwner
}

// Catches the stale `Item-0` winning only because it sorts first: App A's real entry is `Alpha`, the one whose
// value sits between its neighbours on the bar.
@Test func anEntryBetweenTheNeighboursIsChosenOverAStaleOneThatSortsFirst() throws {
    let result = bar(
        [(1, appB, 50), (2, appA, 100), (3, appC, 150)],
        [
            "status:com.example.b::Item-0": 400, "status:com.example.c::Item-0": 200,
            "status:com.example.a::Item-0": 450, "status:com.example.a::Alpha": 300,
        ]
    )
    let items = try #require(result["com.example.a"])
    #expect(items.map(\.key) == ["status:com.example.a::Alpha"])
    #expect(items.map(\.certain) == [true])
}

// Catches a guess being presented as certain: both entries fit, so nothing tells them apart.
@Test func twoEntriesBetweenTheNeighboursLeaveTheItemUncertain() throws {
    let result = bar(
        [(1, appB, 50), (2, appA, 100), (3, appC, 150)],
        [
            "status:com.example.b::Item-0": 400, "status:com.example.c::Item-0": 200,
            "status:com.example.a::Item-0": 350, "status:com.example.a::Alpha": 300,
        ]
    )
    let items = try #require(result["com.example.a"])
    #expect(items.map(\.certain) == [false])
    #expect(items.map(\.key) == ["status:com.example.a::Item-0"])
    #expect(try #require(result["com.example.b"]).map(\.certain) == [true])
}

// The measured shape: a stale `Item-1` (869.5) beside the real `Item-0` (349), the drawn item between neighbours
// valued 381 and 233.
@Test func theMeasuredStaleEntryShapeResolvesToTheEntryBetweenTheNeighbours() throws {
    let entries: [String: Double] = [
        "status:com.example.b::Item-0": 381, "status:com.example.c::Item-0": 233,
        "status:com.example.a::Item-0": 349, "status:com.example.a::Item-1": 869.5,
    ]
    let result = bar([(1, appB, 50), (2, appA, 100), (3, appC, 150)], entries)
    let items = try #require(result["com.example.a"])
    #expect(items.map(\.key) == ["status:com.example.a::Item-0"])
    #expect(items.map(\.certain) == [true])

    // Catches an index preference: with the values swapped, `Item-1` is the one between the neighbours.
    var swapped = entries
    swapped["status:com.example.a::Item-0"] = 869.5
    swapped["status:com.example.a::Item-1"] = 349
    let other = try #require(bar([(1, appB, 50), (2, appA, 100), (3, appC, 150)], swapped)["com.example.a"])
    #expect(other.map(\.key) == ["status:com.example.a::Item-1"])
    #expect(other.map(\.certain) == [true])
}

// With no neighbour on a side, that side is unbounded.
@Test func aSideWithoutANeighbourIsUnbounded() throws {
    let entries: [String: Double] = [
        "status:com.example.c::Item-0": 500,
        "status:com.example.a::Item-0": 900, "status:com.example.a::Item-1": 100,
    ]
    let left = try #require(bar([(2, appA, 100), (3, appC, 150)], entries)["com.example.a"])
    #expect(left.map(\.key) == ["status:com.example.a::Item-0"])
    #expect(left.map(\.certain) == [true])
    let right = try #require(bar([(3, appC, 50), (2, appA, 100)], entries)["com.example.a"])
    #expect(right.map(\.key) == ["status:com.example.a::Item-1"])
    #expect(right.map(\.certain) == [true])
}

// Catches an uncertain neighbour used as a bound: B has more entries than items and its key is a guess, so its
// value says nothing about where the bar really is.
@Test func anUncertainNeighbourIsSkippedAsABound() throws {
    let entries: [String: Double] = [
        "status:com.example.c::Item-0": 400, "status:com.example.d::Item-0": 200,
        "status:com.example.b::Item-0": 100, "status:com.example.b::Item-1": 110,
        "status:com.example.a::Item-0": 300, "status:com.example.a::Item-1": 500,
    ]
    let result = bar([(1, appC, 50), (2, appB, 100), (3, appA, 150), (4, appD, 200)], entries)
    #expect(try #require(result["com.example.b"]).map(\.certain) == [false])
    let items = try #require(result["com.example.a"])
    #expect(items.map(\.key) == ["status:com.example.a::Item-0"])
    #expect(items.map(\.certain) == [true])
}

// Catches two drawn items of one app both taking the single entry that fits: their keys must stay distinct.
@Test func twoItemsThatFitTheSameEntryAreBothUncertainAndKeepDistinctKeys() throws {
    let entries: [String: Double] = [
        "status:com.example.b::Item-0": 400, "status:com.example.c::Item-0": 200,
        "status:com.example.a::Item-0": 300, "status:com.example.a::Item-1": 900, "status:com.example.a::Item-2": 950,
    ]
    let items = try #require(bar([(1, appB, 50), (2, appA, 100), (2, appA, 120), (3, appC, 150)], entries)["com.example.a"])
    #expect(items.count == 2)
    #expect(Set(items.map(\.key)).count == 2)
    #expect(items.map(\.certain) == [false, false])
}

// Owners with no more entries than drawn items are named as before, and are certain.
@Test func ownersWithAsManyEntriesAsDrawnItemsAreUnchangedAndCertain() throws {
    let entries: [String: Double] = [
        "status:com.example.a::Item-0": 300, "status:com.example.a::Item-1": 500,
        "status:com.example.b::Alpha": 100,
    ]
    let result = bar([(1, appA, 50), (1, appA, 80), (2, appB, 100), (3, appC, 150)], entries)
    #expect(try #require(result["com.example.a"]).map(\.key) == ["status:com.example.a::Item-1", "status:com.example.a::Item-0"])
    #expect(try #require(result["com.example.a"]).map(\.certain) == [true, true])
    #expect(try #require(result["com.example.b"]).map(\.key) == ["status:com.example.b::Alpha"])
    #expect(try #require(result["com.example.c"]).map(\.key) == ["status:com.example.c::Item-0"])
    #expect(try #require(result["com.example.c"]).map(\.certain) == [true])
}

// Catches Hulder's exact key being demoted by its stale `Item-0`.
@Test func hulderOwnKeyIsAlwaysCertain() throws {
    let entries = [
        "status:com.michaelrigart.hulder::Item-0": 900.0,
        "status:com.michaelrigart.hulder::HulderDivider": 400.0,
        "status:com.example.b::Item-0": 410.0,
    ]
    let result = owned(
        groups: [group(1, x: 50), group(10, x: 100)], owners: [1: appB, 10: hulder], entries: entries, own: hulderID)
    let own = try #require(result.first { $0.owner == hulder })
    #expect(own.items.map(\.orderKeyIsCertain) == [true])
}

// MARK: R58, concealed owners without order entries

// An app that is running and not concealed, without entries or drawn items, has none to keep.
@Test func aRunningOwnerThatIsNotConcealedAndDrawsNothingIsStillOmitted() {
    #expect(owned(owners: [99: appH], entries: nil, concealed: []).isEmpty)
    #expect(owned(owners: [99: appH], entries: [:], concealed: [AppID("com.example.other")]).filter { $0.owner == appH }.isEmpty)
}

// MARK: Entry items of a concealed owner

@Test func aNeverObservedConcealedOwnerWithTwoEntriesGivesTwoUncertainItems() throws {
    let entries: [String: Double] = ["status:com.example.h::Alpha": 300, "status:com.example.h::Beta": 200]

    let result = owned(owners: [99: appH], entries: entries, concealed: [AppID("com.example.h")])

    try #require(result.count == 1)
    let items = result[0].items
    #expect(items.map(\.key.raw) == ["status:com.example.h::Alpha", "status:com.example.h::Beta"])
    #expect(items.map(\.orderKeyIsCertain) == [false, false])
}

@Test func aNeverObservedConcealedOwnerWithOneEntryGivesOneCertainItem() throws {
    let result = owned(
        owners: [99: appH], entries: ["status:com.example.h::Alpha": 300], concealed: [AppID("com.example.h")])

    try #require(result.count == 1)
    let items = result[0].items
    #expect(items.map(\.key.raw) == ["status:com.example.h::Alpha"])
    #expect(items.map(\.orderKeyIsCertain) == [true])
}

// Catches tracking coverage keyed by bundle identity: a process that draws an item but resolves to no owner (or to
// one without a bundle identifier) still has menus that tracking must see.
@Test func theDrawnProcessesIncludeOwnersThatResolveToNothing() {
    let snapshot = BarSnapshot(groups: [group(10, x: 10), group(20, x: 50), group(30, x: 90), group(10, x: 130)], overflowIndicatorX: nil)

    #expect(InventoryAssembly.drawnProcesses(of: snapshot) == [10, 20, 30])
    #expect(InventoryAssembly.drawnProcesses(of: BarSnapshot(groups: [], overflowIndicatorX: nil)) == [])
    #expect(InventoryAssembly.drawnProcesses(of: nil) == nil)
}

// Catches MenuBarAgent's `module:` keys used as bounds: they are positional guesses, so a leftover entry of a
// hidden module next to an ambiguous app could make that app's wrong key look certain.
@Test func menuBarAgentItemsAreNotUsedAsBounds() throws {
    let entries: [String: Double] = [
        "status:com.example.b::Item-0": 400, "module:Clock": 200,
        "status:com.example.a::Item-0": 350, "status:com.example.a::Item-1": 150,
    ]
    let result = bar([(1, appB, 50), (2, appA, 100), (5, agent, 150)], entries)
    // Bounded by the module (200), only `Item-0` would fit; without it, both fit.
    let items = try #require(result["com.example.a"])
    #expect(items.map(\.certain) == [false])
    #expect(try #require(result["com.apple.MenuBarAgent"]).map(\.certain) == [true])
}
