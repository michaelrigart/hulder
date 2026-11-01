import HulderCore

/// Maps controller tokens to live assertions. `MenuBarAssertion.invalidate()` is idempotent and stays
/// effective if activation completes later, so a token is dropped from the map on invalidation: a late
/// `activate` for it then finds nothing and fails without touching the framework.
actor AssertionBackend27: ConcealmentBackend {
    private let core: MenuBarClientCore
    private var assertions: [ConcealmentToken: MenuBarAssertion] = [:]
    private var nextID: UInt64 = 1

    init(core: MenuBarClientCore) {
        self.core = core
    }

    func prepare(_ list: AllowList) async throws -> ConcealmentToken {
        let arguments = AllowListTranslation.arguments(for: list)
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

    func activate(_ token: ConcealmentToken) async throws {
        guard let assertion = assertions[token] else { throw MenuBarAssertionError.invalidated }
        do {
            try await assertion.activate()
        } catch MenuBarAssertionError.activationFailed {
            throw ConcealmentFailure.rejected
        } catch MenuBarAssertionError.unavailable {
            throw ConcealmentFailure.unavailable(Self.unavailableText(core.availability))
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
