import ApplicationServices
import Darwin
import HulderCore
import os
import Testing
@testable import HulderPlatform27

/// A registrar that records its calls and fails the registration of the notifications in `failing`.
private final class RecordingRegistrar: Sendable {
    private struct State {
        var added: [String] = []
        var removed: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failing: Set<String>

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var added: [String] { state.withLock { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }

    var registrar: AXAppObserver.Registrar {
        AXAppObserver.Registrar(
            add: { [self] _, _, name, _ in
                if failing.contains(name) { return .cannotComplete }
                state.withLock { $0.added.append(name) }
                return .success
            },
            remove: { [self] _, _, name in
                state.withLock { $0.removed.append(name) }
                return .success
            })
    }
}

// Catches an observer that registered only some of its notifications being reported as attached: tracking would
// say `.full` while the app's menu events never arrive.
@Test func anObserverThatMissesOneNotificationIsNotAttachedAndLetsGoOfTheOthers() {
    let notifications = MenuWindowSource27.notifications
    let recording = RecordingRegistrar(failing: [kAXMenuClosedNotification])

    let observer = AXAppObserver.attach(
        pid: getpid(), notifications: notifications, timeout: 0.25, registrar: recording.registrar, handler: { _ in })

    #expect(observer == nil)
    #expect(Set(recording.removed) == Set(recording.added))
    #expect(recording.removed.count == notifications.count - 1)
}

@Test func anObserverThatRegistersAllItsNotificationsIsAttached() {
    let notifications = MenuWindowSource27.notifications
    let recording = RecordingRegistrar()

    let observer = AXAppObserver.attach(
        pid: getpid(), notifications: notifications, timeout: 0.25, registrar: recording.registrar, handler: { _ in })

    #expect(observer != nil)
    #expect(recording.added == notifications)
    #expect(recording.removed.isEmpty)
    observer?.invalidate()
}

@Test func noNotificationRegisteringIsNotAttachedEither() {
    let notifications = MenuWindowSource27.notifications

    let observer = AXAppObserver.attach(
        pid: getpid(), notifications: notifications, timeout: 0.25,
        registrar: RecordingRegistrar(failing: Set(notifications)).registrar, handler: { _ in })

    #expect(observer == nil)
}

// The path a covered app takes: the source reports the failed attach, so the tracker counts it as unattached and
// says partial.
@Test(.timeLimit(.minutes(1))) func aCoveredAppWhoseObserverMissedOneNotificationMakesTrackingPartial() async {
    let pid = getpid()
    let published = OSAllocatedUnfairLock<[MenuTracking]>(initialState: [])
    let source = MenuWindowSource27(
        barEdges: BarBottomEdges27(), timeout: 0.25,
        registrar: RecordingRegistrar(failing: [kAXWindowCreatedNotification]).registrar)
    let engine = MenuTracker27.Session(source: source, queue: AXQueue(), after: nil) { _, _, tracking in
        if let tracking { published.withLock { $0.append(tracking) } }
    }

    await engine.coveredChanged([pid])
    await engine.processesChanged([pid])
    await engine.trustChanged(true)

    #expect(published.withLock { $0.last } == .partial)
    #expect(!published.withLock { $0.contains(.full) })
}
