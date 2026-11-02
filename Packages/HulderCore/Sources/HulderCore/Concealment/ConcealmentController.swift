import Foundation

public struct ConcealmentToken: Hashable, Sendable {
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

public enum ConcealmentFailure: Error, Equatable, Sendable {
    case unavailable(String)
    case rejected
    case timedOut
}

public enum ApplyOutcome: Equatable, Sendable {
    case applied
    case unchanged
    case superseded
    case failed(ConcealmentFailure)
}

public protocol ConcealmentBackend: Sendable {
    /// Creates the assertion object for the list. It only creates objects and enqueues work, so it must not block.
    /// The controller's timeout covers this call and `activate` together. A token that arrives after the
    /// timeout is invalidated without being activated.
    func prepare(_ list: AllowList) async throws -> ConcealmentToken

    /// Returns when the system confirms the assertion, or throws when it fails. The controller never cancels
    /// it. After a timeout it invalidates the token, which ends a pending activation with an error, and the
    /// backend invalidates the assertion again if the system confirms it later.
    func activate(_ token: ConcealmentToken) async throws

    /// Idempotent. It only enqueues work, so it must not block. It must stay effective if the activation
    /// completes after the call.
    func invalidate(_ token: ConcealmentToken) async
}

public actor ConcealmentController {
    private struct Request {
        let concealment: Concealment
        let complete: @Sendable (ApplyOutcome) -> Void
    }

    private struct Attempt {
        let race: ActivationRace
    }

    private let backend: any ConcealmentBackend
    private let clock: any Clock<Duration>
    private let timeout: Duration

    public private(set) var current: Concealment = .none
    private var live: ConcealmentToken?
    private var attempt: Attempt?
    private var queue: [Request] = []
    private var worker: Task<Void, Never>?
    private var closed = false

    static let unavailableText = "Concealment is unavailable."

    public init(backend: any ConcealmentBackend, clock: any Clock<Duration>, timeout: Duration = .seconds(3)) {
        self.backend = backend
        self.clock = clock
        self.timeout = timeout
    }

    var queuedRequests: Int { queue.count }

    var queuedConcealments: [Concealment] { queue.map(\.concealment) }

    public func apply(_ concealment: Concealment) async -> ApplyOutcome {
        await withCheckedContinuation { continuation in
            submit(concealment) { continuation.resume(returning: $0) }
        }
    }

    /// Queues the request before it returns, so calls made one after another from one task are queued in
    /// that order. `complete` is called once, with the request's outcome.
    public func submit(_ concealment: Concealment, complete: @escaping @Sendable (ApplyOutcome) -> Void) {
        if closed {
            complete(.superseded)
            return
        }
        queue.append(Request(concealment: concealment, complete: complete))
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    public func releaseAll() async {
        guard !closed else { return }
        closed = true
        current = .none
        let pending = attempt
        let ended = live
        live = nil
        let waiting = queue
        queue = []
        for request in waiting { request.complete(.superseded) }
        await pending?.race.resolve(.released)
        // A token still being prepared is invalidated by the attempt when it comes back.
        let doomed = await [ended, pending?.race.token].compactMap { $0 }
        for token in doomed { await backend.invalidate(token) }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            let outcome = await process(request.concealment)
            request.complete(outcome)
        }
        worker = nil
    }

    private func process(_ concealment: Concealment) async -> ApplyOutcome {
        if closed || !queue.isEmpty { return .superseded }
        if concealment == current { return .unchanged }
        switch concealment {
        case .none:
            let old = live
            live = nil
            current = .none
            if let old { await backend.invalidate(old) }
            return .applied
        case .allow(let list):
            return await activate(list)
        }
    }

    /// The timeout covers `prepare` and `activate` together: a call that never returns must not hold the
    /// queue, whichever of the two it is.
    private func activate(_ list: AllowList) async -> ApplyOutcome {
        let race = ActivationRace()
        attempt = Attempt(race: race)
        let sleep = clock.sleeper(after: timeout)
        let timer = Task.detached {
            try? await sleep()
            await race.resolve(.timedOut)
        }
        Self.startAttempt(backend: backend, list: list, race: race)

        let result = await race.wait()
        timer.cancel()
        attempt = nil

        switch result {
        case .released:
            return .superseded
        case .prepareFailed(let failure):
            return .failed(failure)
        case .timedOut:
            if let token = await race.token { await backend.invalidate(token) }
            return .failed(.timedOut)
        case .failed:
            if let token = await race.token { await backend.invalidate(token) }
            return .failed(.rejected)
        case .activated(let token):
            if closed || !queue.isEmpty {
                await backend.invalidate(token)
                return .superseded
            }
            let old = live
            live = token
            current = .allow(list)
            if let old { await backend.invalidate(old) }
            return .applied
        }
    }

    // Runs unstructured and is never cancelled: a timeout must not wait on it, and it must still
    // see a late result, so that it can invalidate the token if the race was already decided. A token
    // that `prepare` returns after the race is decided is invalidated without being activated.
    private static func startAttempt(backend: any ConcealmentBackend, list: AllowList, race: ActivationRace) {
        Task.detached {
            let token: ConcealmentToken
            do {
                token = try await backend.prepare(list)
            } catch let failure as ConcealmentFailure {
                await race.resolve(.prepareFailed(failure))
                return
            } catch {
                await race.resolve(.prepareFailed(.unavailable(unavailableText)))
                return
            }
            guard await race.prepared(token) else {
                await backend.invalidate(token)
                return
            }
            let result: ActivationRace.Result
            do {
                try await backend.activate(token)
                result = .activated(token)
            } catch {
                result = .failed
            }
            if await !race.resolve(result) {
                await backend.invalidate(token)
            }
        }
    }
}

private actor ActivationRace {
    enum Result { case activated(ConcealmentToken), failed, prepareFailed(ConcealmentFailure), timedOut, released }

    private var result: Result?
    private var waiter: CheckedContinuation<Result, Never>?
    private(set) var token: ConcealmentToken?

    /// Records the prepared token. False when the race is already decided, so the token is not to be used.
    func prepared(_ token: ConcealmentToken) -> Bool {
        guard result == nil else { return false }
        self.token = token
        return true
    }

    @discardableResult
    func resolve(_ new: Result) -> Bool {
        guard result == nil else { return false }
        result = new
        waiter?.resume(returning: new)
        waiter = nil
        return true
    }

    func wait() async -> Result {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
