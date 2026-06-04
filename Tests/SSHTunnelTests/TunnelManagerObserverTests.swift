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

    /// `updateSettings` validates before mutating, so a rejected update must
    /// leave the store byte-for-byte unchanged — this is the contract the
    /// observer's `try?` quietly relies on.
    @MainActor
    func testUpdateSettingsRejectsInvalidSettingsWithoutMutatingStore() {
        let settings = makeTestSettings()
        let store = TunnelSettingsStore(tunnels: [settings])
        let manager = TunnelManager(
            settingsStore: store,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: []
        )

        var invalid = settings
        invalid.name = ""  // empty after normalization → .emptyName

        XCTAssertThrowsError(try manager.updateSettings(invalid)) { error in
            XCTAssertEqual(error as? TunnelSettingsValidationError, .emptyName)
        }
        XCTAssertEqual(
            store.tunnel(for: settings.id)?.name, "Test Tunnel",
            "a rejected update must not partially persist"
        )

        manager.stopSynchronously()
    }

    /// The `.tunnelSettingsChanged` observer wraps `updateSettings` in `try?`.
    /// An invalid broadcast must be swallowed (no crash, no corruption) while a
    /// subsequent valid broadcast still applies — proving the pipeline survives
    /// a bad payload rather than wedging on it.
    @MainActor
    func testInvalidSettingsBroadcastIsDroppedButValidOnesStillApply() async {
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

        var invalid = settings
        invalid.name = ""
        NotificationCenter.default.post(name: .tunnelSettingsChanged, object: invalid)

        // A valid follow-up acts as a liveness sentinel: once it lands we know
        // the observer drained the invalid one ahead of it.
        var valid = settings
        valid.name = "Renamed"
        NotificationCenter.default.post(name: .tunnelSettingsChanged, object: valid)

        let applied = await waitUntil { store.tunnel(for: settings.id)?.name == "Renamed" }
        XCTAssertTrue(applied, "valid broadcast must still apply after a dropped invalid one")

        manager.stopSynchronously()
        withExtendedLifetime(manager) {}
    }
}
