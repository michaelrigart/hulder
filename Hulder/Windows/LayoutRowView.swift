import AppKit
import HulderCore
import SwiftUI

import enum HulderCore.Section
import struct HulderCore.Layout

/// What the rows can ask for. `LayoutView` turns each into a `LayoutActions` call.
struct LayoutRowHandlers {
    var drop: (ItemKey, Section, ItemKey?) -> Void
    var move: (AssignableUnit, Section) -> Void
    var forget: (AppID) -> Void
}

/// One section: its title and a strip of its entries in bar order. Dropping on the strip puts an
/// item at the end of the row.
struct LayoutRowView: View {
    let section: Section
    let entries: [LayoutEntry]
    let misplaced: Set<ItemKey>
    let layout: Layout
    let menuBar: MenuBarModel
    let handlers: LayoutRowHandlers

    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            Text(section.title)
                .font(.headline)
                .frame(width: 110, alignment: .leading)
            strip
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
    }

    private var strip: some View {
        let neighbours = RowNeighbours.byItem(in: entries)
        return ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(entries, id: \.rowID) { entry in
                    LayoutEntryView(
                        entry: entry, section: section, label: menuBar.label(of: entry, layout: layout),
                        isMisplaced: entry.itemKey.map(misplaced.contains) ?? false,
                        neighbours: entry.itemKey.flatMap { neighbours[$0] },
                        handlers: handlers)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first else { return false }
            handlers.drop(ItemKey(raw: raw), section, nil)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// One icon in a row: an item, or an app that has none on the bar.
struct LayoutEntryView: View {
    let entry: LayoutEntry
    let section: Section
    let label: String
    let isMisplaced: Bool
    let neighbours: RowNeighbours?
    let handlers: LayoutRowHandlers

    @ScaledMetric private var iconSize = 24
    @State private var dropTargeted = false

    var body: some View {
        switch entry {
        case .item(let item): present(item)
        case .absentApp: absent
        }
    }

    private func present(_ item: MenuBarItem) -> some View {
        icon(title: item.rowTitle)
            .overlay(alignment: .topTrailing) {
                if isMisplaced {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .font(.caption)
                        .help("On the wrong side of Hulder's icon. Tidy moves it back.")
                }
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .opacity(dropTargeted ? 1 : 0)
            }
            .modifier(DragSource(key: item.key, isEnabled: item.unit != nil))
            .dropDestination(for: String.self) { dropped, _ in
                guard let raw = dropped.first, raw != item.key.raw else { return false }
                handlers.drop(ItemKey(raw: raw), section, item.key)
                return true
            } isTargeted: { dropTargeted = $0 }
            .modifier(chrome)
            .accessibilityValue(isMisplaced ? "Out of place on the menu bar" : "")
    }

    private var absent: some View {
        icon(title: nil)
            .opacity(0.4)
            .modifier(chrome)
    }

    private func icon(title: String?) -> some View {
        HStack(spacing: 4) {
            AppIconView(bundleID: entry.appID?.bundleID, size: iconSize)
            if let title { Text(title).font(.callout).lineLimit(1) }
        }
        .padding(6)
    }

    private var chrome: EntryChrome {
        EntryChrome(entry: entry, section: section, label: label, neighbours: neighbours, handlers: handlers)
    }
}

/// Makes an item draggable by its key, when Hulder can assign it.
private struct DragSource: ViewModifier {
    let key: ItemKey
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled { content.draggable(key.raw) } else { content }
    }
}

/// What every entry shares: the tooltip, the VoiceOver label, focus, the keys and the context menu.
/// Everything a drag does is here too: "Move to" a section (⌘⌥←/→), and "Move Left" and "Move Right"
/// within the row (⌘←/→).
private struct EntryChrome: ViewModifier {
    let entry: LayoutEntry
    let section: Section
    let label: String
    let neighbours: RowNeighbours?
    let handlers: LayoutRowHandlers

    private var targets: [Section] { Section.displayOrder.filter { $0 != section } }
    private var canMoveLeft: Bool { neighbours?.dropPoint(moving: .left) != nil }
    private var canMoveRight: Bool { neighbours?.dropPoint(moving: .right) != nil }

    func body(content: Content) -> some View {
        content
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityActions { voiceOverActions }
            .contextMenu { menuActions }
            .focusable()
            .onKeyPress(keys: [.leftArrow, .rightArrow], action: keyPressed)
    }

    @ViewBuilder
    private var menuActions: some View {
        if entry.itemKey != nil, entry.unit != nil {
            Button("Move Left") { moveInRow(.left) }.disabled(!canMoveLeft)
            Button("Move Right") { moveInRow(.right) }.disabled(!canMoveRight)
        }
        if let unit = entry.unit {
            Menu("Move to") {
                ForEach(targets, id: \.self) { target in
                    Button(target.title) { handlers.move(unit, target) }
                }
            }
        }
        if case .absentApp(let app, _) = entry {
            Button("Forget") { handlers.forget(app) }
        }
    }

    @ViewBuilder
    private var voiceOverActions: some View {
        if let unit = entry.unit {
            if canMoveLeft { Button("Move Left") { moveInRow(.left) } }
            if canMoveRight { Button("Move Right") { moveInRow(.right) } }
            ForEach(targets, id: \.self) { target in
                Button("Move to \(target.title)") { handlers.move(unit, target) }
            }
        }
        if case .absentApp(let app, _) = entry {
            Button("Forget") { handlers.forget(app) }
        }
    }

    /// Arrow keys also carry the numeric-pad and function flags, so only the modifiers that matter count.
    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        let direction: BarDirection = press.key == .leftArrow ? .left : .right
        switch press.modifiers.intersection([.command, .option, .control, .shift]) {
        case [.command, .option]:
            guard let unit = entry.unit, let target = section.neighbour(direction) else { return .ignored }
            handlers.move(unit, target)
        case [.command]:
            guard entry.unit != nil, direction == .left ? canMoveLeft : canMoveRight else { return .ignored }
            moveInRow(direction)
        default:
            return .ignored
        }
        return .handled
    }

    private func moveInRow(_ direction: BarDirection) {
        guard let key = entry.itemKey, let point = neighbours?.dropPoint(moving: direction) else { return }
        handlers.drop(key, section, point.anchor)
    }
}

/// Items Hulder lists but can't assign, each with its reason.
struct ReadOnlyItemsView: View {
    let items: [MenuBarItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't be assigned")
                .font(.headline)
            ForEach(items, id: \.key) { item in
                HStack(spacing: 8) {
                    AppIconView(bundleID: item.owner.appID?.bundleID, size: 20)
                    VStack(alignment: .leading) {
                        Text(item.label)
                        Text(item.readOnlyReason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .help(item.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An app's icon from its bundle identifier, loaded off the main actor. A placeholder stands in until
/// it loads, and for an app that can't be found.
struct AppIconView: View {
    let bundleID: String?
    let size: CGFloat

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            guard let bundleID else { return }
            icon = await Self.loadIcon(bundleID)
        }
    }

    private nonisolated static func loadIcon(_ bundleID: String) async -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}

extension LayoutEntry {
    /// Identifies the entry in a row.
    var rowID: String {
        switch self {
        case .item(let item): item.key.raw
        case .absentApp(let app, _): "absent:" + app.bundleID
        }
    }

    /// What the entry assigns: its item's unit, or the app that has no item on the bar.
    var unit: AssignableUnit? {
        switch self {
        case .item(let item): item.unit
        case .absentApp(let app, _): .app(app)
        }
    }

    var appID: AppID? {
        switch self {
        case .item(let item): item.owner.appID
        case .absentApp(let app, _): app
        }
    }
}
