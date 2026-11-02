import Foundation
import Testing
@testable import HulderPlatform27

private final class Recorder: @unchecked Sendable { // reason: the tests below run on one thread
    var released: [pid_t] = []
    var releasedWhileObserved: [pid_t] = []
}

private final class FakeApp: NSObject {
    @objc dynamic var isFinishedLaunching = false
    let pid: pid_t
    private let recorder: Recorder

    init(pid: pid_t, recorder: Recorder) {
        self.pid = pid
        self.recorder = recorder
    }

    deinit {
        recorder.released.append(pid)
        if observationInfo != nil { recorder.releasedWhileObserved.append(pid) }
    }
}

private func makeWatches() -> LaunchWatches<FakeApp> {
    LaunchWatches<FakeApp>(pid: \.pid) { app in app.observe(\.isFinishedLaunching) { _, _ in } }
}

private func watch(_ pids: [pid_t], in watches: LaunchWatches<FakeApp>, recorder: Recorder) {
    watches.update(pids.map { FakeApp(pid: $0, recorder: recorder) }) { _ in true }
}

// Catches the crash seen when an app exited while still launching: nothing but the snapshot held the
// NSRunningApplication, so AppKit released it with its observation registered.
@Test func aWatchedAppIsNotReleasedWhileItsObservationIsRegistered() {
    let recorder = Recorder()
    let watches = makeWatches()

    watch([1, 2], in: watches, recorder: recorder)

    #expect(recorder.released.isEmpty)
    watches.removeAll()
}

@Test func aProcessThatGoesAwayIsUnobservedBeforeItsAppIsReleased() {
    let recorder = Recorder()
    let watches = makeWatches()
    watch([1, 2], in: watches, recorder: recorder)

    watches.update([]) { _ in true }

    #expect(recorder.released.sorted() == [1, 2])
    #expect(recorder.releasedWhileObserved.isEmpty)
}

@Test func tearingDownUnobservesEveryAppBeforeItIsReleased() {
    let recorder = Recorder()
    let watches = makeWatches()
    watch([1, 2], in: watches, recorder: recorder)

    watches.removeAll()

    #expect(recorder.released.sorted() == [1, 2])
    #expect(recorder.releasedWhileObserved.isEmpty)
}

@Test func anAppIsWatchedOnceAndOnlyWhileItNeedsWatching() {
    let recorder = Recorder()
    let watches = makeWatches()
    let launching = FakeApp(pid: 1, recorder: recorder)
    let finished = FakeApp(pid: 2, recorder: recorder)

    watches.update([launching, finished]) { $0.pid == 1 }
    watches.update([launching, finished]) { $0.pid == 1 }

    #expect(launching.observationInfo != nil)
    #expect(finished.observationInfo == nil)
    watches.removeAll()
    #expect(launching.observationInfo == nil)
}

// Catches observed apps released while still observed when the watches are freed without a teardown: the dictionary
// destroys each entry's app before its token.
@Test func freeingTheWatchesUnobservesEveryAppBeforeItIsReleased() {
    let recorder = Recorder()
    do {
        let watches = makeWatches()
        watch([1, 2], in: watches, recorder: recorder)
    }

    #expect(recorder.released.sorted() == [1, 2])
    #expect(recorder.releasedWhileObserved.isEmpty)
}

// Catches an update queued behind the teardown starting watches nobody will ever invalidate.
@Test func anUpdateAfterTheTeardownWatchesNothing() {
    let recorder = Recorder()
    let watches = makeWatches()
    let app = FakeApp(pid: 1, recorder: recorder)
    watches.removeAll()

    watches.update([app]) { _ in true }

    #expect(app.observationInfo == nil)
}
