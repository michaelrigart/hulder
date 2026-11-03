import AppKit
import HulderCore
import SwiftUI

import enum HulderCore.Section

/// Assigns apps to sections and puts their items in order. It holds no rules: every decision comes
/// from `MenuBarModel`, `StateModel` and `LayoutActions`.
struct LayoutView: View {
    /// The result of one action. The id tells two identical results apart.
    private struct ActionResult: Equatable {
        let id: Int
        let outcome: LayoutOutcome
    }

    let state: StateModel
    let menuBar: MenuBarModel
    let actions: LayoutActions
    let access: (any OrderAccess)?
    let platform: any MenuBarPlatform

    @State private var result: ActionResult?
    @State private var actionCount = 0

    var body: some View {
        let layout = state.state.layout
        let rows = menuBar.rows(layout: layout)
        let misplaced = menuBar.misplaced(layout: layout)
        let readOnly = menuBar.readOnlyItems()

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    ForEach(Section.displayOrder, id: \.self) { section in
                        LayoutRowView(
                            section: section, entries: rows[section] ?? [], misplaced: misplaced, layout: layout,
                            menuBar: menuBar, handlers: handlers)
                    }
                }
                if !misplaced.isEmpty { tidyBar }
                if let notice = result?.outcome.notice { noticeLine(notice) }
                ReorderingAccessView(menuBar: menuBar, access: access, onGranted: { result = nil })
                if !readOnly.isEmpty { ReadOnlyItemsView(items: readOnly) }
                Divider()
                LayoutLimitsView()
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity, minHeight: 360, idealHeight: 640, maxHeight: .infinity)
        .task { platform.requestScan() }
        .onChange(of: result?.id) {
            if let text = result?.outcome.notice?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var handlers: LayoutRowHandlers {
        LayoutRowHandlers(
            drop: { key, section, anchor in run { await actions.drop(key, to: section, before: anchor) } },
            move: { unit, section in run { await actions.move(unit, to: section) } },
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
        Label(notice.text, systemImage: notice.isProblem ? "exclamationmark.triangle" : "info.circle")
            .foregroundStyle(notice.isProblem ? Color.red : Color.secondary)
    }

    /// Clears the previous line when an action starts, then shows what this one did, unless a newer
    /// action has started since.
    private func run(_ operation: @escaping () async -> LayoutOutcome) {
        actionCount += 1
        let id = actionCount
        result = nil
        Task {
            let outcome = await operation()
            if id == actionCount { result = ActionResult(id: id, outcome: outcome) }
        }
    }
}
