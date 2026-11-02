import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

/// Whole seconds from a fixed start, one per call.
private final class Ticker: Sendable {
    private let count = Mutex(0)

    func next() -> Date {
        count.withLock { count in
            count += 1
            return Date(timeIntervalSince1970: 1_800_000_000 + Double(count))
        }
    }

    static func name(_ tick: Int) -> String {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(tick))
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) + ".plist"
    }
}

private let a = "status:com.example.a::Item-0"
private let b = "status:com.example.b::Item-0"
private let c = "status:com.example.c::Item-0"
private let clock = "module:Clock"
private let unsupported = OrderStoreError.unsupportedFormat("The menu bar order has a format Hulder doesn't know.")

private func keys(_ raws: String...) -> [ItemKey] {
    raws.map(ItemKey.init(raw:))
}

private let positions = [clock: 0.0, a: 233, b: 349, c: 381]
private let base = BarOrder(keys: keys(c, b, a, clock), pinned: [ItemKey(raw: clock)])
/// Moves `a` between `c` (381) and `b` (349): `a` becomes 365.
private let move = OrderChange(target: keys(c, a, b, clock), moved: keys(a))
private let moved = BarOrder(keys: move.target, pinned: base.pinned)

private func openStore(
    _ backend: FakePositionsBackend,
    _ folders: OrderFolders,
    now: @escaping @Sendable () -> Date = { Date() },
    onAvailabilityChange: @escaping @Sendable () -> Void = {}
) async throws -> OrderStore27 {
    try await OrderStore27.open(
        backend: backend, container: folders.container, backups: folders.backups,
        drawnKeys: { _ in [] }, now: now, onAvailabilityChange: onAvailabilityChange
    )
}

@Test func backupKeepsNewestTen() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(positions)
    let ticker = Ticker()
    let store = try await openStore(FakePositionsBackend(positions), folders, now: { ticker.next() })

    for _ in 0..<12 { try await store.backup() }

    #expect(try folders.backupNames() == (3...12).map(Ticker.name))
    #expect(try await store.latestBackupOrder() == base)
}

@Test(.timeLimit(.minutes(1))) func restoreWritesTheNewestBackup() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try FileManager.default.createDirectory(at: folders.backups, withIntermediateDirectories: true)
    let older = [clock: 0.0, a: 100, b: 349, c: 381]
    let newer = [clock: 0.0, a: 400, b: 349, c: 381]
    try folders.writePlist(older, to: folders.backups.appending(path: Ticker.name(1)))
    try folders.writePlist(newer, to: folders.backups.appending(path: Ticker.name(2)))
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    let restored = BarOrder(keys: keys(a, c, b, clock), pinned: base.pinned)
    var iterator = store.changes().makeAsyncIterator()

    #expect(try await store.latestBackupOrder() == restored)
    try await store.restoreLatestBackup()

    #expect(backend.positions == newer)
    #expect(await iterator.next() == base)
    #expect(await iterator.next() == restored)
}

@Test(.timeLimit(.minutes(1))) func staleBaseThrows() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    backend.replace(with: [clock: 0.0, a: 233, b: 390, c: 381])

    await #expect(throws: OrderStoreError.stale) { try await store.write(move, expecting: base) }
    #expect(!backend.log.contains(.set))
    // A write that stops at its read publishes what it read.
    var iterator = store.changes().makeAsyncIterator()
    #expect(await iterator.next() == BarOrder(keys: keys(b, c, a, clock), pinned: base.pinned))
}

@Test func writeReadsImmediatelyBeforeSetting() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    backend.clearLog()

    try await store.write(move, expecting: base)

    #expect(backend.log == [.copy, .set, .copy])
    #expect(backend.positions == [clock: 0.0, a: 365, b: 349, c: 381])
}

@Test func unrepresentableWriteNeverSets() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let z = "status:com.example.z::Item-0"
    let backend = FakePositionsBackend([z: 200, a: 100, c: 100])
    let store = try await openStore(backend, folders)
    let current = try await store.read()
    #expect(current.keys == keys(z, a, c))

    let change = OrderChange(target: keys(a, z, c), moved: keys(z))
    await #expect(throws: OrderStoreError.unrepresentable) { try await store.write(change, expecting: current) }
    #expect(!backend.log.contains(.set))
}

@Test(.timeLimit(.minutes(1))) func subscriberBeforeWriteSeesTheTarget() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let changes: AsyncStream<BarOrder>
    do {
        let store = try await openStore(FakePositionsBackend(positions), folders)
        changes = store.changes()
        try await store.write(move, expecting: base)
    }

    // Releasing the store ends its streams, so this collects everything the subscriber was sent.
    var elements: [BarOrder] = []
    for await order in changes { elements.append(order) }
    #expect(elements == [base, moved])
}

@Test(.timeLimit(.minutes(1))) func changesEmitsTheCachedOrderFirst() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    backend.clearLog()
    backend.replace(with: [clock: 0.0, a: 500, b: 349, c: 381])

    var iterator = store.changes().makeAsyncIterator()

    #expect(backend.log.isEmpty)
    #expect(await iterator.next() == base)
    #expect(backend.log.isEmpty)
}

/// The watcher reports and never reads: a stuck read could not hold the report back, and every read has one path.
@Test(.timeLimit(.minutes(1))) func aFileEventAsksForAnEvaluationAndReadsNothing() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let (events, event) = AsyncStream.makeStream(of: Void.self)
    let store = try await OrderStore27.open(
        backend: backend, container: folders.container, backups: folders.backups, drawnKeys: { _ in [] },
        onFolderChange: { event.yield() }
    )
    backend.clearLog()

    backend.replace(with: [clock: 0.0, a: 365, b: 349, c: 381])
    try Data().write(to: folders.preferences.appending(path: "replaced"))
    var iterator = events.makeAsyncIterator()
    await iterator.next()

    #expect(backend.log.isEmpty)
    // The evaluation's read is what publishes the new order.
    var changes = store.changes().makeAsyncIterator()
    #expect(await changes.next() == base)
    #expect(try await store.read() == moved)
    #expect(await changes.next() == moved)
}

@Test func anUnknownFormatTurnsReorderingOffUntilItIsReadable() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let reports = Mutex(0)
    let store = try await openStore(backend, folders, onAvailabilityChange: { reports.withLock { $0 += 1 } })
    #expect(store.availability == .available)

    backend.holdUnknownFormat()
    await #expect(throws: unsupported) { try await store.read() }
    #expect(store.availability == .unavailable("The menu bar order has a format Hulder doesn't know."))
    await #expect(throws: unsupported) { try await store.write(move, expecting: base) }
    #expect(!backend.log.contains(.set))

    backend.replace(with: positions)
    #expect(try await store.read() == base)
    #expect(store.availability == .available)
    #expect(reports.withLock { $0 } == 2)
}

/// The window between the read and the set is kept as short as it can be: the read is published with the re-read
/// after the set, not before it.
@Test(.timeLimit(.minutes(1))) func nothingIsPublishedBetweenTheReadAndTheSet() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    // A native drag the store has had no event for yet: b moves left of c.
    let dragged = [clock: 0.0, a: 233, b: 390, c: 381]
    let draggedOrder = BarOrder(keys: keys(b, c, a, clock), pinned: base.pinned)
    let change = OrderChange(target: keys(b, a, c, clock), moved: keys(a))
    let cachedAtSet = Mutex<[String: Double]?>(nil)
    let changes: AsyncStream<BarOrder>
    do {
        let store = try await openStore(backend, folders)
        changes = store.changes()
        backend.replace(with: dragged)
        backend.onSet { [weak store] in cachedAtSet.withLock { $0 = store?.entries } }

        try await store.write(change, expecting: draggedOrder)
    }

    var elements: [BarOrder] = []
    for await order in changes { elements.append(order) }
    #expect(cachedAtSet.withLock { $0 } == positions)
    #expect(elements == [base, BarOrder(keys: change.target, pinned: base.pinned)])
}

@Test func aFailedSetThrowsIO() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    backend.failSets()
    backend.clearLog()

    await #expect(throws: OrderStoreError.io) { try await store.write(move, expecting: base) }
    #expect(backend.log == [.copy, .set, .copy])
    #expect(backend.positions == positions)
}

@Test func drawnKeysAreTheDrawnItemsNamedFromTheOrderFile() {
    let named = "status:com.example.a::Alpha"
    let snapshot = BarSnapshot(groups: [DrawnGroup(pid: 10, frame: CGRect(x: 900, y: 0, width: 24, height: 24))], overflowIndicatorX: nil)
    let owners: [pid_t: ItemOwner] = [10: .app(AppID("com.example.a"), name: "A")]
    // `named` was just moved; `b`'s app draws nothing.
    let entries = [clock: 0.0, named: 365, b: 349]

    #expect(OrderStore27.drawnKeys(in: snapshot, owners: owners, entries: entries, own: nil) == [ItemKey(raw: named)])
}

// Catches a confirmation that expects a different key for Hulder's divider than the inventory gives it.
@Test func drawnKeysNameHulderByItsAutosaveName() {
    let own = AppID("com.michaelrigart.hulder")
    let snapshot = BarSnapshot(groups: [DrawnGroup(pid: 10, frame: CGRect(x: 900, y: 0, width: 24, height: 24))], overflowIndicatorX: nil)
    let owners: [pid_t: ItemOwner] = [10: .app(own, name: "Hulder")]
    let entries = ["status:com.michaelrigart.hulder::Item-0": 900.0, "status:com.michaelrigart.hulder::HulderDivider": 400.0]

    #expect(OrderStore27.drawnKeys(in: snapshot, owners: owners, entries: entries, own: own)
        == [ItemKey(raw: "status:com.michaelrigart.hulder::HulderDivider")])
}

// Pins what makes a caller's deadline safe: a call runs whole in one block on the store's serial queue, so one the
// caller stopped waiting for lands in full, before any later call, and publishes once. A change that split a call
// across blocks, or let a later call overtake it, would let a timeout leave a half-written or re-ordered state.
@Test(.timeLimit(.minutes(1))) func aWriteItsCallerStoppedWaitingForStillLandsWholeAndBeforeLaterCalls() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    var iterator = store.changes().makeAsyncIterator()
    #expect(await iterator.next() == base)
    let (insideSet, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
    backend.onSet {
        insideSet.signal()
        release.wait()
    }

    let abandoned = Task { try await store.write(move, expecting: base) }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            insideSet.wait()
            continuation.resume()
        }
    }
    // The caller's deadline has passed; it never looks at `abandoned` again. A later call queues behind it.
    let later = Task { try await store.read() }
    release.signal()

    #expect(try await later.value == moved)
    #expect(await iterator.next() == moved)
    #expect(backend.positions == [clock: 0.0, a: 365, b: 349, c: 381])
    #expect(backend.log.filter { $0 == .set }.count == 1)
    _ = await abandoned.result
}

@Test(.timeLimit(.minutes(1))) func aShutDownStoreStopsWatchingAndEndsItsSubscribers() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    let changes = store.changes()
    backend.clearLog()

    store.shutDown()
    try Data().write(to: folders.preferences.appending(path: "replaced"))
    try await Task.sleep(for: .milliseconds(100))

    #expect(backend.log.isEmpty)
    var elements: [BarOrder] = []
    for await order in changes { elements.append(order) }
    #expect(elements == [base])
}

/// What a store tells its owner when a call stalls: which store, and when macOS answered.
private final class Stalls: Sendable {
    private let stalled = Mutex<[OrderStore27]>([])
    private let answers = Mutex(0)
    let (answered, answeredSignal) = AsyncStream.makeStream(of: Void.self)

    var stores: [OrderStore27] { stalled.withLock { $0 } }
    var answerCount: Int { answers.withLock { $0 } }

    func stall(_ store: OrderStore27) {
        stalled.withLock { $0.append(store) }
    }

    func answer() {
        answers.withLock { $0 += 1 }
        answeredSignal.yield()
    }
}

private func openWatchedStore(
    _ backend: FakePositionsBackend, _ folders: OrderFolders, _ stalls: Stalls, timeout: Duration = .milliseconds(50)
) async throws -> OrderStore27 {
    let store = try await OrderStore27.open(
        backend: backend, container: folders.container, backups: folders.backups, drawnKeys: { _ in [] },
        timeout: { timeout }, onStall: { stalls.stall($0) }, onAnswered: { stalls.answer() }
    )
    return store
}

@Test(.timeLimit(.minutes(1))) func aStalledReadThrowsReportsItsStoreAndReportsTheAnswer() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let stalls = Stalls()
    let store = try await openWatchedStore(backend, folders, stalls)
    backend.holdCopies()
    defer { backend.release() }

    await #expect(throws: OrderStoreError.unanswered) { try await store.read() }

    #expect(stalls.stores.count == 1 && stalls.stores[0] === store)
    #expect(stalls.answerCount == 0)
    backend.release()
    var answers = stalls.answered.makeAsyncIterator()
    await answers.next()
    #expect(stalls.answerCount == 1)
}

@Test(.timeLimit(.minutes(1))) func aStalledWriteThrowsAndIsNeverRepeated() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let stalls = Stalls()
    let store = try await openWatchedStore(backend, folders, stalls)
    backend.holdSets()
    defer { backend.release() }

    await #expect(throws: OrderStoreError.unanswered) { try await store.write(move, expecting: base) }

    #expect(stalls.stores.count == 1)
    backend.release()
    var answers = stalls.answered.makeAsyncIterator()
    await answers.next()
    #expect(backend.setCalls == 1)
}

@Test(.timeLimit(.minutes(1))) func aStalledRestoreThrowsAndReportsTheStall() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try FileManager.default.createDirectory(at: folders.backups, withIntermediateDirectories: true)
    try folders.writePlist(positions, to: folders.backups.appending(path: Ticker.name(1)))
    let backend = FakePositionsBackend(positions)
    let stalls = Stalls()
    let store = try await openWatchedStore(backend, folders, stalls)
    backend.holdSets()
    defer { backend.release() }

    await #expect(throws: OrderStoreError.unanswered) { try await store.restoreLatestBackup() }

    #expect(stalls.stores.count == 1)
}

/// The queue is serial, so a call that never started still waits for the stuck one, and expires on its own deadline.
@Test(.timeLimit(.minutes(1))) func aCallQueuedBehindAStuckReadExpiresToo() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let stalls = Stalls()
    let store = try await openWatchedStore(backend, folders, stalls)
    backend.holdCopies()
    defer { backend.release() }
    await #expect(throws: OrderStoreError.unanswered) { try await store.read() }

    await #expect(throws: OrderStoreError.unanswered) { try await store.backup() }

    #expect(stalls.stores.count == 2)
}
