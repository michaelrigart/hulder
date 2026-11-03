import Synchronization
import Testing
@testable import HulderCore

struct OrderControllerTests {
    typealias Call = FakeOrderStore.Call

    private func ks(_ raws: String...) -> [ItemKey] { raws.map { ItemKey(raw: $0) } }
    private func order(_ raws: [String], pinned: Set<String> = []) -> BarOrder {
        BarOrder(keys: raws.map { ItemKey(raw: $0) }, pinned: Set(pinned.map { ItemKey(raw: $0) }))
    }

    private let abc = ["a", "b", "c"]

    /// `a` moves after `b`.
    private var swapAB: OrderChange {
        OrderChange(target: ks("b", "a", "c"), moved: ks("a"))
    }

    private func make(
        order initial: BarOrder? = nil,
        drawn: Set<ItemKey>? = nil,
        script: FakeOrderStore.Script = .init()
    ) -> (FakeOrderStore, ManualClock, OrderController) {
        let order = initial ?? self.order(abc)
        let store = FakeOrderStore(order: order, drawn: drawn ?? Set(order.keys), script: script)
        let clock = ManualClock()
        return (store, clock, OrderController(store: store, clock: clock))
    }

    /// Waits for the confirmation timer of the `operation`-th write or restore. Each operation starts four
    /// sleeps: one for each of its three store calls, each ended when its call returns, and then the
    /// confirmation's. Exactly one sleeper once four have started per operation can only be the last.
    private func waitForTimer(_ clock: ManualClock, operation: Int = 1) async -> Bool {
        await waitUntil { clock.sleepsRequested == 4 * operation && clock.sleeperCount == 1 }
    }

    /// Waits until the store holds the call and its deadline is the one sleeper.
    private func waitForHeld(
        _ call: FakeOrderStore.Held, _ store: FakeOrderStore, _ clock: ManualClock
    ) async -> Bool {
        await waitUntil { await store.isHeld(call) && clock.sleeperCount == 1 }
    }

    @Test func writeIsPrecededByBackup() async {
        let (store, _, controller) = make()
        let change = swapAB

        #expect(await controller.perform { _ in change } == .applied)

        #expect(await store.log == [.read, .backup, .write(change), .drawn])
    }

    @Test func nilPlanIsUnchangedAndNeverWrites() async {
        let (store, _, controller) = make()

        #expect(await controller.perform { _ in nil } == .unchanged)

        #expect(await store.log == [.read])
    }

    @Test func staleOrderIsPlannedOnceMore() async {
        let (store, _, controller) = make(script: .init(staleWrites: 1))
        let change = swapAB

        #expect(await controller.perform { _ in change } == .applied)

        #expect(await store.log == [.read, .backup, .write(change), .read, .backup, .write(change), .drawn])
    }

    @Test func staleRetryPlansAgain() async {
        let (store, _, controller) = make(script: .init(staleWrites: 1))
        let seen = Seen()

        let outcome = await controller.perform { order in
            seen.record(order)
            return OrderChange(target: ks("b", "a", "c"), moved: ks("a"))
        }

        #expect(outcome == .applied)
        #expect(seen.count == 2)
        #expect(await store.log.count == 7)
    }

    @Test func staleRetryWritesTheReplannedChange() async {
        // A native drag lands before the first write, so the retry must plan against the dragged order.
        let (store, _, controller) = make(script: .init(dragBeforeStale: ks("c", "a", "b")))
        let moveAToEnd: @Sendable (BarOrder) -> OrderChange? = { order in
            let rest = order.keys.filter { $0 != ItemKey(raw: "a") }
            return OrderChange(target: rest + [ItemKey(raw: "a")], moved: [ItemKey(raw: "a")])
        }

        #expect(await controller.perform(moveAToEnd) == .applied)

        let first = OrderChange(target: ks("b", "c", "a"), moved: ks("a"))
        let second = OrderChange(target: ks("c", "b", "a"), moved: ks("a"))
        #expect(await store.log == [.read, .backup, .write(first), .read, .backup, .write(second), .drawn])
        #expect(await store.order.keys == second.target)
    }

    @Test func staleTwiceGivesUp() async {
        let (store, clock, controller) = make(script: .init(staleWrites: 2))
        let change = swapAB

        #expect(await controller.perform { _ in change } == .gaveUp)

        #expect(await store.writeAttempts == 2)
        #expect(await store.log == [.read, .backup, .write(change), .read, .backup, .write(change)])
        #expect(clock.sleeperCount == 0)
    }

    @Test func unsupportedFormatNeverWrites() async {
        let (store, _, controller) = make(script: .init(readError: .unsupportedFormat("format v3")))

        #expect(await controller.perform { _ in self.swapAB } == .unavailable("format v3"))

        #expect(await store.log == [.read])
    }

    @Test func noAccessNeverWrites() async {
        let (store, _, controller) = make(script: .init(readError: .noAccess))

        #expect(await controller.perform { _ in self.swapAB } == .unavailable("No access to the order file"))

        #expect(await store.log == [.read])
    }

    @Test func ioFailureFails() async {
        let (store, _, controller) = make(script: .init(writeError: .io))
        let change = swapAB

        #expect(await controller.perform { _ in change } == .failed)

        #expect(await store.log == [.read, .backup, .write(change)])
    }

    /// The store's own deadline passing is the same as the controller's: the abandoned write can still land.
    @Test func aWriteTheStoreGaveUpOnIsUnconfirmedNotFailed() async {
        let (store, _, controller) = make(script: .init(writeError: .unanswered))
        let change = swapAB

        #expect(await controller.perform { _ in change } == .unconfirmed)

        #expect(await store.log == [.read, .backup, .write(change)])
    }

    @Test func aRestoreTheStoreGaveUpOnIsUnconfirmedNotFailed() async {
        let (_, _, controller) = make(script: .init(backupOrder: order(["b", "a", "c"]), restoreError: .unanswered))

        #expect(await controller.restore() == .unconfirmed)
    }

    @Test func aReadTheStoreGaveUpOnFails() async {
        let (store, _, controller) = make(script: .init(readError: .unanswered))

        #expect(await controller.perform { _ in self.swapAB } == .failed)

        #expect(await store.log == [.read])
    }

    @Test func unrepresentableFails() async {
        let (store, _, controller) = make(script: .init(writeError: .unrepresentable))
        let change = swapAB

        #expect(await controller.perform { _ in change } == .failed)

        #expect(await store.log == [.read, .backup, .write(change)])
    }

    @Test func writesRunOneAtATime() async throws {
        let (store, _, controller) = make()
        let first = swapAB
        let second = OrderChange(target: ks("c", "b", "a"), moved: ks("c"))
        await store.holdNextWrite()

        let one = Task { await controller.perform { _ in first } }
        try #require(await waitUntil { await store.writeIsHeld })
        let two = Task { await controller.perform { _ in second } }
        try #require(await waitUntil { await controller.waitingOperations == 1 })

        #expect(await store.log.filter { $0 == .read }.count == 1)

        await store.releaseWrite()
        #expect(await one.value == .applied)
        #expect(await two.value == .applied)
        #expect(await store.log == [
            .read, .backup, .write(first), .drawn,
            .read, .backup, .write(second), .drawn,
        ])
    }

    @Test func theNextOperationWaitsForConfirmation() async throws {
        let (store, clock, controller) = make(script: .init(writeEffect: .silent))
        let first = swapAB
        let second = OrderChange(target: ks("c", "b", "a"), moved: ks("c"))

        let one = Task { await controller.perform { _ in first } }
        try #require(await waitForTimer(clock))
        let two = Task { await controller.perform { _ in second } }
        try #require(await waitUntil { await controller.waitingOperations == 1 })
        #expect(await store.log == [.read, .backup, .write(first)])

        await clock.advance(by: .seconds(3))
        #expect(await one.value == .unconfirmed)
        try #require(await waitForTimer(clock, operation: 2))
        #expect(await store.log.filter { $0 == .read }.count == 2)

        await clock.advance(by: .seconds(3))
        #expect(await two.value == .unconfirmed)
    }

    @Test func unconfirmedAfterTimeout() async throws {
        let (store, clock, controller) = make(script: .init(writeEffect: .silent))
        let change = swapAB

        let perform = Task { await controller.perform { _ in change } }
        try #require(await waitForTimer(clock))
        await clock.advance(by: .seconds(2))
        await clock.advance(by: .seconds(1))

        #expect(await perform.value == .unconfirmed)
        #expect(await store.log == [.read, .backup, .write(change)])
    }

    @Test func confirmationDoesNotFireEarly() async throws {
        let (store, clock, controller) = make(script: .init(writeEffect: .silent))
        let change = swapAB

        let perform = Task { await controller.perform { _ in change } }
        try #require(await waitForTimer(clock))
        await clock.advance(by: .seconds(2))
        await store.emitChanges(order(["b", "a", "c"]))

        #expect(await perform.value == .applied)
        #expect(clock.sleeperCount == 0)
    }

    @Test func appliedLeavesNoTimerBehind() async {
        let (_, clock, controller) = make()
        let change = swapAB

        #expect(await controller.perform { _ in change } == .applied)

        #expect(clock.sleeperCount == 0)
    }

    @Test func movedDrawnItemIsApplied() async {
        let initial = order(["h1", "D", "v1", "v2"])
        let change = OrderChange(target: ks("h1", "D", "v2", "v1"), moved: ks("v2"))
        let (_, clock, controller) = make(order: initial, drawn: Set(ks("D", "v1", "v2")))

        #expect(await controller.perform { _ in change } == .applied)

        #expect(clock.sleeperCount == 0)
    }

    @Test func hiddenItemMoveIsSaved() async {
        let initial = order(["h1", "h2", "D", "v1"])
        let change = OrderChange(target: ks("h2", "h1", "D", "v1"), moved: ks("h2"))
        let (_, clock, controller) = make(order: initial, drawn: Set(ks("D", "v1")))

        #expect(await controller.perform { _ in change } == .saved)

        #expect(clock.sleeperCount == 0)
    }

    @Test func aDrawnMovedItemAmongHiddenOnesIsApplied() async {
        let initial = order(["h1", "h2", "D", "v1", "v2"])
        let change = OrderChange(target: ks("h2", "h1", "D", "v2", "v1"), moved: ks("h2", "v1"))
        let (_, _, controller) = make(order: initial, drawn: Set(ks("D", "v1")))

        #expect(await controller.perform { _ in change } == .applied)
    }

    @Test func aWriteWhoseSavedOrderIsNotTheTargetIsUnconfirmed() async throws {
        let change = swapAB
        let (store, clock, controller) = make(script: .init(writeEffect: .silent))

        let perform = Task { await controller.perform { _ in change } }
        try #require(await waitForTimer(clock))
        await store.emitChanges(order(["c", "a", "b"]))
        await clock.advance(by: .seconds(3))

        #expect(await perform.value == .unconfirmed)
        #expect(await store.log.contains(.drawn) == false)
    }

    @Test func emptyDrawnIsSaved() async {
        let change = swapAB
        let (_, _, controller) = make(drawn: [])

        #expect(await controller.perform { _ in change } == .saved)
    }

    @Test func preWriteValuesNeverConfirm() async throws {
        let change = swapAB
        let (store, clock, controller) = make(
            order: order(["b", "a", "c"]), script: .init(writeEffect: .silent))

        let perform = Task { await controller.perform { _ in change } }
        try #require(await waitForTimer(clock))
        await clock.advance(by: .seconds(3))

        #expect(await perform.value == .unconfirmed)
        #expect(await store.log.contains(.drawn) == false)
    }

    // MARK: - Store calls are bounded

    @Test func aReadThatNeverReturnsFailsWithoutWriting() async throws {
        let (store, clock, controller) = make()
        await store.hold(.read)

        let perform = Task { await controller.perform { _ in self.swapAB } }
        try #require(await waitForHeld(.read, store, clock))
        await clock.advance(by: .seconds(3))

        #expect(await perform.value == .failed)
        #expect(await store.log == [.read])
        #expect(clock.sleeperCount == 0)
        await store.release(.read)
    }

    @Test func aStoreCallThatReturnsInTimeIsNotCutOff() async throws {
        let (store, clock, controller) = make()
        await store.hold(.read)

        let perform = Task { await controller.perform { _ in self.swapAB } }
        try #require(await waitForHeld(.read, store, clock))
        await clock.advance(by: .seconds(2))
        await store.release(.read)

        #expect(await perform.value == .applied)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aBackupThatNeverReturnsFailsWithoutWriting() async throws {
        let (store, clock, controller) = make()
        await store.hold(.backup)

        let perform = Task { await controller.perform { _ in self.swapAB } }
        try #require(await waitForHeld(.backup, store, clock))
        await clock.advance(by: .seconds(3))

        #expect(await perform.value == .failed)
        #expect(await store.log == [.read, .backup])
        #expect(await store.order == order(abc))
        await store.release(.backup)
    }

    @Test func aWriteThatNeverReturnsIsUnconfirmedAndMayStillLand() async throws {
        let (store, clock, controller) = make()
        let change = swapAB
        await store.hold(.write)

        let perform = Task { await controller.perform { _ in change } }
        try #require(await waitForHeld(.write, store, clock))
        await clock.advance(by: .seconds(3))

        // Not "failed": the abandoned write is still in the store and can land after this answer.
        #expect(await perform.value == .unconfirmed)
        #expect(await store.log == [.read, .backup, .write(change)])
        #expect(clock.sleeperCount == 0)
        await store.release(.write)
        try #require(await waitUntil { await store.order.keys == change.target })
    }

    @Test func afterAWriteTimesOutTheNextOperationRuns() async throws {
        let (store, clock, controller) = make()
        await store.hold(.write)
        let first = Task { await controller.perform { _ in self.swapAB } }
        try #require(await waitForHeld(.write, store, clock))
        await clock.advance(by: .seconds(3))
        #expect(await first.value == .unconfirmed)

        let second = OrderChange(target: ks("c", "a", "b"), moved: ks("c"))
        #expect(await controller.perform { _ in second } == .applied)
        await store.release(.write)
    }

    @Test func aRestoreThatNeverReturnsIsUnconfirmed() async throws {
        let backup = order(["b", "a", "c"])
        let (store, clock, controller) = make(script: .init(backupOrder: backup))
        await store.hold(.restore)

        let restore = Task { await controller.restore() }
        try #require(await waitForHeld(.restore, store, clock))
        await clock.advance(by: .seconds(3))

        #expect(await restore.value == .unconfirmed)
        #expect(await store.log == [.read, .latestBackupOrder, .restore])
        #expect(clock.sleeperCount == 0)
        await store.release(.restore)
    }

    @Test func aBackupReadThatNeverReturnsFailsBeforeRestoring() async throws {
        let (store, clock, controller) = make(script: .init(backupOrder: order(["b", "a", "c"])))
        await store.hold(.latestBackupOrder)

        let restore = Task { await controller.restore() }
        try #require(await waitForHeld(.latestBackupOrder, store, clock))
        await clock.advance(by: .seconds(3))

        #expect(await restore.value == .failed)
        #expect(await store.log == [.read, .latestBackupOrder])
        await store.release(.latestBackupOrder)
    }

    @Test func aDrawnKeysReadThatNeverReturnsLeavesTheMoveSaved() async throws {
        let (store, clock, controller) = make()
        await store.hold(.drawn)

        let perform = Task { await controller.perform { _ in self.swapAB } }
        try #require(await waitForHeld(.drawn, store, clock))
        await clock.advance(by: .seconds(3))

        #expect(await perform.value == .saved)
        await store.release(.drawn)
    }

    @Test func restoreConfirmsAnImmediateEmission() async {
        let backup = order(["b", "a", "c"])
        let (store, clock, controller) = make(script: .init(backupOrder: backup))

        #expect(await controller.restore() == .applied)

        #expect(await store.log == [.read, .latestBackupOrder, .restore, .drawn])
        #expect(clock.sleeperCount == 0)
    }

    @Test func restoreWithConcurrentDragIsUnconfirmed() async throws {
        let backup = order(["b", "a", "c"])
        let (store, clock, controller) = make(
            script: .init(backupOrder: backup, restoreEffect: .drag(ks("c", "a", "b"))))

        let restore = Task { await controller.restore() }
        try #require(await waitForTimer(clock))
        await clock.advance(by: .seconds(3))

        #expect(await restore.value == .unconfirmed)
        #expect(await store.log.contains(.drawn) == false)
    }

    @Test func restoreOfAFullReorderIsApplied() async throws {
        let backup = order(["c", "b", "a"])
        let (store, clock, controller) = make(script: .init(backupOrder: backup))

        #expect(await controller.restore() == .applied)

        #expect(await store.order == backup)
        #expect(clock.sleeperCount == 0)
    }

    @Test func restoreOfTheCurrentOrderIsUnchanged() async {
        let (store, clock, controller) = make(script: .init(backupOrder: order(abc)))

        #expect(await controller.restore() == .unchanged)

        #expect(await store.log == [.read, .latestBackupOrder])
        #expect(clock.sleeperCount == 0)
    }

    @Test func restoreWithoutAccessIsUnavailable() async {
        let (store, _, controller) = make(script: .init(readError: .noAccess))

        #expect(await controller.restore() == .unavailable("No access to the order file"))

        #expect(await store.log == [.read])
    }
}

private final class Seen: Sendable {
    private let orders = Mutex<[BarOrder]>([])

    func record(_ order: BarOrder) {
        orders.withLock { $0.append(order) }
    }

    var count: Int { orders.withLock { $0.count } }
}
