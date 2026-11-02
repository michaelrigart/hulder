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
