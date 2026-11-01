import Darwin
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
    /// The apps that reported an event, which only means "read their windows again". One consumer.
    var events: AsyncStream<pid_t> { get }
}

enum WindowRule {
    static let tolerance = 2.0

    /// A window whose top edge sits at the bar's bottom edge is a menu or popover opened from the bar.
    static func isAnchored(top: Double, barBottom: Double?) -> Bool {
        guard let barBottom else { return false }
        return abs(top - barBottom) <= tolerance
    }
}

/// Whether any app shows a menu, from Accessibility events on every running app. Events are hints: each one
/// makes the tracker read that app's windows again. Follows the Accessibility state: it attaches once trusted
/// and lets go when the grant is lost.
final class MenuTracker27: Sendable {
    private let source: any MenuWindowSource
    private let queue: AXQueue
    private let trust: @Sendable () -> AsyncStream<Bool>
    private let processes: @Sendable () -> AsyncStream<Set<pid_t>>
    private let capability = OSAllocatedUnfairLock(initialState: MenuTracking.unavailable)

    /// Full only once attachment to the running apps has completed.
    var tracking: MenuTracking { capability.withLock { $0 } }

    init(
        source: any MenuWindowSource,
        queue: AXQueue,
        trust: @escaping @Sendable () -> AsyncStream<Bool>,
        processes: @escaping @Sendable () -> AsyncStream<Set<pid_t>>
    ) {
        self.source = source
        self.queue = queue
        self.trust = trust
        self.processes = processes
    }

    /// True while any app is open, with the current value first. The source has one event stream, so call this
    /// for one consumer at a time.
    func values() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let session = Session(source: source, queue: queue, capability: capability, continuation: continuation)
            continuation.yield(false)
            session.start(trust: trust(), processes: processes())
            continuation.onTermination = { _ in session.stop() }
        }
    }

    private actor Session {
        private let source: any MenuWindowSource
        private let queue: AXQueue
        private let capability: OSAllocatedUnfairLock<MenuTracking>
        private let continuation: AsyncStream<Bool>.Continuation
        private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

        private var trusted = false
        private var processes: Set<pid_t> = []
        private var attached: Set<pid_t> = []
        private var state = MenuOpenState()
        private var lastEmitted = false

        init(
            source: any MenuWindowSource,
            queue: AXQueue,
            capability: OSAllocatedUnfairLock<MenuTracking>,
            continuation: AsyncStream<Bool>.Continuation
        ) {
            self.source = source
            self.queue = queue
            self.capability = capability
            self.continuation = continuation
        }

        nonisolated func start(trust: AsyncStream<Bool>, processes: AsyncStream<Set<pid_t>>) {
            let events = source.events
            let started = [
                Task { for await trusted in trust { await self.trustChanged(trusted) } },
                Task { for await pids in processes { await self.processesChanged(pids) } },
                Task { for await pid in events { await self.event(pid) } },
            ]
            tasks.withLock { $0 = started }
        }

        nonisolated func stop() {
            tasks.withLock { $0 }.forEach { $0.cancel() }
            Task { await self.shutdown() }
        }

        private func shutdown() async {
            trusted = false
            capability.withLock { $0 = .unavailable }
            await detach(attached)
            attached = []
        }

        private func trustChanged(_ isTrusted: Bool) async {
            guard isTrusted != trusted else { return }
            trusted = isTrusted
            if isTrusted {
                await attach(processes)
                guard trusted else { return }
                capability.withLock { $0 = .full }
                await readAll(processes)
            } else {
                capability.withLock { $0 = .unavailable }
                let released = attached
                attached = []
                state = MenuOpenState()
                publish()
                await detach(released)
            }
        }

        private func processesChanged(_ new: Set<pid_t>) async {
            let removed = processes.subtracting(new)
            let added = new.subtracting(processes)
            processes = new
            for pid in removed { state.remove(pid) }
            publish()
            let released = removed.intersection(attached)
            attached.subtract(released)
            await detach(released)
            if trusted, !added.isEmpty {
                await attach(added)
                await readAll(added.intersection(processes))
            }
        }

        private func event(_ pid: pid_t) async {
            guard trusted, processes.contains(pid) else { return }
            await refresh(pid)
        }

        /// A failed attach is not retried for the same grant.
        private func attach(_ pids: Set<pid_t>) async {
            let results = await withTaskGroup(of: (pid_t, Bool).self) { group in
                for pid in pids {
                    group.addTask { [source, queue] in (pid, await queue.run { source.attach(pid) }) }
                }
                var results: [pid_t: Bool] = [:]
                for await (pid, attached) in group { results[pid] = attached }
                return results
            }
            let succeeded = Set(results.filter(\.value).keys)
            let failed = results.count - succeeded.count
            if failed > 0 { PlatformLog.menus.notice("menu tracking could not attach to \(failed) apps") }
            // The grant can be lost, or an app can quit, while the attaches run.
            let keep = trusted ? succeeded.intersection(processes) : []
            attached.formUnion(keep)
            await detach(succeeded.subtracting(keep))
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
            publish()
        }

        private func publish() {
            let open = state.anyOpen
            guard open != lastEmitted else { return }
            lastEmitted = open
            continuation.yield(open)
        }
    }
}
