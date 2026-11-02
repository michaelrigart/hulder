import Foundation
import Observation

public enum StoreStatus: Equatable, Sendable {
    case ok
    case recovered
    /// Hulder won't change the settings file. The text is fixed by Hulder and safe to show.
    case readOnly(String)
}

@MainActor @Observable
public final class StateModel {
    public private(set) var state: HulderState
    public private(set) var storeStatus: StoreStatus
    /// True after a save failed that the file's format didn't cause, until the next save succeeds.
    public private(set) var saveFailed = false
    /// How many saves have failed for a reason other than the file's format. It only grows.
    public private(set) var failedSaveCount = 0

    @ObservationIgnored private let store: StateStore

    public init(store: StateStore) {
        self.store = store
        switch store.load() {
        case .fresh:
            state = HulderState()
            storeStatus = .ok
        case .loaded(let loaded):
            state = loaded
            storeStatus = .ok
        case .recoveredFromCorrupt:
            state = HulderState()
            storeStatus = .recovered
        case .refused(let error):
            state = HulderState()
            storeStatus = .readOnly(Self.text(for: error))
        }
    }

    public func assign(_ app: AppID, to section: Section) {
        change { $0.layout.assign(app, to: section) }
    }

    public func forget(_ app: AppID) {
        change { $0.layout.forget(app) }
    }

    /// Updates the name and `lastSeen` of every app. Returns the apps that were new, in input order.
    @discardableResult
    public func recordSightings(_ sightings: [(AppID, String)], at date: Date) -> [AppID] {
        var added: [AppID] = []
        change { state in
            for (app, name) in sightings where state.layout.recordSighting(app, name: name, at: date) {
                added.append(app)
            }
        }
        return added
    }

    public func update(_ body: (inout HulderSettings) -> Void) {
        change { body(&$0.settings) }
    }

    public func setDefaultSection(_ section: Section) {
        change { $0.layout.defaultSection = section }
    }

    private func change(_ body: (inout HulderState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        save()
    }

    private func save() {
        if case .readOnly = storeStatus { return }
        do {
            try store.save(state)
            saveFailed = false
        } catch let error as StateFileError {
            storeStatus = .readOnly(Self.text(for: error))
        } catch {
            saveFailed = true
            failedSaveCount += 1
        }
    }

    private static func text(for error: StateFileError) -> String {
        switch error {
        case .unsupportedVersion(let version):
            "Settings were saved by a newer version of Hulder (format \(version))."
        case .corrupt:
            "The settings file can't be read, so Hulder won't change it."
        }
    }
}
