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

// Catches an attach to MenuBarAgent while Accessibility is revoked or the session is stopped, which can only fail.
@Test func theAgentIsAttachedOnlyWhileTrustedAndRunning() {
    #expect(AgentObservation.mayAttach(trusted: true, stopped: false))
    #expect(!AgentObservation.mayAttach(trusted: false, stopped: false))
    #expect(!AgentObservation.mayAttach(trusted: true, stopped: true))
}

// Catches the failure from an attach that trust was lost during being logged, and recorded so it hides a real one.
@Test func anAttachFailureAfterTrustIsLostIsNotReported() {
    #expect(!AgentObservation.reportsFailure(pid: 42, lastReported: nil, trusted: false, stopped: false))
    #expect(!AgentObservation.reportsFailure(pid: 42, lastReported: nil, trusted: true, stopped: true))
}

// Catches a failure that happens after a re-grant going unlogged because the revocation's failure was recorded.
@Test func theFirstAttachFailureWhileTrustedIsReported() {
    #expect(AgentObservation.reportsFailure(pid: 42, lastReported: nil, trusted: true, stopped: false))
}

// Catches the same agent's failure being logged on every pass.
@Test func aRepeatedFailureForTheSamePidIsReportedOnce() {
    #expect(!AgentObservation.reportsFailure(pid: 42, lastReported: 42, trusted: true, stopped: false))
    #expect(AgentObservation.reportsFailure(pid: 43, lastReported: 42, trusted: true, stopped: false))
}
