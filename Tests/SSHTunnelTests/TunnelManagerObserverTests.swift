import XCTest
@testable import SSHTunnelKit

final class TunnelManagerObserverTests: XCTestCase {

    @MainActor
    func testStoppedManagerIgnoresSettingsChangeBroadcast() async {
        // The `.tunnelSettingsChanged` observer must be removed on shutdown.
        // Otherwise a stopped manager keeps mutating its store from the shared
        // NotificationCenter (and cross-contaminates other instances/tests).
        let settings = makeTestSettings()
        let store = TunnelSettingsStore(tunnels: [settings])
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: StubSSHMasterClient(),
            portChecker: StubPortChecker(),
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )
        let manager = TunnelManager(
            settingsStore: store,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: [controller]
        )

        manager.stopSynchronously()

        var changed = settings
        changed.name = "Changed After Stop"
        NotificationCenter.default.post(name: .tunnelSettingsChanged, object: changed)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            store.tunnel(for: settings.id)?.name,
            "Test Tunnel",
            "a stopped manager must not react to settings-change broadcasts"
        )

        // Keep the manager alive until the end so deinit doesn't race the post.
        withExtendedLifetime(manager) {}
    }
}
