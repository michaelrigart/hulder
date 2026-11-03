import Foundation

public enum LayoutOutcome: Equatable, Sendable {
    /// Why an item that changed section stays where it is on the bar.
    public enum InPlaceReason: Equatable, Sendable {
        /// Hulder can't tell the app's order entries apart.
        case uncertainKey
        /// macOS keeps the item at the right end of the bar.
        case pinned
    }

    /// The section changed or the bar now shows the new order.
    case done
    /// The new order is persisted, but none of the moved items is drawn, so the bar can't show it.
    case saved
    case unchanged
    /// The item is in the section, but its icons weren't repositioned.
    case sectionChangedInPlace(Section, InPlaceReason)
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
    /// Pinned items, Clock and Control Center, never move in the order.
    public static let pinnedText = "macOS keeps this item at the right end of the bar."

    private let state: StateModel
    private let menuBar: MenuBarModel
    private var order: OrderController?
    /// The inputs of `FirstSightingRule`. They only store what the platform last said.
    private var reordering = Availability.notChecked
    private var orderStoreUnobtainable = false

    public init(state: StateModel, menuBar: MenuBarModel, order: OrderController?) {
        self.state = state
        self.menuBar = menuBar
        self.order = order
    }

    // The four inputs of the first-sighting rule. Each returns true when it ended the waiting: the mode a pass that
    // read the order file would get was `.wait` and isn't any more. The caller then asks for a scan, so an app left
    // new by a waiting pass is recorded by the next pass even on an idle bar, before a later grant could place it.

    /// The order capability. A change of availability clears "the store couldn't be opened".
    @discardableResult
    public func reorderingChanged(_ availability: Availability) -> Bool {
        change {
            if availability != reordering { orderStoreUnobtainable = false }
            reordering = availability
        }
    }

    /// Installs the controller.
    @discardableResult
    public func setOrderController(_ order: OrderController) -> Bool {
        change {
            self.order = order
            orderStoreUnobtainable = false
        }
    }

    /// Reordering is available but the order store could not be opened.
    @discardableResult
    public func orderControllerUnobtainable() -> Bool {
        change { orderStoreUnobtainable = true }
    }

    @discardableResult
    public func removeOrderController() -> Bool {
        change { order = nil }
    }

    private func change(_ body: () -> Void) -> Bool {
        let before = firstSightingMode(passReadOrderFile: true)
        body()
        return before == .wait && firstSightingMode(passReadOrderFile: true) != .wait
    }

    private func firstSightingMode(passReadOrderFile: Bool) -> FirstSightingMode {
        FirstSightingRule.mode(
            reordering: reordering, hasController: order != nil, controllerUnobtainable: orderStoreUnobtainable,
            passReadOrderFile: passReadOrderFile)
    }

    /// Assigns the unit, then places all of its items at the divider.
    public func move(_ unit: AssignableUnit, to section: Section) async -> LayoutOutcome {
        let items = items(of: unit)
        guard !isOwn(unit) else { return .unchanged }
        guard let changed = assign(unit, name: name(of: items), to: section) else { return .unchanged }
        if let kept = keptInPlace(items, sectionChanged: changed, to: section) { return kept }
        let keys = items.map(\.key)
        guard !keys.isEmpty, let order else { return changed ? .done : .unchanged }
        guard let snapshot = snapshot() else { return noSnapshot }
        let outcome = await order.perform {
            OrderPlanner.placeAtDivider(keys, section: section, in: snapshot.context($0))
        }
        return finish(outcome, sectionChanged: changed)
    }

    public func move(app: AppID, to section: Section) async -> LayoutOutcome {
        await move(.app(app), to: section)
    }

    /// Assigns the dropped item's unit. The item goes before `before`, or to the end of the row when
    /// that item is gone. Within a section only the item moves; across sections the unit's other items
    /// go to the divider, as in `move`. A drop within a section that can't move the item records nothing, so an
    /// Apple item stays unassigned.
    public func drop(_ key: ItemKey, to section: Section, before anchor: ItemKey?) async -> LayoutOutcome {
        guard let item = menuBar.inventory.items.first(where: { $0.key == key }), let unit = item.unit, !isOwn(unit)
        else { return .unchanged }
        let sectionChanges = state.state.layout.effectiveSection(of: unit) != section
        let moving = sectionChanges ? items(of: unit) : [item]
        if !sectionChanges, let refusal = refusalWithinSection(item) { return refusal }
        guard let changed = assign(unit, name: name(of: [item]), to: section) else { return .unchanged }
        if let kept = keptInPlace(moving, sectionChanged: changed, to: section) { return kept }
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

    /// Records the apps a scan pass found, and places the new ones, as `FirstSightingRule` allows. Placing is one
    /// change: one backup and one write. Only items on the wrong side of the divider for their section move, and
    /// those keep their order, so a bar the user arranged is left alone. Items whose key is uncertain are skipped.
    /// Does nothing without a divider; a failure is recorded.
    ///
    /// Called after every scan pass, with every app it found. `orderEntriesAvailable` says the pass ran with the
    /// order file's entries, so its items carry the keys the file knows. While the pass can't place, a new app stays
    /// unrecorded and is new again in the next pass; the apps the layout knows are recorded either way.
    public func recordSightings(
        _ sightings: [(AppID, String)], orderEntriesAvailable: Bool, at date: Date
    ) async {
        switch firstSightingMode(passReadOrderFile: orderEntriesAvailable) {
        case .wait:
            let known = state.state.layout.apps
            state.recordSightings(sightings.filter { known[$0.0] != nil }, at: date)
        case .recordOnly:
            state.recordSightings(sightings, at: date)
        case .recordAndPlace:
            await place(state.recordSightings(sightings, at: date))
        }
    }

    /// The certain items of the apps just recorded, from this pass's inventory. A key the order file doesn't hold
    /// moves nothing: an app whose entry macOS hadn't written when it was drawn is recorded all the same.
    private func place(_ apps: [AppID]) async {
        let keys = Set(apps.map(AssignableUnit.app).filter { !isOwn($0) }.flatMap {
            items(of: $0).filter(\.orderKeyIsCertain).map(\.key)
        })
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

    /// Why items that can't move in the order stay where they are, after the section is assigned: nothing is
    /// written. Without a change of section nothing happened. Nil when the items can move, or without reordering.
    private func keptInPlace(_ items: [MenuBarItem], sectionChanged: Bool, to section: Section) -> LayoutOutcome? {
        guard order != nil, let reason = inPlaceReason(items) else { return nil }
        guard sectionChanged else { return .unavailable(text(for: reason)) }
        return .sectionChangedInPlace(section, reason)
    }

    /// Checked before a drop within a section records anything.
    private func refusalWithinSection(_ item: MenuBarItem) -> LayoutOutcome? {
        guard order != nil else { return .unavailable(Self.noReorderingText) }
        if let reason = inPlaceReason([item]) { return .unavailable(text(for: reason)) }
        return snapshot() == nil ? noSnapshot : nil
    }

    private func inPlaceReason(_ items: [MenuBarItem]) -> LayoutOutcome.InPlaceReason? {
        if items.contains(where: { !$0.orderKeyIsCertain }) { return .uncertainKey }
        let pinned = menuBar.order?.pinned ?? []
        return items.contains { pinned.contains($0.key) } ? .pinned : nil
    }

    private func text(for reason: LayoutOutcome.InPlaceReason) -> String {
        switch reason {
        case .uncertainKey: Self.uncertainKeyText
        case .pinned: Self.pinnedText
        }
    }

    private func items(of unit: AssignableUnit) -> [MenuBarItem] {
        menuBar.inventory.items.filter { $0.unit == unit }
    }

    private func name(of items: [MenuBarItem]) -> String? {
        guard case .app(_, let name)? = items.first?.owner else { return nil }
        return name
    }

    /// Hulder's own app is the divider, which belongs to no section.
    private func isOwn(_ unit: AssignableUnit) -> Bool {
        menuBar.ownApp.map(AssignableUnit.app) == unit
    }

    /// Records an app the layout hasn't seen, then assigns it: `Layout.assign` ignores unknown apps. A system item
    /// is assigned as it is. Returns whether its section changed, or nil when the app is unknown and has no name to
    /// record.
    private func assign(_ unit: AssignableUnit, name: String?, to section: Section) -> Bool? {
        let layout = state.state.layout
        let changed = layout.effectiveSection(of: unit) != section
        switch unit {
        case .systemItem(let item):
            state.assign(item, to: section)
        case .app(let app):
            if layout.apps[app] == nil {
                guard let name else { return nil }
                state.recordSightings([(app, name)], at: Date())
            }
            state.assign(app, to: section)
        }
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
