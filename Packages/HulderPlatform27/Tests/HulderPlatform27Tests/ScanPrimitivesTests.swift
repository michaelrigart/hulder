import Darwin
import Foundation
import os
import Testing
@testable import HulderPlatform27

@Test func axQueueRunsBodiesOffTheMainThread() async {
    let queue = AXQueue()
    let onMain = await queue.run { Thread.isMainThread }
    #expect(onMain == false)
}

@Test func axQueueNeverRunsMoreBodiesThanItsWidth() async {
    let queue = AXQueue(width: 2)
    let running = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
    let results = await withTaskGroup(of: Int.self) { group in
        for number in 0..<8 {
            group.addTask {
                await queue.run {
                    running.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                    Thread.sleep(forTimeInterval: 0.02)
                    running.withLock { $0.current -= 1 }
                    return number
                }
            }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(results.sorted() == Array(0..<8))
    #expect(running.withLock { $0.peak } <= 2)
}

@Test func runningPIDsIncludesThisProcess() {
    #expect(ExtrasMenuBarReader.runningPIDs().contains(getpid()))
}

@Test func runningPIDsKeepsTheOldestProcesses() {
    // launchd is the oldest process, so it sits at the end of the kernel's newest-first list.
    #expect(ExtrasMenuBarReader.runningPIDs().contains(1))
}

@Test func assertionOnUnavailableFrameworkThrows() {
    let core = MenuBarClientCore(resolver: .frameworkMissing)
    #expect(throws: MenuBarAssertionError.unavailable) {
        try MenuBarAssertion(core: core, bundleIDs: [], systemItems: [])
    }
}

#if DEBUG
@Test func probeArgumentsFollowTheFlag() {
    #expect(PlatformProbe27.arguments(from: ["/x/Hulder", "-HulderProbe", "hide", "com.example.app"]) == ["hide", "com.example.app"])
    #expect(PlatformProbe27.arguments(from: ["/x/Hulder"]) == nil)
}
#endif
