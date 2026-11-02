import Foundation
import Testing
@testable import HulderPlatform27

@Test(.timeLimit(.minutes(1))) func anExitingProcessIsReported() async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/cat")
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    var exits = ProcessExit27.exits(of: process.processIdentifier).makeAsyncIterator()

    try input.fileHandleForWriting.close()

    #expect(await exits.next() != nil)
    #expect(await exits.next() == nil)
    process.waitUntilExit()
}

// Catches an exit missed because the process ended before the watch was armed, which would keep a dead pid watched
// for the rest of the run.
@Test(.timeLimit(.minutes(1))) func aProcessThatHasAlreadyExitedIsReportedAtOnce() async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/true")
    try process.run()
    let pid = process.processIdentifier
    process.waitUntilExit()

    var exits = ProcessExit27.exits(of: pid).makeAsyncIterator()

    #expect(await exits.next() != nil)
    #expect(await exits.next() == nil)
}
