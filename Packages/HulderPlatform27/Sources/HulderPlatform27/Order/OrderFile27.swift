import Foundation
import HulderCore
import Synchronization

/// The order file as the platform sees it: the store opened on the granted container, and whether reordering
/// is available. Reordering needs access to the container, the preferences functions, and positions in the
/// measured format; once a store is open, its latest read decides the last. A store, once open, serves the
/// rest of the run, so whoever holds it keeps seeing changes: it reads the order again on a change in the
/// container's preferences folder and on each scan pass, as the folder can lag the preferences. While access is
/// granted but no store opens, a change in that folder, or a grant, tries again.
final class OrderFile27: Sendable {
    static let notGranted = "Access to the menu bar order file is not granted."

    private struct State {
        var store: OrderStore27?
        /// Why no store could be opened, once an evaluation has found out.
        var failure: Availability?
        var emitted: Availability?
        var subscribers: [UUID: AsyncStream<Availability>.Continuation] = [:]
        /// The latest evaluation; each one waits for the one before.
        var evaluation: Task<Void, Never>?
        var onOrderChange: (@Sendable () -> Void)?
        /// The watch that retries opening, and the container it watches.
        var retry: (container: URL, watcher: any DispatchSourceFileSystemObject)?
        /// How many calls missed their deadline and macOS hasn't answered yet. While there are any, no further
        /// blocking call starts: each holds a thread.
        var outstanding = 0
    }

    private enum Opening {
        case opened(OrderStore27)
        /// `retryOn` is the container whose changes could make it open, or nil when no file change can help.
        case unavailable(String, retryOn: URL?)
    }

    private let container: @Sendable () async -> URL?
    private let makeBackend: @Sendable (URL) -> any PositionsBackend
    private let backups: URL
    private let drawnKeys: OrderStore27.DrawnKeysReader
    private let timeout: @Sendable () -> Duration
    private let retryQueue = DispatchQueue(label: "com.michaelrigart.hulder.order-retry", qos: .utility)
    private let state = Mutex(State())

    init(
        container: @escaping @Sendable () async -> URL?,
        makeBackend: @escaping @Sendable (URL) -> any PositionsBackend,
        backups: URL,
        drawnKeys: @escaping OrderStore27.DrawnKeysReader,
        timeout: @escaping @Sendable () -> Duration = { OrderStore27.readTimeout }
    ) {
        self.container = container
        self.makeBackend = makeBackend
        self.backups = backups
        self.drawnKeys = drawnKeys
        self.timeout = timeout
    }

    deinit {
        state.withLock { $0.retry }?.watcher.cancel()
    }

    /// Starts the first evaluation. From the moment a store opens, each of its order changes calls `onOrderChange`.
    func start(onOrderChange: @escaping @Sendable () -> Void) {
        state.withLock { $0.onOrderChange = onOrderChange }
        _ = enqueueEvaluation()
    }

    /// Evaluates again, after any evaluation under way, and returns once done. Call it after a grant.
    func evaluate() async {
        await enqueueEvaluation().value
    }

    /// Whether reordering is available: the current value first, once known, then each change.
    func reorderingChanges() -> AsyncStream<Availability> {
        let (stream, continuation) = AsyncStream.makeStream(of: Availability.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { state in
            if let emitted = state.emitted { continuation.yield(emitted) }
            state.subscribers[id] = continuation
        }
        return stream
    }

    /// The store, after the evaluation under way, when reordering is available.
    func availableStore() async -> OrderStore27? {
        await state.withLock { $0.evaluation }?.value
        return state.withLock { state in
            state.store.flatMap { $0.availability == .available ? $0 : nil }
        }
    }

    /// The open store's positions as last read, or nil before one is open.
    func entries() -> [String: Double]? {
        state.withLock { $0.store }?.entries
    }

    /// The open store's positions after reading them again, the way a folder change does, or nil when the pass
    /// has no order to go by: no store is open, or the read just made failed (no access, an unknown format, no
    /// answer). A store keeps the positions of its last successful read, which are not what this pass saw. The file
    /// in the folder can lag the preferences by seconds, so a scan pass reads here rather than waiting for a folder
    /// change. With no store open nothing is evaluated, so passes don't multiply openings.
    func currentEntries() async -> [String: Double]? {
        if state.withLock({ $0.store }) != nil { await enqueueEvaluation().value }
        guard let store = state.withLock({ $0.store }), store.availability == .available else { return nil }
        return store.entries
    }

    private func enqueueEvaluation() -> Task<Void, Never> {
        state.withLock { state in
            let previous = state.evaluation
            let next = Task {
                await previous?.value
                await self.evaluateNow()
            }
            state.evaluation = next
            return next
        }
    }

    /// Every blocking call has a deadline, so the next evaluation never waits long for this one. While a call that
    /// missed its deadline is unanswered, no other starts: reordering stays unavailable for the same reason, and
    /// the last answer enqueues the next evaluation. A folder change, a grant and an answer all come here.
    private func evaluateNow() async {
        if state.withLock({ state in
            if state.outstanding > 0 { state.failure = .unavailable(OrderStore27.unansweredReason) }
            return state.outstanding > 0
        }) {
            emit()
            return
        }
        if let store = state.withLock({ $0.store }) {
            // A grant can bring back access the store lost, and a folder change is a new order to publish; the
            // read does both. One that stalls has already dropped the store.
            _ = try? await store.read()
        } else {
            switch await open() {
            case .opened(let store):
                adopt(store)
            case .unavailable(let reason, let container):
                state.withLock { $0.failure = .unavailable(reason) }
                await retry(on: container)
            }
        }
        emit()
    }

    /// The store's queue is its own, so an opening that never returns blocks nothing after it. One that returns
    /// after its deadline was abandoned: its store is closed and nothing it read is published; the evaluation that
    /// follows its answer opens a store of its own.
    private func open() async -> Opening {
        let container: URL?
        do {
            container = try await grantedContainer()
        } catch {
            return .unavailable(OrderStore27.unansweredReason, retryOn: nil)
        }
        guard let container else { return .unavailable(Self.notGranted, retryOn: nil) }
        let backend = makeBackend(container)
        // No change to the file brings back a missing function.
        if case .unavailable(let reason) = backend.availability { return .unavailable(reason, retryOn: nil) }
        let (backups, drawnKeys, timeout, countStall) = (backups, drawnKeys, timeout, countStall)
        let onAvailabilityChange: @Sendable () -> Void = { [weak self] in self?.emit() }
        let onStall: @Sendable (OrderStore27) -> Void = { [weak self] in self?.stalled($0) }
        let onAnswered: @Sendable () -> Void = { [weak self] in self?.answered() }
        let onFolderChange: @Sendable () -> Void = { [weak self] in _ = self?.enqueueEvaluation() }
        do {
            return .opened(try await Deadline.run(within: timeout(), {
                try await OrderStore27.open(
                    backend: backend, container: container, backups: backups, drawnKeys: drawnKeys, timeout: timeout,
                    onAvailabilityChange: onAvailabilityChange, onStall: onStall, onAnswered: onAnswered,
                    onFolderChange: onFolderChange
                )
            }, expired: countStall, late: { result in
                if case .success(let store) = result { store.shutDown() }
                onAnswered()
            }))
        } catch is Deadline.Expired {
            return .unavailable(OrderStore27.unansweredReason, retryOn: container)
        } catch {
            return .unavailable(OrderStore27.reason(for: error as? OrderStoreError ?? .io), retryOn: container)
        }
    }

    /// The granted container, bounded like every other call that can block. Throws `Deadline.Expired`.
    private func grantedContainer() async throws -> URL? {
        let (container, countStall) = (container, countStall)
        let onAnswered: @Sendable () -> Void = { [weak self] in self?.answered() }
        return try await Deadline.run(within: timeout(), { await container() }, expired: countStall, late: { _ in onAnswered() })
    }

    private var countStall: @Sendable () -> Void {
        { [weak self] in self?.state.withLock { $0.outstanding += 1 } }
    }

    /// macOS answered a call that missed its deadline. When none is left outstanding, that is the event to
    /// evaluate again on; the evaluation has deadlines of its own.
    private func answered() {
        let last = state.withLock { state in
            state.outstanding = max(0, state.outstanding - 1)
            return state.outstanding == 0
        }
        if last { _ = enqueueEvaluation() }
    }

    /// A call to the open store missed its deadline. Whatever it was, the store's queue may be stuck behind it
    /// and every later call would wait there. Forget the store at once, so nothing reads it as available; the
    /// evaluation after macOS answers opens a new one on a queue of its own. A call that was not the current
    /// store's only counts. Folder watching is left to the evaluation the answer enqueues. Nothing is retried: a write that stalled is reported by its caller and not repeated.
    private func stalled(_ store: OrderStore27) {
        let dropped = state.withLock { state in
            state.outstanding += 1
            guard state.store === store else { return false }
            state.store = nil
            state.failure = .unavailable(OrderStore27.unansweredReason)
            return true
        }
        guard dropped else { return }
        store.shutDown()
        emit()
    }

    /// Watches `container`'s preferences folder and evaluates again on each change; nil stops watching.
    private func retry(on container: URL?) async {
        if state.withLock({ $0.retry?.container }) == container { return }
        stopRetrying()
        guard let container else { return }
        let queue = retryQueue
        let watcher = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? OrderStore27.preferencesWatcher(container: container, queue: queue)) }
        }
        guard let watcher else { return }
        watcher.setEventHandler { [weak self] in _ = self?.enqueueEvaluation() }
        watcher.resume()
        state.withLock { $0.retry = (container, watcher) }
    }

    private func stopRetrying() {
        let retry = state.withLock { state in
            defer { state.retry = nil }
            return state.retry
        }
        retry?.watcher.cancel()
    }

    /// Keeps the store, then forwards its order changes; its first, sent at once, is the order just read.
    private func adopt(_ store: OrderStore27) {
        stopRetrying()
        let onOrderChange = state.withLock { state in
            state.store = store
            state.failure = nil
            return state.onOrderChange
        }
        guard let onOrderChange else { return }
        let changes = store.changes()
        Task {
            for await _ in changes { onOrderChange() }
        }
    }

    /// Sends the current availability to the subscribers when it differs from the last one sent.
    private func emit() {
        let changed = state.withLock { state -> Availability? in
            guard let current = state.store?.availability ?? state.failure, current != state.emitted else { return nil }
            state.emitted = current
            for subscriber in state.subscribers.values { subscriber.yield(current) }
            return current
        }
        switch changed {
        case .available: PlatformLog.order.notice("reordering is available")
        case .unavailable: PlatformLog.order.notice("reordering is unavailable")
        case nil: break
        }
    }
}
