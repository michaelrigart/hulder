import Foundation

public struct AllowList: Equatable, Sendable {
    public var apps: Set<AppID>
    /// Empty keeps every system item.
    public var hiddenSystemItems: Set<SystemItemID>

    public init(apps: Set<AppID>, hiddenSystemItems: Set<SystemItemID> = []) {
        self.apps = apps
        self.hiddenSystemItems = hiddenSystemItems
    }
}

public enum Concealment: Equatable, Sendable {
    case none
    case allow(AllowList)
}

public enum ConcealmentPlanner {
    public static func plan(layout: Layout, state: RevealState, running: Set<AppID>, own: AppID) -> Concealment {
        if state == .revealedAll { return .none }

        let others = running.subtracting([own])
        let hasConcealable = others.contains { section(of: $0, in: layout) != .visible }
            || layout.systemItems.values.contains { $0 != .visible }
        if !hasConcealable { return .none }

        var allowed = others.filter { !state.conceals(section(of: $0, in: layout)) }
        for (app, known) in layout.apps where known.section == .visible {
            allowed.insert(app)
        }
        allowed.formUnion(AppleOwners.all.subtracting(AppleOwners.assignable))
        allowed.insert(own)
        let hidden = Set(layout.systemItems.filter { state.conceals($0.value) }.keys)
        return .allow(AllowList(apps: allowed, hiddenSystemItems: hidden))
    }

    /// Apple's owners count as Visible until the user assigns one; MenuBarAgent and Control Center can't be assigned.
    private static func section(of app: AppID, in layout: Layout) -> Section {
        if AppleOwners.assignable.contains(app) { return layout.section(of: app) ?? .visible }
        if AppleOwners.all.contains(app) { return .visible }
        return layout.effectiveSection(of: app)
    }
}
