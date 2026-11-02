import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

/// The granted container, as a test decides it.
private final class FakeAccess: Sendable {
    private let granted = Mutex<URL?>(nil)

    func grant(_ container: URL) {
        granted.withLock { $0 = container }
    }

    func container() -> URL? {
        granted.withLock { $0 }
    }
}

private let a = "status:com.example.a::Item-0"
private let b = "status:com.example.b::Item-0"
private let clock = "module:Clock"
private let positions = [clock: 0.0, a: 233, b: 349]
private let order = BarOrder(keys: [b, a, clock].map(ItemKey.init(raw:)), pinned: [ItemKey(raw: clock)])
private let unknownFormat = Availability.unavailable("The menu bar order has a format Hulder doesn't know.")

private let unanswered = Availability.unavailable(OrderStore27.unansweredReason)

/// The deadline of the file's calls, as a test sets it: long, so a call that must succeed never races it, and
/// short only for the call that must stall.
private final class Deadlines: Sendable {
    private let current = Mutex(Duration.seconds(60))

    func stallSoon() {
        current.withLock { $0 = .milliseconds(50) }
    }

    func patient() {
        current.withLock { $0 = .seconds(60) }
    }

    var value: Duration { current.withLock { $0 } }
}

private func makeFile(
    _ access: FakeAccess, _ backend: FakePositionsBackend, _ folders: OrderFolders, deadlines: Deadlines = Deadlines()
) -> OrderFile27 {
    makeFile(access, backends: { _ in backend }, folders, deadlines: deadlines)
}

private func makeFile(
    _ access: FakeAccess, backends: @escaping @Sendable (URL) -> any PositionsBackend, _ folders: OrderFolders,
    deadlines: Deadlines = Deadlines()
) -> OrderFile27 {
    OrderFile27(
        container: { access.container() }, makeBackend: backends,
        backups: folders.backups, drawnKeys: { _ in [] }, timeout: { deadlines.value }
    )
}

@Test(.timeLimit(.minutes(1))) func reorderingWaitsForAccessThenOpensTheStore() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    let file = makeFile(access, FakePositionsBackend(positions), folders)
    let (scanRequests, requestScan) = AsyncStream.makeStream(of: Void.self)
    file.start(onOrderChange: { requestScan.yield() })
    var reordering = file.reorderingChanges().makeAsyncIterator()

    #expect(await reordering.next() == .unavailable(OrderFile27.notGranted))
    #expect(await file.availableStore() == nil)
    #expect(file.entries() == nil)

    access.grant(folders.container)
    await file.evaluate()

    #expect(await reordering.next() == .available)
    #expect(try await file.availableStore()?.read() == order)
    #expect(file.entries() == positions)
    // The new store's first order asks for a scan, so items get their names from the file.
    var scans = scanRequests.makeAsyncIterator()
    #expect(await scans.next() != nil)
}

@Test(.timeLimit(.minutes(1))) func missingPreferencesFunctionsAreTheReason() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let missing = Availability.unavailable("_CFPreferencesCopyAppValueWithContainer missing")
    let file = makeFile(access, FakePositionsBackend(positions, availability: missing), folders)
    file.start(onOrderChange: {})

    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == missing)
    #expect(await file.availableStore() == nil)
}

@Test(.timeLimit(.minutes(1))) func anUnknownFormatTurnsReorderingOffAndAGrantChecksAgain() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let file = makeFile(access, backend, folders)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == .available)

    backend.holdUnknownFormat()
    try Data().write(to: folders.preferences.appending(path: "replaced"))
    #expect(await reordering.next() == unknownFormat)
    #expect(await file.availableStore() == nil)

    backend.replace(with: positions)
    await file.evaluate()
    #expect(await reordering.next() == .available)
    #expect(await file.availableStore() != nil)
}

/// While access is granted but no store opens, a change in the preferences folder tries again. No polling.
@Test(.timeLimit(.minutes(1))) func aStoreThatFailedToOpenOpensOnTheNextFileEvent() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    backend.holdUnknownFormat()
    let file = makeFile(access, backend, folders)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == unknownFormat)

    backend.replace(with: positions)
    try Data().write(to: folders.preferences.appending(path: "replaced"))

    #expect(await reordering.next() == .available)
    #expect(try await file.availableStore()?.read() == order)
}

/// A stuck `copyPositions` blocks a thread of the store's own queue, so the evaluation ends at its deadline.
@Test(.timeLimit(.minutes(1))) func aStalledOpeningReportsReorderingUnavailableAfterItsDeadline() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    backend.holdCopies()
    defer { backend.release() }
    let deadlines = Deadlines()
    deadlines.stallSoon()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()

    #expect(await reordering.next() == unanswered)
    #expect(await file.availableStore() == nil)
    #expect(file.entries() == nil)
}

/// macOS answering the abandoned opening is the event that evaluates again; no change to the folder is needed.
@Test(.timeLimit(.minutes(1))) func aLateOpeningMakesReorderingAvailableWithoutAFolderChange() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    backend.holdCopies()
    defer { backend.release() }
    let deadlines = Deadlines()
    deadlines.stallSoon()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == unanswered)

    deadlines.patient()
    backend.release()

    #expect(await reordering.next() == .available)
    #expect(try await file.availableStore()?.read() == order)
    #expect(file.entries() == positions)
}

/// The abandoned opening's store stops watching, and only the store of the evaluation that follows its answer is
/// adopted: a change in the folder reaches the second backend and never the first.
@Test(.timeLimit(.minutes(1))) func aLateOpeningChangesNothingAndReleasesItsStore() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let (first, second) = (FakePositionsBackend(positions), FakePositionsBackend(positions))
    first.holdCopies()
    defer { first.release() }
    let handed = Mutex(0)
    let deadlines = Deadlines()
    deadlines.stallSoon()
    let file = makeFile(access, backends: { _ in
        handed.withLock { count in
            count += 1
            return count == 1 ? first : second
        }
    }, folders, deadlines: deadlines)
    let orderChanges = Mutex(0)
    file.start(onOrderChange: { orderChanges.withLock { $0 += 1 } })
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == unanswered)
    #expect(await file.availableStore() == nil)

    deadlines.patient()
    first.release()
    // The late store was shut down before the evaluation that opens the second one was enqueued.
    #expect(await reordering.next() == .available)
    let before = (first.log.count, second.log.count)
    #expect(before.0 == 2)

    try Data().write(to: folders.preferences.appending(path: "replaced"))
    while second.log.count == before.1 { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(100))

    #expect(first.log.count == before.0)
    #expect(handed.withLock { $0 } == 2)
}

@Test(.timeLimit(.minutes(1))) func aSecondEvaluationDuringAStallStartsNoNewCall() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    backend.holdCopies()
    defer { backend.release() }
    let deadlines = Deadlines()
    deadlines.stallSoon()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    var starts = backend.copyStarts.makeAsyncIterator()
    await starts.next()
    #expect(await reordering.next() == unanswered)

    await file.evaluate()
    await file.evaluate()

    #expect(backend.copyCalls == 1)
    #expect(await file.availableStore() == nil)

    // The one outstanding call answers, and the evaluation it enqueues is the next to call.
    deadlines.patient()
    backend.release()
    #expect(await reordering.next() == .available)
}

@Test(.timeLimit(.minutes(1))) func aStalledReadOnReevaluationReportsUnavailable() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let deadlines = Deadlines()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == .available)

    deadlines.stallSoon()
    backend.holdCopies()
    defer { backend.release() }
    await file.evaluate()

    #expect(await reordering.next() == unanswered)
    #expect(await file.availableStore() == nil)

    // While the read is outstanding, a further evaluation calls nothing.
    let calls = backend.copyCalls
    await file.evaluate()
    #expect(backend.copyCalls == calls)
}

@Test(.timeLimit(.minutes(1))) func aDroppedStoresLateReadMakesReorderingAvailableWithoutAFolderChange() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let deadlines = Deadlines()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == .available)
    deadlines.stallSoon()
    backend.holdCopies()
    defer { backend.release() }
    await file.evaluate()
    #expect(await reordering.next() == unanswered)

    deadlines.patient()
    backend.release()

    #expect(await reordering.next() == .available)
    #expect(try await file.availableStore()?.read() == order)
}

/// A ⌘-drag's folder change asks the file for an evaluation, whose read is bounded like any other; the watcher
/// reads nothing itself.
@Test(.timeLimit(.minutes(1))) func aStalledReadAfterAFolderChangeReportsReorderingUnavailable() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let deadlines = Deadlines()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == .available)

    deadlines.stallSoon()
    backend.holdCopies()
    defer { backend.release() }
    try Data().write(to: folders.preferences.appending(path: "replaced"))

    #expect(await reordering.next() == unanswered)
    #expect(await file.availableStore() == nil)

    // macOS answers: one evaluation follows and reads again.
    deadlines.patient()
    backend.release()
    #expect(await reordering.next() == .available)
    #expect(try await file.availableStore()?.read() == order)
}

@Test(.timeLimit(.minutes(1))) func aFolderChangePublishesTheNewOrderThroughTheEvaluation() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let file = makeFile(access, backend, folders)
    let (changes, changed) = AsyncStream.makeStream(of: Void.self)
    file.start(onOrderChange: { changed.yield() })
    var iterator = changes.makeAsyncIterator()
    await iterator.next()

    backend.replace(with: [clock: 0.0, a: 233, b: 100])
    try Data().write(to: folders.preferences.appending(path: "replaced"))

    await iterator.next()
    #expect(file.entries() == [clock: 0.0, a: 233, b: 100])
}

@Test(.timeLimit(.minutes(1))) func aStalledWriteReportsReorderingUnavailableAndDropsTheStore() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = FakeAccess()
    access.grant(folders.container)
    let backend = FakePositionsBackend(positions)
    let deadlines = Deadlines()
    let file = makeFile(access, backend, folders, deadlines: deadlines)
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()
    #expect(await reordering.next() == .available)
    let store = try #require(await file.availableStore())

    deadlines.stallSoon()
    backend.holdSets()
    defer { backend.release() }
    let change = OrderChange(target: [a, b, clock].map(ItemKey.init(raw:)), moved: [ItemKey(raw: b)])
    await #expect(throws: OrderStoreError.io) { try await store.write(change, expecting: order) }

    #expect(await reordering.next() == unanswered)
    #expect(await file.availableStore() == nil)
    #expect(file.entries() == nil)

    // The write is not repeated; the answer only brings one evaluation.
    deadlines.patient()
    backend.release()
    #expect(await reordering.next() == .available)
    #expect(backend.setCalls == 1)
}

@Test(.timeLimit(.minutes(1))) func aStalledContainerResolutionReportsReorderingUnavailable() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let released = Mutex(false)
    let deadlines = Deadlines()
    deadlines.stallSoon()
    let calls = Mutex(0)
    let file = OrderFile27(
        container: {
            let first = calls.withLock { count in
                count += 1
                return count == 1
            }
            if first {
                await withCheckedContinuation { continuation in
                    if released.withLock({ $0 }) { continuation.resume() } else { release.withLock { $0 = continuation } }
                }
            }
            return folders.container
        },
        makeBackend: { _ in FakePositionsBackend(positions) }, backups: folders.backups, drawnKeys: { _ in [] },
        timeout: { deadlines.value }
    )
    file.start(onOrderChange: {})
    var reordering = file.reorderingChanges().makeAsyncIterator()

    #expect(await reordering.next() == unanswered)
    await file.evaluate()
    #expect(calls.withLock { $0 } == 1)

    deadlines.patient()
    released.withLock { $0 = true }
    release.withLock { $0.take() }?.resume()
    #expect(await reordering.next() == .available)
}

@Test func capabilitiesPassReorderingThrough() {
    let unavailable = Availability.unavailable(OrderFile27.notGranted)
    #expect(Platform27.capabilities(hiding: .available, trusted: true, tracking: .full, reordering: unavailable).reordering == unavailable)
    #expect(Platform27.capabilities(hiding: .available, trusted: false, tracking: .full, reordering: .available).reordering == .available)
}
