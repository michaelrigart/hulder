import Darwin
import Foundation
import HulderCore
import os

/// What the tracker needs from Accessibility, so tests can fake it. Calls block, so the tracker makes them on
/// an `AXQueue`.
protocol MenuWindowSource: Sendable {
    /// Starts watching `pid`; false when that fails.
    func attach(_ pid: pid_t) -> Bool
    func detach(_ pid: pid_t)
    /// Reads the app's windows once.
    func isOpen(_ pid: pid_t) -> Bool
    /// The apps that reported an event, which only means "read their windows again". Each call is an
    /// independent stream that ends with its consumer.
    func events() -> AsyncStream<pid_t>
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

        private var trusted = false
        private var processes: Set<pid_t> = []
        private var attached: Set<pid_t> = []
        private var attaching: Set<pid_t> = []
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

        /// Ends the engine. The returned task finishes when everything is detached.
        nonisolated func stop() -> Task<Void, Never> {
            tasks.withLock { $0 }.forEach { $0.cancel() }
            return Task { await self.shutdown() }
        }

        private func shutdown() async {
            trusted = false
            let released = attached
            attached = []
            await detach(released)
        }

        private func trustChanged(_ isTrusted: Bool) async {
            guard isTrusted != trusted else { return }
            trusted = isTrusted
            if isTrusted {
                _ = await attachMissing()
                guard trusted else { return }
                publisher(id, nil, .full)
                await readAll(processes)
            } else {
                let released = attached
                attached = []
                state.removeAll()
                publisher(id, false, .unavailable)
                await detach(released)
            }
        }

        private func processesChanged(_ new: Set<pid_t>) async {
            let removed = processes.subtracting(new)
            let added = new.subtracting(processes)
            processes = new
            for pid in removed { state.remove(pid) }
            publisher(id, state.anyOpen, nil)
            let released = removed.intersection(attached)
            attached.subtract(released)
            await detach(released)
            guard trusted else { return }
            // Apps whose attach failed earlier are tried again with every change.
            let fresh = await attachMissing()
            await readAll(added.union(fresh).intersection(processes))
        }

        private func finishedLaunching(_ pid: pid_t) async {
            guard trusted, processes.contains(pid), !attached.contains(pid) else { return }
            if await attachMissing(only: [pid]).contains(pid) { await refresh(pid) }
        }

        private func event(_ pid: pid_t) async {
            guard trusted, processes.contains(pid) else { return }
            await refresh(pid)
        }

        /// Attaches to the running apps that aren't attached, and returns the ones that succeeded. While untrusted
        /// nothing is tried; once trusted, a failure is tried again on the app's finished launching and on the next
        /// change of the process set.
        private func attachMissing(only subset: Set<pid_t>? = nil) async -> Set<pid_t> {
            let todo = (subset ?? processes).intersection(processes).subtracting(attached).subtracting(attaching)
            guard trusted, !todo.isEmpty else { return [] }
            attaching.formUnion(todo)
            await previous?.value
            let results = await withTaskGroup(of: (pid_t, Bool).self) { group in
                for pid in todo {
                    group.addTask { [source, queue] in (pid, await queue.run { source.attach(pid) }) }
                }
                var results: [pid_t: Bool] = [:]
                for await (pid, attached) in group { results[pid] = attached }
                return results
            }
            attaching.subtract(todo)
            let succeeded = Set(results.filter(\.value).keys)
            let failed = results.count - succeeded.count
            if failed > 0 { PlatformLog.menus.notice("menu tracking could not attach to \(failed) apps") }
            // The grant can be lost, or an app can quit, while the attaches run.
            let keep = trusted ? succeeded.intersection(processes) : []
            attached.formUnion(keep)
            await detach(succeeded.subtracting(keep))
            return keep
        }

        private func detach(_ pids: Set<pid_t>) async {
            guard !pids.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for pid in pids {
                    group.addTask { [source, queue] in await queue.run { source.detach(pid) } }
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
