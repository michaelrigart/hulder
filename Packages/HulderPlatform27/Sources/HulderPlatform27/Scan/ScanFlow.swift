import HulderCore

/// What a scan session emits when trust changes or a pass finishes, and which owners it remembers.
/// Pure: the session applies the decision under its lock, so a pass that read the bar just before a
/// revocation can't be emitted after the stale pass that follows it.
enum ScanFlow {
    struct Pass: Equatable, Sendable {
        var scans: [AppScan]
        /// Whether the order file's entries were read for this pass, the same read its keys were made from.
        var orderEntriesAvailable: Bool
        /// The owners of the bar that was read, or nil when the bar could not be read.
        var owners: [ItemOwner]?
    }

    struct Decision: Equatable, Sendable {
        var emit: ScanPass?
        var previousOwners: [ItemOwner]
    }

    /// With `finished` nil, a trust change; otherwise a pass that has just finished, whatever it read.
    static func decide(
        wasTrusted: Bool, trusted: Bool, stopped: Bool, previousOwners: [ItemOwner], finished: Pass?
    ) -> Decision {
        let keep = Decision(emit: nil, previousOwners: previousOwners)
        guard !stopped else { return keep }
        guard let finished else {
            guard wasTrusted, !trusted, !previousOwners.isEmpty else { return keep }
            let stale = InventoryAssembly.scans(
                snapshot: nil, owners: [:], listings: [:], entries: nil, concealed: [], previousOwners: previousOwners)
            return Decision(emit: ScanPass(scans: stale, orderEntriesAvailable: false), previousOwners: previousOwners)
        }
        guard trusted else { return keep }
        let pass = ScanPass(scans: finished.scans, orderEntriesAvailable: finished.orderEntriesAvailable)
        return Decision(emit: pass, previousOwners: finished.owners ?? previousOwners)
    }
}
