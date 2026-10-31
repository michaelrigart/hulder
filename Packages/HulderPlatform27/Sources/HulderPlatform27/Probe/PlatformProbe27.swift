#if DEBUG
import AppKit
import ApplicationServices

/// Debug-only probe that measures what macOS 27 allows. The app starts it when launched with
/// `-HulderProbe <subcommand> <arguments>`; every reading goes to the unified log under
/// category `probe`.
public enum PlatformProbe27 {
    /// The arguments after `-HulderProbe`, or nil when the app was not launched as a probe.
    public static func arguments(from commandLine: [String]) -> [String]? {
        guard let flag = commandLine.firstIndex(of: "-HulderProbe") else { return nil }
        return Array(commandLine[(flag + 1)...])
    }

    @MainActor
    public static func run(arguments: [String], clock: any Clock<Duration> = ContinuousClock()) async {
        let runner = ProbeRunner(clock: clock)
        await runner.run(arguments)
    }
}

@MainActor
final class ProbeRunner {
    static let watchDuration: Duration = .seconds(120)
    static let activationTimeout: Duration = .seconds(3)
    static let allowedSystemItems = Array(0...127)

    let queue = AXQueue()
    let panel = ProbePanel()
    let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func run(_ arguments: [String]) async {
        let command = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        note("probe start: \(arguments.joined(separator: " "))")
        switch (command, rest.count) {
        case ("scan", 0):
            await requireAccessibility()
            _ = await scan(label: "scan")
        case ("hide", 1):
            await requireAccessibility()
            await hide(rest[0])
        case ("swap", 2):
            await swap(rest[0], rest[1])
        case ("crash", 1):
            await crash(rest[0])
        case ("menus", 0):
            await requireAccessibility()
            await menus()
        case ("items-watch", 0):
            await requireAccessibility()
            await itemsWatch()
        case ("order-dump", 0):
            ProbeOrderDump.run()
        default:
            note("usage: scan | hide <bundleID> | swap <a> <b> | crash <bundleID> | menus | items-watch | order-dump")
        }
        note("probe end: \(command)")
        NSApp.terminate(nil)
    }

    // MARK: Accessibility

    private func requireAccessibility() async {
        if AXIsProcessTrusted() {
            note("accessibility: trusted")
            return
        }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        await panel.wait("Hulder is not trusted for Accessibility yet. Grant it in System Settings > Privacy & Security > Accessibility, then click Continue.")
        note("accessibility: trusted=\(AXIsProcessTrusted())")
    }

    // MARK: scan

    struct ProbeProcess: Sendable {
        let pid: pid_t
        let bundleID: String?
        let scan: RawScan

        var items: [RawItem] {
            if case .items(let items) = scan { return items }
            return []
        }
    }

    struct ScanReport {
        let processes: [ProbeProcess]
        let duration: Duration

        func items(ownedBy bundleID: String) -> [(pid: pid_t, items: [RawItem])] {
            processes.filter { $0.bundleID == bundleID && !$0.items.isEmpty }.map { ($0.pid, $0.items) }
        }
    }

    func scan(label: String) async -> ScanReport {
        let pids = ExtrasMenuBarReader.runningPIDs()
        let timeout = queue.messagingTimeout
        let queue = queue
        let start = ContinuousClock.now
        var results: [ProbeProcess] = []
        await withTaskGroup(of: ProbeProcess.self) { group in
            for pid in pids {
                // The owner lookup is a LaunchServices call, so it runs on the queue too.
                group.addTask {
                    await queue.run {
                        let scan = ExtrasMenuBarReader.readItems(pid: pid, timeout: timeout)
                        return ProbeProcess(pid: pid, bundleID: Self.bundleID(of: pid), scan: scan)
                    }
                }
            }
            for await result in group { results.append(result) }
        }
        let duration = ContinuousClock.now - start

        let processes = results.sorted { $0.pid < $1.pid }
        var timeouts = 0
        var failures: [Int32: Int] = [:]
        var itemCount = 0
        var withItems = 0
        for process in processes {
            switch process.scan {
            case .timedOut:
                timeouts += 1
                note("\(label): pid=\(process.pid) owner=\(process.bundleID ?? "nil") timed out")
            case .failed(let error):
                failures[error.rawValue, default: 0] += 1
            case .items(let items):
                guard !items.isEmpty else { continue }
                withItems += 1
                itemCount += items.count
                for item in items { note("\(label): pid=\(process.pid) owner=\(process.bundleID ?? "nil") \(Self.describe(item))") }
            }
        }
        let failureSummary = failures.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        note("\(label) done: processes=\(processes.count) withItems=\(withItems) items=\(itemCount) timeouts=\(timeouts) failedByAXErrorCode=[\(failureSummary)] durationMs=\(Self.milliseconds(duration))")
        return ScanReport(processes: processes, duration: duration)
    }

    // MARK: hide / swap / crash

    private func makeAssertion(hiding bundleID: String, core: MenuBarClientCore) throws -> MenuBarAssertion {
        var allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let wasRunning = allowed.remove(bundleID) != nil
        if let own = Bundle.main.bundleIdentifier { allowed.insert(own) }
        note("assertion hiding \(bundleID): wasRunning=\(wasRunning) allowedBundleIDs=\(allowed.count) systemItems=0...\(Self.allowedSystemItems.last ?? 0)")
        return try MenuBarAssertion(core: core, bundleIDs: allowed.sorted(), systemItems: Self.allowedSystemItems)
    }

    enum Activation: Sendable {
        case completed
        case failed(String)
        case timedOut

        /// A silent agent still gets measured: only a reported failure stops the step.
        var proceeds: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    /// Activates, waiting at most `activationTimeout` on the injected clock for the completion.
    private func activate(_ assertion: MenuBarAssertion, label: String) async -> Activation {
        let start = ContinuousClock.now
        let clock = clock
        let timeout = Self.activationTimeout
        let outcome = await withTaskGroup(of: Activation?.self) { group in
            group.addTask {
                do {
                    try await assertion.activate()
                    return .completed
                } catch {
                    return .failed("\(error)")
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return nil
                }
            }
            var first: Activation?
            for await result in group {
                if let result, first == nil {
                    first = result
                    group.cancelAll()
                }
            }
            return first ?? .timedOut
        }
        let latency = Self.milliseconds(ContinuousClock.now - start)
        switch outcome {
        case .completed: note("\(label): completion with no error, latencyMs=\(latency)")
        case .failed(let reason): note("\(label): activation failed (\(reason)), latencyMs=\(latency)")
        case .timedOut: note("\(label): no completion within \(Self.activationTimeout), continuing")
        }
        return outcome
    }

    private func availableCore() -> MenuBarClientCore? {
        let core = MenuBarClientCore()
        note("MenuBarClientCore availability: \(core.availability)")
        return core.availability == .available ? core : nil
    }

    private func hide(_ bundleID: String) async {
        guard let core = availableCore() else { return }
        let before = await scan(label: "scan before hide")
        logTarget(bundleID, in: before, label: "before hide")

        guard let assertion = try? makeAssertion(hiding: bundleID, core: core) else {
            note("hide: could not create the assertion")
            return
        }
        defer { assertion.invalidate() }
        guard await activate(assertion, label: "hide \(bundleID)").proceeds else { return }

        let after = await scan(label: "scan while hidden")
        logTarget(bundleID, in: after, label: "while hidden")
        await panel.wait("\(bundleID) should be hidden now. Check the menu bar, then click Continue to invalidate the assertion.")
        assertion.invalidate()
        note("hide: assertion invalidated")
        await panel.wait("Assertion invalidated. Is \(bundleID) back? Click Continue to finish.")
    }

    private func logTarget(_ bundleID: String, in report: ScanReport, label: String) {
        let owned = report.items(ownedBy: bundleID)
        note("\(label): \(bundleID) has \(owned.reduce(0) { $0 + $1.items.count }) items listed in \(owned.count) processes")
        for entry in owned {
            for item in entry.items { note("\(label): pid=\(entry.pid) \(Self.describe(item))") }
        }
    }

    private func swap(_ first: String, _ second: String) async {
        guard let core = availableCore() else { return }
        guard let a = try? makeAssertion(hiding: first, core: core),
              let b = try? makeAssertion(hiding: second, core: core) else {
            note("swap: could not create the assertions")
            return
        }
        defer {
            a.invalidate()
            b.invalidate()
        }
        guard await activate(a, label: "swap: hide \(first)").proceeds else { return }
        await panel.wait("\(first) is hidden. Watch the menu bar closely, then click Continue to activate the second assertion (hiding \(second)) while the first is still live.")
        guard await activate(b, label: "swap: hide \(second)").proceeds else { return }
        await panel.wait("Both assertions are live. What is hidden now? Click Continue to invalidate the first (\(first)).")
        a.invalidate()
        note("swap: first assertion invalidated")
        await panel.wait("Only the second assertion is live. Is \(first) back and \(second) hidden, with no flash? Click Continue to invalidate the second.")
        b.invalidate()
        note("swap: second assertion invalidated")
        await panel.wait("Both invalidated. Is everything back? Click Continue to finish.")
    }

    private func crash(_ bundleID: String) async {
        guard let core = availableCore() else { return }
        guard let assertion = try? makeAssertion(hiding: bundleID, core: core) else {
            note("crash: could not create the assertion")
            return
        }
        guard await activate(assertion, label: "crash: hide \(bundleID)").proceeds else { return }
        await panel.wait("\(bundleID) is hidden. Clicking Continue calls abort() on Hulder. Time how long the menu bar takes to show everything again.")
        note("crash: calling abort() now")
        abort()
    }

    // MARK: Helpers

    nonisolated static func bundleID(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    nonisolated static func describe(_ item: RawItem) -> String {
        "item[\(item.index)] id=\(item.identifier ?? "nil") desc=\(item.description ?? "nil") title=\(item.title ?? "nil") frame=\(format(item.frame))"
    }

    nonisolated static func format(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return "(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))"
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

func note(_ message: String) {
    PlatformLog.probe.notice("\(message, privacy: .public)")
}
#endif
