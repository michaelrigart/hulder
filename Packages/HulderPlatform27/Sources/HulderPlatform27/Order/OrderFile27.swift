import Foundation
import HulderCore
import Synchronization

/// The order file as the platform sees it: the store opened on the granted container, and whether reordering
/// is available. Reordering needs access to the container, the preferences functions, and positions in the
/// measured format; once a store is open, its latest read decides the last. A store, once open, serves the
/// rest of the run, so whoever holds it keeps seeing changes.
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
    }

    private enum Opening {
        case opened(OrderStore27)
        case unavailable(String)
    }

    private let container: @Sendable () async -> URL?
    private let makeBackend: @Sendable (URL) -> any PositionsBackend
    private let backups: URL
    private let drawnKeys: OrderStore27.DrawnKeysReader
    private let state = Mutex(State())

    init(
        container: @escaping @Sendable () async -> URL?,
        makeBackend: @escaping @Sendable (URL) -> any PositionsBackend,
        backups: URL,
        drawnKeys: @escaping OrderStore27.DrawnKeysReader
    ) {
        self.container = container
        self.makeBackend = makeBackend
        self.backups = backups
        self.drawnKeys = drawnKeys
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

    /// The open store's positions, or nil before one is open.
    func entries() -> [String: Double]? {
        state.withLock { $0.store }?.entries
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

    private func evaluateNow() async {
        if let store = state.withLock({ $0.store }) {
            // A grant can bring back access the store lost; the read reports the store's availability.
            _ = try? await store.read()
        } else {
            switch await open() {
            case .opened(let store): adopt(store)
            case .unavailable(let reason): state.withLock { $0.failure = .unavailable(reason) }
            }
        }
        emit()
    }

    private func open() async -> Opening {
        guard let container = await container() else { return .unavailable(Self.notGranted) }
        let backend = makeBackend(container)
        if case .unavailable(let reason) = backend.availability { return .unavailable(reason) }
        do {
            return .opened(try await OrderStore27.open(
                backend: backend, container: container, backups: backups, drawnKeys: drawnKeys,
                onAvailabilityChange: { [weak self] in self?.emit() }
            ))
        } catch {
            return .unavailable(OrderStore27.reason(for: error as? OrderStoreError ?? .io))
        }
    }

    /// Keeps the store, then forwards its order changes; its first, sent at once, is the order just read.
    private func adopt(_ store: OrderStore27) {
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
