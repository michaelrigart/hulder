import HulderCore

/// Maps controller tokens to live assertions. `MenuBarAssertion.invalidate()` is idempotent and stays
/// effective if activation completes later, so a token is dropped from the map on invalidation: a late
/// `activate` for it then finds nothing and fails without touching the framework.
actor AssertionBackend27: ConcealmentBackend {
    typealias Translation = @Sendable (AllowList) -> (bundleIDs: [String], systemItems: [Int])

    private let core: MenuBarClientCore
    private let translate: Translation
    private var assertions: [ConcealmentToken: MenuBarAssertion] = [:]
    private var nextID: UInt64 = 1

    /// `translate` is `AllowListTranslation` unless the debug probe narrows the system items.
    init(core: MenuBarClientCore, translate: @escaping Translation = AllowListTranslation.arguments(for:)) {
        self.core = core
        self.translate = translate
    }

    func prepare(_ list: AllowList) async throws -> ConcealmentToken {
        let arguments = translate(list)
        let assertion: MenuBarAssertion
        do {
            assertion = try MenuBarAssertion(core: core, bundleIDs: arguments.bundleIDs, systemItems: arguments.systemItems)
        } catch {
            throw ConcealmentFailure.unavailable(Self.unavailableText(core.availability))
        }
        let token = ConcealmentToken(id: nextID)
        nextID += 1
        assertions[token] = assertion
        return token
    }

    /// Every failure, including a token that was already invalidated, reaches the core as `.rejected`.
    func activate(_ token: ConcealmentToken) async throws {
        guard let assertion = assertions[token] else { throw ConcealmentFailure.rejected }
        do {
            try await assertion.activate()
        } catch {
            throw ConcealmentFailure.rejected
        }
    }

    func invalidate(_ token: ConcealmentToken) async {
        assertions.removeValue(forKey: token)?.invalidate()
    }

    private static func unavailableText(_ availability: Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "Concealment is unavailable."
    }
}
