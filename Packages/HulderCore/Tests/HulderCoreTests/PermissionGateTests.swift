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

        gate.update(capabilities(listing: missing))

        #expect(!gate.feedsDriver)
    }

    @Test func theDriverIsFedAfterTheGrantAndAfterARevocation() {
        var gate = PermissionGate()

        gate.update(capabilities(listing: .available))
        #expect(gate.feedsDriver)

        gate.update(capabilities(listing: missing))
        #expect(gate.feedsDriver)
    }

    @Test func onboardingShowsAtLaunchWithoutTheGrantAndEndsWithIt() {
        var gate = PermissionGate()
        #expect(!gate.showsOnboarding)

        gate.update(capabilities(listing: missing))
        #expect(gate.showsOnboarding)

        gate.update(capabilities(listing: .available))
        #expect(!gate.showsOnboarding)
    }

    @Test func onboardingDoesNotReturnAfterARevocation() {
        var gate = PermissionGate()
        gate.update(capabilities(listing: .available))

        gate.update(capabilities(listing: missing))

        #expect(!gate.showsOnboarding)
    }

    @Test func onboardingIsNotShownWhenHidingIsUnavailable() {
        var gate = PermissionGate()

        gate.update(capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."), listing: missing))

        #expect(!gate.showsOnboarding)
        #expect(!gate.feedsDriver)
    }
}
