import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

private let keep = AppID("com.example.keep")
private let other = AppID("com.example.other")
private let third = AppID("com.example.third")

/// A backend over the fake framework. The allow list reaches the framework with the behavior's token appended,
/// which is how the fake finds its behavior.
private func makeBackend(_ behavior: FakeBehavior) -> AssertionBackend27 {
    AssertionBackend27(core: MenuBarClientCore(resolver: fakeResolver)) { list in
        (list.apps.map(\.bundleID).sorted() + [behavior.token], [0])
    }
}

// Parked item 36. Catches a backend that drops a token on invalidate but forgets the activation that completes
// afterwards: the framework would keep the assertion, and keep hiding apps, until Hulder quits.
@Test(.timeLimit(.minutes(1)))
func aLateActivationAfterInvalidateReachesTheFrameworkInvalidateAgain() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let backend = makeBackend(behavior)
    let token = try await backend.prepare(AllowList(apps: [keep]))
    let activation = Task { try await backend.activate(token) }
    for await _ in behavior.activated { break }

    await backend.invalidate(token)
    await #expect(throws: ConcealmentFailure.rejected) { try await activation.value }
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 1)

    behavior.complete(with: nil)
    await MenuBarAssertion.drainQueue()
    #expect(behavior.invalidateCalls == 2)
}

@Test(.timeLimit(.minutes(1)))
func anInvalidatedTokenCannotActivateAgain() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let backend = makeBackend(behavior)
    let token = try await backend.prepare(AllowList(apps: [keep]))
    await backend.invalidate(token)
    await #expect(throws: ConcealmentFailure.rejected) { try await backend.activate(token) }
    #expect(behavior.activateCalls == 0)
}

@Test func prepareFailsAsUnavailableWithoutTheFramework() async {
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: .frameworkMissing))
    await #expect(throws: ConcealmentFailure.self) { try await backend.prepare(AllowList(apps: [keep])) }
}

// Catches phantom items: Layout would list apps that nothing hides, such as an app whose icon is switched off.
@Test(.timeLimit(.minutes(1)))
func concealedAppsAreTheRunningAppsOutsideTheConfirmedAllowList() async throws {
    let behavior = FakeBehavior(mode: .succeed)
    let backend = makeBackend(behavior)
    let running: Set<AppID> = [keep, other]
    #expect(await backend.concealedApps(among: running).isEmpty)

    let token = try await backend.prepare(AllowList(apps: [keep]))
    #expect(await backend.concealedApps(among: running).isEmpty)

    try await backend.activate(token)
    #expect(await backend.concealedApps(among: running) == [other])

    await backend.invalidate(token)
    #expect(await backend.concealedApps(among: running).isEmpty)
}

// Catches an assertion still activating that already counts as hiding.
@Test(.timeLimit(.minutes(1)))
func anAssertionThatIsStillActivatingConcealsNothing() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let backend = makeBackend(behavior)
    let token = try await backend.prepare(AllowList(apps: [keep]))
    let activation = Task { try await backend.activate(token) }
    for await _ in behavior.activated { break }
    #expect(await backend.concealedApps(among: [keep, other]).isEmpty)

    behavior.complete(with: nil)
    try await activation.value
    #expect(await backend.concealedApps(among: [keep, other]) == [other])
}

// While the old assertion is still live, an app either list leaves out counts as concealed. macOS lets the older one
// govern, so this is a superset, which is safe: the inventory treats an app as concealed only when it isn't drawn.
@Test(.timeLimit(.minutes(1)))
func twoLiveAssertionsConcealWhatEitherConceals() async throws {
    let first = FakeBehavior(mode: .succeed)
    let second = FakeBehavior(mode: .succeed)
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: fakeResolver)) { list in
        (list.apps.map(\.bundleID).sorted() + [list.apps.contains(other) ? first.token : second.token], [0])
    }
    let old = try await backend.prepare(AllowList(apps: [keep, other]))
    try await backend.activate(old)
    let new = try await backend.prepare(AllowList(apps: [keep, third]))
    try await backend.activate(new)

    let running: Set<AppID> = [keep, other, third]
    #expect(await backend.concealedApps(among: running) == [other, third])
    await backend.invalidate(old)
    #expect(await backend.concealedApps(among: running) == [other])
    await backend.invalidate(new)
    #expect(await backend.concealedApps(among: running).isEmpty)
}

// Catches a scan that runs before the concealment is confirmed: it would find the hidden apps undrawn and not
// concealed, and drop their items from the inventory until the next scan.
@Test(.timeLimit(.minutes(1)))
func theBackendReportsEachChangeToWhatItConceals() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let changes = Mutex(0)
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: fakeResolver), translate: { list in
        (list.apps.map(\.bundleID).sorted() + [behavior.token], [0])
    }, onConcealmentChange: { changes.withLock { $0 += 1 } })
    let token = try await backend.prepare(AllowList(apps: [keep]))
    let activation = Task { try await backend.activate(token) }
    for await _ in behavior.activated { break }
    #expect(changes.withLock { $0 } == 0)

    behavior.complete(with: nil)
    try await activation.value
    #expect(changes.withLock { $0 } == 1)

    await backend.invalidate(token)
    await backend.invalidate(token)
    #expect(changes.withLock { $0 } == 2)
}

@Test(.timeLimit(.minutes(1)))
func anAssertionThatNeverConfirmedDoesNotReportAChange() async throws {
    let behavior = FakeBehavior(mode: .hold)
    let changes = Mutex(0)
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: fakeResolver), translate: { list in
        (list.apps.map(\.bundleID).sorted() + [behavior.token], [0])
    }, onConcealmentChange: { changes.withLock { $0 += 1 } })
    let token = try await backend.prepare(AllowList(apps: [keep]))
    let activation = Task { try await backend.activate(token) }
    for await _ in behavior.activated { break }
    await backend.invalidate(token)
    _ = await activation.result
    behavior.complete(with: nil)
    await MenuBarAssertion.drainQueue()
    #expect(changes.withLock { $0 } == 0)
}
