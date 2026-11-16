import Foundation
import Testing
@testable import HulderPlatform27

private func readPid(_ file: URL) throws -> pid_t {
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(pid_t(text))
}

@Test(.timeLimit(.minutes(1))) func exitStatusZeroIsTrue() async {
    let check = ChildExitStatus(executable: URL(filePath: "/usr/bin/true"), arguments: [], timeout: 5)
    #expect(await check.run() == true)
}

@Test(.timeLimit(.minutes(1))) func exitStatusOneIsFalse() async {
    let check = ChildExitStatus(executable: URL(filePath: "/usr/bin/false"), arguments: [], timeout: 5)
    #expect(await check.run() == false)
}

@Test(.timeLimit(.minutes(1))) func anyOtherExitStatusIsNil() async {
    let check = ChildExitStatus(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exit 2"], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aChildKilledBySignalOneIsNotAnExitStatusOne() async {
    let check = ChildExitStatus(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "kill -HUP $$"], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aMissingExecutableIsNil() async {
    let check = ChildExitStatus(executable: URL(filePath: "/nonexistent/hulder"), arguments: [], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aChildThatDoesNotExitInTimeIsNilAndTerminated() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "hulder-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let check = ChildExitStatus(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 5", "sh", pidFile.path],
        timeout: 0.5)
    #expect(await check.run() == nil)
    let pid = try readPid(pidFile)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test(.timeLimit(.minutes(1))) func aChildThatIgnoresTerminateIsKilledSoonAfterTheTimeout() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "hulder-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let check = ChildExitStatus(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; while :; do /bin/sleep 0.05; done", "sh", pidFile.path],
        timeout: 0.5)
    let elapsed = await ContinuousClock().measure { #expect(await check.run() == nil) }
    #expect(elapsed < .seconds(3))
    let pid = try readPid(pidFile)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test(.timeLimit(.minutes(1))) func theAnswerIsBoundedWhenTheKillDoesNotLand() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "hulder-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let check = ChildExitStatus(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; exec /bin/sleep 5", "sh", pidFile.path],
        timeout: 0.2,
        kill: { _ in })
    let elapsed = await ContinuousClock().measure { #expect(await check.run() == nil) }
    #expect(elapsed < .milliseconds(1500))
    let pid = try readPid(pidFile)
    kill(pid, SIGKILL)
}
