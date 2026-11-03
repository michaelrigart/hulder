#if DEBUG
// Throwaway spike (branch spike/nc-blink, never merged): can Notification Center open from the clock with the
// hidden apps' icons never drawn? Drops the assertion, replays a click on the clock, and activates a fresh
// assertion after a gap, while a sampler logs whether the hidden app's icon is drawn and whether
// Notification Center has a window.
import AppKit
import ApplicationServices
import HulderCore

private func axAttr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

private func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

private func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt) // swiftlint:disable:this force_cast
    AXValueGetValue(s as! AXValue, .cgSize, &sz) // swiftlint:disable:this force_cast
    return CGRect(origin: pt, size: sz)
}

private func runningPID(_ bundle: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
}

private enum BlinkBar {
    /// MenuBarAgent's item groups: (owner pid, frame, hosted identifier).
    static func groups() -> [(pid: pid_t, frame: CGRect, identifier: String?)] {
        guard let agent = runningPID("com.apple.MenuBarAgent") else { return [] }
        var result: [(pid_t, CGRect, String?)] = []
        for window in (axAttr(AXUIElementCreateApplication(agent), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        where (axAttr(window, kAXSubroleAttribute) as? String) == kAXDialogSubrole {
            for group in axChildren(window) where (axAttr(group, kAXRoleAttribute) as? String) == kAXGroupRole {
                guard let remote = axChildren(group).first, let frame = axFrame(group) else { continue }
                var owner: pid_t = 0
                AXUIElementGetPid(remote, &owner)
                let identifier = axChildren(remote).first.flatMap { axAttr($0, kAXIdentifierAttribute) as? String }
                result.append((owner, frame, identifier))
            }
            if !result.isEmpty { return result }
        }
        return result
    }

    static func clockPoint() -> CGPoint? {
        groups().first { $0.identifier == "com.apple.menuextra.clock" }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    /// Whether `pid` has a group with a real slot on the bar.
    static func drawn(_ pid: pid_t) -> Bool {
        groups().contains { $0.pid == pid && $0.frame.width > 0 && $0.frame.minX > 0 }
    }

    static func notificationCenterOpen() -> Bool {
        guard let nc = runningPID("com.apple.notificationcenterui") else { return false }
        let windows = (axAttr(AXUIElementCreateApplication(nc), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.contains { (axAttr($0, kAXSubroleAttribute) as? String) == "AXSystemDialog" }
    }

    static func click(_ point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }
}

/// Polls the bar every 10 ms on its own thread and records changes, from `start`.
private final class BlinkSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var running = true
    private var firstDrawnMs: Int?
    private var firstNCOpenMs: Int?

    func start(target: pid_t, from start: Date, for seconds: Double) {
        Thread.detachNewThread { [self] in
            var lastDrawn: Bool?
            var lastNC: Bool?
            while Date().timeIntervalSince(start) < seconds, lock.withLock({ running }) {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let drawn = BlinkBar.drawn(target)
                let nc = BlinkBar.notificationCenterOpen()
                lock.withLock {
                    if drawn != lastDrawn { events.append("\(ms)ms hiddenAppDrawn=\(drawn)") }
                    if nc != lastNC { events.append("\(ms)ms ncOpen=\(nc)") }
                    if drawn, firstDrawnMs == nil { firstDrawnMs = ms }
                    if nc, firstNCOpenMs == nil { firstNCOpenMs = ms }
                }
                lastDrawn = drawn
                lastNC = nc
                usleep(10_000)
            }
        }
    }

    var firstNCOpen: Int? { lock.withLock { firstNCOpenMs } }

    func summary() -> String {
        lock.withLock {
            "firstHiddenAppDrawnMs=\(firstDrawnMs.map(String.init) ?? "never") firstNCOpenMs=\(firstNCOpenMs.map(String.init) ?? "never") events=[\(events.joined(separator: ", "))]"
        }
    }
}

extension ProbeRunner {
    /// Gaps in ms between the replayed click and the new activation; -1 means "as soon as Notification Center has a
    /// window", at most 1 s.
    func ncBlink(hiding bundleID: String, gaps: [Int]) async {
        guard let target = runningPID(bundleID) else { note("nc-blink: \(bundleID) is not running"); return }
        guard let point = BlinkBar.clockPoint() else { note("nc-blink: the clock was not found"); return }
        var apps = await first(of: RunningApps27().values()) ?? []
        apps.remove(AppID(bundleID))
        apps.insert(ownAppID)
        let list = AllowList(apps: apps)
        let backend = platform.concealment

        guard var token = try? await backend.prepare(list), (try? await backend.activate(token)) != nil else {
            note("nc-blink: the first activation failed"); return
        }
        try? await clock.sleep(for: .seconds(1))
        note("nc-blink: hiding \(bundleID) (pid \(target)), drawn=\(BlinkBar.drawn(target)), clock at \(point)")
        await panel.wait("\(bundleID) is hidden. Watch its spot on the bar and the right edge of the screen. Click Continue to run trial 1 of \(gaps.count).")

        for (index, gap) in gaps.enumerated() {
            let label = gap < 0 ? "when NC has a window" : "\(gap) ms"
            guard let next = try? await backend.prepare(list) else { note("nc-blink: prepare failed"); break }
            let sampler = BlinkSampler()
            let start = Date()
            sampler.start(target: target, from: start, for: 2.5)
            await backend.invalidate(token)
            _ = await drained(MenuBarAssertion.queue)
            let invalidatedMs = Int(Date().timeIntervalSince(start) * 1000)
            BlinkBar.click(point)
            let clickedMs = Int(Date().timeIntervalSince(start) * 1000)
            if gap < 0 {
                for _ in 0..<200 where sampler.firstNCOpen == nil { try? await Task.sleep(for: .milliseconds(5)) }
            } else if gap > 0 {
                try? await Task.sleep(for: .milliseconds(gap))
            }
            let activatingMs = Int(Date().timeIntervalSince(start) * 1000)
            let activated = (try? await backend.activate(next)) != nil
            let activatedMs = Int(Date().timeIntervalSince(start) * 1000)
            token = next
            try? await Task.sleep(for: .seconds(2.6))
            note("nc-blink trial \(index + 1) gap=\(label): invalidatedMs=\(invalidatedMs) clickedMs=\(clickedMs) activatingMs=\(activatingMs) activated=\(activated) activatedMs=\(activatedMs) \(sampler.summary()) ncOpenNow=\(BlinkBar.notificationCenterOpen()) hiddenAppDrawnNow=\(BlinkBar.drawn(target))")
            await panel.wait("Trial \(index + 1) (\(label)): did \(bundleID)'s icon flash? Is Notification Center showing? Note both, then close Notification Center the way you normally would (click outside it, or Escape), note whether it closed, and click Continue.")
            note("nc-blink trial \(index + 1) after close: ncOpen=\(BlinkBar.notificationCenterOpen()) hiddenAppDrawn=\(BlinkBar.drawn(target))")
        }

        await backend.invalidate(token)
        _ = await drained(MenuBarAssertion.queue)
        note("nc-blink: done, assertion invalidated")
    }
}
#endif
