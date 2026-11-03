import HulderCore
import SwiftUI

struct PermissionsSettingsView: View {
    let menuBar: MenuBarModel
    @State private var orderFile: OrderFileAccessFlow

    init(menuBar: MenuBarModel, access: (any OrderAccess)?) {
        self.menuBar = menuBar
        _orderFile = State(initialValue: OrderFileAccessFlow(access: access))
    }

    var body: some View {
        let accessibility = menuBar.accessibilityRow
        let order = PermissionRow.orderFile(granted: orderFile.granted, reordering: menuBar.capabilities.reordering)
        Form {
            Section {
                PermissionStatusView(row: accessibility)
                if accessibility.canGrant {
                    HStack {
                        Button("Ask for Permission", action: AccessibilityPrompt.ask)
                        Button("Open System Settings", action: AccessibilityPrompt.openSettings)
                    }
                }
            } header: {
                Text("Device Control and Data Access")
            } footer: {
                Text("Lets Hulder see which apps own menu bar items. It is under Privacy & Security in System Settings.")
            }
            Section {
                PermissionStatusView(row: order)
                if order.canGrant {
                    Button("Allow reordering…") { orderFile.allow(onGranted: {}) }
                        .disabled(orderFile.picking)
                }
                if let problem = orderFile.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Menu bar order file")
            } footer: {
                Text("Lets Hulder put icons in order. You pick the folder yourself; Hulder reads and writes nothing else.")
            }
        }
        .formStyle(.grouped)
        .task(id: menuBar.capabilities.reordering) { await orderFile.refresh() }
    }
}

/// A permission's state. The icon and the words say it as well as the colour does.
struct PermissionStatusView: View {
    let row: PermissionRow

    var body: some View {
        Label(row.text, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(prefix + row.text)
    }

    private var symbol: String {
        switch row.level {
        case .allowed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .lost: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch row.level {
        case .allowed: .green
        case .needsAttention: .orange
        case .lost: .red
        }
    }

    private var prefix: String {
        switch row.level {
        case .allowed: ""
        case .needsAttention: "Needs attention. "
        case .lost: "Removed. "
        }
    }
}
