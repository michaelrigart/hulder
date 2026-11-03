import Foundation

/// The text "Copy Diagnostics" puts on the pasteboard. It holds fixed text and counts only: no app names,
/// bundle identifiers or paths, and no system error descriptions.
public enum DiagnosticsReport {
    @MainActor
    public static func make(
        macOSVersion: String, appVersion: String, layout: Layout, menuBar: MenuBarModel, storeStatus: StoreStatus
    ) -> String {
        var lines = ["Hulder diagnostics", "macOS: \(macOSVersion)", "Hulder: \(appVersion)", "", "Capabilities"]
        for line in menuBar.capabilities.availabilityLines {
            lines.append(line.isAvailable ? "\(line.name): available" : "\(line.name): unavailable (\(line.detail))")
        }
        lines += ["Menu tracking: \(menuBar.capabilities.menuTracking.name)"]
        lines += ["", "Settings file: \(storeStatus.title)", "", "Counts"]
        var perSection: [Section: Int] = [:]
        for section in layout.apps.values.map(\.section) + layout.systemItems.values {
            perSection[section, default: 0] += 1
        }
        for section in Section.displayOrder.reversed() {
            lines.append("\(section.title): \(perSection[section] ?? 0)")
        }
        lines += [
            "Running: \(menuBar.running.count)",
            "Items: \(menuBar.inventory.items.count)",
            "Stale owners: \(menuBar.inventory.stale.count)",
            "",
        ]
        if menuBar.failures.isEmpty {
            lines.append("Recent failures: none")
        } else {
            lines.append("Recent failures")
            let format = Date.ISO8601FormatStyle()
            for record in menuBar.failures {
                lines.append("\(record.date.formatted(format)) \(record.kind.rawValue): \(record.kind.message)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
