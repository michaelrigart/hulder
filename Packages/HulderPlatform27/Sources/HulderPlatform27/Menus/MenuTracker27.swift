import CoreGraphics
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

    /// A window whose top edge sits at the bottom edge of the menu bar of the screen it is on. The screen is the
    /// one whose horizontal extent holds the window's centre; displays side by side never share one.
    static func isAnchored(frame: CGRect, edges: [BarEdge]) -> Bool {
        edges.contains { $0.xRange.contains(frame.midX) && abs(frame.minY - $0.bottom) <= tolerance }
    }

    /// A menu or popover opened from the bar is anchored at the bar and is not a standard window. A maximized
    /// or tiled document window touches the bar too, but it is not a menu.
    static func isOpen(subrole: String?, frame: CGRect, edges: [BarEdge]) -> Bool {
        subrole != standardWindowSubrole && isAnchored(frame: frame, edges: edges)
    }
}

/// Whether any app shows a menu, from Accessibility events on every watched process. Events are hints: each one
/// makes the tracker read that process's windows again. Follows the Accessibility state: it attaches once trusted
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
    private let covered: @Sendable () -> AsyncStream<Set<pid_t>>
    private let exits: @Sendable (pid_t) -> AsyncStream<Void>
    private let hub = OSAllocatedUnfairLock(initialState: Hub())

    /// Full only while every process in the coverage set is attached, with all of its notifications registered;
    /// partial otherwise. The set is the processes that draw an item on the bar, whoever they are, and the two system
    /// apps that own menus (Control Center and Notification Center).
    var tracking: MenuTracking { hub.withLock { $0.tracking } }

    /// `launched` yields an app's pid when it has finished launching, which is when its Accessibility server exists.
    /// `covered` yields the processes that full tracking needs, by pid: a process without a bundle identifier counts
    /// like any other. `exits` yields once when the process of a pid exits.
    init(
        source: any MenuWindowSource,
        queue: AXQueue,
        trust: @escaping @Sendable () -> AsyncStream<Bool>,
        processes: @escaping @Sendable () -> AsyncStream<Set<pid_t>>,
        launched: @escaping @Sendable () -> AsyncStream<pid_t>,
        covered: @escaping @Sendable () -> AsyncStream<Set<pid_t>>,
        exits: @escaping @Sendable (pid_t) -> AsyncStream<Void>
    ) {
        self.source = source
        self.queue = queue
        self.trust = trust
        self.processes = processes
        self.launched = launched
        self.covered = covered
        self.exits = exits
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
        let engine = Session(source: source, queue: queue, exits: exits, after: hub.lastShutdown) { [weak self] id, open, tracking in
            self?.publish(engine: id, open: open, tracking: tracking)
        }
        hub.engine = engine
        return engine
    }

    private func startIfNew(_ engine: Session?) {
        engine?.start(trust: trust(), processes: processes(), launched: launched(), covered: covered())
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

    /// The tracker's state machine. One set decides what is watched: the trackable apps (`processes`), every process
    /// that draws an item (`covered`), and every process that has drawn one and hasn't exited (`seen`). A pid is
    /// tested against that set and no other, so attaching, reading, handling events and dropping state can't
    /// disagree about who is watched. An observer lives as long as its process, not as long as its item is drawn.
    actor Session {
        typealias Publish = @Sendable (_ engine: UUID, _ open: Bool?, _ tracking: MenuTracking?) -> Void

        nonisolated let id = UUID()
        private let source: any MenuWindowSource
        private let queue: AXQueue
        private let exits: @Sendable (pid_t) -> AsyncStream<Void>
        private let previous: Task<Void, Never>?
        private let publisher: Publish
        private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
        /// Set when the engine is stopped. A cancelled task can still be handed input that was buffered before it
        /// was cancelled, so once this is set every handler does nothing.
        private let stopFlag = OSAllocatedUnfairLock(initialState: false)
        private var stopped: Bool { stopFlag.withLock { $0 } }

        private struct Failure {
            var launchRetries = 1
            var changeRetries = 1
        }

        private enum Trigger {
            case grant, processChange, launch
        }

        private var trusted = false
        /// False from the grant until its attach round has settled: until then the value stays unavailable, so a
        /// launch doesn't show a partial.
        private var settled = false
        private var processes: Set<pid_t> = []
        private var covered: Set<pid_t> = []
        /// The processes that have been covered and haven't exited. It survives a lost grant.
        private var seen: Set<pid_t> = []
        private var exitWatches: [pid_t: Task<Void, Never>] = [:]
        private var attached: [pid_t: MenuObserverToken] = [:]
        private var attaching: Set<pid_t> = []
        /// Processes whose attach failed, with the retries they have left. Cleared with the grant.
        private var failures: [pid_t: Failure] = [:]
        /// Processes that finished launching while their attach was in flight.
        private var launchSignalled: Set<pid_t> = []
        /// The covered processes without an observer in the last line logged.
        private var loggedUnobserved: Set<pid_t> = []
        private var state = MenuOpenState()

        private var watched: Set<pid_t> { processes.union(covered).union(seen) }

        init(
            source: any MenuWindowSource, queue: AXQueue, exits: @escaping @Sendable (pid_t) -> AsyncStream<Void>,
            after previous: Task<Void, Never>?, publish: @escaping Publish
        ) {
            self.source = source
            self.queue = queue
            self.exits = exits
            self.previous = previous
            self.publisher = publish
        }

        nonisolated func start(
            trust: AsyncStream<Bool>, processes: AsyncStream<Set<pid_t>>, launched: AsyncStream<pid_t>,
            covered: AsyncStream<Set<pid_t>>
        ) {
            let events = source.events()
            let started = [
                Task { for await trusted in trust { await self.trustChanged(trusted) } },
                Task { for await pids in processes { await self.processesChanged(pids) } },
                Task { for await pid in launched { await self.finishedLaunching(pid) } },
                Task { for await pid in events { await self.event(pid) } },
                Task { for await value in covered { await self.coveredChanged(value) } },
            ]
            tasks.withLock { $0 = started }
        }

        /// Ends the engine. Only creates the returned task, which cancels the inputs and detaches everything;
        /// it finishes when that is done.
        nonisolated func stop() -> Task<Void, Never> {
            let tasks = tasks
            stopFlag.withLock { $0 = true }
            return Task {
                tasks.withLock { $0 }.forEach { $0.cancel() }
                await self.shutdown()
            }
        }

        private func shutdown() async {
            trusted = false
            exitWatches.values.forEach { $0.cancel() }
            exitWatches = [:]
            let released = Array(attached.values)
            attached = [:]
            await detach(released)
        }

        func trustChanged(_ isTrusted: Bool) async {
            guard !stopped, isTrusted != trusted else { return }
            trusted = isTrusted
            settled = false
            failures = [:]
            launchSignalled = []
            loggedUnobserved = []
            if isTrusted {
                _ = await attachMissing(trigger: .grant)
                guard trusted, !stopped else { return }
                settled = true
                publishTracking()
                await readAll(watched)
            } else {
                let released = Array(attached.values)
                attached = [:]
                state.removeAll()
                publisher(id, false, .unavailable)
                await detach(released)
            }
        }

        func processesChanged(_ new: Set<pid_t>) async {
            guard !stopped else { return }
            let old = watched
            let left = processes.subtracting(new)
            processes = new
            await watchedChanged(from: old, reread: left)
        }

        func coveredChanged(_ new: Set<pid_t>) async {
            guard !stopped else { return }
            let old = watched
            let joined = new.subtracting(covered).subtracting(seen)
            covered = new
            watchExits(of: joined)
            await watchedChanged(from: old)
        }

        /// The process of `pid` exited. It leaves the watched set unless its item is still drawn: then it stays
        /// covered and keeps its observer until a scan stops drawing it. Either way it is read again, and an exited
        /// process reads as closed.
        func exited(_ pid: pid_t) async {
            guard !stopped, seen.contains(pid) else { return }
            let old = watched
            seen.remove(pid)
            exitWatches[pid] = nil
            await watchedChanged(from: old, reread: [pid], retry: false)
        }

        func finishedLaunching(_ pid: pid_t) async {
            guard !stopped, trusted, watched.contains(pid), attached[pid] == nil else { return }
            if attaching.contains(pid) {
                launchSignalled.insert(pid)
                return
            }
            let attachedNow = await attachMissing([pid], trigger: .launch).contains(pid)
            publishTracking()
            if attachedNow { await refresh(pid) }
        }

        /// Starts watching the exit of each pid that has just been covered for the first time, or again as a new
        /// process. Each stream is made here, so an exit before the watch's first read isn't missed.
        private func watchExits(of pids: Set<pid_t>) {
            for pid in pids {
                seen.insert(pid)
                let exits = exits(pid)
                exitWatches[pid] = Task {
                    for await _ in exits {
                        await self.exited(pid)
                        return
                    }
                }
            }
        }

        /// The watched set changed from `old`. A pid that left it is detached and loses its open state, failure
        /// record and launch signal; one that joined is attached and read, and so is every pid that failed before
        /// and has its one retry. `reread` pids that are still watched are read again.
        private func watchedChanged(from old: Set<pid_t>, reread: Set<pid_t> = [], retry: Bool = true) async {
            let new = watched
            let removed = old.subtracting(new)
            let added = new.subtracting(old)
            for pid in removed {
                state.remove(pid)
                failures[pid] = nil
                launchSignalled.remove(pid)
            }
            publisher(id, state.anyOpen, nil)
            let released = removed.compactMap { attached.removeValue(forKey: $0) }
            publishTracking()
            await detach(released)
            guard trusted, !stopped else { return }
            let fresh = retry ? await attachMissing(trigger: .processChange) : []
            publishTracking()
            await readAll(added.union(fresh).union(reread).intersection(watched))
        }

        /// Full while every covered process is attached, partial otherwise, said at once on every change of what is
        /// covered, watched or attached; an attach in flight is not attached. Silent until the grant's attach round
        /// has settled. It logs the covered processes without an observer each time that set changes.
        private func publishTracking() {
            guard trusted, settled, !stopped else { return }
            let observed = Set(attached.keys)
            publisher(id, nil, TrackingCoverage.tracking(covered: covered, attached: observed))
            let unobserved = covered.subtracting(observed)
            guard unobserved != loggedUnobserved else { return }
            loggedUnobserved = unobserved
            if unobserved.isEmpty {
                PlatformLog.menus.notice("menu tracking: every covered process has an observer")
            } else {
                let pids = unobserved.sorted().map(String.init).joined(separator: ", ")
                PlatformLog.menus.notice("menu tracking: covered processes without an observer: \(pids)")
            }
        }

        private func event(_ pid: pid_t) async {
            guard !stopped, trusted, watched.contains(pid) else { return }
            await refresh(pid)
        }

        /// The pids to attach now. One that failed gets one more try on its finished launching and one on the next
        /// change of the watched set's inputs, then stays unattached until the grant is given again.
        private func claim(_ candidates: Set<pid_t>, for trigger: Trigger) -> Set<pid_t> {
            var claimed: Set<pid_t> = []
            for pid in candidates where watched.contains(pid) && attached[pid] == nil && !attaching.contains(pid) {
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

        /// Attaches to the watched processes that aren't attached, and returns the ones that succeeded. While
        /// untrusted nothing is tried.
        private func attachMissing(_ candidates: Set<pid_t>? = nil, trigger: Trigger) async -> Set<pid_t> {
            guard trusted, !stopped else { return [] }
            let todo = claim(candidates ?? watched, for: trigger)
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
                        // The grant can be lost, or the process can leave the watched set, while the attach runs.
                        if trusted, !stopped, watched.contains(pid) {
                            attached[pid] = token
                            failures[pid] = nil
                            fresh.insert(pid)
                            publishTracking()
                        } else {
                            unwanted.append(token)
                        }
                    } else if trusted, !stopped, watched.contains(pid) {
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
