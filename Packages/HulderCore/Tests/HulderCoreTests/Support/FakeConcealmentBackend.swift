import Foundation
import Synchronization
@testable import HulderCore

actor FakeConcealmentBackend: ConcealmentBackend {
    enum Behaviour: Sendable {
        case succeed, fail
        /// Ignores cancellation; resumes only through `complete` or `fail`.
        case hang
        /// Records that it was cancelled, but still waits for `complete` or `fail`.
        case hangObservingCancellation
    }

    enum Call: Equatable, Sendable {
        case prepare(UInt64, Set<AppID>)
        case activate(UInt64)
        case invalidate(UInt64)
    }

    struct Failure: Error {}

    private var script: [UInt64: Behaviour]
    private var nextToken: UInt64 = 0
    private var waiting: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var resolved: [UInt64: Result<Void, any Error>] = [:]
    private var prepareError: (any Error)?
    private var holdsPrepare = false
    private var heldPrepare: CheckedContinuation<Void, Never>?
    private let cancelled = Mutex<Set<UInt64>>([])

    private(set) var log: [Call] = []
    private(set) var activeTokens: Set<UInt64> = []

    init(script: [UInt64: Behaviour] = [:]) {
        self.script = script
    }

    nonisolated var cancelledTokens: Set<UInt64> { cancelled.withLock { $0 } }

    var prepareIsHeld: Bool { heldPrepare != nil }

    func setPrepareError(_ error: (any Error)?) {
        prepareError = error
    }

    func holdNextPrepare() {
        holdsPrepare = true
    }

    func releasePrepare() {
        heldPrepare?.resume()
        heldPrepare = nil
    }

    func prepare(_ list: AllowList) async throws -> ConcealmentToken {
        if let prepareError { throw prepareError }
        if holdsPrepare {
            holdsPrepare = false
            await withCheckedContinuation { heldPrepare = $0 }
        }
        nextToken += 1
        log.append(.prepare(nextToken, list.apps))
        return ConcealmentToken(id: nextToken)
    }

    func activate(_ token: ConcealmentToken) async throws {
        log.append(.activate(token.id))
        switch script[token.id] ?? .succeed {
        case .succeed:
            break
        case .fail:
            throw Failure()
        case .hang:
            try await suspend(token.id)
        case .hangObservingCancellation:
            try await withTaskCancellationHandler {
                try await suspend(token.id)
            } onCancel: {
                cancelled.withLock { _ = $0.insert(token.id) }
            }
        }
        activeTokens.insert(token.id)
    }

    func invalidate(_ token: ConcealmentToken) async {
        log.append(.invalidate(token.id))
        activeTokens.remove(token.id)
    }

    func complete(_ id: UInt64) {
        finish(id, with: .success(()))
    }

    func fail(_ id: UInt64) {
        finish(id, with: .failure(Failure()))
    }

    private func suspend(_ id: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if let result = resolved[id] {
                continuation.resume(with: result)
            } else {
                waiting[id] = continuation
            }
        }
    }

    private func finish(_ id: UInt64, with result: Result<Void, any Error>) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else {
            resolved[id] = result
        }
    }
}
