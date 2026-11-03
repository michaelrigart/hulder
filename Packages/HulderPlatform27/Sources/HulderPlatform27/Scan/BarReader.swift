import AppKit
import HulderCore

/// Everything one look at the bar reads, before `InventoryAssembly` turns it into scans.
struct BarReading: Sendable {
    var snapshot: BarSnapshot?
    var owners: [pid_t: ItemOwner]
    var running: Set<AppID>
    var agentPID: pid_t?
    /// What the extras listing returned for each process the bar draws, MenuBarAgent excepted.
    var listings: [pid_t: RawScan]
    /// How long the read of the bar itself took.
    var readDuration: Duration

    /// The listings that were read, which supply names for the drawn items.
    var listedItems: [pid_t: [RawItem]] {
        listings.compactMapValues { scan in
            guard case .items(let items) = scan else { return nil }
            return items
        }
    }
}

/// The one place that reads the bar: the scanner and the debug probe both go through it, so the probe reports
/// what Hulder reads.
enum BarReader {
    static func read(queue: AXQueue) async -> BarReading {
        let timeout = queue.messagingTimeout
        let gathered = await queue.run { () -> BarReading in
            let readStart = ContinuousClock.now
            let snapshot = MenuBarAgentReader.read(timeout: timeout)
            let readDuration = ContinuousClock.now - readStart
            var owners: [pid_t: ItemOwner] = [:]
            var running = Set<AppID>()
            for app in NSWorkspace.shared.runningApplications {
                guard let owner = OwnerResolver27.owner(of: app), let appID = owner.appID else { continue }
                owners[app.processIdentifier] = owner
                running.insert(appID)
            }
            for group in snapshot?.groups ?? [] where owners[group.pid] == nil {
                owners[group.pid] = OwnerResolver27.owner(of: group.pid)
            }
            return BarReading(
                snapshot: snapshot, owners: owners, running: running, agentPID: MenuBarAgentReader.agentPID(),
                listings: [:], readDuration: readDuration)
        }
        var reading = gathered
        reading.listings = await listings(for: gathered, queue: queue)
        return reading
    }

    /// The extras listing of each drawn owner except MenuBarAgent, which has none. It supplies names only.
    private static func listings(for reading: BarReading, queue: AXQueue) async -> [pid_t: RawScan] {
        guard let snapshot = reading.snapshot else { return [:] }
        let pids = Set(snapshot.groups.map(\.pid)).filter {
            reading.owners[$0]?.appID?.bundleID != MenuBarAgentReader.agentBundleID
        }
        let timeout = queue.messagingTimeout
        return await withTaskGroup(of: (pid_t, RawScan).self) { group in
            for pid in pids {
                group.addTask { (pid, await queue.run { ExtrasMenuBarReader.readItems(pid: pid, timeout: timeout) }) }
            }
            var result: [pid_t: RawScan] = [:]
            for await (pid, scan) in group { result[pid] = scan }
            return result
        }
    }
}
