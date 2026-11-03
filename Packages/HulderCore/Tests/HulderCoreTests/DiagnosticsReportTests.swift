import Foundation
import Testing
@testable import HulderCore

@MainActor
struct DiagnosticsReportTests {
    private let secret = AppID("com.example.secret")

    private func fixture() -> (Layout, MenuBarModel) {
        var layout = Layout()
        _ = layout.recordSighting(secret, name: "Secret App", at: Date(timeIntervalSince1970: 0))
        layout.assign(secret, to: .hidden)
        let menuBar = MenuBarModel(
            capabilities: Capabilities(
                hiding: .available, listing: .available,
                reordering: .unavailable("No access to the order file"), menuTracking: .full))
        menuBar.running = [secret]
        menuBar.inventory = InventorySnapshot(
            items: [MenuBarItem(key: ItemKey(raw: "k1"), owner: .app(secret, name: "Secret App"))], stale: [])
        menuBar.recordFailure(.orderUnconfirmed, at: Date(timeIntervalSince1970: 1_700_000_000))
        menuBar.recordFailure(.hidingTimedOut, at: Date(timeIntervalSince1970: 1_700_000_060))
        return (layout, menuBar)
    }

    private func report(storeStatus: StoreStatus = .ok) -> String {
        let (layout, menuBar) = fixture()
        return DiagnosticsReport.make(
            macOSVersion: "27.2", appVersion: "0.1.0", layout: layout, menuBar: menuBar, storeStatus: storeStatus)
    }

    @Test func reportHasCountsButNoNamesOrPaths() {
        let text = report()

        #expect(text.contains("Hidden: 1"))
        #expect(text.contains("Running: 1"))
        #expect(text.contains("Items: 1"))
        #expect(text.contains("orderUnconfirmed: The new order didn't show up on the menu bar."))
        #expect(text.contains("No access to the order file"))
        #expect(!text.contains("Secret App"))
        #expect(!text.contains("com.example.secret"))
    }

    @Test func reportNamesTheVersionsAndEverySectionCount() {
        let text = report()

        #expect(text.contains("macOS: 27.2"))
        #expect(text.contains("Hulder: 0.1.0"))
        #expect(text.contains("Visible: 0"))
        #expect(text.contains("Always Hidden: 0"))
        #expect(text.contains("Stale owners: 0"))
    }

    @Test func failuresCarryIso8601TimestampsOldestFirst() {
        let text = report()

        let first = text.range(of: "2023-11-14T22:13:20Z orderUnconfirmed")
        let second = text.range(of: "2023-11-14T22:14:20Z hidingTimedOut: Hiding didn't take effect")
        #expect(first != nil)
        #expect(second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }

    @Test func aReadOnlyStoreIsReportedWithItsFixedText() {
        let text = report(storeStatus: .readOnly("The settings file can't be read, so Hulder won't change it."))

        #expect(text.contains("Settings file: Read-only. The settings file can't be read, so Hulder won't change it."))
    }

    @Test func noFailuresIsSaidSo() {
        let (layout, _) = fixture()
        let text = DiagnosticsReport.make(
            macOSVersion: "27.2", appVersion: "0.1.0", layout: layout, menuBar: MenuBarModel(), storeStatus: .ok)

        #expect(text.contains("Recent failures: none"))
    }

    @Test func menuTrackingIsItsOwnLineSoPartialAndUnavailableReadDifferently() {
        func text(_ tracking: MenuTracking) -> String {
            let menuBar = MenuBarModel(
                capabilities: Capabilities(
                    hiding: .available, listing: .available, reordering: .available, menuTracking: tracking))
            return DiagnosticsReport.make(
                macOSVersion: "27.2", appVersion: "0.1.0", layout: Layout(), menuBar: menuBar, storeStatus: .ok)
        }

        #expect(text(.full).contains("Menu tracking: full"))
        #expect(text(.partial).contains("Menu tracking: partial"))
        #expect(text(.unavailable).contains("Menu tracking: unavailable"))
    }

    @Test func reportDoesNotRepeatTheAutomaticHidingLineOrDoubleUpUnavailable() {
        let menuBar = MenuBarModel(
            capabilities: Capabilities(
                hiding: .available, listing: .available, reordering: .available, menuTracking: .partial))
        let text = DiagnosticsReport.make(
            macOSVersion: "27.2", appVersion: "0.1.0", layout: Layout(), menuBar: menuBar, storeStatus: .ok)

        #expect(!text.contains("Automatic hiding"))
        #expect(!text.contains("unavailable (Off"))
    }
}
