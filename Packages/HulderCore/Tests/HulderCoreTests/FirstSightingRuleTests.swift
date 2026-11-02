import Testing
@testable import HulderCore

struct FirstSightingRuleTests {
    private func mode(
        _ reordering: Availability, controller: Bool, unobtainable: Bool, readFile: Bool
    ) -> FirstSightingMode {
        FirstSightingRule.mode(
            reordering: reordering, hasController: controller, controllerUnobtainable: unobtainable,
            passReadOrderFile: readFile)
    }

    // The fifth row catches apps never recorded on a Mac without order access, where no pass reads the order file.
    @Test func everyInputGivesItsMode() {
        #expect(mode(.notChecked, controller: false, unobtainable: false, readFile: true) == .wait)
        #expect(mode(.available, controller: false, unobtainable: false, readFile: true) == .wait)
        #expect(mode(.available, controller: false, unobtainable: true, readFile: true) == .recordOnly)
        #expect(mode(.unavailable("x"), controller: false, unobtainable: false, readFile: true) == .recordOnly)
        #expect(mode(.unavailable("x"), controller: false, unobtainable: false, readFile: false) == .recordOnly)
        #expect(mode(.available, controller: true, unobtainable: false, readFile: true) == .recordAndPlace)
        #expect(mode(.available, controller: true, unobtainable: false, readFile: false) == .wait)
    }
}
