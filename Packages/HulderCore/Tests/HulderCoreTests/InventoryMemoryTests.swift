import Testing
@testable import HulderCore

struct InventoryMemoryTests {
    private let a = ItemOwner.app(AppID("com.example.a"), name: "A")
    private let b = ItemOwner.app(AppID("com.example.b"), name: "B")
    private let h = ItemOwner.app(AppID("com.example.h"), name: "H")

    private func item(
        _ key: String, _ owner: ItemOwner, at position: Double? = nil, certain: Bool = true
    ) -> MenuBarItem {
        MenuBarItem(key: ItemKey(raw: key), owner: owner, barPosition: position, orderKeyIsCertain: certain)
    }

    private var a1: MenuBarItem { item("a1", a, at: 100) }
    private var b1: MenuBarItem { item("b1", b, at: 200) }

    private func drawn(
        _ owners: [(ItemOwner, [MenuBarItem])], concealed: [(ItemOwner, [MenuBarItem])] = [], entries: Bool = true
    ) -> ScanPass {
        ScanPass(
            drawn: owners.map { OwnerItems(owner: $0.0, items: $0.1) },
            concealed: concealed.map { OwnerItems(owner: $0.0, items: $0.1) },
            orderEntriesAvailable: entries)
    }

    private func hidden(_ owners: [(ItemOwner, [MenuBarItem])], entries: Bool = true) -> ScanPass {
        drawn([], concealed: owners, entries: entries)
    }

    @Test func aDrawnOwnerIsListedAndNotStale() {
        var memory = InventoryMemory()

        let snapshot = memory.apply(drawn([(a, [a1])]))

        #expect(snapshot == InventorySnapshot(items: [a1], stale: []))
    }

    // Review Focus 2: catches a revocation emptying Layout, and an unread pass that forgets or invents memory.
    @Test func anUnreadBarKeepsEveryItemAndMarksItsOwnersStale() {
        var memory = InventoryMemory()
        let alpha = item("h::Alpha", h)
        let first = memory.apply(drawn([(a, [a1]), (b, [b1])], concealed: [(h, [alpha])]))
        #expect(first.items == [a1, b1, alpha])

        let unread = memory.apply(.unread)
        #expect(unread.items == [a1, b1, alpha])
        #expect(unread.stale == ["com.example.a", "com.example.b", "com.example.h"])
        #expect(memory.apply(.unread) == unread)

        let aHidden = memory.apply(hidden([(a, [])]))
        #expect(aHidden.items.map(\.key.raw) == ["a1"])

        let beta = item("h::Beta", h)
        let hHidden = memory.apply(hidden([(h, [beta])]))
        #expect(hHidden == InventorySnapshot(items: [beta], stale: []))
    }

    // Pre-merge round 1, R58: catches hidden items vanishing without order access.
    @Test func aHiddenAppSeenDrawnKeepsItsItemsWithoutOrderEntries() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [a1])]))

        let snapshot = memory.apply(hidden([(a, [])]))

        #expect(snapshot.items.map(\.key.raw) == ["a1"])
        #expect(snapshot.items.map(\.barPosition) == [nil])
        #expect(snapshot.stale == ["com.example.a"])
    }

    // Round 2 (5), R61(5): catches a stale entry becoming a phantom item.
    @Test func aHiddenAppSeenDrawnGetsNoItemFromItsEntries() {
        var memory = InventoryMemory()
        let alpha = item("a::Alpha", a, at: 100)
        _ = memory.apply(drawn([(a, [alpha])], entries: true))

        let snapshot = memory.apply(hidden([(a, [item("a::Alpha", a), item("a::Item-0", a)])]))

        #expect(snapshot.items.map(\.key.raw) == ["a::Alpha"])
        #expect(snapshot.stale == ["com.example.a"])
    }

    // Review of this task, finding 1: catches made-up keys being placed over the file's.
    @Test func aHiddenAppSeenOnlyBeforeTheOrderFileWasReadTakesItsEntryItems() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [item("a::Item-0", a, at: 100)])], entries: false))

        let snapshot = memory.apply(hidden([(a, [item("a::Alpha", a)])]))

        #expect(snapshot.items.map(\.key.raw) == ["a::Alpha"])
        #expect(snapshot.items.map(\.orderKeyIsCertain) == [true])
        #expect(snapshot.stale.isEmpty)
    }

    // R58 on a Mac without order access.
    @Test func aHiddenAppSeenOnlyBeforeTheOrderFileWasReadKeepsWhatItDrewWithoutEntries() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [item("a::Item-0", a, at: 100)])], entries: false))

        let snapshot = memory.apply(hidden([(a, [])], entries: false))

        #expect(snapshot.items.map(\.key.raw) == ["a::Item-0"])
        #expect(snapshot.items.map(\.barPosition) == [nil])
        #expect(snapshot.stale == ["com.example.a"])
    }

    // R61(5): catches a remembered uncertain key turning certain, which would let Layout move the wrong entry.
    @Test func aRememberedItemKeepsItsKeyCertainty() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [item("a::Item-0", a, at: 100, certain: false)])]))

        let snapshot = memory.apply(hidden([(a, [])]))

        #expect(snapshot.items.map(\.orderKeyIsCertain) == [false])
    }

    // Round 3: catches "seen drawn" outliving the items it saw.
    @Test func anAppThatQuitAndCameBackHiddenShowsWhatItLastDrew() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [a1])]))

        #expect(memory.apply(drawn([(b, [b1])])).items == [b1])

        let back = memory.apply(hidden([(a, [])]))
        #expect(back.items.map(\.key.raw) == ["a1"])
        #expect(back.stale == ["com.example.a"])

        let twoEntries = memory.apply(hidden([(a, [item("a::Alpha", a), item("a::Beta", a)])]))
        #expect(twoEntries.items.map(\.key.raw) == ["a1"])
    }

    @Test func aHiddenAppNeverSeenDrawnTakesItsEntryItems() {
        var memory = InventoryMemory()
        let alpha = item("h::Alpha", h)

        let snapshot = memory.apply(hidden([(h, [alpha])]))

        #expect(snapshot == InventorySnapshot(items: [alpha], stale: []))
    }

    // R58.
    @Test func aHiddenAppNeverSeenAndWithoutEntriesIsStaleWithoutItems() {
        var memory = InventoryMemory()

        let snapshot = memory.apply(hidden([(h, [])]))

        #expect(snapshot == InventorySnapshot(items: [], stale: ["com.example.h"]))
    }

    @Test func drawingAgainReplacesWhatWasRemembered() {
        var memory = InventoryMemory()
        let a2 = item("a2", a, at: 150)
        _ = memory.apply(drawn([(a, [a1, a2])]))
        _ = memory.apply(drawn([(a, [a1])]))

        let snapshot = memory.apply(hidden([(a, [])]))

        #expect(snapshot.items.map(\.key.raw) == ["a1"])
    }

    // Task 9's merger rule.
    @Test func anOwnerNeitherDrawnNorHiddenIsLeftOut() {
        var memory = InventoryMemory()
        _ = memory.apply(drawn([(a, [a1]), (b, [b1])]))

        let snapshot = memory.apply(drawn([(b, [b1])]))

        #expect(snapshot == InventorySnapshot(items: [b1], stale: []))
    }

    @Test func anOwnerBothDrawnAndHiddenUsesItsDrawnItems() {
        var memory = InventoryMemory()

        let snapshot = memory.apply(drawn([(a, [a1])], concealed: [(a, [item("a::Alpha", a)])]))

        #expect(snapshot == InventorySnapshot(items: [a1], stale: []))
    }

    @Test func drawnOwnersComeFirstThenHiddenOnesInThePassesOrder() {
        var memory = InventoryMemory()
        let h1 = item("h1", h)

        let snapshot = memory.apply(drawn([(b, [b1]), (a, [a1])], concealed: [(h, [h1])]))

        #expect(snapshot.items == [b1, a1, h1])
    }
}
