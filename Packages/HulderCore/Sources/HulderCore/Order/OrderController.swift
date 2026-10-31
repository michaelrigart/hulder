import Foundation

public enum OrderStoreError: Error, Equatable, Sendable {
    /// The order on disk is not the one the write expected.
    case stale
    /// The text is fixed by Hulder and safe to show.
    case unsupportedFormat(String)
    case noAccess
    case io
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
    /// Throws `OrderStoreError.stale` when the order on disk isn't `base`. A concurrent MenuBarAgent
    /// update is never lost.
    func write(_ change: OrderChange, expecting base: BarOrder) async throws
    func latestBackupOrder() async throws -> BarOrder
    func restoreLatestBackup() async throws

    /// The persisted order: the current value first, then again whenever the file changes.
    func changes() -> AsyncStream<BarOrder>

    /// The left-to-right order of the items MenuBarAgent is drawing: the current value first, then
    /// again on every observed change to the bar. A persisted order isn't applied until this shows it.
    func displayed() -> AsyncStream<[ItemKey]>
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
            let watch = ConfirmationWatch(store: store, target: change.target, moved: change.moved)
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
            return await confirm(watch)
        }
    }

    private func restoreBackup() async throws -> OrderOutcome {
        let current = try await store.read()
        let backup = try await store.latestBackupOrder()
        if backup == current { return .unchanged }
        let moved = backup.keys.enumerated().compactMap { index, key in
            current.keys.firstIndex(of: key) == index ? nil : key
        }
        let watch = ConfirmationWatch(store: store, target: backup.keys, moved: moved)
        do {
            try await store.restoreLatestBackup()
        } catch {
            watch.cancel()
            throw error
        }
        return await confirm(watch)
    }

    // Ends at the timeout even if the streams never emit again, and leaves nothing running.
    private func confirm(_ watch: ConfirmationWatch) async -> OrderOutcome {
        let sleep = clock.sleeper(after: confirmTimeout)
        let confirmation = watch.confirmation
        let timer = Task.detached {
            try? await sleep()
            await confirmation.timeOut()
        }
        let outcome = await confirmation.outcome()
        timer.cancel()
        watch.cancel()
        return outcome
    }

    private static func outcome(for error: any Error) -> OrderOutcome {
        switch error as? OrderStoreError {
        case .unsupportedFormat(let reason): .unavailable(reason)
        case .noAccess: .unavailable(noAccessText)
        case .stale, .io, nil: .failed
        }
    }
}

/// The two subscriptions of one operation, feeding one `Confirmation`.
private struct ConfirmationWatch: Sendable {
    let confirmation: Confirmation
    private let readers: [Task<Void, Never>]

    init(store: any OrderStore, target: [ItemKey], moved: [ItemKey]) {
        let confirmation = Confirmation(target: target, moved: Set(moved))
        let displayed = store.displayed()
        let changes = store.changes()
        self.confirmation = confirmation
        readers = [
            Task.detached {
                var first = true
                for await keys in displayed {
                    // The first element is the state from before the operation: it tells which moved
                    // items are drawn, but never confirms the move.
                    await confirmation.observe(displayed: keys, isInitial: first)
                    first = false
                }
            },
            Task.detached {
                for await order in changes.dropFirst() { await confirmation.observe(changes: order) }
            },
        ]
    }

    func cancel() {
        for reader in readers { reader.cancel() }
    }
}

/// Decides the outcome from the evidence, first result wins.
private actor Confirmation {
    private let target: [ItemKey]
    private let moved: Set<ItemKey>
    private var changesShowTarget = false
    // Until the first `displayed` element arrives, the moved items are assumed drawn.
    private var movedItemsAreDrawn = true
    private var result: OrderOutcome?
    private var waiter: CheckedContinuation<OrderOutcome, Never>?

    init(target: [ItemKey], moved: Set<ItemKey>) {
        self.target = target
        self.moved = moved
    }

    func observe(displayed keys: [ItemKey], isInitial: Bool) {
        movedItemsAreDrawn = keys.contains(where: moved.contains)
        if movedItemsAreDrawn && !isInitial {
            let present = Set(keys)
            if target.filter(present.contains) == keys { resolve(.applied) }
        }
        resolveSaved()
    }

    func observe(changes order: BarOrder) {
        if order.keys == target { changesShowTarget = true }
        resolveSaved()
    }

    func timeOut() {
        resolve(.unconfirmed)
    }

    func outcome() async -> OrderOutcome {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    // The latest `displayed` element decides. Nothing drawn can show the move, so the persisted order is
    // all the evidence there can be, and the bar has no reason to re-emit.
    private func resolveSaved() {
        if changesShowTarget && !movedItemsAreDrawn { resolve(.saved) }
    }

    private func resolve(_ outcome: OrderOutcome) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}
