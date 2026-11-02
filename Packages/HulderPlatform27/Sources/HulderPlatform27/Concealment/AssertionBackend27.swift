import HulderCore

/// Maps controller tokens to live assertions. `MenuBarAssertion.invalidate()` is idempotent and stays
/// effective if activation completes later, so a token is dropped from the map on invalidation: a late
/// `activate` for it then finds nothing and fails without touching the framework.
actor AssertionBackend27: ConcealmentBackend {
    typealias Translation = @Sendable (AllowList) -> (bundleIDs: [String], systemItems: [Int])

    private struct Entry {
        let assertion: MenuBarAssertion
        let allowedBundleIDs: Set<String>
        /// Set once the system has confirmed the assertion, which is when it starts to hide apps.
        var confirmed = false
    }

    private let core: MenuBarClientCore
    private let translate: Translation
    private let onConcealmentChange: @Sendable () -> Void
    private var assertions: [ConcealmentToken: Entry] = [:]
    private var nextID: UInt64 = 1

    /// `translate` is `AllowListTranslation` unless the debug probe narrows the system items.
    /// `onConcealmentChange` runs when `concealedApps` may answer differently: after the system confirms an
    /// assertion, and after a confirmed one is invalidated.
    init(
        core: MenuBarClientCore,
        translate: @escaping Translation = AllowListTranslation.arguments(for:),
        onConcealmentChange: @escaping @Sendable () -> Void = {}
    ) {
        self.core = core
        self.translate = translate
        self.onConcealmentChange = onConcealmentChange
    }

    /// The framework objects are made on the assertion queue, which the caller awaits without blocking.
    func prepare(_ list: AllowList) async throws -> ConcealmentToken {
        let arguments = translate(list)
        let assertion: MenuBarAssertion
        do {
            assertion = try await MenuBarAssertion.make(core: core, bundleIDs: arguments.bundleIDs, systemItems: arguments.systemItems)
        } catch {
            throw ConcealmentFailure.unavailable(Self.unavailableText(core.availability))
        }
        let token = ConcealmentToken(id: nextID)
        nextID += 1
        assertions[token] = Entry(assertion: assertion, allowedBundleIDs: Set(arguments.bundleIDs))
        return token
    }

    /// Every failure, including a token that was already invalidated, reaches the core as `.rejected`.
    func activate(_ token: ConcealmentToken) async throws {
        guard let assertion = assertions[token]?.assertion else { throw ConcealmentFailure.rejected }
        do {
            try await assertion.activate()
        } catch {
            throw ConcealmentFailure.rejected
        }
        guard assertions[token] != nil else { return }
        assertions[token]?.confirmed = true
        onConcealmentChange()
    }

    func invalidate(_ token: ConcealmentToken) async {
        guard let entry = assertions.removeValue(forKey: token) else { return }
        entry.assertion.invalidate()
        if entry.confirmed { onConcealmentChange() }
    }

    /// The apps among `running` that the confirmed assertions hide. Live assertions intersect, so an app
    /// stays visible only when every one of them allows it. None while no assertion is confirmed.
    func concealedApps(among running: Set<AppID>) -> Set<AppID> {
        let allowed = assertions.values.filter(\.confirmed).map(\.allowedBundleIDs)
        guard let first = allowed.first else { return [] }
        let visible = allowed.dropFirst().reduce(first) { $0.intersection($1) }
        return running.filter { !visible.contains($0.bundleID) }
    }

    private static func unavailableText(_ availability: Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "Concealment is unavailable."
    }
}
