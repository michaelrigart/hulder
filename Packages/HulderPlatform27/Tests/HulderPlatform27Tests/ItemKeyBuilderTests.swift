import Testing
import HulderCore
@testable import HulderPlatform27

private func keys(_ token: String, drawn: Int, _ entries: [String: Double]) -> [String] {
    ItemKeyBuilder.keys(ownerToken: token, drawnCount: drawn, entries: entries).map(\.raw)
}

@Test func identicalItemsGetDistinctStableKeys() {
    let first = ItemKeyBuilder.keys(ownerToken: "com.example.a", drawnCount: 2, entries: [:])
    #expect(first.map(\.raw) == ["status:com.example.a::Item-1", "status:com.example.a::Item-0"])
    #expect(ItemKeyBuilder.keys(ownerToken: "com.example.a", drawnCount: 2, entries: [:]) == first)
}

@Test func entriesAreAssignedFromTheRight() {
    let entries = ["status:com.example.a::Item-0": 300.0, "status:com.example.a::Item-1": 500.0]
    #expect(keys("com.example.a", drawn: 2, entries) == ["status:com.example.a::Item-1", "status:com.example.a::Item-0"])
}

@Test func staleEntriesBeyondTheDrawnCountAreSkipped() {
    let entries = ["status:com.example.a::Item-0": 349.0, "status:com.example.a::Item-1": 869.5]
    #expect(keys("com.example.a", drawn: 1, entries) == ["status:com.example.a::Item-0"])
}

@Test func staleEntriesAreChosenByIndexNotByText() {
    let entries = ["status:com.example.a::Item-10": 900.0, "status:com.example.a::Item-2": 100.0]
    #expect(keys("com.example.a", drawn: 1, entries) == ["status:com.example.a::Item-2"])
}

@Test func namedEntriesKeepTheirNames() {
    let entries = ["status:com.example.a::Alpha": 501.0, "status:com.example.a::Beta": 456.0]
    #expect(keys("com.example.a", drawn: 2, entries) == ["status:com.example.a::Alpha", "status:com.example.a::Beta"])
}

@Test func extraDrawnItemsGetUnusedIndexes() {
    let entries = ["status:com.example.a::Item-0": 100.0]
    #expect(keys("com.example.a", drawn: 2, entries) == ["status:com.example.a::Item-1", "status:com.example.a::Item-0"])
}

@Test func otherOwnersEntriesAreIgnored() {
    let entries = ["status:com.example.ab::Item-0": 100.0, "module:Clock": 0.0]
    #expect(keys("com.example.a", drawn: 1, entries) == ["status:com.example.a::Item-0"])
}

@Test func equalValuesFollowTheCodecOrder() {
    let one = ["status:com.example.a::Item-0": 300.0, "status:com.example.a::Item-1": 300.0]
    let other = ["status:com.example.a::Item-1": 300.0, "status:com.example.a::Item-0": 300.0]
    let expected = ["status:com.example.a::Item-0", "status:com.example.a::Item-1"]
    #expect(keys("com.example.a", drawn: 2, one) == expected)
    #expect(keys("com.example.a", drawn: 2, other) == expected)
}

@Test func unresolvedOwnerUsesItsProcessName() {
    #expect(ItemKeyBuilder.ownerToken(.unresolved(processName: "tray")) == "tray")
    #expect(ItemKeyBuilder.ownerToken(.app(AppID("com.example.a"), name: "A")) == "com.example.a")
}

@Test func systemGroupsTakeModulesFromTheRight() {
    let entries = ["module:Clock": 0.0, "module:BentoBox-0": 106.0, "module:WiFi": 211.0]
    #expect(ItemKeyBuilder.systemKeys(drawnCount: 2, entries: entries).map(\.raw) == ["module:BentoBox-0", "module:Clock"])
}

@Test func leftOverSystemGroupsGetPlaceholderKeys() {
    let entries = ["module:Clock": 0.0, "status:com.example.a::Item-0": 50.0]
    #expect(ItemKeyBuilder.systemKeys(drawnCount: 3, entries: entries).map(\.raw) == ["module:#0", "module:#1", "module:Clock"])
}

@Test func ownKeysNameTheLeftmostItemByTheAutosaveNameAndIgnoreStaleEntries() {
    let entries = ["status:com.example.h::Item-0": 900.0, "status:com.example.h::Divider": 400.0]
    let own = ItemKeyBuilder.ownKeys(ownerToken: "com.example.h", autosaveName: "Divider", drawnCount: 1, entries: entries)
    #expect(own.map(\.raw) == ["status:com.example.h::Divider"])
}

@Test func ownKeysGiveAnExtraDrawnItemTheNextUnusedName() {
    let own = ItemKeyBuilder.ownKeys(ownerToken: "com.example.h", autosaveName: "Divider", drawnCount: 2, entries: [:])
    #expect(own.map(\.raw) == ["status:com.example.h::Divider", "status:com.example.h::Item-0"])
    #expect(ItemKeyBuilder.ownKeys(ownerToken: "com.example.h", autosaveName: "Divider", drawnCount: 0, entries: [:]).isEmpty)
}

private func bracketed(_ bounds: [ItemKeyBuilder.Bounds], _ entries: [String: Double]) -> [String] {
    ItemKeyBuilder.bracketed(ownerToken: "com.example.a", bounds: bounds, entries: entries).map { "\($0.key.raw)|\($0.isCertain)" }
}

// Catches a neighbour's own value counting as inside the bracket: the bounds are strict, right < v < left.
@Test func bracketBoundsAreStrict() {
    let entries = ["status:com.example.a::Item-0": 300.0, "status:com.example.a::Item-1": 100.0]
    #expect(bracketed([.init(upper: 300, lower: nil)], entries) == ["status:com.example.a::Item-1|true"])
    #expect(bracketed([.init(upper: nil, lower: 100)], entries) == ["status:com.example.a::Item-0|true"])
}

// Catches an item with no fitting entry being named with a made-up certain key.
@Test func anItemWithNoFittingEntryIsUncertainAndNamedAsBefore() {
    let entries = ["status:com.example.a::Item-0": 300.0, "status:com.example.a::Item-1": 100.0]
    #expect(bracketed([.init(upper: 50, lower: nil)], entries) == ["status:com.example.a::Item-0|false"])
}

// Catches the leftover items being named from entries a resolved item has already taken.
@Test func anUncertainItemNextToAResolvedOneDoesNotReuseItsEntry() {
    let entries = [
        "status:com.example.a::Item-0": 300.0, "status:com.example.a::Item-1": 250.0, "status:com.example.a::Item-2": 900.0,
    ]
    let result = bracketed([.init(upper: 1000, lower: 800), .init(upper: 320, lower: 200)], entries)
    #expect(result == ["status:com.example.a::Item-2|true", "status:com.example.a::Item-0|false"])
}
