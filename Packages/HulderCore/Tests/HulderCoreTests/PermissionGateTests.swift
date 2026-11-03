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

    @Test func outsideApplicationsAGrantNeverFeedsTheDriver() {
        var gate = PermissionGate(installedInApplications: false)

        gate.update(capabilities(listing: missing))
        gate.update(capabilities(listing: .available))

        #expect(!gate.feedsDriver)
        #expect(gate.showsMoveNotice)
        #expect(!gate.showsOnboarding)
    }

    @Test func insideApplicationsThereIsNoMoveNotice() {
        var gate = PermissionGate()

        gate.update(capabilities(listing: missing))
        #expect(!gate.showsMoveNotice)

        gate.update(capabilities(listing: .available))
        #expect(!gate.showsMoveNotice)
        #expect(gate.feedsDriver)
    }

    @Test func theMoveNoticeIsNotShownWhenHidingIsUnavailable() {
        var gate = PermissionGate(installedInApplications: false)

        gate.update(capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."), listing: missing))

        #expect(!gate.showsMoveNotice)
    }

    @Test func noSequenceOfUpdatesFeedsTheDriverOutsideApplications() {
        let states: [Capabilities] = [
            capabilities(listing: missing),
            capabilities(listing: .available),
            capabilities(hiding: .unavailable("Hulder needs macOS 27 or later."), listing: .available),
        ]
        for first in states {
            for second in states {
                for third in states {
                    var gate = PermissionGate(installedInApplications: false)
                    for step in [first, second, third] {
                        gate.update(step)
                        #expect(!gate.feedsDriver)
                        #expect(!gate.showsOnboarding)
                    }
                }
            }
        }
    }
}
