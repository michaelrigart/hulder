/// Decides when the apps of a first sighting may be placed on the bar.
///
/// At launch the first scan can finish before the order file is open. Sightings made until the order
/// capability's first real answer wait in a queue. If that answer is "available", they are placed once, when
/// the order controller is installed. If it is a refusal, they are dropped. After that first answer a sighting
/// made without a controller is never placed, so a later grant can't move items the user arranged since.
struct SightingPlacementGate {
    private var evaluated: Bool
    private var hasController: Bool
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

    /// The apps to place now: the same apps with a controller, none while one is awaited or after the
    /// first answer.
    mutating func sighted(_ apps: [AppID]) -> [AppID] {
        if hasController { return apps }
        if !evaluated { enqueue(apps) }
        return []
    }

    /// The queued apps to place now, which only the first controller releases.
    mutating func controllerInstalled() -> [AppID] {
        hasController = true
        evaluated = true
        defer { queued = [] }
        return queued
    }

    /// Reordering was available but no controller could be made: that is the first answer, and a refusal.
    mutating func controllerUnobtainable() {
        evaluated = true
        queued = []
    }

    mutating func controllerRemoved() {
        hasController = false
    }

    private mutating func enqueue(_ apps: [AppID]) {
        for app in apps where !queued.contains(app) { queued.append(app) }
    }
}
