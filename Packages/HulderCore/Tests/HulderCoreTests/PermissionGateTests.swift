import Testing
@testable import HulderCore

struct PermissionGateTests {
    private func capabilities(
        hiding: Availability = .available, listing: Availability
    ) -> Capabilities {
        Capabilities(hiding: hiding, listing: listing, reordering: .available, menuTracking: .full)
    }

    private let missing = Availability.unavailable("Accessibility access is not granted.")

    @Test func nothingFeedsTheDriverBeforeTheGrant() {
        var gate = PermissionGate()
        #expect(!gate.feedsDriver)

        gate.update(capabilities(listing: missing), installedInApplications: true)

        #expect(!gate.feedsDriver)
    }

    @Test func theDriverIsFedAfterTheGrantAndAfterARevocation() {
        var gate = PermissionGate()

        gate.update(capabilities(listing: .available), installedInApplications: true)
        #expect(gate.feedsDriver)

        gate.update(capabilities(listing: missing), installedInApplications: true)
        #expect(gate.feedsDriver)
    }

    @Test func onboardingShowsAtLaunchWithoutTheGrantAndEndsWithIt() {
        var gate = PermissionGate()
        #expect(!gate.showsOnboarding)

        gate.update(capabilities(listing: missing), installedInApplications: true)
        #expect(gate.showsOnboarding)

        gate.update(capabilities(listing: .available), installedInApplications: true)
        #expect(!gate.showsOnboarding)
    }

    @Test func onboardingDoesNotReturnAfterARevocation() {
        var gate = PermissionGate()
        gate.update(capabilities(listing: .available), installedInApplications: true)

        gate.update(capabilities(listing: missing), installedInApplications: true)

        #expect(!gate.showsOnboarding)
    }

    @Test func onboardingIsNotShownWhenHidingIsUnavailable() {
        var gate = PermissionGate()

        gate.update(capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."), listing: missing), installedInApplications: true)

        #expect(!gate.showsOnboarding)
        #expect(!gate.feedsDriver)
    }

    @Test func outsideApplicationsAGrantNeverFeedsTheDriver() {
        var gate = PermissionGate()

        gate.update(capabilities(listing: missing), installedInApplications: false)
        gate.update(capabilities(listing: .available), installedInApplications: false)

        #expect(!gate.feedsDriver)
        #expect(gate.showsMoveNotice)
        #expect(!gate.showsOnboarding)
    }

    @Test func insideApplicationsThereIsNoMoveNotice() {
        var gate = PermissionGate()

        gate.update(capabilities(listing: missing), installedInApplications: true)
        #expect(!gate.showsMoveNotice)

        gate.update(capabilities(listing: .available), installedInApplications: true)
        #expect(!gate.showsMoveNotice)
        #expect(gate.feedsDriver)
    }

    @Test func theMoveNoticeIsNotShownWhenHidingIsUnavailable() {
        var gate = PermissionGate()

        gate.update(
            capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."), listing: missing),
            installedInApplications: false)

        #expect(!gate.showsMoveNotice)
    }
}
