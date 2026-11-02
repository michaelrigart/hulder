import Testing
@testable import HulderCore

struct LoginItemRuleTests {
    @Test func turningItOnRegistersAnItemThatIsNotRegisteredOrWasNeverFound() {
        #expect(LoginItemRule.action(enabled: true, status: .notRegistered) == .register)
        // macOS reports a main app that was never registered as not found; a choice in System Settings shows as
        // requires-approval, so registering here overrides nothing.
        #expect(LoginItemRule.action(enabled: true, status: .notFound) == .register)
        // Enabled is done; requires-approval is the user's choice in System Settings and is not overridden.
        #expect(LoginItemRule.action(enabled: true, status: .enabled) == .none)
        #expect(LoginItemRule.action(enabled: true, status: .requiresApproval) == .none)
    }

    @Test func turningItOffUnregistersAnItemThatIsEnabledOrWaitingForApproval() {
        #expect(LoginItemRule.action(enabled: false, status: .enabled) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .requiresApproval) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .notRegistered) == .none)
        #expect(LoginItemRule.action(enabled: false, status: .notFound) == .none)
    }
}
