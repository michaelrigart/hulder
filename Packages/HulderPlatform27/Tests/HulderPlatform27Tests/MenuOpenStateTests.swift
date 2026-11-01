import Testing
@testable import HulderPlatform27

@Test func olderReadFinishingLastIsIgnored() {
    var state = MenuOpenState()
    let older = state.begin(7)
    let newer = state.begin(7)
    state.finish(7, generation: newer, isOpen: true)
    state.finish(7, generation: older, isOpen: false)
    #expect(state.anyOpen)
}

@Test func quitAppIsForgotten() {
    var state = MenuOpenState()
    let generation = state.begin(7)
    state.finish(7, generation: generation, isOpen: true)
    #expect(state.anyOpen)
    state.remove(7)
    #expect(!state.anyOpen)
    state.finish(7, generation: generation, isOpen: true)
    #expect(!state.anyOpen)
}

@Test func anyOpenStaysTrueWhileAnotherAppIsOpen() {
    var state = MenuOpenState()
    let first = state.begin(1)
    let second = state.begin(2)
    state.finish(1, generation: first, isOpen: true)
    state.finish(2, generation: second, isOpen: true)
    let reread = state.begin(1)
    state.finish(1, generation: reread, isOpen: false)
    #expect(state.anyOpen)
}
