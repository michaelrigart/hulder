import Darwin
import Foundation
import HulderCore
import Synchronization

/// The bar's order in the Menu Bar preferences of the granted group container.
///
/// Every backend and file call runs on one serial queue. Reads therefore reach the cache and the subscribers in
/// the order they were made, and a write's read, set and re-read run with nothing in between. A watch on the
/// container's preferences folder re-reads on every change, the user's own ⌘-drags included.
final class OrderStore27: OrderStore {
    typealias DrawnKeysReader = @Sendable (_ entries: [String: Double]) async -> Set<ItemKey>

    static let backupsToKeep = 10
    static let preferencesFile = "Library/Preferences/com.apple.MenuBar.plist"
    static let unreadableReason = "Hulder can't read the menu bar order file."

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private struct Snapshot: Sendable {
        let order: BarOrder
        let positions: [String: NSNumber]
    }

    private struct State {
        var snapshot: Snapshot
        /// The last read's result: `.unavailable` while the positions can't be read or decoded.
        var availability = Availability.available
        var subscribers: [UUID: AsyncStream<BarOrder>.Continuation] = [:]
    }

    private let backend: any PositionsBackend
    private let codec = OrderFileCodec()
    private let preferencesFile: URL
    private let backups: URL
    private let readDrawnKeys: DrawnKeysReader
    private let now: @Sendable () -> Date
    private let onAvailabilityChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private let watcher: any DispatchSourceFileSystemObject
    private let state: Mutex<State>

    /// Reads the order and starts watching `container`'s preferences folder. Throws when the positions can't be
    /// read or decoded, or the folder can't be watched. `onAvailabilityChange` runs on the store's queue
    /// whenever `availability` changes.
    static func open(
        backend: any PositionsBackend,
        container: URL,
        backups: URL,
        drawnKeys: @escaping DrawnKeysReader,
        now: @escaping @Sendable () -> Date = { Date() },
        onAvailabilityChange: @escaping @Sendable () -> Void = {}
    ) async throws -> OrderStore27 {
        let queue = DispatchQueue(label: "com.michaelrigart.hulder.order", qos: .userInitiated)
        let directory = container.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        let codec = OrderFileCodec()
        let (initial, watcher) = try await run(on: queue) {
            let initial = try snapshot(of: backend.copyPositions(), codec: codec)
            return (initial, try makeWatcher(directory: directory, queue: queue))
        }
        let store = OrderStore27(
            backend: backend, preferencesFile: container.appending(path: preferencesFile), backups: backups,
            drawnKeys: drawnKeys, now: now, onAvailabilityChange: onAvailabilityChange,
            queue: queue, watcher: watcher, initial: initial
        )
        // A change between the first read and the watch starting has no event of its own.
        _ = try await store.read()
        return store
    }

    private init(
        backend: any PositionsBackend,
        preferencesFile: URL,
        backups: URL,
        drawnKeys: @escaping DrawnKeysReader,
        now: @escaping @Sendable () -> Date,
        onAvailabilityChange: @escaping @Sendable () -> Void,
        queue: DispatchQueue,
        watcher: any DispatchSourceFileSystemObject,
        initial: Snapshot
    ) {
        self.backend = backend
        self.preferencesFile = preferencesFile
        self.backups = backups
        readDrawnKeys = drawnKeys
        self.now = now
        self.onAvailabilityChange = onAvailabilityChange
        self.queue = queue
        self.watcher = watcher
        state = Mutex(State(snapshot: initial))
        watcher.setEventHandler { [weak self] in self?.reread() }
        watcher.resume()
    }

    deinit {
        watcher.cancel()
        let subscribers = state.withLock { state in
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        subscribers.forEach { $0.finish() }
    }

    var availability: Availability { state.withLock { $0.availability } }

    /// The positions of the last successful read, for naming items.
    var entries: [String: Double] { state.withLock { $0.snapshot.positions.mapValues(\.doubleValue) } }

    func read() async throws -> BarOrder {
        try await run { try self.readNow().order }
    }

    /// Copies the order file to `<backups>/<UTC timestamp>.plist`, then keeps only the newest `backupsToKeep`.
    func backup() async throws {
        try await run {
            let data = try self.contents(of: self.preferencesFile)
            let destination = self.backups.appending(path: self.now().formatted(Self.timestamp) + ".plist")
            do {
                try FileManager.default.createDirectory(at: self.backups, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                PlatformLog.order.notice("the order backup could not be written: \(error.localizedDescription, privacy: .private)")
                throw OrderStoreError.io
            }
            self.pruneBackups()
        }
    }

    /// Reads the order, then sets only the moved keys' positions, all in one block on the queue, then re-reads
    /// and broadcasts. A MenuBarAgent update landing between that read and the set is still lost: the window of
    /// microseconds the spec accepts.
    func write(_ change: OrderChange, expecting base: BarOrder) async throws {
        try await run {
            let current = try self.readNow()
            guard current.order == base else {
                PlatformLog.order.notice("the order changed since the move was planned")
                throw OrderStoreError.stale
            }
            let updated: [String: NSNumber]
            do {
                updated = try self.codec.applying(change, to: current.positions)
            } catch {
                PlatformLog.order.notice("the order can't be written without moving items that didn't move")
                throw error
            }
            try self.set(updated)
            PlatformLog.order.notice("wrote the order: \(change.moved.count) items moved")
            _ = try? self.readNow()
        }
    }

    func latestBackupOrder() async throws -> BarOrder {
        try await run { try self.codec.decode(file: self.latestBackup()) }
    }

    /// Sets the newest backup's positions, then re-reads and broadcasts, in one block on the queue.
    func restoreLatestBackup() async throws {
        try await run {
            try self.set(self.codec.positions(fromFile: self.latestBackup()))
            PlatformLog.order.notice("restored the order from the latest backup")
            _ = try? self.readNow()
        }
    }

    /// The cached order first, from the same lock step that registers the subscriber, then each order a read
    /// finds that differs from the one before.
    func changes() -> AsyncStream<BarOrder> {
        let (stream, continuation) = AsyncStream.makeStream(of: BarOrder.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { state in
            continuation.yield(state.snapshot.order)
            state.subscribers[id] = continuation
        }
        return stream
    }

    func drawnKeys() async -> Set<ItemKey> {
        await readDrawnKeys(entries)
    }

    /// The fixed reason reordering is unavailable after a read failed with `error`.
    static func reason(for error: OrderStoreError) -> String {
        if case .unsupportedFormat(let text) = error { return text }
        return unreadableReason
    }

    // MARK: On the queue

    private func reread() {
        _ = try? readNow()
    }

    /// Reads and decodes the positions, then publishes the result to the cache, the subscribers and the
    /// availability.
    private func readNow() throws(OrderStoreError) -> Snapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        let read = Result { () throws(OrderStoreError) in try Self.snapshot(of: backend.copyPositions(), codec: codec) }
        publish(read)
        return try read.get()
    }

    private func publish(_ read: Result<Snapshot, OrderStoreError>) {
        let (orderChanged, availability, availabilityChanged) = state.withLock { state in
            let previous = state.availability
            var orderChanged = false
            switch read {
            case .success(let snapshot):
                state.availability = .available
                orderChanged = snapshot.order != state.snapshot.order
                state.snapshot = snapshot
                if orderChanged {
                    for subscriber in state.subscribers.values { subscriber.yield(snapshot.order) }
                }
            case .failure(let error):
                state.availability = .unavailable(Self.reason(for: error))
            }
            return (orderChanged, state.availability, state.availability != previous)
        }
        if orderChanged { PlatformLog.order.notice("the saved order changed") }
        guard availabilityChanged else { return }
        switch availability {
        case .available: PlatformLog.order.notice("the order file is readable again")
        case .unavailable: PlatformLog.order.notice("the order file can't be read or has an unknown format")
        }
        onAvailabilityChange()
    }

    private func set(_ positions: [String: NSNumber]) throws(OrderStoreError) {
        guard backend.setPositions(positions) else {
            PlatformLog.order.notice("the order could not be saved")
            throw .io
        }
    }

    private func latestBackup() throws(OrderStoreError) -> Data {
        guard let newest = backupFiles().last else {
            PlatformLog.order.notice("there is no order backup")
            throw .io
        }
        return try contents(of: newest)
    }

    /// Oldest first: the names are UTC timestamps, so they sort in time order.
    private func backupFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneBackups() {
        for file in backupFiles().dropLast(Self.backupsToKeep) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                PlatformLog.order.notice("an old order backup could not be removed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// The file names here are fixed or timestamps, so they are safe to log.
    private func contents(of file: URL) throws(OrderStoreError) -> Data {
        do {
            return try Data(contentsOf: file)
        } catch {
            PlatformLog.order.notice(
                "\(file.lastPathComponent, privacy: .public) could not be read: \(error.localizedDescription, privacy: .private)"
            )
            throw .io
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Self.run(on: queue, body)
    }

    // MARK: Helpers

    private static func run<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    /// Nil from the preferences means the value can't be read: after a grant, that is lost access.
    private static func snapshot(of value: Any?, codec: OrderFileCodec) throws(OrderStoreError) -> Snapshot {
        guard let value else { throw .noAccess }
        let positions = try codec.positions(from: value)
        return Snapshot(order: codec.order(of: positions), positions: positions)
    }

    /// A watch on the folder, which macOS changes by replacing the order file. It starts once resumed.
    private static func makeWatcher(directory: URL, queue: DispatchQueue) throws(OrderStoreError) -> any DispatchSourceFileSystemObject {
        let descriptor = Darwin.open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            PlatformLog.order.notice("the order file's folder could not be watched: errno \(errno)")
            throw .noAccess
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: queue
        )
        source.setCancelHandler { close(descriptor) }
        return source
    }
}

extension OrderStore27 {
    /// Reads the items MenuBarAgent draws, once per call, on `queue`.
    static func drawnKeysReader(queue: AXQueue) -> DrawnKeysReader {
        { entries in
            let timeout = queue.messagingTimeout
            return await queue.run {
                guard let snapshot = MenuBarAgentReader.read(timeout: timeout) else { return [] }
                var owners: [pid_t: ItemOwner] = [:]
                for pid in Set(snapshot.groups.map(\.pid)) { owners[pid] = OwnerResolver27.owner(of: pid) }
                return drawnKeys(in: snapshot, owners: owners, entries: entries)
            }
        }
    }

    /// The keys the inventory gives these drawn items, built the same way so that the two always agree.
    static func drawnKeys(in snapshot: BarSnapshot, owners: [pid_t: ItemOwner], entries: [String: Double]) -> Set<ItemKey> {
        let scans = InventoryAssembly.scans(
            snapshot: snapshot, owners: owners, listings: [:], entries: entries, running: [], previousOwners: []
        )
        return Set(scans.flatMap { scan -> [ItemKey] in
            guard case .complete(let items) = scan.result else { return [] }
            return items.map(\.key)
        })
    }
}
