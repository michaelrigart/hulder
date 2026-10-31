import Foundation
import os

/// Fixed failure categories; system error descriptions are logged privately and never carried.
enum MenuBarAssertionError: Error, Equatable, Sendable {
    case unavailable
    case alreadyUsed
    case activationFailed
}

/// One live "assessment mode" assertion: while active, the menu bar drops every application
/// whose bundle identifier is not in `bundleIDs`. It has no timeout; the caller owns that.
final class MenuBarAssertion: @unchecked Sendable { // reason: reached from the completion queue; all mutable state is behind `state`
    private enum Phase { case idle, activating, active, invalidated }

    private static let queue = DispatchQueue(label: "com.michaelrigart.hulder.concealment", qos: .userInitiated)

    private let core: MenuBarClientCore
    private let assertion: NSObject
    private let configuration: NSObject
    private let state = OSAllocatedUnfairLock(initialState: Phase.idle)

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

    func activate() async throws {
        let started = state.withLock { phase -> Bool in
            guard phase == .idle else { return false }
            phase = .activating
            return true
        }
        guard started else { throw MenuBarAssertionError.alreadyUsed }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                self.core.activate(self.assertion, configuration: self.configuration) { error in
                    if let error {
                        PlatformLog.concealment.notice("assertion activation failed: \(error.localizedDescription, privacy: .private)")
                        self.state.withLock { if $0 == .activating { $0 = .idle } }
                        continuation.resume(throwing: MenuBarAssertionError.activationFailed)
                    } else {
                        self.state.withLock { if $0 == .activating { $0 = .active } }
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Idempotent. Calls the framework's `invalidate` once, in order after `activate`.
    func invalidate() {
        let wasUsed = state.withLock { phase -> Bool in
            defer { phase = .invalidated }
            return phase == .activating || phase == .active
        }
        guard wasUsed else { return }
        Self.queue.async { self.core.invalidate(self.assertion) }
    }
}
