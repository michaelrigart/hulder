import Testing
@testable import HulderPlatform27

@Test(.timeLimit(.minutes(1))) func subscribersGetTheCurrentValueThenEachChange() async {
    let shared = SharedValue<Bool>(false)
    let first = shared.values()
    let second = shared.values()

    shared.set(true)
    shared.finish()

    var firstValues: [Bool] = []
    for await value in first { firstValues.append(value) }
    var secondValues: [Bool] = []
    for await value in second { secondValues.append(value) }

    #expect(firstValues == [false, true])
    #expect(secondValues == [false, true])
}

@Test(.timeLimit(.minutes(1))) func anEqualValueIsNotYielded() async {
    let shared = SharedValue<Bool>(false)
    var iterator = shared.values().makeAsyncIterator()
    #expect(await iterator.next() == false)

    #expect(shared.set(false) == false)
    #expect(shared.set(true))
    #expect(await iterator.next() == true)
}

@Test(.timeLimit(.minutes(1))) func nothingIsYieldedBeforeTheFirstValue() async {
    let shared = SharedValue<Bool>(nil)
    var iterator = shared.values().makeAsyncIterator()

    // With no value held, the first set is a change, and it is the subscriber's first element.
    #expect(shared.set(true))

    #expect(await iterator.next() == true)
    var late = shared.values().makeAsyncIterator()
    #expect(await late.next() == true)
}

@Test(.timeLimit(.minutes(1))) func aLateSubscriberStartsAtTheCurrentValue() async {
    let shared = SharedValue<Bool>(false)
    shared.set(true)

    var iterator = shared.values().makeAsyncIterator()

    #expect(await iterator.next() == true)
}

@Test(.timeLimit(.minutes(1))) func finishEndsEveryStream() async {
    let shared = SharedValue<Bool>(false)
    var iterator = shared.values().makeAsyncIterator()
    #expect(await iterator.next() == false)

    shared.finish()

    #expect(await iterator.next() == nil)
    var late = shared.values().makeAsyncIterator()
    #expect(await late.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func aCancelledSubscriberDoesNotStopTheOthers() async {
    let shared = SharedValue<Bool>(false)
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        for await _ in shared.values() { signal.yield() }
    }
    var startedIterator = started.makeAsyncIterator()
    await startedIterator.next()
    var other = shared.values().makeAsyncIterator()
    #expect(await other.next() == false)

    task.cancel()
    await task.value
    shared.set(true)

    #expect(await other.next() == true)
}
