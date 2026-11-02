import Testing
import HulderCore
@testable import HulderPlatform27

private let appH = ItemOwner.app(AppID("com.example.h"), name: "H")

private func read(entries: Bool) -> ScanPass {
    ScanPass(drawn: [OwnerItems(owner: appH, items: [])], concealed: [], orderEntriesAvailable: entries)
}

// Catches a revocation that leaves the kept inventory looking fresh.
@Test func aRevocationEmitsAnUnreadPass() {
    #expect(ScanFlow.decide(wasTrusted: true, trusted: false, stopped: false, finished: nil) == .unread)
}

// Nothing was read before, and the memory in the core has nothing to mark: the pass is still emitted, so the core
// needs no special case.
@Test func aRevocationEmitsAnUnreadPassAlsoWhenNothingWasReadBefore() {
    let pass = ScanFlow.decide(wasTrusted: true, trusted: false, stopped: false, finished: nil)

    #expect(pass?.drawn == nil)
    #expect(pass?.orderEntriesAvailable == false)
}

// Catches a pass that read the bar before a revocation being emitted after the unread pass that follows it.
@Test func aPassFinishingAfterARevocationIsDropped() {
    #expect(ScanFlow.decide(wasTrusted: false, trusted: false, stopped: false, finished: read(entries: true)) == nil)
}

// Catches the order-entries flag being taken from anywhere but the pass's own read.
@Test func aPassFinishingWhileTrustedIsEmittedUnchanged() {
    for flag in [true, false] {
        let pass = read(entries: flag)
        #expect(ScanFlow.decide(wasTrusted: true, trusted: true, stopped: false, finished: pass) == pass)
    }
}

@Test func aPassThatCouldNotReadTheBarIsEmitted() {
    #expect(ScanFlow.decide(wasTrusted: true, trusted: true, stopped: false, finished: .unread) == .unread)
}

@Test func aGrantEmitsNothingOnItsOwn() {
    #expect(ScanFlow.decide(wasTrusted: false, trusted: true, stopped: false, finished: nil) == nil)
}

@Test func nothingIsEmittedOnceStopped() {
    #expect(ScanFlow.decide(wasTrusted: true, trusted: false, stopped: true, finished: nil) == nil)
    #expect(ScanFlow.decide(wasTrusted: true, trusted: true, stopped: true, finished: read(entries: true)) == nil)
}
