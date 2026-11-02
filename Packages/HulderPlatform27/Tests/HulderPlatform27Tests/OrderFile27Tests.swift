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

private func makeFile(_ access: FakeAccess, _ backend: FakePositionsBackend, _ folders: OrderFolders) -> OrderFile27 {
    OrderFile27(
        container: { access.container() }, makeBackend: { _ in backend },
        backups: folders.backups, drawnKeys: { _ in [] }
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

@Test func capabilitiesPassReorderingThrough() {
    let unavailable = Availability.unavailable(OrderFile27.notGranted)
    #expect(Platform27.capabilities(hiding: .available, trusted: true, tracking: .full, reordering: unavailable).reordering == unavailable)
    #expect(Platform27.capabilities(hiding: .available, trusted: false, tracking: .full, reordering: .available).reordering == .available)
}
