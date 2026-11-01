import Foundation

public enum OrderStoreError: Error, Equatable, Sendable {
    /// The order on disk is not the one the write expected.
    case stale
    /// The text is fixed by Hulder and safe to show.
    case unsupportedFormat(String)
    case noAccess
    case io
    /// The target can't be written without changing items that didn't move.
    case unrepresentable
}

public enum OrderOutcome: Equatable, Sendable {
    case applied
    /// Persisted, but none of the moved items is drawn, so the bar can't show the move.
    case saved
    case unchanged
    case unconfirmed
    case gaveUp
    case unavailable(String)
    case failed
}

public protocol OrderStore: Sendable {
    func read() async throws -> BarOrder
    func backup() async throws
    /// Re-reads the order immediately before writing and throws `OrderStoreError.stale` when that isn't
    /// `base`. A MenuBarAgent update landing between that re-read and the write is still lost: a window
    /// of microseconds that the spec accepts.
    func write(_ change: OrderChange, expecting base: BarOrder) async throws
    func latestBackupOrder() async throws -> BarOrder
    func restoreLatestBackup() async throws

    /// The persisted order: the current value first, then again whenever the file changes.
    func changes() -> AsyncStream<BarOrder>

    /// The keys of the items MenuBarAgent draws now, including those in macOS's overflow, read once per
    /// call. Empty when they can't be read.
    func drawnKeys() async -> Set<ItemKey>
}

public actor OrderController {
    private let store: any OrderStore
    private let clock: any Clock<Duration>
    private let confirmTimeout: Duration

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    static let noAccessText = "No access to the order file"

    public init(store: any OrderStore, clock: any Clock<Duration>, confirmTimeout: Duration = .seconds(3)) {
        self.store = store
        self.clock = clock
        self.confirmTimeout = confirmTimeout
    }

    var waitingOperations: Int { waiting.count }

    public func perform(_ plan: @Sendable (BarOrder) -> OrderChange?) async -> OrderOutcome {
        await acquire()
        defer { release() }
        do {
            return try await write(plan)
        } catch {
            return Self.outcome(for: error)
        }
    }

    public func restore() async -> OrderOutcome {
        await acquire()
        defer { release() }
        do {
            return try await restoreBackup()
        } catch {
            return Self.outcome(for: error)
        }
    }

    // Operations run one at a time, in the order they arrived. The lock is handed straight to the
    // next waiter, so a newcomer can't overtake a queued operation.
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func write(_ plan: @Sendable (BarOrder) -> OrderChange?) async throws -> OrderOutcome {
        var base = try await store.read()
        guard var change = plan(base) else { return .unchanged }
        var retried = false
        while true {
            // Subscribed before the backup and the write, so that nothing they emit is missed.
            let watch = ConfirmationWatch(store: store, target: change.target)
            do {
                try await store.backup()
                try await store.write(change, expecting: base)
            } catch OrderStoreError.stale {
                watch.cancel()
                if retried { return .gaveUp }
                retried = true
                base = try await store.read()
                guard let next = plan(base) else { return .unchanged }
                change = next
                continue
            } catch {
                watch.cancel()
                throw error
            }
            return await confirm(watch, moved: change.moved)
        }
    }

    private func restoreBackup() async throws -> OrderOutcome {
        let current = try await store.read()
        let backup = try await store.latestBackupOrder()
        if backup == current { return .unchanged }
        let moved = backup.keys.enumerated().compactMap { index, key in
            current.keys.firstIndex(of: key) == index ? nil : key
        }
        let watch = ConfirmationWatch(store: store, target: backup.keys)
        do {
            try await store.restoreLatestBackup()
        } catch {
            watch.cancel()
            throw error
        }
        return await confirm(watch, moved: moved)
    }

    // Ends at the timeout even if the stream never emits again, and leaves nothing running.
    private func confirm(_ watch: ConfirmationWatch, moved: [ItemKey]) async -> OrderOutcome {
        let sleep = clock.sleeper(after: confirmTimeout)
        let confirmation = watch.confirmation
        let timer = Task.detached {
            try? await sleep()
            await confirmation.timeOut()
        }
        let saved = await confirmation.isSaved()
        timer.cancel()
        watch.cancel()
        guard saved else { return .unconfirmed }
        let drawn = await store.drawnKeys()
        return moved.contains(where: drawn.contains) ? .applied : .saved
    }

    private static func outcome(for error: any Error) -> OrderOutcome {
        switch error as? OrderStoreError {
        case .unsupportedFormat(let reason): .unavailable(reason)
        case .noAccess: .unavailable(noAccessText)
        case .stale, .io, .unrepresentable, nil: .failed
        }
    }
}

/// The subscription of one operation to the persisted order, feeding one `Confirmation`.
private struct ConfirmationWatch: Sendable {
    let confirmation: Confirmation
    private let reader: Task<Void, Never>

    init(store: any OrderStore, target: [ItemKey]) {
        let confirmation = Confirmation(target: target)
        let changes = store.changes()
        self.confirmation = confirmation
        // The first element is the state from before the operation and never confirms the move.
        reader = Task.detached {
            for await order in changes.dropFirst() { await confirmation.observe(order) }
        }
    }

    func cancel() {
        reader.cancel()
    }
}

/// Waits for the persisted order to match the target, or for the timeout.
private actor Confirmation {
    private let target: [ItemKey]
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    init(target: [ItemKey]) {
        self.target = target
    }

    func observe(_ order: BarOrder) {
        if order.keys == target { resolve(true) }
    }

    func timeOut() {
        resolve(false)
    }

    func isSaved() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func resolve(_ saved: Bool) {
        guard result == nil else { return }
        result = saved
        waiter?.resume(returning: saved)
        waiter = nil
    }
}
