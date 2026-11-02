import Foundation

/// Which way along the menu bar. Left is toward hidden.
public enum BarDirection: Sendable {
    case left
    case right
}

extension Section {
    /// The sections as the bar runs from left to right: the order of the Layout window's rows.
    public static let displayOrder: [Section] = [.alwaysHidden, .hidden, .visible]

    /// The section one step along the bar, or nil at its end.
    public func neighbour(_ direction: BarDirection) -> Section? {
        guard let index = Self.displayOrder.firstIndex(of: self) else { return nil }
        let next = direction == .left ? index - 1 : index + 1
        return Self.displayOrder.indices.contains(next) ? Self.displayOrder[next] : nil
    }
}

extension LayoutEntry {
    public var itemKey: ItemKey? {
        if case .item(let item) = self { item.key } else { nil }
    }
}

/// Where an item can move within its row.
public struct RowNeighbours: Equatable, Sendable {
    /// The item to its left, or nil at the start of the row.
    public let left: ItemKey?
    /// The item to its right, or nil at the end of the row.
    public let right: ItemKey?
    /// The item after `right`. Moving right is dropping before this item, or at the end of the row when
    /// it is nil.
    public let afterRight: ItemKey?

    public init(left: ItemKey?, right: ItemKey?, afterRight: ItemKey?) {
        self.left = left
        self.right = right
        self.afterRight = afterRight
    }

    /// The neighbours of each item of one row, in the row's order. Apps without an item on the bar
    /// are not neighbours and have no entry.
    public static func byItem(in entries: [LayoutEntry]) -> [ItemKey: RowNeighbours] {
        let keys = entries.compactMap(\.itemKey)
        var result: [ItemKey: RowNeighbours] = [:]
        for (index, key) in keys.enumerated() {
            let right = keys.indices.contains(index + 1) ? keys[index + 1] : nil
            let afterRight = keys.indices.contains(index + 2) ? keys[index + 2] : nil
            result[key] = RowNeighbours(left: index > 0 ? keys[index - 1] : nil, right: right, afterRight: afterRight)
        }
        return result
    }
}

extension MenuBarItem {
    public var ownerName: String {
        switch owner {
        case .app(_, let name): name
        case .unresolved(let processName): processName
        }
    }

    /// "<app name>: <description or title>", or the app name alone when the item has neither.
    public var label: String {
        let detail = [description, title].compactMap { $0 }.first { !$0.isEmpty }
        return detail.map { "\(ownerName): \($0)" } ?? ownerName
    }

    /// Why Hulder can't assign the item. An item macOS manages is reported as such first, whatever its owner.
    public var readOnlyReason: String {
        isManagedByMacOS ? "Managed by macOS" : "Hulder can't hide this: it has no app bundle"
    }
}

extension MenuBarModel {
    /// The tooltip and VoiceOver label of a Layout entry. An app with no item on the bar is "not running"
    /// with the day it was last seen only when it isn't running; otherwise it is "not on the menu bar".
    public func label(
        of entry: LayoutEntry, layout: Layout,
        dateStyle: Date.FormatStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
    ) -> String {
        switch entry {
        case .item(let item):
            return item.label
        case .absentApp(let app, let name):
            if running.contains(app) { return "\(name): not on the menu bar" }
            guard let lastSeen = layout.apps[app]?.lastSeen else { return "\(name): not running" }
            return "\(name): not running, last seen \(lastSeen.formatted(dateStyle))"
        }
    }
}

/// A line under the rows that tells the user what a change did.
public struct LayoutNotice: Equatable, Sendable {
    public let text: String
    public let isProblem: Bool

    public init(text: String, isProblem: Bool) {
        self.text = text
        self.isProblem = isProblem
    }
}

extension LayoutOutcome {
    /// What to tell the user, or nil when the change needs no line.
    public var notice: LayoutNotice? {
        switch self {
        case .done, .unchanged: nil
        case .saved: LayoutNotice(text: "Saved. macOS applies it when these icons are shown.", isProblem: false)
        case .failed(let kind): LayoutNotice(text: kind.message, isProblem: true)
        case .unavailable(let reason): LayoutNotice(text: reason, isProblem: true)
        }
    }
}
