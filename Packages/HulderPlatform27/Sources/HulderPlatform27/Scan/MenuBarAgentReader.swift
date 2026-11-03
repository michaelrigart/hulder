import AppKit
import ApplicationServices
import CoreGraphics

/// One status item MenuBarAgent draws, with the process that owns it.
struct DrawnGroup: Equatable, Sendable {
    var pid: pid_t
    var frame: CGRect
    /// The identifier of the menu extra MenuBarAgent hosts itself, such as `com.apple.menuextra.wifi`. Nil for any
    /// other item, and when the extra carries none.
    var identifier: String?

    init(pid: pid_t, frame: CGRect, identifier: String? = nil) {
        self.pid = pid
        self.frame = frame
        self.identifier = identifier
    }
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

/// One child of a MenuBarAgent window, as read.
enum AgentChild: Equatable, Sendable {
    /// An item MenuBarAgent draws; nil when it holds no remote element to name the owner.
    case group(DrawnGroup?)
    case overflowIndicator(minX: Double)
    case other
}

/// Reads the status items MenuBarAgent draws: its `AXDialog` windows hold one `AXGroup` per drawn item, whose
/// remote child belongs to the process that owns the item, and an overflow indicator beside them while macOS holds
/// items in its overflow. MenuBarAgent's own items also give the identifier of the menu extra they host. The extras listing misses items that
/// these windows hold. Calls block, so run them on an `AXQueue`.
enum MenuBarAgentReader {
    static let agentBundleID = "com.apple.MenuBarAgent"
    private static let overflowIndicatorPrefix = "menu-bar-overflow-indicator"

    private struct ReadFailed: Error {}

    static func agentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first?.processIdentifier
    }

    /// The snapshot a window gives, or nil when it isn't the one that holds the items: a dialog with at least one
    /// item or the overflow indicator. The indicator is absent when nothing is in the overflow. Other windows,
    /// such as the reveal shield, hold neither.
    static func snapshot(subrole: String?, children: [AgentChild]) -> BarSnapshot? {
        guard subrole == kAXDialogSubrole else { return nil }
        var groups: [DrawnGroup] = []
        var indicatorX: Double?
        var holdsItems = false
        for child in children {
            switch child {
            case .group(let group):
                holdsItems = true
                if let group { groups.append(group) }
            case .overflowIndicator(let minX):
                holdsItems = true
                indicatorX = minX
            case .other:
                break
            }
        }
        return holdsItems ? BarSnapshot(groups: groups, overflowIndicatorX: indicatorX) : nil
    }

    /// Nil when any read fails, or when no window holds the items.
    static func read(timeout: Float) -> BarSnapshot? {
        guard let pid = agentPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        do {
            for window in try elements(app, kAXWindowsAttribute, timeout) {
                let subrole = try string(window, kAXSubroleAttribute, timeout)
                guard subrole == kAXDialogSubrole else { continue }
                let children = try elements(window, kAXChildrenAttribute, timeout).map { try agentChild($0, agentPID: pid, timeout) }
                if let snapshot = snapshot(subrole: subrole, children: children) { return snapshot }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func agentChild(_ element: AXUIElement, agentPID: pid_t, _ timeout: Float) throws -> AgentChild {
        switch try string(element, kAXRoleAttribute, timeout) {
        case kAXGroupRole:
            guard let remote = try elements(element, kAXChildrenAttribute, timeout).first else { return .group(nil) }
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(remote, &ownerPID) == .success else { throw ReadFailed() }
            // MenuBarAgent's own items host a menu extra, whose identifier names the item.
            let identifier = ownerPID == agentPID ? hostedIdentifier(remote, timeout) : nil
            return .group(DrawnGroup(pid: ownerPID, frame: try frame(element, timeout), identifier: identifier))
        case kAXButtonRole where try isOverflowIndicator(element, timeout):
            return .overflowIndicator(minX: try frame(element, timeout).minX)
        default:
            return .other
        }
    }

    /// The identifier of the menu extra inside a hosting view, or nil when it holds none or can't be read. The
    /// identifier only improves a name, so a failed read leaves the item to positional keying rather than failing the bar.
    private static func hostedIdentifier(_ remote: AXUIElement, _ timeout: Float) -> String? {
        guard let extra = (try? elements(remote, kAXChildrenAttribute, timeout))?.first else { return nil }
        return (try? string(extra, kAXIdentifierAttribute, timeout)) ?? nil
    }

    private static func isOverflowIndicator(_ element: AXUIElement, _ timeout: Float) throws -> Bool {
        try string(element, kAXIdentifierAttribute, timeout)?.hasPrefix(overflowIndicatorPrefix) == true
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
