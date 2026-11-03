import ApplicationServices
import CoreGraphics
import Testing
@testable import HulderPlatform27

private func item(_ pid: pid_t, x: Double) -> AgentChild {
    .group(DrawnGroup(pid: pid, frame: CGRect(x: x, y: 0, width: 24, height: 24)))
}

// Catches the blocker: with nothing in macOS's overflow there is no indicator, and requiring one made every read of
// the bar fail.
@Test func aDialogOfItemsWithoutAnOverflowIndicatorGivesASnapshotWithNone() {
    let snapshot = MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: [item(10, x: 50), item(20, x: 10)])

    #expect(snapshot == BarSnapshot(groups: [
        DrawnGroup(pid: 20, frame: CGRect(x: 10, y: 0, width: 24, height: 24)),
        DrawnGroup(pid: 10, frame: CGRect(x: 50, y: 0, width: 24, height: 24)),
    ], overflowIndicatorX: nil))
}

@Test func anOverflowIndicatorBesideTheItemsGivesItsX() {
    let snapshot = MenuBarAgentReader.snapshot(
        subrole: kAXDialogSubrole, children: [item(10, x: 50), .overflowIndicator(minX: 700), .other])

    #expect(snapshot?.overflowIndicatorX == 700)
    #expect(snapshot?.groups.map(\.pid) == [10])
}

@Test func aDialogWithAnIndicatorAndNoItemsStillCounts() {
    let snapshot = MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: [.overflowIndicator(minX: 700)])

    #expect(snapshot == BarSnapshot(groups: [], overflowIndicatorX: 700))
}

@Test func aGroupThatNamesNoOwnerIsLeftOutButStillMarksTheWindow() {
    let snapshot = MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: [.group(nil), item(10, x: 50)])

    #expect(snapshot?.groups.map(\.pid) == [10])
    #expect(MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: [.group(nil)]) == BarSnapshot(groups: [], overflowIndicatorX: nil))
}

@Test func windowsThatHoldNeitherItemsNorTheIndicatorGiveNothing() {
    #expect(MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: []) == nil)
    #expect(MenuBarAgentReader.snapshot(subrole: kAXDialogSubrole, children: [.other, .other]) == nil)
    #expect(MenuBarAgentReader.snapshot(subrole: kAXStandardWindowSubrole, children: [item(10, x: 50)]) == nil)
    #expect(MenuBarAgentReader.snapshot(subrole: nil, children: [item(10, x: 50)]) == nil)
}
