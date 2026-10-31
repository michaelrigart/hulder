import Foundation

public struct AllowList: Equatable, Sendable {
    public var apps: Set<AppID>
    public var keepsAllSystemItems: Bool

    public init(apps: Set<AppID>, keepsAllSystemItems: Bool = true) {
        self.apps = apps
        self.keepsAllSystemItems = keepsAllSystemItems
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
        let hasConcealable = others.contains { layout.effectiveSection(of: $0) != .visible }
        if !hasConcealable { return .none }

        let held: Set<Section> = state == .hidden ? [.hidden, .alwaysHidden] : [.alwaysHidden]
        var allowed = others.filter { !held.contains(layout.effectiveSection(of: $0)) }
        for (app, known) in layout.apps where known.section == .visible {
            allowed.insert(app)
        }
        allowed.insert(own)
        return .allow(AllowList(apps: allowed, keepsAllSystemItems: true))
    }
}
