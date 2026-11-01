import Foundation
import os
import Testing
@testable import HulderPlatform27

/// What the fake framework does, and what it saw. Tests find theirs through a token passed in
/// the allowed bundle identifiers, so tests can run in parallel.
final class FakeBehavior: Sendable {
    enum Mode: Sendable { case hold, succeed, fail, succeedTwice }

    private struct State {
        var mode: Mode
        var completions: [@Sendable (NSError?) -> Void] = []
        var activateCalls = 0
        var invalidateCalls = 0
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [String: FakeBehavior]())

    let token = UUID().uuidString
    let activated: AsyncStream<Void>
    private let activatedContinuation: AsyncStream<Void>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(mode: Mode) {
        state = OSAllocatedUnfairLock(initialState: State(mode: mode))
        (activated, activatedContinuation) = AsyncStream.makeStream()
        Self.registry.withLock { $0[token] = self }
    }

    deinit { Self.registry.withLock { _ = $0.removeValue(forKey: token) } }

    static func behavior(for bundleIDs: [String]) -> FakeBehavior? {
        registry.withLock { registry in
            for id in bundleIDs { if let behavior = registry[id] { return behavior } }
            return nil
        }
    }

    var activateCalls: Int { state.withLock { $0.activateCalls } }
    var invalidateCalls: Int { state.withLock { $0.invalidateCalls } }

    func didActivate(completion: @escaping @Sendable (NSError?) -> Void) {
        let mode = state.withLock { state -> Mode in
            state.activateCalls += 1
            state.completions.append(completion)
            return state.mode
        }
        switch mode {
        case .hold: break
        case .succeed: completion(nil)
        case .succeedTwice:
            completion(nil)
            completion(nil)
        case .fail: completion(NSError(domain: "FakeFramework", code: 7))
        }
        activatedContinuation.yield()
    }

    func didInvalidate() { state.withLock { $0.invalidateCalls += 1 } }

    /// Answers every held activation.
    func complete(with error: NSError?) {
        let held = state.withLock { state -> [@Sendable (NSError?) -> Void] in
            defer { state.completions = [] }
            return state.completions
        }
        for completion in held { completion(error) }
    }
}

final class FakeConfiguration: NSObject {
    let behavior: FakeBehavior?

    @objc(initWithAllowedSystemItems:allowedBundleIdentifiers:)
    init(allowedSystemItems: NSArray, allowedBundleIdentifiers: NSArray) {
        behavior = FakeBehavior.behavior(for: allowedBundleIdentifiers as? [String] ?? [])
        super.init()
    }
}

final class FakeAssertion: NSObject {
    private var behavior: FakeBehavior?

    @objc(activateWithConfiguration:completionHandler:)
    func activate(configuration: AnyObject, completionHandler: @escaping @Sendable (NSError?) -> Void) {
        behavior = (configuration as? FakeConfiguration)?.behavior
        behavior?.didActivate(completion: completionHandler)
    }

    @objc func invalidate() { behavior?.didInvalidate() }
}

extension MenuBarAssertion {
    /// Returns once everything queued so far on the framework queue has run.
    static func drainQueue() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

private let fakeResolver = ClassResolver(
    loadFramework: { _ in true },
    lookup: { name in
        switch name {
        case MenuBarClientCore.assertionClassName: FakeAssertion.self
        case MenuBarClientCore.configurationClassName: FakeConfiguration.self
        default: nil
        }
    }
)

private func makeAssertion(_ behavior: FakeBehavior) throws -> MenuBarAssertion {
    let core = MenuBarClientCore(resolver: fakeResolver)
    #expect(core.availability == .available)
    return try MenuBarAssertion(core: core, bundleIDs: [behavior.token], systemItems: [0])
}

@Test func activateSucceedsWhenTheCompletionHasNoError() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let assertion = try makeAssertion(behavior)
    try await assertion.activate()
    #expect(behavior.activateCalls == 1)
}

@Test func invalidateIsIdempotent() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let assertion = try makeAssertion(behavior)
    try await assertion.activate()
    assertion.invalidate()
    assertion.invalidate()
    // The framework call is queued behind activate on one serial queue; wait for it to run.
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 1)
}

@Test func invalidateWithoutActivationNeverCallsTheFramework() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let assertion = try makeAssertion(behavior)
    assertion.invalidate()
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 0)
}

@Test func secondActivateThrowsAlreadyUsed() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let assertion = try makeAssertion(behavior)
    try await assertion.activate()
    await #expect(throws: MenuBarAssertionError.alreadyUsed) { try await assertion.activate() }
    #expect(behavior.activateCalls == 1)
}

@Test func errorCompletionThrowsActivationFailed() async throws {
    let behavior = FakeBehavior(mode: .fail)
    let assertion = try makeAssertion(behavior)
    await #expect(throws: MenuBarAssertionError.activationFailed) { try await assertion.activate() }
}

@Test(.timeLimit(.minutes(1)))
func cancellingAnActivationThatNeverCompletesThrowsCancelled() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let assertion = try makeAssertion(behavior)
    let task = Task { try await assertion.activate() }
    for await _ in behavior.activated { break }
    task.cancel()
    await #expect(throws: MenuBarAssertionError.cancelled) { try await task.value }
}

@Test(.timeLimit(.minutes(1)))
func aCompletionAfterCancellationDoesNotTrap() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let assertion = try makeAssertion(behavior)
    let task = Task { try await assertion.activate() }
    for await _ in behavior.activated { break }
    task.cancel()
    _ = await task.result
    behavior.complete(with: nil)
    // The framework did activate it, so invalidate still releases it.
    assertion.invalidate()
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 1)
}

@Test func aDoubledCompletionDoesNotTrap() async throws {
    let behavior = FakeBehavior(mode: .succeedTwice)
    let assertion = try makeAssertion(behavior)
    try await assertion.activate()
    #expect(behavior.activateCalls == 1)
}

@Test(.timeLimit(.minutes(1)))
func aSuccessAfterInvalidateIsNotReportedAsSuccess() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let assertion = try makeAssertion(behavior)
    let task = Task { try await assertion.activate() }
    for await _ in behavior.activated { break }
    assertion.invalidate()
    behavior.complete(with: nil)
    await #expect(throws: MenuBarAssertionError.invalidated) { try await task.value }
}

@Test(.timeLimit(.minutes(1)))
func invalidateEndsAnActivationTheFrameworkNeverCompletes() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let assertion = try makeAssertion(behavior)
    let task = Task { try await assertion.activate() }
    for await _ in behavior.activated { break }
    assertion.invalidate()
    await #expect(throws: MenuBarAssertionError.invalidated) { try await task.value }
    behavior.complete(with: nil)
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 1)
}
