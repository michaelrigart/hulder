import Foundation
@testable import HulderCore

actor FakeConcealmentBackend: ConcealmentBackend {
    enum Behaviour: Sendable {
        case succeed, fail, hang
    }

    enum Call: Equatable, Sendable {
        case prepare(UInt64, Set<AppID>)
        case activate(UInt64)
        case invalidate(UInt64)

        var summary: String {
            switch self {
            case .prepare(let id, _): "prepare(\(id))"
            case .activate(let id): "activate(\(id))"
            case .invalidate(let id): "invalidate(\(id))"
            }
        }
    }

    struct Failure: Error {}

    private var script: [UInt64: Behaviour]
    private var nextToken: UInt64 = 0
    private var waiting: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var resolved: [UInt64: Result<Void, any Error>] = [:]

    private var prepareError: (any Error)?
    private(set) var log: [Call] = []
    private(set) var activeTokens: Set<UInt64> = []

    init(script: [UInt64: Behaviour] = [:]) {
        self.script = script
    }

    var summary: [String] { log.map(\.summary) }

    func count(of entry: String) -> Int {
        summary.filter { $0 == entry }.count
    }

    func setFailsPrepare(_ value: Bool) {
        prepareError = value ? Failure() : nil
    }

    func setPrepareError(_ error: (any Error)?) {
        prepareError = error
    }

    func prepare(_ list: AllowList) async throws -> ConcealmentToken {
        if let prepareError { throw prepareError }
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
            // Deliberately ignores cancellation: it resumes only through complete or fail.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if let result = resolved[token.id] {
                    continuation.resume(with: result)
                } else {
                    waiting[token.id] = continuation
                }
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

    private func finish(_ id: UInt64, with result: Result<Void, any Error>) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else {
            resolved[id] = result
        }
    }
}
