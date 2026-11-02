import AppKit
import HulderCore
import SwiftUI

import enum HulderCore.Section

/// Assigns apps to sections and puts their items in order. It holds no rules: every decision comes
/// from `MenuBarModel`, `StateModel` and `LayoutActions`.
struct LayoutView: View {
    let state: StateModel
    let menuBar: MenuBarModel
    let actions: LayoutActions
    let access: (any OrderAccess)?
    let platform: any MenuBarPlatform

    @State private var outcome: LayoutOutcome?

    var body: some View {
        let layout = state.state.layout
        let rows = menuBar.rows(layout: layout)
        let misplaced = menuBar.misplaced(layout: layout)
        let readOnly = menuBar.readOnlyItems(layout: layout)

        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                ForEach(Section.displayOrder, id: \.self) { section in
                    LayoutRowView(
                        section: section, entries: rows[section] ?? [], misplaced: misplaced, layout: layout,
                        handlers: handlers)
                }
            }
            if !misplaced.isEmpty { tidyBar }
            if let notice = outcome?.notice { noticeLine(notice) }
            ReorderingAccessView(menuBar: menuBar, access: access)
            if !readOnly.isEmpty { ReadOnlyItemsView(items: readOnly) }
            Divider()
            LayoutLimitsView()
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .task { platform.requestScan() }
        .onChange(of: outcome) {
            if let text = outcome?.notice?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var handlers: LayoutRowHandlers {
        LayoutRowHandlers(
            drop: { key, section, anchor in run { await actions.drop(key, to: section, before: anchor) } },
            move: { app, section in run { await actions.move(app: app, to: section) } },
            forget: { state.forget($0) })
    }

    private var tidyBar: some View {
        HStack {
            Label("Some icons are on the wrong side of Hulder's icon.", systemImage: "exclamationmark.circle.fill")
                .symbolRenderingMode(.multicolor)
            Spacer()
            Button("Tidy") { run { await actions.tidy() } }
        }
    }

    private func noticeLine(_ notice: LayoutNotice) -> some View {
        Label(notice.text, systemImage: notice.symbol)
            .foregroundStyle(notice.isProblem ? Color.red : Color.secondary)
    }

    private func run(_ operation: @escaping () async -> LayoutOutcome) {
        Task { outcome = await operation() }
    }
}

struct LayoutNotice {
    let text: String
    let symbol: String
    let isProblem: Bool
}

extension LayoutOutcome {
    /// What to tell the user, or nil when the change needs no line.
    var notice: LayoutNotice? {
        switch self {
        case .done, .unchanged: nil
        case .saved: LayoutNotice(
            text: "Saved. macOS applies it when these icons are shown.", symbol: "info.circle", isProblem: false)
        case .failed(let kind): LayoutNotice(text: kind.message, symbol: "exclamationmark.triangle", isProblem: true)
        case .unavailable(let reason): LayoutNotice(text: reason, symbol: "exclamationmark.triangle", isProblem: true)
        }
    }
}
