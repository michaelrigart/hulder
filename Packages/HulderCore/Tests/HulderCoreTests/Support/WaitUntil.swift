/// Yields until the condition holds, for at most 10,000 turns. Returns whether it held.
func waitUntil(
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
