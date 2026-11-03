import Foundation
import os

/// Fixed failure categories; system error descriptions are logged privately and never carried.
enum MenuBarAssertionError: Error, Equatable, Sendable {
    case unavailable
    case alreadyUsed
    case activationFailed
    /// The waiting task was cancelled. The framework may still activate the assertion later, so
    /// the caller must `invalidate()` it.
    case cancelled
    /// The assertion was invalidated while activating.
    case invalidated
}

/// One live "assessment mode" assertion: while active, the menu bar drops every application
/// whose bundle identifier is not in `bundleIDs`. It has no timeout; the caller owns that by
/// cancelling the task that awaits `activate()`.
final class MenuBarAssertion: @unchecked Sendable { // reason: reached from the completion queue; all mutable state is behind `state`
    private enum Phase { case idle, activating, active, invalidated }

    private struct State {
        var phase = Phase.idle
        var cancelled = false
        /// Present from the moment activation is dispatched until it is resumed, exactly once.
        var continuation: CheckedContinuation<Void, Error>?
    }

    static let queue = DispatchQueue(label: "com.michaelrigart.hulder.concealment", qos: .userInitiated)

    private let core: MenuBarClientCore
    private let assertion: NSObject
    private let configuration: NSObject
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(core: MenuBarClientCore, bundleIDs: [String], systemItems: [Int]) throws {
        guard core.availability == .available,
              let configuration = core.makeConfiguration(systemItems: systemItems, bundleIDs: bundleIDs),
              let assertion = core.makeAssertion() else {
            throw MenuBarAssertionError.unavailable
        }
        self.core = core
        self.configuration = configuration
        self.assertion = assertion
    }

    /// Allocates and initialises the framework objects on `queue`, off the caller's executor, and returns once
    /// they exist. The caller never blocks on the framework, whatever it does in `-init`.
    static func make(core: MenuBarClientCore, bundleIDs: [String], systemItems: [Int]) async throws -> MenuBarAssertion {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try MenuBarAssertion(core: core, bundleIDs: bundleIDs, systemItems: systemItems) })
            }
        }
    }

    func activate() async throws {
        let started = state.withLock { state -> Bool in
            guard state.phase == .idle else { return false }
            state.phase = .activating
            return true
        }
        guard started else { throw MenuBarAssertionError.alreadyUsed }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = state.withLock { state -> MenuBarAssertionError? in
                    if state.cancelled { return .cancelled }
                    if state.phase == .invalidated { return .invalidated }
                    state.continuation = continuation
                    return nil
                }
                if let early {
                    continuation.resume(throwing: early)
                    return
                }
                Self.queue.async {
                    // An `invalidate()` that slipped in before this block ran must not be followed by an activation.
                    guard self.state.withLock({ $0.phase != .invalidated }) else { return }
                    self.core.activate(self.assertion, configuration: self.configuration) { self.complete($0) }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Idempotent. Calls the framework's `invalidate` once, in order after `activate`, and ends a pending
    /// `activate()` with `.invalidated`, so a framework that never completes does not leak the waiter. An
    /// activation that completes afterwards is invalidated once more.
    func invalidate() {
        let (wasUsed, pending) = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
            let wasUsed = state.phase == .activating || state.phase == .active
            state.phase = .invalidated
            let pending = state.continuation
            state.continuation = nil
            return (wasUsed, pending)
        }
        pending?.resume(throwing: MenuBarAssertionError.invalidated)
        guard wasUsed else { return }
        Self.queue.async { self.core.invalidate(self.assertion) }
    }

    /// The framework's completion handler: may run on any queue, late, or more than once.
    private func complete(_ error: NSError?) {
        if let error {
            PlatformLog.concealment.notice("assertion activation failed: \(error.localizedDescription, privacy: .private)")
        }
        let (continuation, outcome) = state.withLock { state -> (CheckedContinuation<Void, Error>?, MenuBarAssertionError?) in
            let continuation = state.continuation
            state.continuation = nil
            if state.phase == .invalidated { return (continuation, .invalidated) }
            if error != nil {
                if state.phase == .activating { state.phase = .idle }
                return (continuation, .activationFailed)
            }
            if state.phase == .activating { state.phase = .active }
            return (continuation, nil)
        }
        // The framework activated an assertion that was invalidated meanwhile, so its first invalidate may
        // have found nothing to end. Invalidate again, in order after the activation.
        if outcome == .invalidated, error == nil {
            Self.queue.async { self.core.invalidate(self.assertion) }
        }
        guard let continuation else { return }
        if let outcome {
            continuation.resume(throwing: outcome)
        } else {
            continuation.resume()
        }
    }

    private func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.cancelled = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: MenuBarAssertionError.cancelled)
    }
}
