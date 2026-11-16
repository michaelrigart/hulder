import Foundation
import Testing
@testable import HulderPlatform27

private let fastTiming = RelaunchHelper.Timing(pollInterval: 0.02, dropPolls: 10, confirmPolls: 10, stablePolls: 2, attempts: 3)

/// Fake `open`, `lsappinfo` and `logger` in a temporary directory, with state in files; the directory
/// is removed when the fakes go. `open` logs each call and takes its outcome from the first line of
/// `open-results`: `ok` starts a copy that stays, `brief` starts one that LaunchServices lists for one
/// `find` only (a new copy that hands over to a running one and exits), `fail` exits 1, `none` exits 0
/// but starts nothing; an empty file means `ok`. An `open` sent while the old copy is still listed
/// starts nothing, as when a new copy hands over to it, and does not use up a result. A started copy
/// is this test process, which is alive and has another pid than the old copy. `lsappinfo` lists a
/// stale entry for the old copy while `stale-polls` is above 0 (each `find` uses one; `forever` never
/// runs out) and the new copy once started. A `blip` lists a copy at the first `find` of one step only
/// (the step the script names in `HULDER_RELAUNCH_STEP`, such as `entry 2`) and records that step. The
/// `logger` records its arguments.
private final class Fakes: Sendable {
    let directory: URL
    let oldPID: Int32
    var open: String { directory.appending(path: "open").path }
    var lsappinfo: String { directory.appending(path: "lsappinfo").path }
    var logger: String { directory.appending(path: "logger").path }
    var openLog: [String] { lines("open.log") }
    var loggerLog: [String] { lines("logger.log") }
    /// The steps whose `find` listed a blip.
    var blips: [String] { lines("blips.log") }

    /// `blipStep` is the step whose first `find` lists a copy once; `isRunning` means a new copy is
    /// running and listed from the start.
    init(oldPID: Int32, openResults: [String] = [], stalePolls: String = "0", blipStep: String? = nil, isRunning: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        self.oldPID = oldPID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openResults.map { $0 + "\n" }.joined().write(to: directory.appending(path: "open-results"), atomically: true, encoding: .utf8)
        try stalePolls.write(to: directory.appending(path: "stale-polls"), atomically: true, encoding: .utf8)
        try blipStep?.write(to: directory.appending(path: "blip-step"), atomically: true, encoding: .utf8)
        let newPID = ProcessInfo.processInfo.processIdentifier
        if isRunning { try String(newPID).write(to: directory.appending(path: "new-pid"), atomically: true, encoding: .utf8) }
        try write("open", """
            #!/bin/sh
            d="\(directory.path)"
            echo "$@" >> "$d/open.log"
            polls=$(cat "$d/stale-polls")
            if [ "$polls" = forever ] || [ "$polls" -gt 0 ]; then exit 0; fi
            result=$(head -n 1 "$d/open-results")
            tail -n +2 "$d/open-results" > "$d/open-results.next"; mv "$d/open-results.next" "$d/open-results"
            case "$result" in
              fail) exit 1 ;;
              none) exit 0 ;;
              brief) echo \(newPID) > "$d/new-pid"; echo 1 > "$d/new-lives" ;;
              *) echo \(newPID) > "$d/new-pid"; rm -f "$d/new-lives" ;;
            esac
            """)
        try write("lsappinfo", """
            #!/bin/sh
            d="\(directory.path)"
            case "$1" in
              find)
                polls=$(cat "$d/stale-polls")
                if [ "$polls" = forever ]; then echo 'ASN:0x0-0x1-"Hulder":'
                elif [ "$polls" -gt 0 ]; then echo 'ASN:0x0-0x1-"Hulder":'; echo $((polls-1)) > "$d/stale-polls"; fi
                if [ -f "$d/blip-step" ] && [ "$HULDER_RELAUNCH_STEP" = "$(cat "$d/blip-step")" ]; then
                  echo 'ASN:0x0-0x3-"Hulder":'; echo "$HULDER_RELAUNCH_STEP" >> "$d/blips.log"; rm "$d/blip-step"
                fi
                if [ -f "$d/new-pid" ]; then
                  if [ ! -f "$d/new-lives" ]; then echo 'ASN:0x0-0x2-"Hulder":'
                  elif [ "$(cat "$d/new-lives")" -gt 0 ]; then echo 'ASN:0x0-0x2-"Hulder":'; echo $(( $(cat "$d/new-lives") - 1 )) > "$d/new-lives"; fi
                fi ;;
              info)
                case "$4" in
                  ASN:0x0-0x1) echo '"pid"=\(oldPID)' ;;
                  ASN:0x0-0x2) echo "\\"pid\\"=$(cat "$d/new-pid")" ;;
                  ASN:0x0-0x3) echo '"pid"=\(newPID)' ;;
                esac ;;
            esac
            """)
        try write("logger", """
            #!/bin/sh
            echo "$@" >> "\(directory.path)/logger.log"
            """)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func lines(_ name: String) -> [String] {
        ((try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func write(_ name: String, _ text: String) throws {
        let url = directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func helper(timing: RelaunchHelper.Timing = fastTiming) -> RelaunchHelper {
        RelaunchHelper(open: open, lsappinfo: lsappinfo, logger: logger, timing: timing)
    }

    func run(timing: RelaunchHelper.Timing = fastTiming) async -> Bool? {
        let command = helper(timing: timing).invocation(oldPID: oldPID, bundlePath: "/Applications/Hulder.app", bundleID: "com.example.hulder")
        return await ChildExitStatus(executable: command.executable, arguments: command.arguments, timeout: 20).run()
    }
}

/// A pid that no process has: a child that has already exited.
private func exitedPID() throws -> Int32 {
    let child = Process()
    child.executableURL = URL(filePath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    return child.processIdentifier
}

@Test(.timeLimit(.minutes(1))) func aStaleListingThatClearsLetsOneOpenStartTheNewCopy() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), stalePolls: "4")
    #expect(await fakes.run() == true)
    #expect(fakes.openLog == ["/Applications/Hulder.app"])
}

@Test(.timeLimit(.minutes(1))) func anOpenThatFailsOnceIsRepeatedUntilACopyIsRunning() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["fail", "ok"])
    #expect(await fakes.run() == true)
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func anOpenThatNeverStartsACopyGivesUpAfterTheAttemptLimit() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["none", "none", "none", "none", "none"])
    #expect(await fakes.run() == false)
    #expect(fakes.openLog.count == fastTiming.attempts)
    #expect(fakes.loggerLog == ["-t Hulder Relaunch gave up: no new copy after \(fastTiming.attempts) attempts"])
}

@Test(.timeLimit(.minutes(1))) func aRelaunchThatSucceedsLogsNothing() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["fail", "ok"])
    #expect(await fakes.run() == true)
    #expect(fakes.loggerLog.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aNewCopyThatExitsBeforeItIsStableIsNotConfirmedAndOpenIsSentAgain() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["brief", "ok"])
    #expect(await fakes.run() == true)
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func aCopyListedAtOnePollWhenARetryBeginsIsNotConfirmed() async throws {
    // The first attempt's `open` starts nothing; a copy is listed once when the second attempt begins.
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["none", "ok"], blipStep: "entry 2")
    #expect(await fakes.run() == true)
    // The blip landed on the retry's entry check, and one listing did not confirm it: `open` ran again.
    #expect(fakes.blips == ["entry 2"])
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func aCopyAlreadyRunningThatStaysIsConfirmedWithoutAnOpen() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), isRunning: true)
    #expect(await fakes.run() == true)
    #expect(fakes.openLog.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aListingOfTheOldCopyAloneIsNotANewCopy() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["none", "none"], stalePolls: "forever")
    let timing = RelaunchHelper.Timing(pollInterval: 0.02, dropPolls: 3, confirmPolls: 3, stablePolls: 2, attempts: 2)
    #expect(await fakes.run(timing: timing) == false)
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func nothingIsOpenedWhileTheOldProcessIsStillRunning() async throws {
    let old = Process()
    old.executableURL = URL(filePath: "/bin/sleep")
    old.arguments = ["60"]
    try old.run()
    defer { if old.isRunning { old.terminate() } }
    let fakes = try Fakes(oldPID: old.processIdentifier)
    let helper = Task { await fakes.run() }
    try await Task.sleep(for: .milliseconds(400))
    #expect(fakes.openLog.isEmpty)
    old.terminate()
    old.waitUntilExit()
    #expect(await helper.value == true)
    #expect(fakes.openLog.count == 1)
}
