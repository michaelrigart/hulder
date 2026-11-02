#if DEBUG
import AppKit
import ApplicationServices
import HulderCore

/// Debug-only probe that exercises the platform layer's own types on the running system, so a new macOS can be
/// checked by rerunning it. The app starts it when launched with `-HulderProbe <subcommand> <arguments>`; every
/// reading goes to the unified log under category `probe`.
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

    static let usage = "usage: scan | hide <bundleID> [maxSystemItem] | hide-cancel <bundleID> | relist <bundleID> | swap <a> <b> | crash <bundleID> | menus | items-watch | order-pick | order-dump | order-watch | order-move <key> <anchorKey> | order-restore | order-stress <key>"

    let queue = AXQueue()
    let panel = ProbePanel()
    let clock: any Clock<Duration>
    let core = MenuBarClientCore()
    let ownAppID = AppID(Bundle.main.bundleIdentifier ?? PlatformFactory.fallbackBundleID)

    /// The platform as Hulder composes it, built on first use.
    private(set) lazy var platform = Platform27(core: core, ownAppID: ownAppID)

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func run(_ arguments: [String]) async {
        let command = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        note("probe start: \(arguments.joined(separator: " "))")
        note("MenuBarClientCore availability: \(core.availability)")
        switch (command, rest.count) {
        case ("scan", 0):
            await requireAccessibility()
            _ = await scan(label: "scan")
        case ("hide", 1...2):
            let maxSystemItem = rest.count == 2 ? Int(rest[1]) : nil
            if rest.count == 1 || (maxSystemItem ?? -1) >= 0 {
                await requireAccessibility()
                await hide(rest[0], maxSystemItem: maxSystemItem)
            } else {
                note(Self.usage)
            }
        case ("relist", 1):
            await requireAccessibility()
            await relist(rest[0])
        case ("hide-cancel", 1):
            await requireAccessibility()
            await hideCancel(rest[0])
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
        case ("order-pick", 0):
            await orderPick()
        case ("order-dump", 0):
            await orderDump()
        case ("order-watch", 0):
            await orderWatch()
        case ("order-move", 2):
            await orderMove(rest[0], anchor: rest[1])
        case ("order-restore", 0):
            await orderRestore()
        case ("order-stress", 1):
            await orderStress(rest[0])
        default:
            note(Self.usage)
        }
        note("probe end: \(command)")
        NSApp.terminate(nil)
    }

    // MARK: Accessibility

    private func isTrusted() async -> Bool {
        await first(of: AccessibilityTrust27().values()) ?? false
    }

    private func requireAccessibility() async {
        if await isTrusted() {
            note("accessibility: trusted")
            return
        }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        await panel.wait("Hulder is not trusted for Accessibility yet. Grant it in System Settings > Privacy & Security > Device Control and Data Access, then click Continue.")
        note("accessibility: trusted=\(await isTrusted())")
    }

    // MARK: Helpers

    /// The first value of `stream`, or nil if it ends or `timeout` passes first.
    func first<Value: Sendable>(of stream: AsyncStream<Value>, within timeout: Duration = .seconds(3)) async -> Value? {
        let clock = clock
        return await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Runs `bodies` together until `watchDuration` has passed on the clock, then cancels them and returns what
    /// each returned.
    func untilWatchEnds<Result: Sendable>(_ bodies: [@Sendable () async -> Result]) async -> [Result] {
        let clock = clock
        let duration = Self.watchDuration
        return await withTaskGroup(of: Result.self) { group in
            for body in bodies { group.addTask { await body() } }
            try? await clock.sleep(for: duration)
            group.cancelAll()
            var results: [Result] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

func note(_ message: String) {
    PlatformLog.probe.notice("\(message, privacy: .public)")
}
#endif
