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

    #expect(decision.emit == [AppScan(owner: appA, result: .timedOut), AppScan(owner: appH, result: .timedOut)])
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
    let pass = ScanFlow.Pass(scans: [complete(appH)], owners: [appH])

    let decision = ScanFlow.decide(
        wasTrusted: false, trusted: false, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit == nil)
    #expect(decision.previousOwners == [appA])
}

@Test func aPassFinishingWhileTrustedIsEmittedAndRemembersItsOwners() {
    let pass = ScanFlow.Pass(scans: [complete(appH)], owners: [appH])

    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit == [complete(appH)])
    #expect(decision.previousOwners == [appH])
}

@Test func aPassThatCouldNotReadTheBarKeepsTheOwners() {
    let timedOut = AppScan(owner: appA, result: .timedOut)
    let pass = ScanFlow.Pass(scans: [timedOut], owners: nil)

    let decision = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: false, previousOwners: [appA], finished: pass)

    #expect(decision.emit == [timedOut])
    #expect(decision.previousOwners == [appA])
}

@Test func nothingIsEmittedOnceStopped() {
    let pass = ScanFlow.Pass(scans: [complete(appH)], owners: [appH])

    let revoked = ScanFlow.decide(
        wasTrusted: true, trusted: false, stopped: true, previousOwners: [appA], finished: nil)
    let finished = ScanFlow.decide(
        wasTrusted: true, trusted: true, stopped: true, previousOwners: [appA], finished: pass)

    #expect(revoked.emit == nil)
    #expect(finished.emit == nil)
    #expect(finished.previousOwners == [appA])
}
