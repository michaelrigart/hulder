import Foundation
import HulderCore

/// What a scan session emits when trust changes or a pass finishes. Pure: the session applies the decision under its
/// lock, so a pass that read the bar just before a revocation can't be emitted after the stale pass that follows it.
enum ScanFlow {
    /// With `finished` nil, a trust change: a revocation gives an unread pass, so the kept inventory is marked stale,
    /// and anything else nothing. Otherwise a pass that has just finished, emitted unchanged while trusted.
    static func decide(wasTrusted: Bool, trusted: Bool, stopped: Bool, finished: ScanPass?) -> ScanPass? {
        guard !stopped else { return nil }
        guard let finished else { return wasTrusted && !trusted ? .unread : nil }
        return trusted ? finished : nil
    }
}

/// When the session watches MenuBarAgent and when a failure to do so is worth a log line. Pure, like `ScanFlow`.
enum AgentObservation {
    /// An untrusted process can't attach, so trying only produces a failure that isn't the agent's.
    static func mayAttach(trusted: Bool, stopped: Bool) -> Bool {
        trusted && !stopped
    }

    /// Whether a failed attach to `pid` is logged and recorded: once per pid while trusted. Trust lost during the
    /// attach is the cause of its failure, so it is neither logged nor recorded.
    static func reportsFailure(pid: pid_t, lastReported: pid_t?, trusted: Bool, stopped: Bool) -> Bool {
        mayAttach(trusted: trusted, stopped: stopped) && lastReported != pid
    }
}
