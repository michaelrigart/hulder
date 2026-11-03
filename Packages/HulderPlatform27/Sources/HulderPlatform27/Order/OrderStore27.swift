import Darwin
import Foundation
import HulderCore
import Synchronization

/// The bar's order in the Menu Bar preferences of the granted group container.
///
/// Every backend and file call runs on one serial queue. Reads therefore reach the cache and the subscribers in
/// the order they were made, and a write's read, set and re-read run with nothing in between.
///
/// Every call a caller awaits has a deadline. A call that misses it throws `io`, tells `onStall` which store it
/// was, and tells `onAnswered` when macOS finally answers it; whoever owns the store decides what a stall means. The
/// store never retries. A watch on the container's preferences folder only reports the change to `onFolderChange`,
/// the user's own ⌘-drags included, from a queue of its own so that a stuck call can't hold the report back.
final class OrderStore27: OrderStore {
    typealias DrawnKeysReader = @Sendable (_ entries: [String: Double]) async -> Set<ItemKey>

    static let backupsToKeep = 10
    static let preferencesFile = "Library/Preferences/com.apple.MenuBar.plist"
    static let unreadableReason = "Hulder can't read the menu bar order file."
    static let unansweredReason = "macOS didn't answer when Hulder read the menu bar order."
    /// How long opening the store, or a read of it, may take before reordering counts as unavailable: the bound
    /// the order controller puts on its own store calls.
    static let readTimeout = OrderController.defaultTimeout

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
    private let timeout: @Sendable () -> Duration
    private let onStall: @Sendable (OrderStore27) -> Void
    private let onAnswered: @Sendable () -> Void
    private let onFolderChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private let watcher: any DispatchSourceFileSystemObject
    private let state: Mutex<State>

    /// Reads the order and starts watching `container`'s preferences folder. Throws when the positions can't be
    /// read or decoded, or the folder can't be watched. `onAvailabilityChange` runs on the store's queue
    /// whenever `availability` changes. The opening itself has no deadline here: its caller bounds it.
    static func open(
        backend: any PositionsBackend,
        container: URL,
        backups: URL,
        drawnKeys: @escaping DrawnKeysReader,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: @escaping @Sendable () -> Duration = { readTimeout },
        onAvailabilityChange: @escaping @Sendable () -> Void = {},
        onStall: @escaping @Sendable (OrderStore27) -> Void = { _ in },
        onAnswered: @escaping @Sendable () -> Void = {},
        onFolderChange: @escaping @Sendable () -> Void = {}
    ) async throws -> OrderStore27 {
        let queue = DispatchQueue(label: "com.michaelrigart.hulder.order", qos: .userInitiated)
        let events = DispatchQueue(label: "com.michaelrigart.hulder.order-events", qos: .utility)
        let file = container.appending(path: preferencesFile)
        let codec = OrderFileCodec()
        let (initial, watcher) = try await run(on: queue) {
            let initial = try snapshot(of: backend.copyPositions(), file: file, codec: codec)
            return (initial, try preferencesWatcher(container: container, queue: events))
        }
        let store = OrderStore27(
            backend: backend, preferencesFile: file, backups: backups,
            drawnKeys: drawnKeys, now: now, timeout: timeout, onAvailabilityChange: onAvailabilityChange,
            onStall: onStall, onAnswered: onAnswered, onFolderChange: onFolderChange,
            queue: queue, watcher: watcher, initial: initial
        )
        // A change between the first read and the watch starting has no event of its own.
        _ = try await store.runUnbounded { try store.readNow().order }
        return store
    }

    private init(
        backend: any PositionsBackend,
        preferencesFile: URL,
        backups: URL,
        drawnKeys: @escaping DrawnKeysReader,
        now: @escaping @Sendable () -> Date,
        timeout: @escaping @Sendable () -> Duration,
        onAvailabilityChange: @escaping @Sendable () -> Void,
        onStall: @escaping @Sendable (OrderStore27) -> Void,
        onAnswered: @escaping @Sendable () -> Void,
        onFolderChange: @escaping @Sendable () -> Void,
        queue: DispatchQueue,
        watcher: any DispatchSourceFileSystemObject,
        initial: Snapshot
    ) {
        self.backend = backend
        self.preferencesFile = preferencesFile
        self.backups = backups
        readDrawnKeys = drawnKeys
        self.now = now
        self.timeout = timeout
        self.onAvailabilityChange = onAvailabilityChange
        self.onStall = onStall
        self.onAnswered = onAnswered
        self.onFolderChange = onFolderChange
        self.queue = queue
        self.watcher = watcher
        state = Mutex(State(snapshot: initial))
        watcher.setEventHandler { [weak self] in self?.onFolderChange() }
        watcher.resume()
    }

    deinit {
        shutDown()
    }

    /// Stops watching and ends the subscribers. A call already queued still runs, and its result goes nowhere.
    func shutDown() {
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

    /// Writes the positions the preferences hold now to `<backups>/<UTC timestamp>.plist`, then keeps only the
    /// newest `backupsToKeep`. The file in the folder can lag the preferences, so the backup comes from a read of them.
    func backup() async throws {
        try await run {
            let positions = try self.readPositions().get().positions
            let destination = self.backups.appending(path: self.now().formatted(Self.timestamp) + ".plist")
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: [OrderFileCodec.positionsKey: positions], format: .binary, options: 0
                )
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
    /// microseconds the spec accepts. Nothing is published inside that window; the read is published only when
    /// the write stops at it.
    func write(_ change: OrderChange, expecting base: BarOrder) async throws {
        try await run {
            let read = self.readPositions()
            let updated: [String: NSNumber]
            do {
                updated = try self.positions(applying: change, to: read, expecting: base)
            } catch {
                self.publish(read)
                throw error
            }
            let saved = self.backend.setPositions(updated)
            self.publish(self.readPositions())
            guard saved else {
                PlatformLog.order.notice("the order could not be saved")
                throw OrderStoreError.io
            }
            PlatformLog.order.notice("wrote the order: \(change.moved.count) items moved")
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
        if error == .unanswered { return unansweredReason }
        return unreadableReason
    }

    // MARK: On the queue

    /// Reads and decodes the positions, then publishes the result to the cache, the subscribers and the
    /// availability.
    private func readNow() throws(OrderStoreError) -> Snapshot {
        let read = readPositions()
        publish(read)
        return try read.get()
    }

    /// Reads and decodes the positions without publishing them.
    private func readPositions() -> Result<Snapshot, OrderStoreError> {
        dispatchPrecondition(condition: .onQueue(queue))
        return Result { () throws(OrderStoreError) in
            try Self.snapshot(of: backend.copyPositions(), file: preferencesFile, codec: codec)
        }
    }

    /// The positions to set, or why the write stops: the order changed, or the target can't be represented.
    private func positions(
        applying change: OrderChange, to read: Result<Snapshot, OrderStoreError>, expecting base: BarOrder
    ) throws(OrderStoreError) -> [String: NSNumber] {
        let current = try read.get()
        guard current.order == base else {
            PlatformLog.order.notice("the order changed since the move was planned")
            throw .stale
        }
        do {
            return try codec.applying(change, to: current.positions)
        } catch {
            PlatformLog.order.notice("the order can't be written without moving items that didn't move")
            throw error
        }
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

    /// Runs `body` on the queue, giving up on it after the deadline. The queue is serial, so a stuck call holds
    /// every later one back: each of those expires on its own deadline too.
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await Deadline.run(
                within: timeout(), { try await self.runUnbounded(body) },
                expired: {
                    PlatformLog.order.notice("macOS didn't answer a call to the order store in time")
                    self.onStall(self)
                },
                late: { [onAnswered] _ in onAnswered() }
            )
        } catch is Deadline.Expired {
            throw OrderStoreError.unanswered
        }
    }

    private func runUnbounded<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Self.run(on: queue, body)
    }

    // MARK: Helpers

    private static func run<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    /// Nil from the preferences is judged by the order file, as a grant judges it: an unreadable file is no
    /// access, a file without positions in the measured format is an unknown format, and positions the
    /// preferences can't see are no access.
    private static func snapshot(of value: Any?, file: URL, codec: OrderFileCodec) throws(OrderStoreError) -> Snapshot {
        guard let value else {
            _ = try decodeFile(at: file)
            throw .noAccess
        }
        let positions = try codec.positions(from: value)
        return Snapshot(order: codec.order(of: positions), positions: positions)
    }

    /// The order an order file holds: `noAccess` when it can't be read, `unsupportedFormat` when it has no
    /// positions in the measured format.
    static func decodeFile(at file: URL) throws(OrderStoreError) -> BarOrder {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            PlatformLog.order.notice("the order file could not be read: \(error.localizedDescription, privacy: .private)")
            throw .noAccess
        }
        return try OrderFileCodec().decode(file: data)
    }

    /// A watch on `container`'s preferences folder, which macOS changes by replacing the order file. Its events
    /// arrive on `queue` once it is resumed; cancelling it closes the folder.
    static func preferencesWatcher(container: URL, queue: DispatchQueue) throws(OrderStoreError) -> any DispatchSourceFileSystemObject {
        let directory = container.appending(path: "Library/Preferences", directoryHint: .isDirectory)
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
    static func drawnKeysReader(queue: AXQueue, own: AppID) -> DrawnKeysReader {
        { entries in
            let timeout = queue.messagingTimeout
            return await queue.run {
                guard let snapshot = MenuBarAgentReader.read(timeout: timeout) else { return [] }
                var owners: [pid_t: ItemOwner] = [:]
                for pid in Set(snapshot.groups.map(\.pid)) { owners[pid] = OwnerResolver27.owner(of: pid) }
                return drawnKeys(in: snapshot, owners: owners, entries: entries, own: own)
            }
        }
    }

    /// The keys of these drawn items, built by the assembly the inventory uses. It is given no hidden modules, so none
    /// is counted as drawn, but their entries are not withheld either: while a module is hidden, a drawn item's
    /// positional key here may differ from the one the inventory gives it.
    static func drawnKeys(in snapshot: BarSnapshot, owners: [pid_t: ItemOwner], entries: [String: Double], own: AppID?) -> Set<ItemKey> {
        let drawn = InventoryAssembly.pass(
            snapshot: snapshot, owners: owners, listings: [:], entries: entries, concealed: [], own: own
        ).drawn ?? []
        return Set(drawn.flatMap(\.items).map(\.key))
    }
}
