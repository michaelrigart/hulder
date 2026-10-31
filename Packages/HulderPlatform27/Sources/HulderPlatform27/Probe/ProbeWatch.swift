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
    /// Events from this process trigger a full scan of every process instead of a re-read of the
    /// process itself: a menu-bar drag is reported only by the agent, never by the owning app.
    let fullRescanProcess: String?

    static let menus = ProbeWatchPlan(
        appNotifications: [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification],
        barNotifications: [],
        itemNotifications: [kAXMenuOpenedNotification, kAXMenuClosedNotification],
        rescansOnEvent: false,
        fullRescanProcess: nil
    )

    static let items = ProbeWatchPlan(
        appNotifications: [kAXCreatedNotification, kAXUIElementDestroyedNotification],
        barNotifications: [kAXCreatedNotification, kAXUIElementDestroyedNotification],
        itemNotifications: [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification],
        rescansOnEvent: true,
        fullRescanProcess: "com.apple.MenuBarAgent"
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
        let bundleID: String?
        let handle: ProbeAXHandle?
        let scan: RawScan
        let registered: Int
        /// AX error codes of registrations that failed, with counts.
        let failures: [Int32: Int]
    }

    static func attach(
        pid: pid_t,
        plan: ProbeWatchPlan,
        timeout: Float,
        handler: @escaping @MainActor @Sendable (ProbeAXEvent) -> Void
    ) -> Attachment {
        let bundleID = ProbeRunner.bundleID(of: pid)
        let inspection = ExtrasMenuBarReader.inspect(pid: pid, timeout: timeout)
        var observer: AXObserver?
        let created = AXObserverCreate(pid, probeAXCallback, &observer)
        guard created == .success, let observer else {
            return Attachment(bundleID: bundleID, handle: nil, scan: inspection.scan, registered: 0, failures: [created.rawValue: 1])
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
        return Attachment(bundleID: bundleID, handle: handle, scan: inspection.scan, registered: registered, failures: failures)
    }
}

/// Every item of every process at one moment, keyed by process and item index.
struct ProbeFullSnapshot {
    struct Key: Hashable, Comparable {
        let pid: pid_t
        let index: Int

        static func < (lhs: Key, rhs: Key) -> Bool { (lhs.pid, lhs.index) < (rhs.pid, rhs.index) }
    }

    struct Entry {
        let owner: String
        let frame: CGRect?
    }

    let entries: [Key: Entry]

    init(processes: [ProbeRunner.ProbeProcess]) {
        var entries: [Key: Entry] = [:]
        for process in processes {
            for item in process.items {
                entries[Key(pid: process.pid, index: item.index)] = Entry(owner: process.bundleID ?? "nil", frame: item.frame)
            }
        }
        self.entries = entries
    }

    static func diff(old: ProbeFullSnapshot, new: ProbeFullSnapshot) -> [String] {
        var changes: [String] = []
        for key in new.entries.keys.sorted() {
            guard let now = new.entries[key] else { continue }
            guard let was = old.entries[key] else {
                changes.append("appeared \(now.owner) item[\(key.index)] \(format(now.frame))")
                continue
            }
            if !same(was.frame, now.frame) {
                changes.append("moved \(now.owner) item[\(key.index)] \(format(was.frame)) -> \(format(now.frame))")
            }
        }
        for key in old.entries.keys.sorted() where new.entries[key] == nil {
            guard let was = old.entries[key] else { continue }
            changes.append("disappeared \(was.owner) item[\(key.index)] \(format(was.frame))")
        }
        return changes
    }

    private static func same(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.minX - rhs.minX) < 0.01 && abs(lhs.minY - rhs.minY) < 0.01
            && abs(lhs.width - rhs.width) < 0.01 && abs(lhs.height - rhs.height) < 0.01
    }

    private static func format(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return String(format: "(%.1f,%.1f %.1fx%.1f)", frame.minX, frame.minY, frame.width, frame.height)
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
    private var owners: [pid_t: String] = [:]
    private var stopped = false
    private let fullScan: (@MainActor () async -> ProbeRunner.ScanReport)?
    private var fullSnapshot = ProbeFullSnapshot(processes: [])
    private var fullRefreshing = false
    private var fullDirty = false

    init(queue: AXQueue, plan: ProbeWatchPlan, fullScan: (@MainActor () async -> ProbeRunner.ScanReport)? = nil) {
        self.queue = queue
        self.plan = plan
        self.fullScan = fullScan
    }

    /// The snapshot later full rescans are compared against.
    func setBaseline(_ report: ProbeRunner.ScanReport) {
        guard fullScan != nil else { return }
        fullSnapshot = ProbeFullSnapshot(processes: report.processes)
        note("full snapshot: \(fullSnapshot.entries.count) items in \(report.processes.filter { !$0.items.isEmpty }.count) processes")
    }

    private func isFullRescanProcess(_ event: ProbeAXEvent) -> Bool {
        guard fullScan != nil, let target = plan.fullRescanProcess else { return false }
        if event.bundleID == target { return true }
        // A background agent has no bundle ID through NSRunningApplication; match its executable name.
        var name = [CChar](repeating: 0, count: 256)
        let length = Int(proc_name(event.pid, &name, UInt32(name.count)))
        guard length > 0 else { return false }
        let executable = String(decoding: name.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return executable == String(target.split(separator: ".").last ?? "")
    }

    /// Scans every process after an event and logs how items moved; events during a scan cause one more.
    private func scheduleFullRescan(trigger: ProbeAXEvent) {
        guard !stopped, !fullRefreshing, let fullScan else {
            fullDirty = true
            return
        }
        fullRefreshing = true
        Task {
            repeat {
                fullDirty = false
                let report = await fullScan()
                let new = ProbeFullSnapshot(processes: report.processes)
                let changes = ProbeFullSnapshot.diff(old: fullSnapshot, new: new)
                fullSnapshot = new
                let header = "full rescan after \(trigger.notification) scope=\(trigger.scope) durationMs=\(ProbeRunner.milliseconds(report.duration)) items=\(new.entries.count)"
                if changes.isEmpty {
                    note("\(header): no frame change")
                } else {
                    note("\(header): \(changes.count) changes")
                    for change in changes { note("  \(change)") }
                }
            } while fullDirty && !stopped
            fullRefreshing = false
        }
    }

    @discardableResult
    func attach(pid: pid_t) async -> RawScan {
        let timeout = queue.messagingTimeout
        let plan = plan
        let handler: @MainActor @Sendable (ProbeAXEvent) -> Void = { [weak self] event in self?.handle(event) }
        let attachment = await queue.run {
            ProbeAXHandle.attach(pid: pid, plan: plan, timeout: timeout, handler: handler)
        }
        guard !stopped else {
            attachment.handle?.invalidate()
            return attachment.scan
        }
        owners[pid] = attachment.bundleID
        handles[pid]?.invalidate()
        handles[pid] = attachment.handle
        if case .items(let items) = attachment.scan { snapshots[pid] = items }
        let failures = attachment.failures.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        note("attached pid=\(pid) owner=\(attachment.bundleID ?? "nil") registered=\(attachment.registered) failedByAXErrorCode=[\(failures)]")
        return attachment.scan
    }

    func detach() {
        stopped = true
        for handle in handles.values { handle.invalidate() }
        handles = [:]
    }

    private func handle(_ event: ProbeAXEvent) {
        guard !stopped else { return }
        var line = "event owner=\(event.bundleID ?? "nil") pid=\(event.pid) scope=\(event.scope) notification=\(event.notification)"
        if let index = event.itemIndex, let item = snapshots[event.pid]?.first(where: { $0.index == index }) {
            line += " \(ProbeRunner.describe(item))"
        }
        note(line)
        if isFullRescanProcess(event) {
            scheduleFullRescan(trigger: event)
        } else if plan.rescansOnEvent {
            scheduleRefresh(pid: event.pid)
        }
    }

    /// Re-reads one process after a notification; events during a read cause one more read.
    private func scheduleRefresh(pid: pid_t) {
        guard !stopped, refreshing.insert(pid).inserted else {
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
                    note("rescan pid=\(pid) owner=\(owners[pid] ?? "nil"): \(changes.isEmpty ? "no item change" : changes.joined(separator: "; "))")
                } else {
                    note("rescan pid=\(pid): \(scan)")
                }
            } while dirty.contains(pid) && !stopped
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
        await watch(plan: .menus, label: "menus", observeLaunches: true)
    }

    func itemsWatch() async {
        await watch(plan: .items, label: "items-watch", observeLaunches: true)
    }

    private func watch(plan: ProbeWatchPlan, label: String, observeLaunches: Bool) async {
        let report = await scan(label: "\(label) initial scan")
        var fullScan: (@MainActor () async -> ScanReport)?
        if plan.fullRescanProcess != nil {
            fullScan = { [unowned self] in await self.collect() }
        }
        let watcher = ProbeWatcher(queue: queue, plan: plan, fullScan: fullScan)
        watcher.setBaseline(report)

        var pids = Set(report.processes.filter { !$0.items.isEmpty }.map(\.pid))
        if observeLaunches {
            // Apps without items yet are watched too, so a first item appearing is seen.
            let candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
            pids.formUnion(candidates.map(\.processIdentifier))
        }
        if let agent = plan.fullRescanProcess {
            // The agent may be a background process the candidate filter skips.
            pids.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: agent).map(\.processIdentifier))
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
