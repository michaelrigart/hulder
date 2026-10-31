#if DEBUG
import AppKit
import ApplicationServices

/// Which notifications to register on which elements of one process.
struct ProbeWatchPlan: Sendable {
    let appNotifications: [String]
    let barNotifications: [String]
    let itemNotifications: [String]
    /// Re-read the process's items after every notification and log what changed.
    let rescansOnEvent: Bool

    static let menus = ProbeWatchPlan(
        appNotifications: [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification],
        barNotifications: [],
        itemNotifications: [kAXMenuOpenedNotification, kAXMenuClosedNotification],
        rescansOnEvent: false
    )

    static let items = ProbeWatchPlan(
        appNotifications: [kAXCreatedNotification, kAXUIElementDestroyedNotification],
        barNotifications: [kAXCreatedNotification, kAXUIElementDestroyedNotification],
        itemNotifications: [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification],
        rescansOnEvent: true
    )
}

struct ProbeAXEvent: Sendable {
    let pid: pid_t
    let bundleID: String?
    let scope: String
    let itemIndex: Int?
    let notification: String
}

/// The refcon target of one registration; the C callback hops to the main actor through it.
final class ProbeAXRegistration: Sendable {
    let pid: pid_t
    let bundleID: String?
    let scope: String
    let itemIndex: Int?
    let handler: @MainActor @Sendable (ProbeAXEvent) -> Void

    init(pid: pid_t, bundleID: String?, scope: String, itemIndex: Int?, handler: @escaping @MainActor @Sendable (ProbeAXEvent) -> Void) {
        self.pid = pid
        self.bundleID = bundleID
        self.scope = scope
        self.itemIndex = itemIndex
        self.handler = handler
    }
}

private let probeAXCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let registration = Unmanaged<ProbeAXRegistration>.fromOpaque(refcon).takeUnretainedValue()
    let event = ProbeAXEvent(
        pid: registration.pid,
        bundleID: registration.bundleID,
        scope: registration.scope,
        itemIndex: registration.itemIndex,
        notification: notification as String
    )
    // The observer's run loop source is on the main run loop, so this runs on the main thread.
    MainActor.assumeIsolated { registration.handler(event) }
}

/// One process's observer and its registrations. Built on an `AXQueue`; delivers on the main run loop.
final class ProbeAXHandle: @unchecked Sendable { // reason: holds CF objects that are only touched at creation and at invalidate
    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let registrations: [ProbeAXRegistration]

    private init(observer: AXObserver, source: CFRunLoopSource, registrations: [ProbeAXRegistration]) {
        self.observer = observer
        self.source = source
        self.registrations = registrations
    }

    func invalidate() {
        CFRunLoopSourceInvalidate(source)
    }

    struct Attachment: Sendable {
        let handle: ProbeAXHandle?
        let scan: RawScan
        let registered: Int
        /// AX error codes of registrations that failed, with counts.
        let failures: [Int32: Int]
    }

    static func attach(
        pid: pid_t,
        bundleID: String?,
        plan: ProbeWatchPlan,
        timeout: Float,
        handler: @escaping @MainActor @Sendable (ProbeAXEvent) -> Void
    ) -> Attachment {
        let inspection = ExtrasMenuBarReader.inspect(pid: pid, timeout: timeout)
        var observer: AXObserver?
        let created = AXObserverCreate(pid, probeAXCallback, &observer)
        guard created == .success, let observer else {
            return Attachment(handle: nil, scan: inspection.scan, registered: 0, failures: [created.rawValue: 1])
        }

        var registrations: [ProbeAXRegistration] = []
        var registered = 0
        var failures: [Int32: Int] = [:]
        func register(_ notifications: [String], on element: AXUIElement, scope: String, itemIndex: Int?) {
            guard !notifications.isEmpty else { return }
            let registration = ProbeAXRegistration(pid: pid, bundleID: bundleID, scope: scope, itemIndex: itemIndex, handler: handler)
            registrations.append(registration)
            for name in notifications {
                let error = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(registration).toOpaque())
                if error == .success { registered += 1 } else { failures[error.rawValue, default: 0] += 1 }
            }
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        register(plan.appNotifications, on: app, scope: "app", itemIndex: nil)
        if let bar = inspection.menuBar {
            register(plan.barNotifications, on: bar, scope: "bar", itemIndex: nil)
        }
        for (index, element) in inspection.itemElements.enumerated() {
            register(plan.itemNotifications, on: element, scope: "item", itemIndex: index)
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let handle = ProbeAXHandle(observer: observer, source: source, registrations: registrations)
        return Attachment(handle: handle, scan: inspection.scan, registered: registered, failures: failures)
    }
}

/// Observers for a set of processes, with a per-process item snapshot for diffing.
@MainActor
final class ProbeWatcher {
    private let queue: AXQueue
    private let plan: ProbeWatchPlan
    private var handles: [pid_t: ProbeAXHandle] = [:]
    private var snapshots: [pid_t: [RawItem]] = [:]
    private var refreshing: Set<pid_t> = []
    private var dirty: Set<pid_t> = []

    init(queue: AXQueue, plan: ProbeWatchPlan) {
        self.queue = queue
        self.plan = plan
    }

    @discardableResult
    func attach(pid: pid_t) async -> RawScan {
        let bundleID = ProbeRunner.bundleID(of: pid)
        let timeout = queue.messagingTimeout
        let plan = plan
        let handler: @MainActor @Sendable (ProbeAXEvent) -> Void = { [weak self] event in self?.handle(event) }
        let attachment = await queue.run {
            ProbeAXHandle.attach(pid: pid, bundleID: bundleID, plan: plan, timeout: timeout, handler: handler)
        }
        handles[pid]?.invalidate()
        handles[pid] = attachment.handle
        if case .items(let items) = attachment.scan { snapshots[pid] = items }
        let failures = attachment.failures.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        note("attached pid=\(pid) owner=\(bundleID ?? "nil") registered=\(attachment.registered) failedByAXErrorCode=[\(failures)]")
        return attachment.scan
    }

    func detach() {
        for handle in handles.values { handle.invalidate() }
        handles = [:]
    }

    private func handle(_ event: ProbeAXEvent) {
        var line = "event owner=\(event.bundleID ?? "nil") pid=\(event.pid) scope=\(event.scope) notification=\(event.notification)"
        if let index = event.itemIndex, let item = snapshots[event.pid]?.first(where: { $0.index == index }) {
            line += " \(ProbeRunner.describe(item))"
        }
        note(line)
        if plan.rescansOnEvent { scheduleRefresh(pid: event.pid) }
    }

    /// Re-reads one process after a notification; events during a read cause one more read.
    private func scheduleRefresh(pid: pid_t) {
        guard refreshing.insert(pid).inserted else {
            dirty.insert(pid)
            return
        }
        Task {
            repeat {
                dirty.remove(pid)
                let old = snapshots[pid] ?? []
                let scan = await attach(pid: pid)
                if case .items(let new) = scan {
                    let changes = Self.diff(old: old, new: new)
                    note("rescan pid=\(pid) owner=\(ProbeRunner.bundleID(of: pid) ?? "nil"): \(changes.isEmpty ? "no item change" : changes.joined(separator: "; "))")
                } else {
                    note("rescan pid=\(pid): \(scan)")
                }
            } while dirty.contains(pid)
            refreshing.remove(pid)
        }
    }

    nonisolated static func diff(old: [RawItem], new: [RawItem]) -> [String] {
        func keyed(_ items: [RawItem]) -> [String: RawItem] {
            var seen: [String: Int] = [:]
            var result: [String: RawItem] = [:]
            for item in items {
                let base = item.identifier ?? item.description ?? item.title ?? "index\(item.index)"
                let occurrence = seen[base, default: 0]
                seen[base] = occurrence + 1
                result["\(base)#\(occurrence)"] = item
            }
            return result
        }
        let before = keyed(old)
        let after = keyed(new)
        var changes: [String] = []
        for key in after.keys.sorted() where before[key] == nil {
            changes.append("appeared \(key) frame=\(ProbeRunner.format(after[key]?.frame))")
        }
        for key in before.keys.sorted() where after[key] == nil {
            changes.append("disappeared \(key) frame=\(ProbeRunner.format(before[key]?.frame))")
        }
        for key in after.keys.sorted() {
            guard let was = before[key]?.frame, let now = after[key]?.frame, abs(was.minX - now.minX) > 0.5 || abs(was.minY - now.minY) > 0.5 else { continue }
            changes.append("moved \(key) from \(ProbeRunner.format(was)) to \(ProbeRunner.format(now))")
        }
        return changes
    }
}

extension ProbeRunner {
    func menus() async {
        await watch(plan: .menus, label: "menus", observeLaunches: false)
    }

    func itemsWatch() async {
        await watch(plan: .items, label: "items-watch", observeLaunches: true)
    }

    private func watch(plan: ProbeWatchPlan, label: String, observeLaunches: Bool) async {
        let report = await scan(label: "\(label) initial scan")
        let watcher = ProbeWatcher(queue: queue, plan: plan)

        var pids = Set(report.processes.filter { !$0.items.isEmpty }.map(\.pid))
        if observeLaunches {
            // Apps without items yet are watched too, so a first item appearing is seen.
            let candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
            pids.formUnion(candidates.map(\.processIdentifier))
        }
        for pid in pids.sorted() { await watcher.attach(pid: pid) }

        var launchObserver: NSObjectProtocol?
        if observeLaunches {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let bundleID = app.bundleIdentifier ?? "nil"
                MainActor.assumeIsolated {
                    note("launched owner=\(bundleID) pid=\(pid)")
                    Task { await watcher.attach(pid: pid) }
                }
            }
        }

        note("\(label): watching \(pids.count) processes for \(Self.watchDuration)")
        do { try await clock.sleep(for: Self.watchDuration) } catch { note("\(label): wait cancelled") }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        watcher.detach()
        note("\(label): finished")
    }
}
#endif
