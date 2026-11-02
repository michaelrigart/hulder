import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

/// A preferences backend for tests: what `copyPositions` returns, and the calls made.
final class FakePositionsBackend: PositionsBackend {
    enum Call: Equatable, Sendable {
        case copy
        case set
    }

    private struct State {
        var positions: [String: Double]?
        var unknownFormat = false
        var log: [Call] = []
    }

    private let state: Mutex<State>
    let availability: Availability

    init(_ positions: [String: Double]?, availability: Availability = .available) {
        state = Mutex(State(positions: positions))
        self.availability = availability
    }

    var log: [Call] { state.withLock { $0.log } }
    var positions: [String: Double]? { state.withLock { $0.positions } }

    func clearLog() {
        state.withLock { $0.log = [] }
    }

    /// Changes what the preferences hold, as a native drag would, without touching any file.
    func replace(with positions: [String: Double]?) {
        state.withLock { state in
            state.positions = positions
            state.unknownFormat = false
        }
    }

    func holdUnknownFormat() {
        state.withLock { $0.unknownFormat = true }
    }

    func copyPositions() -> Any? {
        let (positions, unknownFormat) = state.withLock { state in
            state.log.append(.copy)
            return (state.positions, state.unknownFormat)
        }
        if unknownFormat { return ["not", "positions"] as NSArray }
        return positions.map { $0.mapValues { NSNumber(value: $0) } as NSDictionary }
    }

    func setPositions(_ positions: [String: NSNumber]) -> Bool {
        let values = positions.mapValues(\.doubleValue)
        state.withLock { state in
            state.log.append(.set)
            state.positions = values
        }
        return true
    }
}

/// A temporary folder laid out like the group container, with a backups folder beside it.
struct OrderFolders {
    let root: URL

    var container: URL { root.appending(path: "com.apple.MenuBar") }
    var preferences: URL { container.appending(path: "Library/Preferences") }
    var plist: URL { preferences.appending(path: "com.apple.MenuBar.plist") }
    var backups: URL { root.appending(path: "OrderBackups") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "HulderOrderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
    }

    static func plistData(_ positions: [String: Double]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["TrailingItemPreferredPositions": positions], format: .binary, options: 0
        )
    }

    func writePlist(_ positions: [String: Double], to url: URL? = nil) throws {
        try Self.plistData(positions).write(to: url ?? plist)
    }

    func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

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

@Test func staleBaseThrows() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    backend.replace(with: [clock: 0.0, a: 233, b: 390, c: 381])

    await #expect(throws: OrderStoreError.stale) { try await store.write(move, expecting: base) }
    #expect(!backend.log.contains(.set))
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

@Test(.timeLimit(.minutes(1))) func aFileEventRereadsAndBroadcasts() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let backend = FakePositionsBackend(positions)
    let store = try await openStore(backend, folders)
    var iterator = store.changes().makeAsyncIterator()
    #expect(await iterator.next() == base)

    backend.replace(with: [clock: 0.0, a: 365, b: 349, c: 381])
    try Data().write(to: folders.preferences.appending(path: "replaced"))

    #expect(await iterator.next() == moved)
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

@Test func anOrderFileWithoutPositionsCannotBeOpened() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    await #expect(throws: OrderStoreError.noAccess) { try await openStore(FakePositionsBackend(nil), folders) }
}
