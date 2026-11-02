import Foundation
import HulderCore
import HulderPlatform27
import Observation
import SwiftUI

/// Builds the platform's models and controllers and connects them. It holds no rules: every decision
/// is made by a type in `HulderCore`.
@MainActor
final class AppComposition {
    private let platform: any MenuBarPlatform
    private let stateModel: StateModel
    private let menuBar: MenuBarModel
    private let layoutActions: LayoutActions
    private let driver: ConcealmentDriver
    private let loginItem = LoginItem()

    private lazy var revealController = RevealController(
        machine: RevealMachine(autoRehide: nil),
        clock: ContinuousClock(),
        onChange: { [weak self] state in self?.revealChanged(state) })
    private lazy var presenter = WindowPresenter(content: { [weak self] kind in
        self?.makeWindowContent(kind) ?? AnyView(EmptyView())
    })
    private lazy var hotkeys = HotkeyCenter(
        onToggle: { [weak self] in self?.revealController.send(.toggle) },
        onRevealAll: { [weak self] in self?.revealController.send(.toggleAll) })
    private lazy var statusItem = StatusItemController(
        send: { [weak self] input in self?.revealController.send(input) },
        showLayout: { [weak self] in self?.presenter.show(.layout) },
        showSettings: { [weak self] in self?.presenter.show(.settings) },
        lastFailure: { [weak self] in self?.menuBar.lastFailure })

    private var subscriptions: [Task<Void, Never>] = []
    private var running: Set<AppID>?
    private var listingSeen = false
    private var onboardingVisible = false
    private var orderTask: Task<Void, Never>?
    private var orderGeneration = 0

    init(platform: any MenuBarPlatform) {
        self.platform = platform
        let stateModel = StateModel(store: StateStore(fileURL: Self.stateFile))
        let menuBar = MenuBarModel()
        self.stateModel = stateModel
        self.menuBar = menuBar
        layoutActions = LayoutActions(state: stateModel, menuBar: menuBar, order: nil)
        driver = ConcealmentDriver(
            controller: ConcealmentController(backend: platform.concealment, clock: ContinuousClock()),
            own: platform.ownAppID,
            onOutcome: { outcome in Self.concealmentFinished(outcome, in: menuBar) })
    }

    func start() {
        _ = statusItem
        applyState()
        trackState()
        subscribe { await self.followCapabilities() }
        subscribe { await self.followRunningApps() }
        subscribe { await self.followScans() }
        subscribe { await self.followMenus() }
        subscribe { await self.followSession() }
    }

    /// Ends the concealment, so every item shows again.
    func shutdown() async {
        subscriptions.forEach { $0.cancel() }
        stopOrder()
        await driver.releaseAll()
    }

    func makeWindowContent(_ kind: WindowKind) -> AnyView {
        switch kind {
        case .onboarding: AnyView(OnboardingView())
        case .layout: AnyView(Text("Layout"))
        case .settings: AnyView(Text("Settings"))
        }
    }

    // MARK: - Platform streams

    private func subscribe(_ body: @escaping @MainActor () async -> Void) {
        subscriptions.append(Task { await body() })
    }

    private func followCapabilities() async {
        for await capabilities in platform.capabilityChanges() {
            capabilitiesChanged(capabilities)
        }
    }

    private func followRunningApps() async {
        for await apps in platform.runningApps() {
            running = apps
            menuBar.running = apps
            pushToDriver()
        }
    }

    private func followScans() async {
        for await scans in platform.scans() {
            await scanned(scans)
        }
    }

    private func followMenus() async {
        for await isOpen in platform.menuOpen() {
            revealController.send(isOpen ? .menuOpened : .menuClosed)
        }
    }

    private func followSession() async {
        for await event in platform.sessionEvents() {
            switch event {
            case .lockedOrAsleep: revealController.send(.lockedOrAsleep)
            }
        }
    }

    // MARK: - Handlers

    private func capabilitiesChanged(_ capabilities: Capabilities) {
        Log.app.notice("""
            Capabilities: hiding \(Self.word(capabilities.hiding), privacy: .public), \
            listing \(Self.word(capabilities.listing), privacy: .public), \
            reordering \(Self.word(capabilities.reordering), privacy: .public), \
            menu tracking \(String(describing: capabilities.menuTracking), privacy: .public)
            """)
        menuBar.capabilities = capabilities
        applyRehide()
        if capabilities.listing == .available {
            listingSeen = true
            if onboardingVisible {
                onboardingVisible = false
                presenter.close(.onboarding)
            }
        } else if capabilities.hiding == .available, !onboardingVisible {
            onboardingVisible = true
            presenter.show(.onboarding)
        }
        pushToDriver()
        if capabilities.reordering == .available {
            startOrderIfNeeded()
        } else {
            stopOrder()
        }
    }

    private func scanned(_ scans: [AppScan]) async {
        let inventory = InventoryMerger.merge(previous: menuBar.inventory, scans: scans)
        menuBar.divider = platform.ownItemKey(in: inventory)
        menuBar.inventory = inventory
        let sightings = SightingRecorder.sightings(in: inventory, own: platform.ownAppID)
        for app in stateModel.recordSightings(sightings, at: Date()) {
            await layoutActions.placeFirstSighting(app)
        }
    }

    private func revealChanged(_ state: RevealState) {
        statusItem.setState(state)
        pushToDriver()
    }

    /// Hands the driver the stored layout, the reveal state and the running apps, once Accessibility has
    /// been granted and the first running apps are known. The driver sends nothing that hasn't changed.
    private func pushToDriver() {
        guard listingSeen, let running else { return }
        driver.update(layout: stateModel.state.layout, state: revealController.state, running: running)
    }

    private func applyRehide() {
        revealController.setAutoRehide(
            RevealPolicy.autoRehide(
                delay: stateModel.state.settings.rehideDelay, tracking: menuBar.capabilities.menuTracking))
    }

    // MARK: - Stored state

    private func applyState() {
        let settings = stateModel.state.settings
        applyRehide()
        hotkeys.apply(toggle: settings.toggleHotkey, revealAll: settings.revealAllHotkey)
        loginItem.apply(settings.launchAtLogin)
        pushToDriver()
    }

    /// Runs `stateChanged` after each change to the stored state. The change has been saved by then, and
    /// the next one is watched from the same turn, so none is missed.
    private func trackState() {
        let model = stateModel
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.stateChanged()
                self?.trackState()
            }
        }
    }

    // `saveFailed` is a level: it stays true while saves keep failing. Each change of the state is one
    // save, so each change that finds it set is one failed save.
    private func stateChanged() {
        applyState()
        if saveFailedAgain {
            Self.record(.settingsNotSaved, in: menuBar)
        }
    }

    /// A read-only store refuses to save without setting `saveFailed`, so a stale flag doesn't count.
    private var saveFailedAgain: Bool {
        if case .readOnly = stateModel.storeStatus { return false }
        return stateModel.saveFailed
    }

    // MARK: - Order access

    private func startOrderIfNeeded() {
        guard orderTask == nil else { return }
        orderGeneration += 1
        let generation = orderGeneration
        orderTask = Task {
            guard let store = await platform.orderStore(), generation == orderGeneration else {
                if generation == orderGeneration { orderTask = nil }
                return
            }
            layoutActions.setOrderController(OrderController(store: store, clock: ContinuousClock()))
            for await order in store.changes() {
                guard generation == orderGeneration else { return }
                menuBar.order = order
            }
        }
    }

    private func stopOrder() {
        orderGeneration += 1
        orderTask?.cancel()
        orderTask = nil
        layoutActions.setOrderController(nil)
        menuBar.order = nil
    }

    // MARK: - Failures

    private static func concealmentFinished(_ outcome: ApplyOutcome, in menuBar: MenuBarModel) {
        guard case .failed(let failure) = outcome else { return }
        switch failure {
        case .rejected: record(.hidingRejected, in: menuBar)
        case .timedOut: record(.hidingTimedOut, in: menuBar)
        case .unavailable: record(.hidingUnavailable, in: menuBar)
        }
    }

    private static func record(_ kind: FailureKind, in menuBar: MenuBarModel) {
        Log.app.notice("Failure: \(kind.rawValue, privacy: .public)")
        menuBar.recordFailure(kind, at: Date())
    }

    // MARK: - Helpers

    private static var stateFile: URL {
        URL.applicationSupportDirectory.appending(path: HulderCore.bundleID).appending(path: "state.json")
    }

    private static func word(_ availability: Availability) -> String {
        availability == .available ? "available" : "unavailable"
    }
}
