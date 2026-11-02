@testable import HulderCore

extension StateModel {
    /// Loads on the calling thread, which the app never does: tests have no start-up step to load in.
    convenience init(store: StateStore) {
        self.init(store: store, load: store.load())
    }
}
