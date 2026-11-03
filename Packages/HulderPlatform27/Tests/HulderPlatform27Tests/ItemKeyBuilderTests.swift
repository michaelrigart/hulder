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

private func systemKeys(_ identifiers: [String?], _ entries: [String: Double]) -> [String] {
    ItemKeyBuilder.systemKeys(identifiers: identifiers, entries: entries).map(\.key.raw)
}

@Test func systemGroupsWithoutIdentifiersTakeModulesFromTheRight() {
    let entries = ["module:Clock": 0.0, "module:BentoBox-0": 106.0, "module:WiFi": 211.0]
    #expect(systemKeys([nil, nil], entries) == ["module:BentoBox-0", "module:Clock"])
}

@Test func leftOverSystemGroupsGetPlaceholderKeys() {
    let entries = ["module:Clock": 0.0, "status:com.example.a::Item-0": 50.0]
    #expect(systemKeys([nil, nil, nil], entries) == ["module:#0", "module:#1", "module:Clock"])
}

// Catches the live case: while Hulder hides, macOS hides Focus too, and the rightmost-entries rule named the drawn
// Wi-Fi, Battery, Control Center and Clock items Battery, FocusModes, BentoBox-0 and Clock.
@Test func systemGroupsTakeTheModuleTheirIdentifierNames() {
    let entries = [
        "module:WiFi": 232.0, "module:Battery": 206.0, "module:FocusModes": 192.0, "module:BentoBox-0": 105.0, "module:Clock": 0.0,
    ]
    let identifiers = [
        "com.apple.menuextra.wifi", "com.apple.menuextra.battery", "com.apple.menuextra.controlcenter", "com.apple.menuextra.clock",
    ]
    #expect(systemKeys(identifiers, entries) == ["module:WiFi", "module:Battery", "module:BentoBox-0", "module:Clock"])
}

// Catches the Control Center item, whose identifier is not its module's name, falling to the positional rule.
@Test func theControlCenterIdentifierIsTheBentoBoxModule() {
    let entries = ["module:BentoBox-3": 105.0, "module:Clock": 0.0, "module:WiFi": 232.0]
    #expect(systemKeys(["com.apple.menuextra.controlcenter"], entries) == ["module:BentoBox-3"])
    #expect(systemKeys(["com.apple.menuextra.CONTROLCENTER"], entries) == ["module:BentoBox-3"])
}

// Catches Focus, whose identifier `focusmode` is not its module's name `FocusModes`, falling to the positional rule and
// shifting every item to its left by one entry. The set is the one measured on macOS 27.2 with every item shown.
@Test func theMeasuredLiveSetIsKeyedByIdentifierFocusIncluded() {
    let entries = [
        "module:WiFi": 232.0, "module:Battery": 206.0, "module:FocusModes": 192.0, "module:BentoBox-0": 105.0, "module:Clock": 0.0,
        "module:AudioVideoModule": 300.0, "module:Display": 290.0, "module:ScreenMirroring": 280.0, "module:Sound": 270.0,
        "module:NowPlaying": 260.0,
    ]
    let identifiers = [
        "com.apple.menuextra.battery", "com.apple.menuextra.wifi", "com.apple.menuextra.focusmode",
        "com.apple.menuextra.clock", "com.apple.menuextra.controlcenter",
    ]
    #expect(systemKeys(identifiers, entries)
        == ["module:Battery", "module:WiFi", "module:FocusModes", "module:Clock", "module:BentoBox-0"])
}

// Catches an identifier that merely begins like a module name being left to position, and the other way round.
@Test func anIdentifierTakesTheOneFreeModuleItsNameBeginsOrIsBeganBy() {
    let entries = ["module:AudioVideoModule": 300.0, "module:Clock": 0.0, "module:Sound": 100.0]
    #expect(systemKeys(["com.apple.menuextra.audiovideo"], entries) == ["module:AudioVideoModule"])
    #expect(systemKeys(["com.apple.menuextra.soundsettings"], entries) == ["module:Sound"])
}

// Catches the Focus alias going missing: the prefix rule alone finds FocusModes only while no other entry begins alike.
@Test func theFocusModeIdentifierIsTheFocusModesModuleEvenWhenAnotherEntryBeginsAlike() {
    let entries = ["module:FocusModes": 300.0, "module:FocusModeAssist": 200.0, "module:Clock": 0.0]
    #expect(systemKeys(["com.apple.menuextra.focusmode"], entries) == ["module:FocusModes"])
}

// Catches a prefix guess picking one of several candidates; the item falls to the entries left over from the right.
@Test func anAmbiguousPrefixFallsBackToPosition() {
    let entries = ["module:ScreenMirroring": 300.0, "module:ScreenTime": 200.0, "module:Clock": 0.0]
    #expect(systemKeys(["com.apple.menuextra.screen"], entries) == ["module:Clock"])
}

// Catches a prefix match winning over an exact one, which would take Battery for BatteryHealth.
@Test func anExactNameBeatsAPrefixMatch() {
    let entries = ["module:BatteryHealth": 300.0, "module:Battery": 200.0]
    #expect(systemKeys(["com.apple.menuextra.battery"], entries) == ["module:Battery"])
}

// Catches an identifier with no name after the prefix matching every entry.
@Test func anEmptyIdentifierNameMatchesNothing() {
    let entries = ["module:Clock": 0.0]
    #expect(systemKeys(["com.apple.menuextra."], entries) == ["module:Clock"])
    #expect(systemKeys(["com.apple.menuextra.", "com.apple.menuextra."], entries) == ["module:#0", "module:Clock"])
}

// Catches an item without an identifier taking an entry that an identified item owns.
@Test func aGroupWithoutAnIdentifierTakesPositionAmongTheEntriesLeftOver() {
    let entries = ["module:WiFi": 232.0, "module:Battery": 206.0, "module:Clock": 0.0]
    #expect(systemKeys(["com.apple.menuextra.clock", nil], entries) == ["module:Clock", "module:Battery"])
    #expect(systemKeys([nil, "com.apple.menuextra.wifi", "com.apple.menuextra.unknown"], entries)
        == ["module:Battery", "module:WiFi", "module:Clock"])
}

// Catches one entry naming two items.
@Test func anEntryIsTakenAtMostOnce() {
    let entries = ["module:Clock": 0.0, "module:WiFi": 232.0]
    #expect(systemKeys(["com.apple.menuextra.clock", "com.apple.menuextra.clock"], entries) == ["module:Clock", "module:WiFi"])
    #expect(systemKeys(["com.apple.menuextra.clock", "com.apple.menuextra.clock", nil], entries)
        == ["module:Clock", "module:#0", "module:WiFi"])
}

private func certain(_ identifiers: [String?], _ entries: [String: Double]) -> [Bool] {
    ItemKeyBuilder.systemKeys(identifiers: identifiers, entries: entries).map(\.isCertain)
}

// Catches Wi-Fi, with no entry of its own, taking Battery's entry from the leftover rule: moving Wi-Fi would then
// rewrite Battery's entry.
@Test func aTableModuleWithoutItsOwnEntryIsUncertainAndNeverTakesAnotherModulesEntry() {
    let entries = ["module:Battery": 206.0, "module:Clock": 0.0]
    let identifiers: [String?] = ["com.apple.menuextra.wifi", "com.apple.menuextra.battery", "com.apple.menuextra.clock"]
    #expect(systemKeys(identifiers, entries) == ["module:WiFi", "module:Battery", "module:Clock"])
    #expect(certain(identifiers, entries) == [false, true, true])
    #expect(systemKeys(["com.apple.menuextra.wifi"], entries) == ["module:WiFi"])
    #expect(systemKeys(["com.apple.menuextra.wifi", nil], entries) == ["module:WiFi", "module:Clock"])
}

// Catches the live set losing its certainty, or Control Center missing its `-0` entry.
@Test func theLiveSetFromTheOrderFileIsCertain() {
    let entries = ["module:WiFi": 232.0, "module:Battery": 206.0, "module:BentoBox-0": 105.0, "module:Clock": 0.0]
    let identifiers: [String?] = [
        "com.apple.menuextra.wifi", "com.apple.menuextra.battery", "com.apple.menuextra.controlcenter", "com.apple.menuextra.clock",
    ]
    #expect(systemKeys(identifiers, entries) == ["module:WiFi", "module:Battery", "module:BentoBox-0", "module:Clock"])
    #expect(certain(identifiers, entries) == [true, true, true, true])
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
