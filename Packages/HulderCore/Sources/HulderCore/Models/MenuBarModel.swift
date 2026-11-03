import Foundation
import Observation

public enum FailureKind: String, Equatable, Sendable, CaseIterable {
    case hidingRejected
    case hidingTimedOut
    case hidingUnavailable
    case orderUnconfirmed
    case orderGaveUp
    case orderWriteFailed
    case settingsNotSaved

    /// A failure to hide items, as against one of the order or of the settings.
    public var isHiding: Bool {
        switch self {
        case .hidingRejected, .hidingTimedOut, .hidingUnavailable: true
        case .orderUnconfirmed, .orderGaveUp, .orderWriteFailed, .settingsNotSaved: false
        }
    }

    public var message: String {
        switch self {
        case .hidingRejected: "macOS refused to hide items."
        case .hidingTimedOut: "Hiding didn't take effect: macOS didn't answer in time."
        case .hidingUnavailable: "Hiding isn't available on this version of macOS."
        case .orderUnconfirmed: "The new order didn't show up on the menu bar."
        case .orderGaveUp: "The menu bar order kept changing, so Hulder stopped."
        case .orderWriteFailed: "Hulder couldn't save the new order."
        case .settingsNotSaved: "Hulder couldn't save its settings."
        }
    }
}

public struct FailureRecord: Equatable, Sendable {
    public var date: Date
    public var kind: FailureKind

    public init(date: Date, kind: FailureKind) {
        self.date = date
        self.kind = kind
    }
}

public enum LayoutEntry: Hashable, Sendable {
    case item(MenuBarItem)
    case absentApp(AppID, name: String)
}

@MainActor @Observable
public final class MenuBarModel {
    public static let failureLimit = 10

    public var inventory: InventorySnapshot = .empty
    public var order: BarOrder?
    /// The item key of Hulder's own icon.
    public var divider: ItemKey?
    public var capabilities: Capabilities {
        didSet { if capabilities.listing == .available { listingWasAvailable = true } }
    }
    /// Whether listing has been available at any point since launch: a later loss is a revocation.
    public private(set) var listingWasAvailable: Bool
    public var running: Set<AppID> = []
    /// What the status item currently shows of the hidden sections.
    public var revealState: RevealState = .hidden
    public private(set) var failures: [FailureRecord] = []
    /// How many failures have been recorded, including those the list has dropped.
    public private(set) var recordedFailureCount = 0

    public var lastFailure: FailureKind? { failures.last?.kind }

    /// The newest hiding failure that no later `.applied` or `.unchanged` outcome has superseded. This is what the
    /// status menu shows: order and settings failures are reported where they happen.
    public private(set) var hidingFailure: FailureKind?

    public init(
        capabilities: Capabilities = Capabilities(
            hiding: .notChecked,
            listing: .notChecked,
            reordering: .notChecked,
            menuTracking: .unavailable)
    ) {
        self.capabilities = capabilities
        listingWasAvailable = capabilities.listing == .available
    }

    public func recordFailure(_ kind: FailureKind, at date: Date) {
        failures.append(FailureRecord(date: date, kind: kind))
        recordedFailureCount += 1
        if kind.isHiding { hidingFailure = kind }
        if failures.count > Self.failureLimit {
            failures.removeFirst(failures.count - Self.failureLimit)
        }
    }

    /// Takes the result of a concealment request: a failure is recorded. An applied request, or one that
    /// found the bar already matching, ends the hiding failure. A superseded one says nothing new.
    public func recordConcealment(_ outcome: ApplyOutcome, at date: Date) {
        switch outcome {
        case .applied, .unchanged: hidingFailure = nil
        case .failed(.rejected): recordFailure(.hidingRejected, at: date)
        case .failed(.timedOut): recordFailure(.hidingTimedOut, at: date)
        case .failed(.unavailable): recordFailure(.hidingUnavailable, at: date)
        case .superseded: break
        }
    }

    /// The assignable entries of each section: items in bar order, then the layout's apps that have
    /// no items, by name. Hulder's own items, items macOS manages other than its hideable modules, and
    /// unresolved owners are not assignable and never appear.
    public func rows(layout: Layout) -> [Section: [LayoutEntry]] {
        var rows = Dictionary(uniqueKeysWithValues: Section.allCases.map { ($0, [LayoutEntry]()) })
        var present: Set<AppID> = []
        for item in inventory.items {
            if let app = item.owner.appID { present.insert(app) }
        }
        for item in inBarOrder() {
            guard let unit = item.unit, unit != ownApp.map(AssignableUnit.app) else { continue }
            rows[layout.effectiveSection(of: unit), default: []].append(.item(item))
        }
        let absent = layout.apps
            .filter { !present.contains($0.key) }
            .sorted { ($0.value.name, $0.key) < ($1.value.name, $1.key) }
        for (app, known) in absent {
            rows[known.section, default: []].append(.absentApp(app, name: known.name))
        }
        return rows
    }

    /// The items Hulder lists but can't assign: those macOS manages other than its hideable modules, and those with
    /// an unresolved owner, in bar order. Never Hulder's own items.
    public func readOnlyItems() -> [MenuBarItem] {
        inBarOrder().filter { $0.key != divider && $0.unit == nil }
    }

    /// Hulder's own app: the owner of its divider item. Nil while the divider is unknown or not drawn.
    var ownApp: AppID? {
        divider.flatMap { key in inventory.items.first { $0.key == key } }?.owner.appID
    }

    /// The items on the wrong side of the divider. Empty without an order.
    public func misplaced(layout: Layout) -> Set<ItemKey> {
        guard let order else { return [] }
        let context = OrderContext(order: order, divider: divider, items: inventory.items, layout: layout)
        return Set(OrderPlanner.misplaced(in: context))
    }

    // Items the order lists come first, in its order. The rest, and every item when there is no
    // order, go by `barPosition`, with undrawn items last in inventory order.
    private func inBarOrder() -> [MenuBarItem] {
        let ranks = Dictionary(
            (order?.keys ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = inventory.items.enumerated().map { (index: $0, item: $1) }
        return indexed.sorted { lhs, rhs in
            switch (ranks[lhs.item.key], ranks[rhs.item.key]) {
            case (let left?, let right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                switch (lhs.item.barPosition, rhs.item.barPosition) {
                case (let left?, let right?): return left == right ? lhs.index < rhs.index : left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.index < rhs.index
                }
            }
        }.map(\.item)
    }
}
