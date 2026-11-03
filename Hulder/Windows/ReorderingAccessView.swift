import HulderCore
import SwiftUI

/// Shows why reordering is unavailable and offers to ask for access to the order file. It decides
/// nothing: whether access exists comes from `OrderFileAccessFlow`, and the reason from the capabilities.
struct ReorderingAccessView: View {
    let menuBar: MenuBarModel
    let access: (any OrderAccess)?
    /// Runs after a grant succeeds.
    let onGranted: () -> Void

    @State private var flow: OrderFileAccessFlow

    init(menuBar: MenuBarModel, access: (any OrderAccess)?, onGranted: @escaping () -> Void) {
        self.menuBar = menuBar
        self.access = access
        self.onGranted = onGranted
        _flow = State(initialValue: OrderFileAccessFlow(access: access))
    }

    var body: some View {
        content
            .task(id: menuBar.capabilities.reordering) { await flow.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        let row = PermissionRow.orderFile(granted: flow.granted, reordering: menuBar.capabilities.reordering)
        if row.canGrant {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(LayoutActions.noReorderingText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow reordering…") { flow.allow(onGranted: onGranted) }
                        .disabled(flow.picking)
                }
                if let problem = flow.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        } else if row.level == .needsAttention {
            Label(row.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
