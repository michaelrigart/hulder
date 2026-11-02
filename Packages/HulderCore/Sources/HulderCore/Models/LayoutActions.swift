import Foundation

public enum LayoutOutcome: Equatable, Sendable {
    /// The section changed or the bar now shows the new order.
    case done
    /// The new order is persisted, but none of the moved items is drawn, so the bar can't show it.
    case saved
    case unchanged
    /// The text is fixed by Hulder and safe to show.
    case unavailable(String)
    case failed(FailureKind)
}

@MainActor
public final class LayoutActions {
    static let noDividerText = "Hulder's icon isn't on the menu bar."
    /// The icon is drawn but the order file has no entry for it. A Command-drag makes macOS write the entry of
    /// every drawn item.
    static let unsavedDividerText = "macOS hasn't saved where Hulder's icon is yet. ⌘-drag it once, then try again."
    public static let noReorderingText = "Reordering needs access to the menu bar order file."
    /// An item whose app has more entries in the order file than drawn items can't be matched to its entry.
    public static let uncertainKeyText =
        "Hulder can't tell this app's icons apart in macOS's saved order. ⌘-drag it on the menu bar instead."

    private let state: StateModel
    private let menuBar: MenuBarModel
    private var order: OrderController?
    private var placement: SightingPlacementGate

    public init(state: StateModel, menuBar: MenuBarModel, order: OrderController?) {
        self.state = state
        self.menuBar = menuBar
        self.order = order
        placement = SightingPlacementGate(hasController: order != nil)
    }

    /// Tells the first-sighting placement what the order capability is. Its first real answer decides
    /// whether the sightings made so far are ever placed.
    public func reorderingChanged(_ availability: Availability) {
        placement.reorderingChanged(availability)
    }

    /// Installs the controller. The first one also places the apps sighted before it was there, in one batch.
    public func setOrderController(_ order: OrderController) async {
        self.order = order
        await place(placement.controllerInstalled())
    }

    /// Reordering is available but the order store could not be opened. For the sightings still waiting for the
    /// first answer, that is a refusal: they are dropped.
    public func orderControllerUnobtainable() {
        placement.controllerUnobtainable()
    }

    public func removeOrderController() {
        order = nil
        placement.controllerRemoved()
    }

    /// Assigns the app, then places all of its items at the divider.
    public func move(app: AppID, to section: Section) async -> LayoutOutcome {
        let items = items(of: app)
        guard !isOwn(app) else { return .unchanged }
        if order != nil, hasUncertainKey(items) { return .unavailable(Self.uncertainKeyText) }
        guard let changed = assign(app, name: name(of: items), to: section) else { return .unchanged }
        let keys = items.map(\.key)
        guard !keys.isEmpty, let order else { return changed ? .done : .unchanged }
        guard let snapshot = snapshot() else { return noSnapshot }
        let outcome = await order.perform {
            OrderPlanner.placeAtDivider(keys, section: section, in: snapshot.context($0))
        }
        return finish(outcome, sectionChanged: changed)
    }

    /// Assigns the dropped item's app. The item goes before `before`, or to the end of the row when
    /// that item is gone. Within a section only the item moves; across sections the app's other items
    /// go to the divider, as in `move`.
    public func drop(_ key: ItemKey, to section: Section, before anchor: ItemKey?) async -> LayoutOutcome {
        guard let item = menuBar.inventory.items.first(where: { $0.key == key }),
              !item.isManagedByMacOS, let app = item.owner.appID, !isOwn(app)
        else { return .unchanged }
        let sectionChanges = state.state.layout.effectiveSection(of: app) != section
        let moving = sectionChanges ? items(of: app) : [item]
        if order != nil, hasUncertainKey(moving) { return .unavailable(Self.uncertainKeyText) }
        guard let changed = assign(app, name: name(of: [item]), to: section) else { return .unchanged }
        guard let order else { return changed ? .done : .unavailable(Self.noReorderingText) }
        guard let snapshot = snapshot() else { return noSnapshot }
        let others = changed ? moving.map(\.key).filter { $0 != key } : []
        let outcome = await order.perform { current in
            // The anchor may have left the bar since the drop; the planner can't tell that from
            // "already in place", so the item goes to the end of the row.
            let anchor = anchor.flatMap { current.keys.contains($0) ? $0 : nil }
            return snapshot.relocate(key, with: others, to: section, before: anchor, in: current)
        }
        return finish(outcome, sectionChanged: changed)
    }

    /// Moves every misplaced item to its side of the divider, except those whose key is uncertain: they stay,
    /// and when nothing else moved the outcome says why.
    public func tidy() async -> LayoutOutcome {
        guard let order else { return .unavailable(Self.noReorderingText) }
        guard let snapshot = snapshot() else { return noSnapshot }
        let uncertain = snapshot.uncertainKeys
        let outcome = finish(await order.perform {
            let context = snapshot.context($0)
            return OrderPlanner.tidy(in: context, only: Set(OrderPlanner.misplaced(in: context)).subtracting(uncertain))
        }, sectionChanged: false)
        guard outcome == .unchanged, !uncertain.isDisjoint(with: menuBar.misplaced(layout: snapshot.layout)) else {
            return outcome
        }
        return .unavailable(Self.uncertainKeyText)
    }

    public func restoreOrder() async -> LayoutOutcome {
        guard let order else { return .unavailable(Self.noReorderingText) }
        return finish(await order.restore(), sectionChanged: false)
    }

    /// Places the items of one scan's new apps, in one change: one backup and one write. Only items on
    /// the wrong side of the divider for their section move, and those keep their order, so a bar the
    /// user arranged is left alone. Items whose key is uncertain are skipped. Does nothing without a divider;
    /// a failure is recorded.
    ///
    /// Without an order controller the apps wait for one only until the order capability's first answer (see
    /// `SightingPlacementGate`); after that they are dropped.
    public func placeFirstSightings(_ apps: [AppID]) async {
        await place(placement.sighted(apps))
    }

    private func place(_ apps: [AppID]) async {
        let keys = Set(apps.filter { !isOwn($0) }.flatMap { items(of: $0).filter(\.orderKeyIsCertain).map(\.key) })
        guard !keys.isEmpty, let order, let snapshot = snapshot() else { return }
        let outcome = await order.perform { OrderPlanner.tidy(in: snapshot.context($0), only: keys) }
        _ = finish(outcome, sectionChanged: false)
    }

    // MARK: - Helpers

    private struct Snapshot: Sendable {
        let layout: Layout
        let items: [MenuBarItem]
        let divider: ItemKey

        var uncertainKeys: Set<ItemKey> {
            Set(items.filter { !$0.orderKeyIsCertain }.map(\.key))
        }

        func context(_ order: BarOrder) -> OrderContext {
            OrderContext(order: order, divider: divider, items: items, layout: layout)
        }

        /// The app's other items go to the divider, then the dropped item to the drop point.
        func relocate(
            _ key: ItemKey, with others: [ItemKey], to section: Section, before anchor: ItemKey?,
            in order: BarOrder
        ) -> OrderChange? {
            let first = OrderPlanner.placeAtDivider(others, section: section, in: context(order))
            let intermediate = BarOrder(keys: first?.target ?? order.keys, pinned: order.pinned)
            guard let second = OrderPlanner.drop([key], section: section, before: anchor, in: context(intermediate))
            else { return first }
            guard second.target != order.keys else { return nil }
            let moved = Set(first?.moved ?? []).union(second.moved)
            return OrderChange(target: second.target, moved: second.target.filter(moved.contains))
        }
    }

    /// Why there is no snapshot: no divider at all, or one the order file doesn't contain yet.
    private var noSnapshot: LayoutOutcome {
        .unavailable(menuBar.divider == nil ? Self.noDividerText : Self.unsavedDividerText)
    }

    /// Nil without a divider, and when the order file is known and has no entry for it: nothing can be
    /// placed against a position that isn't there.
    private func snapshot() -> Snapshot? {
        guard let divider = menuBar.divider, menuBar.order?.keys.contains(divider) ?? true else { return nil }
        return Snapshot(layout: state.state.layout, items: menuBar.inventory.items, divider: divider)
    }

    private func hasUncertainKey(_ items: [MenuBarItem]) -> Bool {
        items.contains { !$0.orderKeyIsCertain }
    }

    private func items(of app: AppID) -> [MenuBarItem] {
        menuBar.inventory.items.filter { $0.owner.appID == app && !$0.isManagedByMacOS }
    }

    private func name(of items: [MenuBarItem]) -> String? {
        guard case .app(_, let name)? = items.first?.owner else { return nil }
        return name
    }

    /// Hulder's own app is the divider, which belongs to no section.
    private func isOwn(_ app: AppID) -> Bool {
        menuBar.ownApp == app
    }

    /// Records an app the layout hasn't seen, then assigns it: `Layout.assign` ignores unknown apps.
    /// Returns whether its section changed, or nil when the app is unknown and has no name to record.
    private func assign(_ app: AppID, name: String?, to section: Section) -> Bool? {
        let layout = state.state.layout
        if layout.apps[app] == nil {
            guard let name else { return nil }
            state.recordSightings([(app, name)], at: Date())
        }
        let changed = layout.effectiveSection(of: app) != section
        state.assign(app, to: section)
        return changed
    }

    private func finish(_ outcome: OrderOutcome, sectionChanged: Bool) -> LayoutOutcome {
        switch outcome {
        case .applied: return .done
        case .saved: return .saved
        case .unchanged: return sectionChanged ? .done : .unchanged
        case .unavailable(let reason): return .unavailable(reason)
        case .unconfirmed: return fail(.orderUnconfirmed)
        case .gaveUp: return fail(.orderGaveUp)
        case .failed: return fail(.orderWriteFailed)
        }
    }

    private func fail(_ kind: FailureKind) -> LayoutOutcome {
        menuBar.recordFailure(kind, at: Date())
        return .failed(kind)
    }
}
