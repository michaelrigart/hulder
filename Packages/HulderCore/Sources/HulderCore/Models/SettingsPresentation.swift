import Foundation

/// One permission as the Settings window shows it.
public struct PermissionRow: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case allowed
        /// Not allowed yet, or not usable. Shown as a warning.
        case needsAttention
        /// Allowed earlier in this run and since removed. Shown red.
        case lost
    }

    public let level: Level
    public let text: String
    public let canGrant: Bool

    public init(level: Level, text: String, canGrant: Bool) {
        self.level = level
        self.text = text
        self.canGrant = canGrant
    }

    static let allowedText = "Allowed."
    static let orderFileMissingText = "Hulder needs access to the menu bar order file to reorder icons."
    static let lostText =
        "Access was removed. Hiding keeps working, but Hulder can't see changes to the menu bar until you allow it again."

    /// The order file. `granted` is `OrderAccess.isGranted()`, nil while it is unknown or when the platform
    /// offers no access. Once access is granted, only the reordering capability says whether it works.
    public static func orderFile(granted: Bool?, reordering: Availability) -> PermissionRow {
        if granted == false {
            return PermissionRow(level: .needsAttention, text: orderFileMissingText, canGrant: true)
        }
        switch reordering {
        case .available: return PermissionRow(level: .allowed, text: allowedText, canGrant: false)
        case .unavailable(let reason): return PermissionRow(level: .needsAttention, text: reason, canGrant: false)
        }
    }
}

extension MenuBarModel {
    /// The Accessibility permission. It can't be granted where hiding itself is unsupported.
    public var accessibilityRow: PermissionRow {
        switch capabilities.listing {
        case .available:
            return PermissionRow(level: .allowed, text: PermissionRow.allowedText, canGrant: false)
        case .unavailable(let reason):
            let canGrant = capabilities.hiding == .available
            return listingWasAvailable
                ? PermissionRow(level: .lost, text: PermissionRow.lostText, canGrant: canGrant)
                : PermissionRow(level: .needsAttention, text: reason, canGrant: canGrant)
        }
    }
}

public struct CapabilityLine: Equatable, Sendable, Identifiable {
    public let name: String
    public let isAvailable: Bool
    /// "Available", or the fixed reason.
    public let detail: String

    public var id: String { name }
}

extension Capabilities {
    static let rehideOffReason = "macOS doesn't let Hulder see every open menu."

    /// Each capability with its reason, in the order About lists them.
    public var lines: [CapabilityLine] {
        func line(_ name: String, _ availability: Availability) -> CapabilityLine {
            switch availability {
            case .available: CapabilityLine(name: name, isAvailable: true, detail: "Available")
            case .unavailable(let reason): CapabilityLine(name: name, isAvailable: false, detail: reason)
            }
        }
        return [
            line("Hiding", hiding),
            line("Listing menu bar items", listing),
            line("Reordering", reordering),
            menuTracking == .full
                ? CapabilityLine(name: "Automatic hiding", isAvailable: true, detail: "Available")
                : CapabilityLine(name: "Automatic hiding", isAvailable: false, detail: "Off: \(Self.rehideOffReason)"),
        ]
    }

    /// Why the rehide delay does nothing, or nil when it applies.
    public var rehideNote: String? {
        menuTracking == .full ? nil : "Automatic hiding is off: \(Self.rehideOffReason)"
    }

    /// Shown in About when Hulder can't hide anything on this macOS.
    public var unsupportedNotice: String? {
        if case .unavailable(let reason) = hiding { "Not supported on this macOS: \(reason)" } else { nil }
    }
}

extension RehideDelay {
    public var title: String {
        switch self {
        case .seconds5: "5 seconds"
        case .seconds10: "10 seconds"
        case .seconds30: "30 seconds"
        case .seconds60: "60 seconds"
        case .never: "Never"
        }
    }
}

extension Section {
    public var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }
}

extension LayoutOutcome {
    /// What to tell the user after Restore. Unlike `notice`, a success gets a line, because the button
    /// has no other sign that it did anything.
    public var restoreNotice: LayoutNotice? {
        switch self {
        case .done: LayoutNotice(text: "Restored the menu bar order.", isProblem: false)
        case .unchanged:
            LayoutNotice(text: "The menu bar already has the order from before Hulder's last change.", isProblem: false)
        default: notice
        }
    }
}
