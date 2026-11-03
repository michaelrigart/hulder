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
    /// The newest queued save. Each save waits for the one before it, so the file takes the states in the
    /// order they were made and the results come back in that order.
    @ObservationIgnored private var lastSave: Task<Void, Never>?

    /// `load` is the result of `StateStore.load()`, which blocks and so runs before the model exists, off the
    /// main actor. The model writes nothing until it has been given one.
    public init(store: StateStore, load: StateLoad) {
        self.store = store
        switch load {
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

    /// Resolves once every save made so far has been written, or has failed and been counted.
    public func flushSaves() async {
        await lastSave?.value
    }

    private func save() {
        if case .readOnly = storeStatus { return }
        let snapshot = state
        let store = store
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            if case .readOnly = storeStatus { return }
            do {
                try await store.write(snapshot)
                saveFailed = false
            } catch let error as StateFileError {
                storeStatus = .readOnly(Self.text(for: error))
            } catch {
                saveFailed = true
                failedSaveCount += 1
            }
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
