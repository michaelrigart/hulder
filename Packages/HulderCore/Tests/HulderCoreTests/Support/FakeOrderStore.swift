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
    }

    /// What a successful `write` does to the streams. The persisted order always becomes the target.
    enum WriteEffect: Sendable {
        /// `changes()` and `displayed()` both emit the target.
        case followTarget
        /// `changes()` emits the target and `displayed()` emits the given order.
        case persist(displayed: [ItemKey])
        /// Nothing is emitted.
        case silent
        /// `changes()` emits the target; `displayed()` emits nothing.
        case persistChangesOnly
    }

    /// What `restoreLatestBackup` does to the streams.
    enum RestoreEffect: Sendable {
        /// Both streams emit the backup order, synchronously inside the call.
        case followBackup
        /// A native drag lands first: both streams emit only the drag's order.
        case drag([ItemKey])
    }

    struct Script: Sendable {
        var readError: OrderStoreError?
        var staleWrites = 0
        var writeError: OrderStoreError?
        var writeEffect = WriteEffect.followTarget
        var backupOrder: BarOrder?
        var restoreEffect = RestoreEffect.followBackup
    }

    private struct Live {
        var order: BarOrder
        var displayed: [ItemKey]
        var changeSubscribers: [AsyncStream<BarOrder>.Continuation] = []
        var displayedSubscribers: [AsyncStream<[ItemKey]>.Continuation] = []

        mutating func emitChanges(_ order: BarOrder) {
            self.order = order
            for subscriber in changeSubscribers { subscriber.yield(order) }
        }

        mutating func emitDisplayed(_ keys: [ItemKey]) {
            displayed = keys
            for subscriber in displayedSubscribers { subscriber.yield(keys) }
        }
    }

    private let live: Mutex<Live>
    private var script: Script
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var holdsNextWrite = false

    private(set) var log: [Call] = []
    private(set) var writeAttempts = 0

    init(order: BarOrder, displayed: [ItemKey], script: Script = Script()) {
        live = Mutex(Live(order: order, displayed: displayed))
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
    func emitDisplayed(_ keys: [ItemKey]) {
        live.withLock { $0.emitDisplayed(keys) }
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
        if script.staleWrites > 0 {
            script.staleWrites -= 1
            throw OrderStoreError.stale
        }
        if live.withLock({ $0.order }) != base { throw OrderStoreError.stale }

        let persisted = BarOrder(keys: change.target, pinned: base.pinned)
        let effect = script.writeEffect
        live.withLock { live in
            switch effect {
            case .followTarget:
                live.emitChanges(persisted)
                live.emitDisplayed(change.target)
            case .persist(let displayed):
                live.emitChanges(persisted)
                live.emitDisplayed(displayed)
            case .silent:
                live.order = persisted
            case .persistChangesOnly:
                live.emitChanges(persisted)
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
            case .followBackup:
                live.emitChanges(backup)
                live.emitDisplayed(backup.keys)
            case .drag(let keys):
                live.emitChanges(BarOrder(keys: keys, pinned: backup.pinned))
                live.emitDisplayed(keys)
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

    nonisolated func displayed() -> AsyncStream<[ItemKey]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ItemKey].self)
        live.withLock { live in
            continuation.yield(live.displayed)
            live.displayedSubscribers.append(continuation)
        }
        return stream
    }
}
