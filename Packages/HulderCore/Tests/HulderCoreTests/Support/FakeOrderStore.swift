import Foundation
import Synchronization
@testable import HulderCore

actor FakeOrderStore: OrderStore {
    enum Call: Equatable, Sendable {
        case read
        case backup
        case write(OrderChange)
        case latestBackupOrder
        case restore
        case drawn
    }

    /// What a successful `write` does to `changes()`. The persisted order always becomes the target.
    enum WriteEffect: Sendable {
        /// `changes()` emits the target.
        case followTarget
        /// Nothing is emitted.
        case silent
    }

    /// What `restoreLatestBackup` does to `changes()`.
    enum RestoreEffect: Sendable {
        /// `changes()` emits the backup order, synchronously inside the call.
        case followBackup
        /// A native drag lands first: `changes()` emits only the drag's order.
        case drag([ItemKey])
    }

    struct Script: Sendable {
        var readError: OrderStoreError?
        var staleWrites = 0
        /// The first write lands this order, as a native drag would, and then throws `stale`.
        var dragBeforeStale: [ItemKey]?
        var writeError: OrderStoreError?
        var writeEffect = WriteEffect.followTarget
        var backupOrder: BarOrder?
        var restoreEffect = RestoreEffect.followBackup
    }

    private struct Live {
        var order: BarOrder
        var changeSubscribers: [AsyncStream<BarOrder>.Continuation] = []

        mutating func emitChanges(_ order: BarOrder) {
            self.order = order
            for subscriber in changeSubscribers { subscriber.yield(order) }
        }
    }

    private let live: Mutex<Live>
    private var script: Script
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var holdsNextWrite = false

    var drawn: Set<ItemKey>
    private(set) var log: [Call] = []
    private(set) var writeAttempts = 0

    init(order: BarOrder, drawn: Set<ItemKey>, script: Script = Script()) {
        live = Mutex(Live(order: order))
        self.drawn = drawn
        self.script = script
    }

    var writeIsHeld: Bool { heldWrite != nil }
    var order: BarOrder { live.withLock { $0.order } }

    func holdNextWrite() {
        holdsNextWrite = true
    }

    func releaseWrite() {
        heldWrite?.resume()
        heldWrite = nil
    }

    /// Injects a change as if MenuBarAgent or a native drag had made it.
    func emitChanges(_ order: BarOrder) {
        live.withLock { $0.emitChanges(order) }
    }

    func read() async throws -> BarOrder {
        log.append(.read)
        if let error = script.readError { throw error }
        return live.withLock { $0.order }
    }

    func backup() async throws {
        log.append(.backup)
    }

    func write(_ change: OrderChange, expecting base: BarOrder) async throws {
        log.append(.write(change))
        writeAttempts += 1
        if holdsNextWrite {
            holdsNextWrite = false
            await withCheckedContinuation { heldWrite = $0 }
        }
        if let error = script.writeError { throw error }
        if let drag = script.dragBeforeStale {
            script.dragBeforeStale = nil
            live.withLock { $0.emitChanges(BarOrder(keys: drag, pinned: base.pinned)) }
            throw OrderStoreError.stale
        }
        if script.staleWrites > 0 {
            script.staleWrites -= 1
            throw OrderStoreError.stale
        }
        if live.withLock({ $0.order }) != base { throw OrderStoreError.stale }

        let persisted = BarOrder(keys: change.target, pinned: base.pinned)
        let effect = script.writeEffect
        live.withLock { live in
            switch effect {
            case .followTarget: live.emitChanges(persisted)
            case .silent: live.order = persisted
            }
        }
    }

    func latestBackupOrder() async throws -> BarOrder {
        log.append(.latestBackupOrder)
        guard let backup = script.backupOrder else { throw OrderStoreError.io }
        return backup
    }

    func restoreLatestBackup() async throws {
        log.append(.restore)
        guard let backup = script.backupOrder else { throw OrderStoreError.io }
        let effect = script.restoreEffect
        live.withLock { live in
            switch effect {
            case .followBackup: live.emitChanges(backup)
            case .drag(let keys): live.emitChanges(BarOrder(keys: keys, pinned: backup.pinned))
            }
        }
    }

    nonisolated func changes() -> AsyncStream<BarOrder> {
        let (stream, continuation) = AsyncStream.makeStream(of: BarOrder.self)
        live.withLock { live in
            continuation.yield(live.order)
            live.changeSubscribers.append(continuation)
        }
        return stream
    }

    func drawnKeys() async -> Set<ItemKey> {
        log.append(.drawn)
        return drawn
    }
}
