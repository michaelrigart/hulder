import Foundation

/// The shell command that starts a new copy of Hulder after this process has exited, and stays until a
/// new copy is confirmed running. A relaunch never leaves two copies or none, so it:
///
/// 1. waits for the old pid to exit;
/// 2. waits (at most `dropPolls` polls) for LaunchServices to stop listing the old copy, so `open`
///    never finds it still registered;
/// 3. runs `open`, then looks for up to `confirmPolls` polls for a copy of the bundle that LaunchServices
///    lists with a pid other than the old one that is alive, and that stays so for `stablePolls`
///    polls in a row (a new copy that hands over to a still-listed old one exits at once);
/// 4. when none is confirmed, tries again from step 2, up to `attempts` in all, then gives up and
///    logs one line to the unified log, so the failure can be seen.
///
/// A copy counts only by its pid, never by the LaunchServices listing alone, so a stale listing of the
/// old copy is not mistaken for the new one. A copy is accepted only after the same stable polls
/// wherever it is found: after `open`, and when a retry begins. The commands and the timing are
/// arguments so a test can run the real script with fake commands. Each `lsappinfo find` carries the
/// step that issued it in `HULDER_RELAUNCH_STEP` (`entry`, `drop` or `confirm`, then the attempt's
/// number), which the real command ignores and a fake can read.
public struct RelaunchHelper: Sendable {
    public struct Timing: Sendable {
        /// Seconds between polls.
        public var pollInterval: Double
        public var dropPolls: Int
        public var confirmPolls: Int
        public var stablePolls: Int
        public var attempts: Int

        public init(pollInterval: Double, dropPolls: Int, confirmPolls: Int, stablePolls: Int, attempts: Int) {
            self.pollInterval = pollInterval
            self.dropPolls = dropPolls
            self.confirmPolls = confirmPolls
            self.stablePolls = stablePolls
            self.attempts = attempts
        }

        /// Polls every 0.1 s: up to 10 s for the old copy to drop, 5 s to confirm a new one (which has
        /// to stay up for 1 s), 5 attempts.
        public static let standard = Timing(pollInterval: 0.1, dropPolls: 100, confirmPolls: 50, stablePolls: 10, attempts: 5)
    }

    public let open: String
    public let lsappinfo: String
    public let logger: String
    public let timing: Timing

    public init(
        open: String = "/usr/bin/open", lsappinfo: String = "/usr/bin/lsappinfo", logger: String = "/usr/bin/logger",
        timing: Timing = .standard
    ) {
        self.open = open
        self.lsappinfo = lsappinfo
        self.logger = logger
        self.timing = timing
    }

    /// Exits 0 once a new copy is confirmed, 1 when it gave up.
    private static let script = #"""
    old=$1; app=$2; bid=$3; open=$4; lsapp=$5; logger=$6; tick=$7; dropmax=$8; confmax=$9; shift 9
    stablemax=$1; attempts=$2
    HULDER_RELAUNCH_STEP=""; export HULDER_RELAUNCH_STEP
    newcopy() {
      for asn in $("$lsapp" find bundleid="$bid" | /usr/bin/grep -Eo 'ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+'); do
        pid=$("$lsapp" info -only pid "$asn" | /usr/bin/sed -n 's/.*pid"\{0,1\} *= *\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)
        if [ -n "$pid" ] && [ "$pid" != "$old" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
      done
      return 1
    }
    stays() {
      stable=$1; i=0
      while [ "$stable" -lt "$stablemax" ]; do
        [ "$i" -lt "$confmax" ] || return 1
        sleep "$tick"; i=$((i+1))
        if newcopy; then stable=$((stable+1)); else stable=0; fi
      done
      return 0
    }
    while kill -0 "$old" 2>/dev/null; do sleep "$tick"; done
    n=0
    while [ "$n" -lt "$attempts" ]; do
      HULDER_RELAUNCH_STEP="entry $((n+1))"
      if newcopy && stays 1; then exit 0; fi
      HULDER_RELAUNCH_STEP="drop $((n+1))"
      i=0
      while [ -n "$("$lsapp" find bundleid="$bid")" ] && [ "$i" -lt "$dropmax" ]; do sleep "$tick"; i=$((i+1)); done
      "$open" "$app"
      HULDER_RELAUNCH_STEP="confirm $((n+1))"
      if stays 0; then exit 0; fi
      n=$((n+1))
    done
    "$logger" -t Hulder "Relaunch gave up: no new copy after $attempts attempts"
    exit 1
    """#

    /// The executable and arguments that run the script for the copy with `oldPID`, which relaunches
    /// the bundle at `bundlePath` (identifier `bundleID`).
    public func invocation(oldPID: Int32, bundlePath: String, bundleID: String) -> (executable: URL, arguments: [String]) {
        let arguments = [
            "-c", Self.script, "sh", String(oldPID), bundlePath, bundleID, open, lsappinfo, logger,
            String(timing.pollInterval), String(timing.dropPolls), String(timing.confirmPolls),
            String(timing.stablePolls), String(timing.attempts),
        ]
        return (URL(fileURLWithPath: "/bin/sh"), arguments)
    }
}
