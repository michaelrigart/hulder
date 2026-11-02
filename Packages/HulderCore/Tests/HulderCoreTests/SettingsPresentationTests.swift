import Foundation
import Testing
@testable import HulderCore

@MainActor
struct SettingsPresentationTests {
    private func capabilities(
        hiding: Availability = .available, listing: Availability = .available,
        reordering: Availability = .available, tracking: MenuTracking = .full
    ) -> Capabilities {
        Capabilities(hiding: hiding, listing: listing, reordering: reordering, menuTracking: tracking)
    }

    // MARK: - Accessibility

    @Test func grantedAccessibilityIsAllowed() {
        let model = MenuBarModel(capabilities: capabilities())

        #expect(model.accessibilityRow.level == .allowed)
        #expect(!model.accessibilityRow.canGrant)
    }

    @Test func accessibilityNeverGrantedNeedsAttentionWithThePlatformsReason() {
        let model = MenuBarModel(capabilities: capabilities(listing: .unavailable("Accessibility access is not granted.")))

        #expect(model.accessibilityRow.level == .needsAttention)
        #expect(model.accessibilityRow.text == "Accessibility access is not granted.")
        #expect(model.accessibilityRow.canGrant)
    }

    @Test func accessibilityRemovedAfterBeingGrantedIsLostAndSaysHidingKeepsWorking() {
        let model = MenuBarModel(capabilities: capabilities())

        model.capabilities = capabilities(listing: .unavailable("Accessibility access is not granted."))

        #expect(model.accessibilityRow.level == .lost)
        #expect(model.accessibilityRow.text.contains("Hiding keeps working"))
        #expect(model.accessibilityRow.canGrant)
    }

    @Test func grantingAgainAfterALossIsAllowedAgain() {
        let model = MenuBarModel(capabilities: capabilities())
        model.capabilities = capabilities(listing: .unavailable("Accessibility access is not granted."))

        model.capabilities = capabilities()

        #expect(model.accessibilityRow.level == .allowed)
    }

    @Test func accessibilityOnAnUnsupportedMacOSCannotBeGranted() {
        let unsupported = Availability.unavailable("Hulder needs macOS 27 or later.")
        let model = MenuBarModel(capabilities: capabilities(hiding: unsupported, listing: unsupported))

        #expect(!model.accessibilityRow.canGrant)
    }

    // MARK: - Order file

    @Test func aGrantThatFailsIsExplainedByItsReason() {
        #expect(PermissionRow.orderFileProblem(for: OrderStoreError.unsupportedFormat("Format 3 isn't supported."))
            == "Format 3 isn't supported.")
        #expect(PermissionRow.orderFileProblem(for: OrderStoreError.noAccess) == "Hulder couldn't open that folder.")
        #expect(PermissionRow.orderFileProblem(for: OrderStoreError.io) == "Hulder couldn't set up reordering.")
        #expect(PermissionRow.orderFileProblem(for: CancellationError()) == "Hulder couldn't set up reordering.")
    }

    @Test func anUngrantedOrderFileCanBeGranted() {
        let row = PermissionRow.orderFile(granted: false, reordering: .unavailable("No access to the order file"))

        #expect(row.level == .needsAttention)
        #expect(row.canGrant)
    }

    @Test func aGrantedOrderFileWithWorkingReorderingIsAllowed() {
        let row = PermissionRow.orderFile(granted: true, reordering: .available)

        #expect(row.level == .allowed)
        #expect(!row.canGrant)
    }

    @Test func aGrantedOrderFileHulderCannotUseShowsTheReasonAndCannotBeGrantedAgain() {
        let row = PermissionRow.orderFile(granted: true, reordering: .unavailable("The order file format is not supported."))

        #expect(row.level == .needsAttention)
        #expect(row.text == "The order file format is not supported.")
        #expect(!row.canGrant)
    }

    // MARK: - Capabilities

    @Test func everyCapabilityShowsItsReasonWhenUnavailable() {
        let unsupported = Availability.unavailable("MenuBarClientCore is missing.")
        let lines = capabilities(hiding: unsupported, listing: .unavailable("Not allowed."), tracking: .unavailable).lines

        #expect(lines.map(\.name) == ["Hiding", "Listing menu bar items", "Reordering", "Automatic hiding"])
        #expect(lines.map(\.isAvailable) == [false, false, true, false])
        #expect(lines[0].detail == "MenuBarClientCore is missing.")
        #expect(lines[1].detail == "Not allowed.")
        #expect(lines[2].detail == "Available")
    }

    // Catches the partial text blaming macOS: partial means an app on the bar whose menus Hulder can't watch.
    @Test func partialMenuTrackingTurnsAutomaticHidingOffWithTheReason() {
        let lines = capabilities(tracking: .partial).lines

        #expect(lines[3].isAvailable == false)
        #expect(lines[3].detail == "Off while an app whose menus Hulder can't watch is on the menu bar.")
        #expect(capabilities(tracking: .unavailable).lines[3].detail == "Off: macOS doesn't let Hulder see every open menu.")
    }

    @Test func fullMenuTrackingKeepsTheRehideDelayEditable() {
        #expect(capabilities(tracking: .full).rehideNote == nil)
        #expect(
            capabilities(tracking: .partial).rehideNote
                == "Automatic hiding is off while an app whose menus Hulder can't watch is on the menu bar.")
        #expect(
            capabilities(tracking: .unavailable).rehideNote
                == "Automatic hiding is off: macOS doesn't let Hulder see every open menu.")
    }

    @Test func anUnsupportedMacOSIsExplainedWithTheHidingReason() {
        let unsupported = capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."))

        #expect(unsupported.unsupportedNotice == "Not supported on this macOS: Hulder needs macOS 27 or later.")
        #expect(capabilities().unsupportedNotice == nil)
    }

    // MARK: - Labels

    @Test func rehideDelaysAndSectionsHaveTitles() {
        #expect(RehideDelay.allCases.map(\.title) == ["5 seconds", "10 seconds", "30 seconds", "60 seconds", "Never"])
        #expect(Section.displayOrder.map(\.title) == ["Always Hidden", "Hidden", "Visible"])
    }

    @Test func theSettingsFileHasOneTitlePerStatus() {
        #expect(StoreStatus.ok.title == "OK")
        #expect(StoreStatus.recovered.title == "Recovered from a damaged file")
        #expect(StoreStatus.readOnly("Fixed text.").title == "Read-only. Fixed text.")
    }

    // MARK: - Restore

    @Test func restoringTellsTheUserWhatHappened() {
        #expect(LayoutOutcome.done.restoreNotice == LayoutNotice(text: "Restored the menu bar order.", isProblem: false))
        #expect(LayoutOutcome.unchanged.restoreNotice
            == LayoutNotice(text: "The menu bar already has the order from before Hulder's last change.", isProblem: false))
        #expect(LayoutOutcome.failed(.orderWriteFailed).restoreNotice
            == LayoutNotice(text: FailureKind.orderWriteFailed.message, isProblem: true))
        #expect(LayoutOutcome.unavailable("No access to the order file").restoreNotice
            == LayoutNotice(text: "No access to the order file", isProblem: true))
    }
}
