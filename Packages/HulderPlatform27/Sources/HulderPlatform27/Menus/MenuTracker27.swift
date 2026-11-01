import Darwin
import Foundation
import HulderCore
import os

/// What the tracker needs from Accessibility, so tests can fake it. Calls block, so the tracker makes them on
/// an `AXQueue`.
protocol MenuWindowSource: Sendable {
    /// Starts watching `pid`; nil when that fails. The token names this observer alone.
    func attach(_ pid: pid_t) -> MenuObserverToken?
    /// Removes the observer the token names, and no other, so engines that watch the same app can't remove
    /// each other's.
    func detach(_ token: MenuObserverToken)
    /// Reads the app's windows once.
    func isOpen(_ pid: pid_t) -> Bool
    /// The apps that reported an event, which only means "read their windows again". Each call is an
    /// independent stream that ends with its consumer.
    func events() -> AsyncStream<pid_t>
}

struct MenuObserverToken: Hashable, Sendable {
    let rawValue: UInt64
}

enum WindowRule {
    static let tolerance = 2.0
    static let standardWindowSubrole = "AXStandardWindow"

    /// A window whose top edge sits at the bar's bottom edge.
    static func isAnchored(top: Double, barBottom: Double?) -> Bool {
        guard let barBottom else { return false }
        return abs(top - barBottom) <= tolerance
    }

    /// A menu or popover opened from the bar is anchored at the bar and is not a standard window. A maximized
    /// or tiled document window touches the bar too, but it is not a menu.
    static func isOpen(subrole: String?, top: Double, barBottom: Double?) -> Bool {
        subrole != standardWindowSubrole && isAnchored(top: top, barBottom: barBottom)
    }
}

/// Whether any app shows a menu, from Accessibility events on every running app. Events are hints: each one
/// makes the tracker read that app's windows again. Follows the Accessibility state: it attaches once trusted
/// and lets go when the grant is lost.
///
/// One engine serves every subscriber of `values()` and `trackingChanges()`: it starts with the first and
/// stops with the last, and each stream is independent and can start again after an earlier one ended.
final class MenuTracker27: Sendable {
    private struct Hub {
        var open = false
        var tracking = MenuTracking.unavailable
        var openSubscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]
        var trackingSubscribers: [UUID: AsyncStream<MenuTracking>.Continuation] = [:]
        var engine: Session?
        /// The previous engine's teardown, which the next engine waits for before it attaches.
        var lastShutdown: Task<Void, Never>?
    }

    private let source: any MenuWindowSource
    private let queue: AXQueue
    private let trust: @Sendable () -> AsyncStream<Bool>
    private let processes: @Sendable () -> AsyncStream<Set<pid_t>>
    private let launched: @Sendable () -> AsyncStream<pid_t>
    private let hub = OSAllocatedUnfairLock(initialState: Hub())

    /// Full only once attachment to the running apps has completed.
    var tracking: MenuTracking { hub.withLock { $0.tracking } }

    /// `launched` yields an app's pid when it has finished launching, which is when its Accessibility server exists.
    init(
        source: any MenuWindowSource,
        queue: AXQueue,
        trust: @escaping @Sendable () -> AsyncStream<Bool>,
        processes: @escaping @Sendable () -> AsyncStream<Set<pid_t>>,
        launched: @escaping @Sendable () -> AsyncStream<pid_t>
    ) {
        self.source = source
        self.queue = queue
        self.trust = trust
        self.processes = processes
        self.launched = launched
    }

    /// True while any app is open, with the current value first.
    func values() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let engine = hub.withLock { hub -> Session? in
                hub.openSubscribers[id] = continuation
                continuation.yield(hub.open)
                return startEngineIfNeeded(&hub)
            }
            startIfNew(engine)
            continuation.onTermination = { [weak self] _ in self?.unsubscribe { $0.openSubscribers[id] = nil } }
        }
    }

    /// The capability, with the current value first: full once attachment has completed, unavailable while
    /// untrusted.
    func trackingChanges() -> AsyncStream<MenuTracking> {
        AsyncStream { continuation in
            let id = UUID()
            let engine = hub.withLock { hub -> Session? in
                hub.trackingSubscribers[id] = continuation
                continuation.yield(hub.tracking)
                return startEngineIfNeeded(&hub)
            }
            startIfNew(engine)
            continuation.onTermination = { [weak self] _ in self?.unsubscribe { $0.trackingSubscribers[id] = nil } }
        }
    }

    private func startEngineIfNeeded(_ hub: inout Hub) -> Session? {
        guard hub.engine == nil else { return nil }
        let engine = Session(source: source, queue: queue, after: hub.lastShutdown) { [weak self] id, open, tracking in
            self?.publish(engine: id, open: open, tracking: tracking)
        }
        hub.engine = engine
        return engine
    }

    private func startIfNew(_ engine: Session?) {
        engine?.start(trust: trust(), processes: processes(), launched: launched())
    }

    private func unsubscribe(_ remove: @Sendable (inout Hub) -> Void) {
        hub.withLock { hub in
            remove(&hub)
            guard let engine = hub.engine, hub.openSubscribers.isEmpty, hub.trackingSubscribers.isEmpty else { return }
            hub.engine = nil
            hub.open = false
            hub.tracking = .unavailable
            // Only creates the task: the cancelling and detaching happen in it, off this lock.
            hub.lastShutdown = engine.stop()
        }
    }

    private func publish(engine id: UUID, open: Bool?, tracking: MenuTracking?) {
        hub.withLock { hub in
            guard hub.engine?.id == id else { return }
            if let open, open != hub.open {
                hub.open = open
                hub.openSubscribers.values.forEach { $0.yield(open) }
            }
            if let tracking, tracking != hub.tracking {
                hub.tracking = tracking
                hub.trackingSubscribers.values.forEach { $0.yield(tracking) }
            }
        }
    }

    private actor Session {
        typealias Publish = @Sendable (_ engine: UUID, _ open: Bool?, _ tracking: MenuTracking?) -> Void

        nonisolated let id = UUID()
        private let source: any MenuWindowSource
        private let queue: AXQueue
        private let previous: Task<Void, Never>?
        private let publisher: Publish
        private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

        private struct Failure {
            var launchRetries = 1
            var changeRetries = 1
        }

        private enum Trigger {
            case grant, processChange, launch
        }

        private var trusted = false
        private var processes: Set<pid_t> = []
        private var attached: [pid_t: MenuObserverToken] = [:]
        private var attaching: Set<pid_t> = []
        /// Apps whose attach failed, with the retries they have left. Cleared with the grant.
        private var failures: [pid_t: Failure] = [:]
        /// Apps that finished launching while their attach was in flight.
        private var launchSignalled: Set<pid_t> = []
        private var state = MenuOpenState()

        init(source: any MenuWindowSource, queue: AXQueue, after previous: Task<Void, Never>?, publish: @escaping Publish) {
            self.source = source
            self.queue = queue
            self.previous = previous
            self.publisher = publish
        }

        nonisolated func start(trust: AsyncStream<Bool>, processes: AsyncStream<Set<pid_t>>, launched: AsyncStream<pid_t>) {
            let events = source.events()
            let started = [
                Task { for await trusted in trust { await self.trustChanged(trusted) } },
                Task { for await pids in processes { await self.processesChanged(pids) } },
                Task { for await pid in launched { await self.finishedLaunching(pid) } },
                Task { for await pid in events { await self.event(pid) } },
            ]
            tasks.withLock { $0 = started }
        }

        /// Ends the engine. Only creates the returned task, which cancels the inputs and detaches everything;
        /// it finishes when that is done.
        nonisolated func stop() -> Task<Void, Never> {
            let tasks = tasks
            return Task {
                tasks.withLock { $0 }.forEach { $0.cancel() }
                await self.shutdown()
            }
        }

        private func shutdown() async {
            trusted = false
            let released = Array(attached.values)
            attached = [:]
            await detach(released)
        }

        private func trustChanged(_ isTrusted: Bool) async {
            guard isTrusted != trusted else { return }
            trusted = isTrusted
            failures = [:]
            launchSignalled = []
            if isTrusted {
                _ = await attachMissing(trigger: .grant)
                guard trusted else { return }
                publisher(id, nil, .full)
                await readAll(processes)
            } else {
                let released = Array(attached.values)
                attached = [:]
                state.removeAll()
                publisher(id, false, .unavailable)
                await detach(released)
            }
        }

        private func processesChanged(_ new: Set<pid_t>) async {
            let removed = processes.subtracting(new)
            let added = new.subtracting(processes)
            processes = new
            for pid in removed {
                state.remove(pid)
                failures[pid] = nil
                launchSignalled.remove(pid)
            }
            publisher(id, state.anyOpen, nil)
            let released = removed.compactMap { attached.removeValue(forKey: $0) }
            await detach(released)
            guard trusted else { return }
            let fresh = await attachMissing(trigger: .processChange)
            await readAll(added.union(fresh).intersection(processes))
        }

        private func finishedLaunching(_ pid: pid_t) async {
            guard trusted, processes.contains(pid), attached[pid] == nil else { return }
            if attaching.contains(pid) {
                launchSignalled.insert(pid)
                return
            }
            if await attachMissing([pid], trigger: .launch).contains(pid) { await refresh(pid) }
        }

        private func event(_ pid: pid_t) async {
            guard trusted, processes.contains(pid) else { return }
            await refresh(pid)
        }

        /// The apps to attach now. An app that failed gets one more try on its finished launching and one on the
        /// next change of the process set, then stays unattached until the grant is given again.
        private func claim(_ candidates: Set<pid_t>, for trigger: Trigger) -> Set<pid_t> {
            var claimed: Set<pid_t> = []
            for pid in candidates where processes.contains(pid) && attached[pid] == nil && !attaching.contains(pid) {
                guard var failure = failures[pid] else {
                    claimed.insert(pid)
                    continue
                }
                switch trigger {
                case .grant:
                    claimed.insert(pid)
                case .processChange where failure.changeRetries > 0:
                    failure.changeRetries -= 1
                    claimed.insert(pid)
                case .launch where failure.launchRetries > 0:
                    failure.launchRetries -= 1
                    claimed.insert(pid)
                default:
                    break
                }
                failures[pid] = failure
            }
            return claimed
        }

        /// Attaches to the running apps that aren't attached, and returns the ones that succeeded. While untrusted
        /// nothing is tried.
        private func attachMissing(_ candidates: Set<pid_t>? = nil, trigger: Trigger) async -> Set<pid_t> {
            guard trusted else { return [] }
            let todo = claim(candidates ?? processes, for: trigger)
            guard !todo.isEmpty else { return [] }
            attaching.formUnion(todo)
            await previous?.value
            var fresh: Set<pid_t> = []
            var unwanted: [MenuObserverToken] = []
            // Each result is settled as it arrives, so a slow attach doesn't hold up the others' bookkeeping.
            await withTaskGroup(of: (pid_t, MenuObserverToken?).self) { group in
                for pid in todo {
                    group.addTask { [source, queue] in (pid, await queue.run { source.attach(pid) }) }
                }
                for await (pid, token) in group {
                    attaching.remove(pid)
                    let launched = launchSignalled.remove(pid) != nil
                    if let token {
                        // The grant can be lost, or an app can quit, while the attach runs.
                        if trusted, processes.contains(pid) {
                            attached[pid] = token
                            failures[pid] = nil
                            fresh.insert(pid)
                        } else {
                            unwanted.append(token)
                        }
                    } else if trusted {
                        if failures[pid] == nil {
                            failures[pid] = Failure()
                            PlatformLog.menus.notice("menu tracking could not attach to pid \(pid)")
                        }
                        // It finished launching while this attach ran: try once more, now.
                        if launched, !claim([pid], for: .launch).isEmpty {
                            attaching.insert(pid)
                            group.addTask { [source, queue] in (pid, await queue.run { source.attach(pid) }) }
                        }
                    }
                }
            }
            await detach(unwanted)
            return fresh
        }

        private func detach(_ tokens: [MenuObserverToken]) async {
            guard !tokens.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for token in tokens {
                    group.addTask { [source, queue] in await queue.run { source.detach(token) } }
                }
            }
        }

        private func readAll(_ pids: Set<pid_t>) async {
            await withTaskGroup(of: Void.self) { group in
                for pid in pids { group.addTask { await self.refresh(pid) } }
            }
        }

        private func refresh(_ pid: pid_t) async {
            let generation = state.begin(pid)
            let open = await queue.run { [source] in source.isOpen(pid) }
            state.finish(pid, generation: generation, isOpen: open)
            publisher(id, state.anyOpen, nil)
        }
    }
}
