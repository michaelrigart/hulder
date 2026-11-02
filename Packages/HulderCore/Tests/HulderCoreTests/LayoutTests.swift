import Foundation
import Testing
@testable import HulderCore

struct LayoutTests {
    let t0 = noon()
    let a = AppID("com.example.a")
    let b = AppID("com.example.b")

    @Test func firstSightingAssignsDefaultSection() {
        var layout = Layout()
        layout.defaultSection = .hidden
        let first = layout.recordSighting(a, name: "A", at: t0)
        #expect(first)
        #expect(layout.section(of: a) == .hidden)

        layout.defaultSection = .visible
        let second = layout.recordSighting(a, name: "A2", at: t0.addingTimeInterval(5))
        #expect(!second)
        #expect(layout.section(of: a) == .hidden)
        #expect(layout.apps[a]?.name == "A2")
    }

    @Test func aSightingOnTheSameDayLeavesLastSeenAlone() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        let before = layout

        _ = layout.recordSighting(a, name: "A", at: t0.addingTimeInterval(5))

        #expect(layout == before)
        #expect(layout.apps[a]?.lastSeen == t0)
    }

    @Test func aSightingOnALaterDayUpdatesLastSeen() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        let later = noon(days: 1)

        _ = layout.recordSighting(a, name: "A", at: later)

        #expect(layout.apps[a]?.lastSeen == later)
    }

    @Test func assignChangesOnlyThatApp() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        _ = layout.recordSighting(b, name: "B", at: t0)
        layout.assign(a, to: .alwaysHidden)
        #expect(layout.section(of: a) == .alwaysHidden)
        #expect(layout.section(of: b) == .visible)
    }

    @Test func forgetRemovesOnlyThatApp() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        _ = layout.recordSighting(b, name: "B", at: t0)
        layout.forget(a)
        #expect(layout.section(of: a) == nil)
        #expect(layout.section(of: b) == .visible)
    }

    @Test func effectiveSectionFallsBackToDefault() {
        var layout = Layout()
        layout.defaultSection = .hidden
        #expect(layout.effectiveSection(of: a) == .hidden)
    }
}
