import Foundation
import Synchronization
import os
import Testing
@testable import HulderPlatform27

private let name = Notification.Name("com.apple.accessibility.api.test")

/// Polls `done` until it holds or ten seconds pass, so no wait is unbounded.
private func wait(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation, until done: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !done() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Reads one subscription to a stream from its start, in the background.
private final class Recorder: Sendable {
    private struct State {
        var seen: [Bool] = []
        var ended = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<Bool>) {
        let state = state
        task = Task {
            for await value in stream { state.withLock { $0.seen.append(value) } }
            state.withLock { $0.ended = true }
        }
    }

    deinit { task.cancel() }

    var all: [Bool] { state.withLock { $0.seen } }

    /// Returns once `count` values have arrived.
    func waitForValues(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = await wait("\(count) values", sourceLocation: sourceLocation) { state.withLock { $0.seen.count >= count } }
    }

    func waitForEnd(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await wait("the stream to end", sourceLocation: sourceLocation) { state.withLock { $0.ended } }
    }
}

/// Holds one call until it is opened, however the two are ordered.
private final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }

    func hold() async {
        for await _ in stream { return }
    }

    func open() {
        continuation.yield()
        continuation.finish()
    }
}

/// Answers each call from a script, in call order, and counts the calls that start. One call can be
/// held at a gate, as a slow child check is.
private final class ScriptedCheck: Sendable {
    private let answers: Mutex<[Bool?]>
    private let calls = Mutex(0)
    private let hold: (call: Int, gate: Gate)?

    init(_ answers: [Bool?], holdingCall call: Int? = nil, at gate: Gate? = nil) {
        self.answers = Mutex(answers)
        hold = call.flatMap { call in gate.map { (call, $0) } }
    }

    var callCount: Int { calls.withLock { $0 } }

    func call() async -> Bool? {
        let number = calls.withLock { count in
            count += 1
            return count
        }
        let answer = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if let hold, hold.call == number {
            await hold.gate.hold()
        }
        return answer
    }

    /// Returns once `count` calls have started. Checks run one at a time, so a call starts only after
    /// the one before it has been applied.
    func waitForCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = await wait("\(count) checks started", sourceLocation: sourceLocation) { calls.withLock { $0 >= count } }
    }
}

private final class Scheduled: Sendable {
    let delays = Mutex<[Duration]>([])
    let work = Mutex<[@Sendable () -> Void]>([])

    func schedule(_ delay: Duration, _ body: @escaping @Sendable () -> Void) {
        delays.withLock { $0.append(delay) }
        work.withLock { $0.append(body) }
    }

    func runNext() {
        let next = work.withLock { items in items.isEmpty ? nil : items.removeFirst() }
        next?()
    }

    func runAll() {
        let pending = work.withLock { items in
            defer { items = [] }
            return items
        }
        for body in pending { body() }
    }
}

private func grant(
    initial: Bool = false, center: NotificationCenter = NotificationCenter(), scheduled: Scheduled = Scheduled(),
    check: @escaping @Sendable () async -> Bool?, fallback: (@Sendable () -> Bool)? = nil
) -> AccessibilityGrant27 {
    AccessibilityGrant27(
        center: center, name: name, initial: { initial }, check: check, fallback: fallback ?? { initial },
        after: scheduled.schedule)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aChangedResultIsEmittedOnceAndBecomesTheValue() async {
    let script = ScriptedCheck([true, false])
    let center = NotificationCenter()
    let scheduled = Scheduled()
    let grant = grant(center: center, scheduled: scheduled, check: script.call)
    let recorder = Recorder(grant.values())
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    scheduled.runAll()
    await recorder.waitForValues(3)
    #expect(recorder.all == [false, true, false])
    #expect(!grant.isGranted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theInitialValueIsWhatTheInitialReadAnswers() {
    #expect(grant(initial: true, check: { nil }).isGranted)
    #expect(!grant(initial: false, check: { nil }).isGranted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func readingTheValueNeverRunsTheCheck() {
    let script = ScriptedCheck([true])
    let grant = grant(check: script.call)
    _ = grant.isGranted
    _ = grant.isGranted
    #expect(script.callCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aNotificationChecksAtOnceAndAtHalfASecondAndTwoSeconds() async {
    let script = ScriptedCheck([nil, nil, nil])
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let grant = grant(center: center, scheduled: scheduled, check: script.call)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    #expect(scheduled.delays.withLock { $0 } == [.milliseconds(500), .seconds(2)])
    #expect(script.callCount == 1)
    scheduled.runNext()
    await script.waitForCalls(2)
    scheduled.runNext()
    await script.waitForCalls(3)
    #expect(script.callCount == 3)
    withExtendedLifetime(grant) {}
}

@MainActor
@Test(.timeLimit(.minutes(1))) func resultsApplyInCheckOrderEvenWhenAnEarlierCheckIsSlow() async {
    let gate = Gate()
    // Call 1 is slow and answers true; call 2 answers false. Side by side, the late true would win.
    let script = ScriptedCheck([true, false], holdingCall: 1, at: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let grant = grant(center: center, scheduled: scheduled, check: script.call)
    let recorder = Recorder(grant.values())
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    scheduled.runAll()
    gate.open()
    await recorder.waitForValues(3)
    #expect(recorder.all == [false, true, false])
    #expect(!grant.isGranted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aFailedCheckAnswersWithTheFallback() async {
    let script = ScriptedCheck([nil, nil, nil])
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let grant = grant(
        initial: true, center: center, scheduled: scheduled, check: script.call, fallback: { false })
    let recorder = Recorder(grant.values())
    center.post(name: name, object: nil)
    scheduled.runAll()
    await recorder.waitForValues(2)
    #expect(recorder.all == [true, false])
    #expect(!grant.isGranted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aCheckThatAnswersIsNotReplacedByTheFallback() async {
    let script = ScriptedCheck([false, false, false])
    let center = NotificationCenter()
    let grant = grant(initial: true, center: center, check: script.call, fallback: { true })
    let recorder = Recorder(grant.values())
    center.post(name: name, object: nil)
    await recorder.waitForValues(2)
    #expect(recorder.all == [true, false])
    #expect(!grant.isGranted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func requestsDuringACheckLeadToExactlyOneMoreCheck() async {
    let gate = Gate()
    let script = ScriptedCheck([true, false, false, false], holdingCall: 1, at: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    var held: AccessibilityGrant27? = grant(center: center, scheduled: scheduled, check: script.call)
    let recorder = Recorder(held!.values())
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    for _ in 0..<4 { center.post(name: name, object: nil) }
    // Each delivered post schedules two later checks, so ten means all five have arrived.
    _ = await wait("the posts to arrive") { scheduled.delays.withLock { $0.count >= 10 } }
    scheduled.runAll()
    gate.open()
    await recorder.waitForValues(3)
    held = nil
    #expect(await recorder.waitForEnd())
    #expect(recorder.all == [false, true, false])
    #expect(script.callCount == 2)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func everySubscriberGetsTheCurrentValueThenEachChange() async {
    let script = ScriptedCheck([true])
    let center = NotificationCenter()
    let grant = grant(center: center, check: script.call)
    let early = Recorder(grant.values())
    await early.waitForValues(1)
    center.post(name: name, object: nil)
    await early.waitForValues(2)
    let late = Recorder(grant.values())
    await late.waitForValues(1)
    #expect(early.all == [false, true])
    #expect(late.all == [true])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamsEndWhenTheGrantObjectGoes() async {
    var held: AccessibilityGrant27? = grant(initial: true, check: { nil })
    let recorder = Recorder(held!.values())
    held = nil
    #expect(await recorder.waitForEnd())
    #expect(recorder.all == [true])
}
