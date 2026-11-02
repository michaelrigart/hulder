import AppKit
import HulderCore
import SwiftUI

import enum HulderCore.Section
import struct HulderCore.Layout

/// What the rows can ask for. `LayoutView` turns each into a `LayoutActions` call.
struct LayoutRowHandlers {
    var drop: (ItemKey, Section, ItemKey?) -> Void
    var move: (AppID, Section) -> Void
    var forget: (AppID) -> Void
}

extension Section {
    /// The rows run top to bottom as the sections run left to right on the bar.
    static let displayOrder: [Section] = [.alwaysHidden, .hidden, .visible]

    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }

    /// The section one step left (toward hidden) or right on the bar, or nil at the end.
    func neighbour(toward direction: HorizontalDirection) -> Section? {
        guard let index = Self.displayOrder.firstIndex(of: self) else { return nil }
        let next = direction == .leading ? index - 1 : index + 1
        return Self.displayOrder.indices.contains(next) ? Self.displayOrder[next] : nil
    }
}

/// One section: its title and a strip of its entries in bar order. Dropping on the strip puts an
/// item at the end of the row.
struct LayoutRowView: View {
    let section: Section
    let entries: [LayoutEntry]
    let misplaced: Set<ItemKey>
    let layout: Layout
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
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(entries, id: \.rowID) { entry in
                    LayoutEntryView(
                        entry: entry, section: section,
                        isMisplaced: entry.itemKey.map(misplaced.contains) ?? false,
                        lastSeen: entry.appID.flatMap { layout.apps[$0]?.lastSeen },
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
    let isMisplaced: Bool
    let lastSeen: Date?
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
        icon
            .overlay(alignment: .topTrailing) {
                if isMisplaced {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .font(.caption)
                }
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .opacity(dropTargeted ? 1 : 0)
            }
            .draggable(item.key.raw)
            .dropDestination(for: String.self) { dropped, _ in
                guard let raw = dropped.first, raw != item.key.raw else { return false }
                handlers.drop(ItemKey(raw: raw), section, item.key)
                return true
            } isTargeted: { dropTargeted = $0 }
            .focusable()
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard press.modifiers == [.command, .option], let app = entry.appID,
                      let target = section.neighbour(toward: press.key == .leftArrow ? .leading : .trailing)
                else { return .ignored }
                handlers.move(app, target)
                return .handled
            }
            .modifier(EntryChrome(entry: entry, section: section, lastSeen: lastSeen, handlers: handlers))
            .accessibilityValue(isMisplaced ? "Out of place on the menu bar" : "")
    }

    private var absent: some View {
        icon
            .opacity(0.4)
            .modifier(EntryChrome(entry: entry, section: section, lastSeen: lastSeen, handlers: handlers))
    }

    private var icon: some View {
        AppIconView(bundleID: entry.appID?.bundleID, size: iconSize)
            .padding(6)
    }
}

/// The tooltip, the VoiceOver label and the "Move to" and "Forget" actions every entry shares.
private struct EntryChrome: ViewModifier {
    let entry: LayoutEntry
    let section: Section
    let lastSeen: Date?
    let handlers: LayoutRowHandlers

    private var targets: [Section] { Section.displayOrder.filter { $0 != section } }

    func body(content: Content) -> some View {
        let label = entry.label(lastSeen: lastSeen)
        content
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityActions { voiceOverActions }
            .contextMenu { menuActions }
    }

    @ViewBuilder
    private var menuActions: some View {
        if let app = entry.appID {
            Menu("Move to") {
                ForEach(targets, id: \.self) { target in
                    Button(target.title) { handlers.move(app, target) }
                }
            }
            if case .absentApp = entry {
                Button("Forget") { handlers.forget(app) }
            }
        }
    }

    @ViewBuilder
    private var voiceOverActions: some View {
        if let app = entry.appID {
            ForEach(targets, id: \.self) { target in
                Button("Move to \(target.title)") { handlers.move(app, target) }
            }
            if case .absentApp = entry {
                Button("Forget") { handlers.forget(app) }
            }
        }
    }
}

/// Items Hulder lists but can't move, each with its reason.
struct ReadOnlyItemsView: View {
    let items: [MenuBarItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't be moved")
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

// MARK: - Names and labels

extension LayoutEntry {
    var rowID: String {
        switch self {
        case .item(let item): item.key.raw
        case .absentApp(let app, _): "absent:" + app.bundleID
        }
    }

    var itemKey: ItemKey? {
        if case .item(let item) = self { item.key } else { nil }
    }

    var appID: AppID? {
        switch self {
        case .item(let item): item.owner.appID
        case .absentApp(let app, _): app
        }
    }

    /// "<app name>: <description or title>" for an item. For an app that isn't on the bar, its name
    /// and the day it was last seen.
    func label(lastSeen: Date?) -> String {
        switch self {
        case .item(let item):
            return item.label
        case .absentApp(_, let name):
            guard let lastSeen else { return "\(name): not running" }
            return "\(name): not running, last seen \(lastSeen.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

extension MenuBarItem {
    var ownerName: String {
        switch owner {
        case .app(_, let name): name
        case .unresolved(let processName): processName
        }
    }

    var label: String {
        let detail = [description, title].compactMap { $0 }.first { !$0.isEmpty }
        return detail.map { "\(ownerName): \($0)" } ?? ownerName
    }

    var readOnlyReason: String {
        isManagedByMacOS ? "Managed by macOS" : "Hulder can't hide this: it has no app bundle"
    }
}
