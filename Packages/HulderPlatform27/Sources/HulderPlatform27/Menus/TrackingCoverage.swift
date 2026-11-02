import Darwin
import os

/// Which processes full menu tracking needs to watch: every process that draws an item on the bar, by pid, and
/// the two system apps that own menus without owning an item.
enum TrackingCoverage {
    static let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.notificationcenterui"]

    /// The union of the latest set of each stream, yielded when it changes, once both have yielded.
    static func union(_ first: AsyncStream<Set<pid_t>>, _ second: AsyncStream<Set<pid_t>>) -> AsyncStream<Set<pid_t>> {
        AsyncStream { continuation in
            struct Latest {
                var first: Set<pid_t>?
                var second: Set<pid_t>?
                var emitted: Set<pid_t>?
            }
            let latest = OSAllocatedUnfairLock(initialState: Latest())
            let update: @Sendable (@Sendable (inout Latest) -> Void) -> Void = { change in
                latest.withLock { latest in
                    change(&latest)
                    guard let first = latest.first, let second = latest.second else { return }
                    let union = first.union(second)
                    guard union != latest.emitted else { return }
                    latest.emitted = union
                    continuation.yield(union)
                }
            }
            let tasks = [
                Task { for await value in first { update { $0.first = value } } },
                Task { for await value in second { update { $0.second = value } } },
            ]
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        }
    }
}
