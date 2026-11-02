import HulderCore
import SwiftUI

/// The Settings window: one tab per pane. Each pane only renders; the rules are in `HulderCore`.
struct SettingsView: View {
    let state: StateModel
    let menuBar: MenuBarModel
    let actions: LayoutActions
    let access: (any OrderAccess)?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(state: state, menuBar: menuBar)
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsView(menuBar: menuBar, access: access)
            }
            Tab("Order", systemImage: "arrow.uturn.backward") {
                OrderSettingsView(menuBar: menuBar, actions: actions)
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView(state: state, menuBar: menuBar)
            }
        }
        .frame(width: 540, height: 460)
    }
}
