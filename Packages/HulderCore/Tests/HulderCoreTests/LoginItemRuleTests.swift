import Testing
@testable import HulderCore

struct LoginItemRuleTests {
    @Test func turningItOnRegistersOnlyAnItemThatIsNotRegistered() {
        #expect(LoginItemRule.action(enabled: true, status: .notRegistered) == .register)
        // Enabled is done; requires-approval is the user's choice in System Settings and is not overridden.
        #expect(LoginItemRule.action(enabled: true, status: .enabled) == .none)
        #expect(LoginItemRule.action(enabled: true, status: .requiresApproval) == .none)
        #expect(LoginItemRule.action(enabled: true, status: .notFound) == .none)
    }

    @Test func turningItOffUnregistersAnItemThatIsEnabledOrWaitingForApproval() {
        #expect(LoginItemRule.action(enabled: false, status: .enabled) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .requiresApproval) == .unregister)
        #expect(LoginItemRule.action(enabled: false, status: .notRegistered) == .none)
        #expect(LoginItemRule.action(enabled: false, status: .notFound) == .none)
    }
}
