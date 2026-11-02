import Foundation

/// The text "Copy Diagnostics" puts on the pasteboard. It holds fixed text and counts only: no app names,
/// bundle identifiers or paths, and no system error descriptions.
public enum DiagnosticsReport {
    @MainActor
    public static func make(
        macOSVersion: String, appVersion: String, layout: Layout, menuBar: MenuBarModel, storeStatus: StoreStatus
    ) -> String {
        var lines = ["Hulder diagnostics", "macOS: \(macOSVersion)", "Hulder: \(appVersion)", "", "Capabilities"]
        for line in menuBar.capabilities.lines {
            lines.append(line.isAvailable ? "\(line.name): available" : "\(line.name): unavailable (\(line.detail))")
        }
        lines += ["", "Settings file: \(describe(storeStatus))", "", "Counts"]
        let perSection = Dictionary(grouping: layout.apps.values, by: \.section)
        for section in Section.displayOrder.reversed() {
            lines.append("\(section.title): \(perSection[section]?.count ?? 0)")
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

    private static func describe(_ status: StoreStatus) -> String {
        switch status {
        case .ok: "ok"
        case .recovered: "recovered from a damaged file"
        case .readOnly(let text): "read-only. \(text)"
        }
    }
}
