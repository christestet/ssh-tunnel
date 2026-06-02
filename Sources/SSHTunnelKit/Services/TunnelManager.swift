import Foundation
import Observation

@MainActor
@Observable
public final class TunnelManager {
    let settingsStore: TunnelSettingsStore
    let logSettingsStore: LogSettingsStore
    private(set) var controllers: [TunnelController] = []
    public var settingsSelection: UUID?
    /// When set, the settings window should scroll to and highlight the
    /// quick forward with this id. Cleared once the settings view consumes it.
    public var settingsQuickForwardFocus: UUID?
    private let sshRunner: SSHRunning
    private let notifier: TunnelNotifying
    private let loginItemManager: LoginItemManaging
    private var networkMonitor: NetworkMonitor?
    private var settingsObserver: NSObjectProtocol?

    public convenience init(settingsStore: TunnelSettingsStore) {
        self.init(
            settingsStore: settingsStore,
            logSettingsStore: nil,
            sshRunner: ProcessSSHRunner(),
            notifier: UserNotificationTunnelNotifier(),
            loginItemManager: nil,
            controllers: nil
        )
    }

    init(
        settingsStore: TunnelSettingsStore,
        logSettingsStore: LogSettingsStore? = nil,
        sshRunner: SSHRunning = ProcessSSHRunner(),
        notifier: TunnelNotifying = UserNotificationTunnelNotifier(),
        loginItemManager: LoginItemManaging? = nil,
        controllers: [TunnelController]? = nil
    ) {
        self.settingsStore = settingsStore
        self.logSettingsStore = logSettingsStore ?? LogSettingsStore()
        self.sshRunner = sshRunner
        self.notifier = notifier
        self.loginItemManager = loginItemManager ?? LoginItemManager()

        if let controllers {
            self.controllers = controllers
        } else {
            for tunnel in settingsStore.tunnels {
                let ctrl = TunnelController(
                    settings: tunnel,
                    sshRunner: sshRunner,
                    notifier: notifier,
                    startsMonitoring: true
                )
                self.controllers.append(ctrl)
            }
        }
        
        syncLoginItemState()
        
        // Always probe options so we have port info for the UI, but we don't
        // wait for this to show the tunnel in the menu bar anymore.
        for ctrl in self.controllers {
            Task { @MainActor in await ctrl.loadResolvedOptions() }
        }
        
        // Automatically monitor network changes
        self.networkMonitor = NetworkMonitor(tunnelManager: self)

        // Keep the token so we can deregister on shutdown/dealloc. Leaking it
        // means every manager ever created keeps reacting to the shared
        // `NotificationCenter`, which cross-contaminates tests and lives for the
        // app's lifetime.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .tunnelSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let settings = notification.object as? TunnelSettings else { return }
            Task { @MainActor in
                try? self.updateSettings(settings)
            }
        }
    }

    /// Kicks off the initial connection for autostart tunnels.
    public func start() async {
        let autostart = settingsStore.autostartTunnels
        TunnelLog.shared.log(.info, .lifecycle, "manager start — \(controllers.count) tunnels, \(autostart.count) autostart")
        for tunnel in autostart {
            if let ctrl = controller(for: tunnel.id) {
                ctrl.prepareForAutostart()
            }
        }

        if networkMonitor?.isNetworkSatisfied == true {
            networkMonitor?.recoverDesiredTunnels()
        } else {
            TunnelLog.shared.log(.notice, .network, "start deferred — network not yet satisfied")
        }
    }

    public var overallState: TunnelState {
        if controllers.contains(where: { $0.state == .failed }) {
            return .failed
        }
        if controllers.contains(where: { $0.state == .connecting || $0.state == .reconnecting }) {
            return .connecting
        }
        if controllers.contains(where: { $0.state == .connected }) {
            return .connected
        }
        return .disconnected
    }

    func controller(for id: UUID) -> TunnelController? {
        controllers.first { $0.id == id }
    }

    func addTunnel() -> TunnelSettings {
        let settings = settingsStore.addTunnel()
        let ctrl = TunnelController(
            settings: settings,
            sshRunner: sshRunner,
            notifier: notifier,
            startsMonitoring: true
        )
        controllers.append(ctrl)
        Task { @MainActor in await ctrl.loadResolvedOptions() }
        return settings
    }

    func addTunnelForEditing() -> TunnelSettings {
        let settings = addTunnel()
        settingsSelection = settings.id
        return settings
    }

    func removeTunnel(id: UUID) async {
        if let ctrl = controller(for: id) {
            if ctrl.isActive {
                await ctrl.stopTunnel()
            }
            ctrl.stopMonitoring()
            controllers.removeAll { $0.id == id }
        }
        settingsStore.removeTunnel(id: id)
        syncLoginItemState()
    }

    func removeTunnelForEditing(id: UUID) async {
        await removeTunnel(id: id)
        settingsSelection = settingsStore.tunnels.first?.id
    }

    func updateSettings(_ settings: TunnelSettings) throws {
        guard settingsStore.tunnel(for: settings.id) != nil else { return }
        let saved = try settingsStore.save(settings)
        if let ctrl = controller(for: saved.id) {
            ctrl.updateSettings(saved)
            Task { @MainActor in await ctrl.loadResolvedOptions() }
        }
        syncLoginItemState()
    }

    func updateSettingsAndApplyChanges(_ settings: TunnelSettings) async throws {
        guard settingsStore.tunnel(for: settings.id) != nil else { return }
        let saved = try settingsStore.save(settings)
        if let ctrl = controller(for: saved.id) {
            await ctrl.updateSettingsAndApplyChanges(saved)
            Task { @MainActor in await ctrl.loadResolvedOptions() }
        }
        syncLoginItemState()
    }

    func removeQuickForward(_ quickForwardID: UUID, from tunnelID: UUID) async throws {
        guard var settings = settingsStore.tunnel(for: tunnelID) else { return }
        settings.quickForwards.removeAll { $0.id == quickForwardID }
        try await updateSettingsAndApplyChanges(settings)
    }

    func moveTunnels(fromOffsets source: IndexSet, toOffset destination: Int) {
        settingsStore.moveTunnels(fromOffsets: source, toOffset: destination)
        reorderControllersToMatchSettings()
    }

    private func reorderControllersToMatchSettings() {
        let order = Dictionary(uniqueKeysWithValues: settingsStore.tunnels.enumerated().map { ($0.element.id, $0.offset) })
        controllers.sort {
            (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max)
        }
    }

    private func syncLoginItemState() {
        let shouldEnable = settingsStore.autostartTunnels.isEmpty == false
        if loginItemManager.isEnabled != shouldEnable {
            loginItemManager.setEnabled(shouldEnable)
        }
    }

    /// Best-effort blocking shutdown for `applicationWillTerminate`.
    public func stopSynchronously(timeout: TimeInterval = 3) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        networkMonitor?.stop()
        for ctrl in controllers {
            ctrl.terminateMasterForShutdown()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !controllers.contains(where: { $0.hasRunningMaster }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for ctrl in controllers {
            ctrl.killMasterIfStillRunning()
        }
    }
}
