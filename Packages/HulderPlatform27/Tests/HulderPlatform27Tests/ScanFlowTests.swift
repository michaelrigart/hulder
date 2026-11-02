import Testing
import HulderCore
@testable import HulderPlatform27

private let appA = ItemOwner.app(AppID("com.example.a"), name: "A")
private let appH = ItemOwner.app(AppID("com.example.h"), name: "H")

private func complete(_ owner: ItemOwner) -> AppScan {
    AppScan(owner: owner, result: .complete([]))
}

@Test func aRevocationTimesOutTheOwnersOfTheLastRead() {
    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: false, stopped: false, previousOwners: [appA, appH], finished: nil)

    #expect(decision.emit?.scans == [AppScan(owner: appA, result: .timedOut), AppScan(owner: appH, result: .timedOut)])
    #expect(decision.previousOwners == [appA, appH])
}

@Test func aRevocationWithoutAReadEmitsNothing() {
    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: false, stopped: false, previousOwners: [], finished: nil)

    #expect(decision.emit == nil)
}

@Test func aGrantEmitsNothingOnItsOwn() {
    let decision = ScanFlow.decide(
        wasTrusted: false, trusted: true, stopped: false, previousOwners: [appA], finished: nil)

    #expect(decision.emit == nil)
    #expect(decision.previousOwners == [appA])
}

@Test func aPassFinishingAfterARevocationIsDroppedAndKeepsTheOwners() {
    let pass = ScanFlow.Pass(scans: [complete(appH)], orderEntriesAvailable: true, owners: [appH])

    let decision = ScanFlow.decide(
        wasTrusted: false, trusted: false, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit == nil)
    #expect(decision.previousOwners == [appA])
}

@Test func aPassFinishingWhileTrustedIsEmittedAndRemembersItsOwners() {
    let pass = ScanFlow.Pass(scans: [complete(appH)], orderEntriesAvailable: true, owners: [appH])

    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit?.scans == [complete(appH)])
    #expect(decision.previousOwners == [appH])
}

@Test func aPassThatCouldNotReadTheBarKeepsTheOwners() {
    let timedOut = AppScan(owner: appA, result: .timedOut)
    let pass = ScanFlow.Pass(scans: [timedOut], orderEntriesAvailable: false, owners: nil)

    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit?.scans == [timedOut])
    #expect(decision.previousOwners == [appA])
}

@Test func nothingIsEmittedOnceStopped() {
    let pass = ScanFlow.Pass(scans: [complete(appH)], orderEntriesAvailable: true, owners: [appH])

    let revoked = ScanFlow.decide(
        wasTrusted: true, trusted: false, stopped: true, previousOwners: [appA], finished: nil)
    let finished = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: true, previousOwners: [appA], finished: pass)

    #expect(revoked.emit == nil)
    #expect(finished.emit == nil)
    #expect(finished.previousOwners == [appA])
}

// Catches the order-entries flag being taken from anywhere but the pass's own read: a pass assembled before the order
// store opened must say so, whatever the store looks like by the time the pass is emitted.
@Test func aPassEmitsWhetherItWasAssembledWithOrderEntries() {
    for flag in [true, false] {
        let pass = ScanFlow.Pass(scans: [complete(appH)], orderEntriesAvailable: flag, owners: [appH])
        let decision = ScanFlow.decide(
            wasTrusted: true, trusted: true, stopped: false, previousOwners: [], finished: pass)
        #expect(decision.emit == ScanPass(scans: [complete(appH)], orderEntriesAvailable: flag))
    }
}

@Test func theRevocationPassClaimsNoOrderEntries() {
    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: false, stopped: false, previousOwners: [appA], finished: nil)

    #expect(decision.emit?.orderEntriesAvailable == false)
}
