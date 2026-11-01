import AppKit
import ApplicationServices
import CoreGraphics

/// One status item MenuBarAgent draws, with the process that owns it.
struct DrawnGroup: Equatable, Sendable {
    var pid: pid_t
    var frame: CGRect
}

struct BarSnapshot: Equatable, Sendable {
    /// Sorted by `frame.minX`. Items in macOS's overflow share one x, so ties keep MenuBarAgent's child order.
    let groups: [DrawnGroup]
    let overflowIndicatorX: Double?

    init(groups: [DrawnGroup], overflowIndicatorX: Double?) {
        self.groups = groups.enumerated()
            .sorted { ($0.element.frame.minX, $0.offset) < ($1.element.frame.minX, $1.offset) }
            .map(\.element)
        self.overflowIndicatorX = overflowIndicatorX
    }
}

/// Reads the status items MenuBarAgent draws: its `AXDialog` windows hold one `AXGroup` per drawn item, with the
/// overflow indicator beside them. The extras listing misses items that these windows hold. Calls block, so run
/// them on an `AXQueue`.
enum MenuBarAgentReader {
    static let agentBundleID = "com.apple.MenuBarAgent"
    private static let overflowIndicatorPrefix = "menu-bar-overflow-indicator"

    private struct ReadFailed: Error {}

    static func agentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first?.processIdentifier
    }

    /// Nil when any read fails.
    static func read(timeout: Float) -> BarSnapshot? {
        guard let pid = agentPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        do {
            for window in try elements(app, kAXWindowsAttribute, timeout) {
                guard try string(window, kAXSubroleAttribute, timeout) == kAXDialogSubrole else { continue }
                let children = try elements(window, kAXChildrenAttribute, timeout)
                guard let indicator = try children.first(where: { try isOverflowIndicator($0, timeout) }) else { continue }
                var groups: [DrawnGroup] = []
                for child in children where try string(child, kAXRoleAttribute, timeout) == kAXGroupRole {
                    guard let remote = try elements(child, kAXChildrenAttribute, timeout).first else { continue }
                    var ownerPID: pid_t = 0
                    guard AXUIElementGetPid(remote, &ownerPID) == .success else { throw ReadFailed() }
                    groups.append(DrawnGroup(pid: ownerPID, frame: try frame(child, timeout)))
                }
                return BarSnapshot(groups: groups, overflowIndicatorX: try frame(indicator, timeout).minX)
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func isOverflowIndicator(_ element: AXUIElement, _ timeout: Float) throws -> Bool {
        guard try string(element, kAXRoleAttribute, timeout) == kAXButtonRole else { return false }
        return try string(element, kAXIdentifierAttribute, timeout)?.hasPrefix(overflowIndicatorPrefix) == true
    }

    private static func value(_ element: AXUIElement, _ attribute: String, _ timeout: Float) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        switch ExtrasMenuBarReader.copyValue(element, attribute) {
        case .value(let value): return value
        case .failed: throw ReadFailed()
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String, _ timeout: Float) throws -> String? {
        try value(element, attribute, timeout) as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String, _ timeout: Float) throws -> [AXUIElement] {
        (try value(element, attribute, timeout) as? [AXUIElement]) ?? []
    }

    private static func frame(_ element: AXUIElement, _ timeout: Float) throws -> CGRect {
        guard let value = try value(element, "AXFrame", timeout), let rect = ExtrasMenuBarReader.rect(from: value) else { throw ReadFailed() }
        return rect
    }
}
