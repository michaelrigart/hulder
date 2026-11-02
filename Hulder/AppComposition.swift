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
    private var gate = PermissionGate()
    private var onboardingVisible = false
    private var settingsFailuresRecorded = 0
    private var failuresLogged = 0
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
        track()
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
        case .layout:
            AnyView(LayoutView(
                state: stateModel, menuBar: menuBar, actions: layoutActions,
                access: platform.orderAccess, platform: platform))
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
        gate.update(capabilities)
        if gate.showsOnboarding, !onboardingVisible {
            onboardingVisible = true
            presenter.show(.onboarding)
        } else if !gate.showsOnboarding, onboardingVisible {
            onboardingVisible = false
            presenter.close(.onboarding)
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

    /// Hands the driver the stored layout, the reveal state and the running apps, once the gate allows it
    /// and the first running apps are known. The driver sends nothing that hasn't changed.
    private func pushToDriver() {
        guard gate.feedsDriver, let running else { return }
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

    /// Runs `stateChanged` after each change to the stored state, to the count of failed saves or to the
    /// count of recorded failures. The next change is watched from the same turn, so none is missed.
    private func track() {
        let (state, menuBar) = (stateModel, menuBar)
        withObservationTracking {
            _ = state.state
            _ = state.failedSaveCount
            _ = menuBar.recordedFailureCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.stateChanged()
                self?.track()
            }
        }
    }

    private func stateChanged() {
        applyState()
        for _ in settingsFailuresRecorded..<stateModel.failedSaveCount {
            menuBar.recordFailure(.settingsNotSaved, at: Date())
        }
        settingsFailuresRecorded = stateModel.failedSaveCount
        logNewFailures()
    }

    /// Every failure goes through `MenuBarModel.recordFailure`, so this is the one place they are logged.
    private func logNewFailures() {
        let new = menuBar.recordedFailureCount - failuresLogged
        failuresLogged = menuBar.recordedFailureCount
        for record in menuBar.failures.suffix(new) {
            Log.app.notice("Failure: \(record.kind.rawValue, privacy: .public)")
        }
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
        case .rejected: menuBar.recordFailure(.hidingRejected, at: Date())
        case .timedOut: menuBar.recordFailure(.hidingTimedOut, at: Date())
        case .unavailable: menuBar.recordFailure(.hidingUnavailable, at: Date())
        }
    }

    // MARK: - Helpers

    private static var stateFile: URL {
        URL.applicationSupportDirectory.appending(path: HulderCore.bundleID).appending(path: "state.json")
    }

    private static func word(_ availability: Availability) -> String {
        availability == .available ? "available" : "unavailable"
    }
}
