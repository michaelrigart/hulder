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
    func prepare(_ list: AllowList) async throws -> ConcealmentToken
    func activate(_ token: ConcealmentToken) async throws
    func invalidate(_ token: ConcealmentToken) async
}

public actor ConcealmentController {
    private struct Request {
        let concealment: Concealment
        let continuation: CheckedContinuation<ApplyOutcome, Never>
    }

    private struct Attempt {
        let token: ConcealmentToken
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

    public func apply(_ concealment: Concealment) async -> ApplyOutcome {
        if closed { return .superseded }
        return await withCheckedContinuation { continuation in
            queue.append(Request(concealment: concealment, continuation: continuation))
            if worker == nil {
                worker = Task { await self.drain() }
            }
        }
    }

    public func releaseAll() async {
        guard !closed else { return }
        closed = true
        current = .none
        let doomed = [live, attempt?.token].compactMap { $0 }
        live = nil
        let waiting = queue
        queue = []
        for request in waiting { request.continuation.resume(returning: .superseded) }
        await attempt?.race.resolve(.released)
        for token in doomed { await backend.invalidate(token) }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            let outcome = await process(request.concealment)
            request.continuation.resume(returning: outcome)
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

    private func activate(_ list: AllowList) async -> ApplyOutcome {
        let token: ConcealmentToken
        do {
            token = try await backend.prepare(list)
        } catch let failure as ConcealmentFailure {
            return .failed(failure)
        } catch {
            return .failed(.unavailable(Self.unavailableText))
        }
        if closed {
            await backend.invalidate(token)
            return .superseded
        }

        let race = ActivationRace()
        attempt = Attempt(token: token, race: race)
        let sleep = Self.sleeper(on: self.clock, for: timeout)
        let timer = Task.detached {
            do { try await sleep() } catch { return }
            await race.resolve(.timedOut)
        }
        let activation = Self.startActivation(backend: backend, token: token, race: race)

        let result = await race.wait()
        timer.cancel()
        activation.cancel()
        attempt = nil

        switch result {
        case .released:
            return .superseded
        case .timedOut:
            await backend.invalidate(token)
            return .failed(.timedOut)
        case .failed:
            await backend.invalidate(token)
            return .failed(.rejected)
        case .activated:
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

    // The deadline is fixed here, when the attempt starts, not when the timer task first gets to run.
    private static func sleeper<C: Clock>(
        on clock: C,
        for delay: Duration
    ) -> @Sendable () async throws -> Void where C.Duration == Duration {
        let deadline = clock.now.advanced(by: delay)
        return { try await clock.sleep(until: deadline, tolerance: nil) }
    }

    // Runs unstructured so a timeout never waits on an activation that ignores cancellation.
    // If the race is already decided when it finishes, the token is invalidated here.
    private static func startActivation(
        backend: any ConcealmentBackend,
        token: ConcealmentToken,
        race: ActivationRace
    ) -> Task<Void, Never> {
        Task.detached {
            let result: ActivationRace.Result
            do {
                try await backend.activate(token)
                result = .activated
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
    enum Result { case activated, failed, timedOut, released }

    private var result: Result?
    private var waiter: CheckedContinuation<Result, Never>?

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
