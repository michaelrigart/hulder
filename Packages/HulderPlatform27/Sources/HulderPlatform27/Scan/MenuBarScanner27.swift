import AppKit
import HulderCore
import os

/// Scans the bar when it may have changed: at start, when the running apps change, on request, and when
/// MenuBarAgent creates or destroys an element. It never polls. A trigger during a pass schedules exactly one more.
final class MenuBarScanner27: Sendable {
    typealias Entries = @Sendable () async -> [String: Double]?

    private let queue: AXQueue
    private let trust: @Sendable () -> AsyncStream<Bool>
    private let apps: @Sendable () -> AsyncStream<Set<AppID>>
    private let entries: Entries
    private let sessions = OSAllocatedUnfairLock<[UUID: Session]>(initialState: [:])

    /// `entries` supplies the order file's entries, or nil when they are unreadable.
    init(
        queue: AXQueue,
        trust: @escaping @Sendable () -> AsyncStream<Bool>,
        apps: @escaping @Sendable () -> AsyncStream<Set<AppID>>,
        entries: @escaping Entries
    ) {
        self.queue = queue
        self.trust = trust
        self.apps = apps
        self.entries = entries
    }

    func scans() -> AsyncStream<[AppScan]> {
        AsyncStream { continuation in
            let session = Session(queue: queue, entries: entries, continuation: continuation)
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

    private struct Gathered: Sendable {
        var snapshot: BarSnapshot?
        var owners: [pid_t: ItemOwner]
        var running: Set<AppID>
        var agentPID: pid_t?
    }

    private final class Session: Sendable {
        private struct State {
            var trusted = false
            var running = false
            var again = false
            var stopped = false
            var previousOwners: [ItemOwner] = []
            var agentObserver: AXAppObserver?
            var observedAgent: pid_t?
            var tasks: [Task<Void, Never>] = []
        }

        private static let agentNotifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification]

        private let queue: AXQueue
        private let entries: Entries
        private let continuation: AsyncStream<[AppScan]>.Continuation
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(queue: AXQueue, entries: @escaping Entries, continuation: AsyncStream<[AppScan]>.Continuation) {
            self.queue = queue
            self.entries = entries
            self.continuation = continuation
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

        private func trustChanged(_ trusted: Bool) async {
            let observer = state.withLock { state -> AXAppObserver? in
                state.trusted = trusted
                guard !trusted else { return nil }
                defer { state.agentObserver = nil; state.observedAgent = nil }
                return state.agentObserver
            }
            observer?.invalidate()
            guard trusted else { return }
            await observeAgent()
            trigger()
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
                PlatformLog.scan.notice("MenuBarAgent could not be observed; item changes will not be seen")
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
                let (scans, agentPID) = await pass()
                let (stopped, observed) = state.withLock { ($0.stopped, $0.observedAgent) }
                if stopped { return }
                continuation.yield(scans)
                if let agentPID, agentPID != observed { await observeAgent() }
                let more = state.withLock { state -> Bool in
                    if state.again, !state.stopped {
                        state.again = false
                        return true
                    }
                    state.running = false
                    return false
                }
                if !more { return }
            }
        }

        private func pass() async -> (scans: [AppScan], agentPID: pid_t?) {
            let entries = await entries()
            let timeout = queue.messagingTimeout
            let gathered = await queue.run { () -> Gathered in
                let snapshot = MenuBarAgentReader.read(timeout: timeout)
                var owners: [pid_t: ItemOwner] = [:]
                var running = Set<AppID>()
                for app in NSWorkspace.shared.runningApplications {
                    guard let owner = OwnerResolver27.owner(of: app), let appID = owner.appID else { continue }
                    owners[app.processIdentifier] = owner
                    running.insert(appID)
                }
                for group in snapshot?.groups ?? [] where owners[group.pid] == nil {
                    owners[group.pid] = OwnerResolver27.owner(of: group.pid)
                }
                return Gathered(snapshot: snapshot, owners: owners, running: running, agentPID: MenuBarAgentReader.agentPID())
            }
            if gathered.snapshot == nil { PlatformLog.scan.notice("the bar could not be read") }

            let listings = await listings(for: gathered)
            let previous = state.withLock { $0.previousOwners }
            let scans = InventoryAssembly.scans(
                snapshot: gathered.snapshot, owners: gathered.owners, listings: listings,
                entries: entries, running: gathered.running, previousOwners: previous
            )
            if gathered.snapshot != nil {
                let owners = scans.map(\.owner)
                state.withLock { $0.previousOwners = owners }
            }
            return (scans, gathered.agentPID)
        }

        /// The extras listing of each drawn owner except MenuBarAgent, which has none. It supplies names only.
        private func listings(for gathered: Gathered) async -> [pid_t: [RawItem]] {
            guard let snapshot = gathered.snapshot else { return [:] }
            let pids = Set(snapshot.groups.map(\.pid)).filter {
                gathered.owners[$0]?.appID?.bundleID != MenuBarAgentReader.agentBundleID
            }
            let timeout = queue.messagingTimeout
            return await withTaskGroup(of: (pid_t, [RawItem]?).self) { [queue] group in
                for pid in pids {
                    group.addTask {
                        let items = await queue.run { () -> [RawItem]? in
                            guard case .items(let items) = ExtrasMenuBarReader.readItems(pid: pid, timeout: timeout) else { return nil }
                            return items
                        }
                        return (pid, items)
                    }
                }
                var result: [pid_t: [RawItem]] = [:]
                for await (pid, items) in group { if let items { result[pid] = items } }
                return result
            }
        }
    }
}
