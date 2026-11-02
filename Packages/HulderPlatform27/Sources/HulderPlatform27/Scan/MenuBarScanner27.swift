import AppKit
import HulderCore
import os

/// Scans the bar when it may have changed: at start, when the running apps change, on request, and when
/// MenuBarAgent creates or destroys an element. It never polls. A trigger during a pass schedules exactly one more.
final class MenuBarScanner27: Sendable {
    typealias Entries = @Sendable () async -> [String: Double]?
    /// Which of the running apps the live concealment hides.
    typealias Concealed = @Sendable (_ running: Set<AppID>) async -> Set<AppID>

    private let queue: AXQueue
    private let trust: @Sendable () -> AsyncStream<Bool>
    private let apps: @Sendable () -> AsyncStream<Set<AppID>>
    private let entries: Entries
    private let concealed: Concealed
    private let own: AppID
    private let sessions = OSAllocatedUnfairLock<[UUID: Session]>(initialState: [:])
    private let drawnHub = DrawnHub()

    /// `entries` supplies the order file's entries, or nil when they are unreadable. `concealed` names the apps
    /// the live concealment hides; only those can have items that the bar doesn't draw. `own` is Hulder.
    init(
        queue: AXQueue,
        trust: @escaping @Sendable () -> AsyncStream<Bool>,
        apps: @escaping @Sendable () -> AsyncStream<Set<AppID>>,
        entries: @escaping Entries,
        concealed: @escaping Concealed,
        own: AppID
    ) {
        self.queue = queue
        self.trust = trust
        self.apps = apps
        self.entries = entries
        self.concealed = concealed
        self.own = own
    }

    func scans() -> AsyncStream<ScanPass> {
        AsyncStream { continuation in
            let session = Session(
                queue: queue, entries: entries, concealed: concealed, own: own, continuation: continuation,
                onDrawn: { [drawnHub] in drawnHub.publish($0) })
            let id = UUID()
            sessions.withLock { $0[id] = session }
            session.start(trust: trust(), apps: apps())
            continuation.onTermination = { [weak self] _ in
                self?.sessions.withLock { $0[id] = nil }
                session.stop()
            }
        }
    }

    func requestScan() {
        sessions.withLock { Array($0.values) }.forEach { $0.trigger() }
    }

    /// The processes that draw an item in the latest pass that could read the bar, with the current set first.
    /// Empty until a pass has finished. A process counts whether or not anything resolves its owner.
    func drawnProcesses() -> AsyncStream<Set<pid_t>> { drawnHub.stream() }

    private final class DrawnHub: Sendable {
        private struct State {
            var latest: Set<pid_t> = []
            var continuations: [UUID: AsyncStream<Set<pid_t>>.Continuation] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func stream() -> AsyncStream<Set<pid_t>> {
            AsyncStream { continuation in
                let id = UUID()
                state.withLock { state in
                    state.continuations[id] = continuation
                    continuation.yield(state.latest)
                }
                continuation.onTermination = { [state] _ in state.withLock { $0.continuations[id] = nil } }
            }
        }

        func publish(_ pids: Set<pid_t>) {
            state.withLock { state in
                guard pids != state.latest else { return }
                state.latest = pids
                state.continuations.values.forEach { $0.yield(pids) }
            }
        }
    }

    private final class Session: Sendable {
        private struct State {
            var trusted = false
            var running = false
            var again = false
            var stopped = false
            var agentObserver: AXAppObserver?
            var observedAgent: pid_t?
            /// The agent pid whose observer could not be created, so the failure is logged once per pid.
            var unobservableAgent: pid_t?
            var tasks: [Task<Void, Never>] = []
        }

        private static let agentNotifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification]

        private let queue: AXQueue
        private let entries: Entries
        private let concealed: Concealed
        private let own: AppID
        private let continuation: AsyncStream<ScanPass>.Continuation
        private let onDrawn: @Sendable (Set<pid_t>) -> Void
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(
            queue: AXQueue, entries: @escaping Entries, concealed: @escaping Concealed, own: AppID,
            continuation: AsyncStream<ScanPass>.Continuation, onDrawn: @escaping @Sendable (Set<pid_t>) -> Void
        ) {
            self.queue = queue
            self.entries = entries
            self.concealed = concealed
            self.own = own
            self.continuation = continuation
            self.onDrawn = onDrawn
        }

        func start(trust: AsyncStream<Bool>, apps: AsyncStream<Set<AppID>>) {
            let started = [
                Task { for await trusted in trust { await self.trustChanged(trusted) } },
                Task { for await _ in apps { self.trigger() } },
            ]
            let stopped = state.withLock { state -> Bool in
                state.tasks = started
                return state.stopped
            }
            if stopped { started.forEach { $0.cancel() } }
        }

        func stop() {
            let (tasks, observer) = state.withLock { state -> ([Task<Void, Never>], AXAppObserver?) in
                state.stopped = true
                defer { state.agentObserver = nil; state.observedAgent = nil }
                return (state.tasks, state.agentObserver)
            }
            tasks.forEach { $0.cancel() }
            observer?.invalidate()
        }

        /// Asks for a pass. Ignored until Accessibility is granted.
        func trigger() {
            let start = state.withLock { state -> Bool in
                guard state.trusted, !state.stopped else { return false }
                if state.running {
                    state.again = true
                    return false
                }
                state.running = true
                return true
            }
            if start { Task { await drain() } }
        }

        /// On a revocation it emits one unread pass, so the kept inventory is marked stale, and scans nothing more
        /// until Accessibility is granted again.
        private func trustChanged(_ trusted: Bool) async {
            let observer = state.withLock { state -> AXAppObserver? in
                let wasTrusted = state.trusted
                state.trusted = trusted
                if let pass = ScanFlow.decide(wasTrusted: wasTrusted, trusted: trusted, stopped: state.stopped, finished: nil) {
                    emit(pass, drawn: nil)
                }
                guard !trusted else { return nil }
                state.again = false
                defer { state.agentObserver = nil; state.observedAgent = nil }
                return state.agentObserver
            }
            observer?.invalidate()
            guard trusted else { return }
            await observeAgent()
            trigger()
        }

        /// Yields a pass to the scan stream and, when the pass read the bar, tells the drawn-processes stream what it
        /// drew. Called under the lock, so the order of emissions is the order of decisions.
        private func emit(_ pass: ScanPass, drawn: Set<pid_t>?) {
            continuation.yield(pass)
            if let drawn { onDrawn(drawn) }
        }

        /// Watches MenuBarAgent's application element for items appearing and disappearing.
        private func observeAgent() async {
            let timeout = queue.messagingTimeout
            let notifications = Self.agentNotifications
            let onChange: @Sendable (pid_t) -> Void = { [weak self] _ in self?.trigger() }
            let attached = await queue.run { () -> (pid: pid_t, observer: AXAppObserver?)? in
                guard let pid = MenuBarAgentReader.agentPID() else { return nil }
                return (pid, AXAppObserver.attach(pid: pid, notifications: notifications, timeout: timeout, handler: onChange))
            }
            guard let attached else {
                PlatformLog.scan.notice("MenuBarAgent is not running; item changes will not be observed")
                return
            }
            guard let observer = attached.observer else {
                let firstFailure = state.withLock { state -> Bool in
                    defer { state.unobservableAgent = attached.pid }
                    return state.unobservableAgent != attached.pid
                }
                if firstFailure { PlatformLog.scan.notice("MenuBarAgent could not be observed; item changes will not be seen") }
                return
            }
            let (old, keep) = state.withLock { state -> (AXAppObserver?, Bool) in
                guard state.trusted, !state.stopped else { return (nil, false) }
                defer { state.agentObserver = observer; state.observedAgent = attached.pid }
                return (state.agentObserver, true)
            }
            old?.invalidate()
            if !keep { observer.invalidate() }
        }

        private func drain() async {
            while true {
                let (finished, agentPID, drawn) = await pass()
                // The decision and the yield happen under the lock, so a revocation can't slip between them.
                let (stopped, observed) = state.withLock { state -> (Bool, pid_t?) in
                    if let pass = ScanFlow.decide(
                        wasTrusted: state.trusted, trusted: state.trusted, stopped: state.stopped, finished: finished)
                    {
                        emit(pass, drawn: drawn)
                    }
                    return (state.stopped, state.observedAgent)
                }
                if stopped { return }
                if let agentPID, agentPID != observed { await observeAgent() }
                let more = state.withLock { state -> Bool in
                    if state.again, state.trusted, !state.stopped {
                        state.again = false
                        return true
                    }
                    state.running = false
                    return false
                }
                if !more { return }
            }
        }

        private func pass() async -> (finished: ScanPass, agentPID: pid_t?, drawn: Set<pid_t>?) {
            let entries = await entries()
            let reading = await BarReader.read(queue: queue)
            if reading.snapshot == nil { PlatformLog.scan.notice("the bar could not be read") }

            let concealed = await concealed(reading.running)
            let pass = InventoryAssembly.pass(
                snapshot: reading.snapshot, owners: reading.owners, listings: reading.listedItems,
                entries: entries, concealed: concealed, own: own)
            return (pass, reading.agentPID, InventoryAssembly.drawnProcesses(of: reading.snapshot))
        }
    }
}
