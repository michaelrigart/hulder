import Synchronization

/// The first of a call's answer and its deadline.
///
/// The call runs unstructured and is never cancelled: the blocking work behind it ignores cancellation, so a
/// structured race would wait for the call itself. `OrderController` bounds its store calls the same way, but its
/// race is private, tied to a clock, and drops a late answer; here the late answer matters (it releases what the
/// call opened and says macOS answered), so the race hands it on.
enum Deadline {
    struct Expired: Error {}

    /// Hands the continuation to whoever asks first.
    private final class Waiter<T: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<T, any Error>?>

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation = Mutex(continuation)
        }

        func take() -> CheckedContinuation<T, any Error>? {
            continuation.withLock { $0.take() }
        }

        /// Takes the continuation and runs `expired` before anyone else can see that it is gone.
        func takeExpired(_ expired: () -> Void) -> CheckedContinuation<T, any Error>? {
            continuation.withLock { continuation in
                guard let taken = continuation.take() else { return nil }
                expired()
                return taken
            }
        }
    }

    /// Returns the call's value, or throws what it threw, or throws `Expired` after `timeout`. `expired` runs once
    /// when the deadline wins, before the throw. `late` runs once with the call's result when the call finishes
    /// after that.
    static func run<T: Sendable>(
        within timeout: Duration,
        _ call: @escaping @Sendable () async throws -> T,
        expired: @escaping @Sendable () -> Void = {},
        late: @escaping @Sendable (Result<T, any Error>) -> Void = { _ in }
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return }
                waiter.takeExpired(expired)?.resume(throwing: Expired())
            }
            Task.detached {
                let result: Result<T, any Error>
                do { result = .success(try await call()) } catch { result = .failure(error) }
                timer.cancel()
                if let waiting = waiter.take() {
                    waiting.resume(with: result)
                } else {
                    late(result)
                }
            }
        }
    }
}
