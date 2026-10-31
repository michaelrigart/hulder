import Foundation

extension Clock where Duration == Swift.Duration {
    // The deadline is fixed here, when the caller asks, not when the sleeping task first gets to run.
    func sleeper(after delay: Swift.Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: delay)
        return { try await self.sleep(until: deadline, tolerance: nil) }
    }
}
