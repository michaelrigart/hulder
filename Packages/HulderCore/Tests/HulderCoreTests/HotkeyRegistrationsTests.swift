import Foundation
import Testing
@testable import HulderCore

struct HotkeyRegistrationsTests {
    private let toggle = Hotkey(keyCode: 4, modifiers: Hotkey.Modifiers.command.rawValue)
    private let revealAll = Hotkey(keyCode: 5, modifiers: Hotkey.Modifiers.option.rawValue)

    private func applied(_ registrations: inout HotkeyRegistrations) -> [HotkeyRegistrations.Step] {
        registrations.apply(toggle: toggle, revealAll: revealAll)
    }

    @Test func applyRegistersEachHotkeyThatIsSetAndNothingElse() {
        var registrations = HotkeyRegistrations()

        #expect(registrations.apply(toggle: toggle, revealAll: nil) == [.register(.toggle, toggle)])
    }

    @Test func applyingTheSameHotkeysAgainDoesNothing() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)

        #expect(applied(&registrations).isEmpty)
    }

    @Test func changingAHotkeyUnregistersTheOldOneThenRegistersTheNew() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)
        let other = Hotkey(keyCode: 6, modifiers: Hotkey.Modifiers.control.rawValue)

        #expect(registrations.apply(toggle: other, revealAll: revealAll)
            == [.unregister(.toggle), .register(.toggle, other)])
    }

    @Test func clearingAHotkeyUnregistersIt() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)

        #expect(registrations.apply(toggle: nil, revealAll: revealAll) == [.unregister(.toggle)])
    }

    @Test func suspendThenResumeRegistersExactlyTheDesiredSetOnce() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)

        #expect(registrations.suspend() == [.unregister(.toggle), .unregister(.revealAll)])
        #expect(registrations.resume() == [.register(.toggle, toggle), .register(.revealAll, revealAll)])
        #expect(registrations.resume().isEmpty)
    }

    @Test func applyWhileSuspendedRegistersNothingUntilResume() {
        var registrations = HotkeyRegistrations()
        _ = registrations.suspend()
        let changed = Hotkey(keyCode: 9, modifiers: Hotkey.Modifiers.control.rawValue)

        #expect(registrations.apply(toggle: changed, revealAll: nil).isEmpty)
        #expect(registrations.resume() == [.register(.toggle, changed)])
    }

    @Test func suspendingTwiceThenResumingOnceEndsRegistered() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)

        #expect(registrations.suspend().count == 2)
        #expect(registrations.suspend().isEmpty)
        #expect(registrations.resume() == [.register(.toggle, toggle), .register(.revealAll, revealAll)])
    }

    @Test func aRefusedCombinationIsNotRetriedUntilItsSettingChanges() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)
        registrations.registrationFailed(.toggle)

        #expect(applied(&registrations).isEmpty)
        let changed = Hotkey(keyCode: 9, modifiers: Hotkey.Modifiers.control.rawValue)
        #expect(registrations.apply(toggle: changed, revealAll: revealAll) == [.register(.toggle, changed)])
    }

    @Test func resumeAfterARefusalRetriesItOnce() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)
        registrations.registrationFailed(.toggle)

        #expect(registrations.suspend() == [.unregister(.revealAll)])
        #expect(registrations.resume() == [.register(.toggle, toggle), .register(.revealAll, revealAll)])
        registrations.registrationFailed(.toggle)
        #expect(applied(&registrations).isEmpty)
    }

    @Test func resumeWithoutSuspendDoesNothing() {
        var registrations = HotkeyRegistrations()
        _ = applied(&registrations)

        #expect(registrations.resume().isEmpty)
    }
}
