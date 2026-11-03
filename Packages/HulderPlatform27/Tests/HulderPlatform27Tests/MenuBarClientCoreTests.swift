import Foundation
import Testing
import HulderCore
@testable import HulderPlatform27

@Test func missingClassIsUnavailable() {
    let core = MenuBarClientCore(resolver: .missing(["MBAssessmentModeAssertion"]))
    #expect(core.availability == .unavailable("MBAssessmentModeAssertion missing"))
}

@Test func missingConfigurationClassIsUnavailable() {
    let core = MenuBarClientCore(resolver: .missing(["MBAssessmentModeConfiguration"]))
    #expect(core.availability == .unavailable("MBAssessmentModeConfiguration missing"))
}

@Test func failedFrameworkLoadIsUnavailable() {
    let core = MenuBarClientCore(resolver: .frameworkMissing)
    #expect(core.availability == .unavailable("MenuBarClientCore missing"))
}

@Test func classWithoutTheExpectedSelectorIsUnavailable() {
    let resolver = ClassResolver(loadFramework: { _ in true }, lookup: { _ in NSObject.self })
    let core = MenuBarClientCore(resolver: resolver)
    #expect(core.availability == .unavailable("initWithAllowedSystemItems:allowedBundleIdentifiers: missing"))
}
