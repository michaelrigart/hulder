/// Decides when the apps of a first sighting may be placed on the bar.
///
/// At launch the first scan can finish before the order file is open, and an item is keyed from the order file's
/// entries: until they are there, a named item still carries a made-up key that the order file doesn't contain.
/// Sightings made until the order capability's first real answer wait in a queue. If that answer is "available",
/// the controller is installed and the queue keeps waiting for the first scan pass that ran with the order entries
/// available; that pass's inventory has the keys the order file knows, and the queue is placed from it. If the
/// answer is a refusal, the queue is dropped. After that first answer a sighting made without a controller is never
/// placed, so a later grant can't move items the user arranged since.
struct SightingPlacementGate {
    private var evaluated: Bool
    private var hasController: Bool
    /// A controller is installed but no scan has finished since with the order entries available.
    private var awaitingScan = false
    private var queued: [AppID] = []

    init(hasController: Bool) {
        self.hasController = hasController
        evaluated = hasController
    }

    /// Feeds the order capability. Its "not checked yet" state is not an answer.
    mutating func reorderingChanged(_ availability: Availability) {
        guard !evaluated, availability != .notChecked, availability != .available else { return }
        evaluated = true
        queued = []
    }

    /// The apps to place now, for a scan pass that finished with `sighted` as its new apps. With a controller
    /// that is the same apps, unless no scan has finished with the order entries available since the controller
    /// came: then they wait, and the first such pass releases them with the queue. Without a controller the apps
    /// wait until the first answer and are never placed after it.
    mutating func sighted(_ apps: [AppID], orderEntriesAvailable: Bool) -> [AppID] {
        guard hasController else {
            if !evaluated { enqueue(apps) }
            return []
        }
        guard awaitingScan else { return apps }
        enqueue(apps)
        guard orderEntriesAvailable else { return [] }
        awaitingScan = false
        defer { queued = [] }
        return queued
    }

    /// The first controller ends the wait for the answer; the queue then waits for a scan.
    mutating func controllerInstalled() {
        hasController = true
        evaluated = true
        awaitingScan = true
    }

    /// Reordering was available but no controller could be made: that is the first answer, and a refusal.
    mutating func controllerUnobtainable() {
        evaluated = true
        queued = []
    }

    mutating func controllerRemoved() {
        hasController = false
        awaitingScan = false
        queued = []
    }

    private mutating func enqueue(_ apps: [AppID]) {
        for app in apps where !queued.contains(app) { queued.append(app) }
    }
}
