import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelManagerLoginItemTests: XCTestCase {
    @MainActor
    func testStartPreparesAutostartTunnelWithoutImmediateSSHStart() async {
        var settings = makeTestSettings()
        settings.autostartOnLogin = true
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: [controller]
        )

        await manager.start()

        XCTAssertTrue(controller.wantsToBeConnected)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(masterClient.startCalls.isEmpty)
        XCTAssertTrue(masterClient.checkCalls.isEmpty)
    }

    @MainActor
    func testOverallStatePrioritizesFailedOverConnected() {
        let connected = TunnelController(
            settings: makeTestSettings(),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            startsMonitoring: false
        )
        var failedSettings = makeTestSettings()
        failedSettings.id = UUID()
        let failed = TunnelController(
            settings: failedSettings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            startsMonitoring: false
        )
        connected.state = .connected
        failed.state = .failed
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: []),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: [connected, failed]
        )

        XCTAssertEqual(manager.overallState, .failed)
    }

    @MainActor
    func testOverallStatePrioritizesTransientStatesOverConnected() {
        let connected = TunnelController(
            settings: makeTestSettings(),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            startsMonitoring: false
        )
        var reconnectingSettings = makeTestSettings()
        reconnectingSettings.id = UUID()
        let reconnecting = TunnelController(
            settings: reconnectingSettings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            startsMonitoring: false
        )
        connected.state = .connected
        reconnecting.state = .reconnecting
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: []),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: [connected, reconnecting]
        )

        XCTAssertEqual(manager.overallState, .connecting)
    }

    @MainActor
    func testEnablingAnyAutostartTunnelRegistersLoginItem() throws {
        let settings = makeTestSettings()
        let loginItems = SpyLoginItemManager()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: loginItems,
            controllers: []
        )

        var updated = settings
        updated.autostartOnLogin = true
        try manager.updateSettings(updated)

        XCTAssertEqual(loginItems.setEnabledCalls, [true])
    }

    @MainActor
    func testRemovingLastAutostartTunnelDisablesLoginItem() async throws {
        var settings = makeTestSettings()
        settings.autostartOnLogin = true
        let loginItems = SpyLoginItemManager(isEnabled: true)
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: loginItems,
            controllers: []
        )

        await manager.removeTunnel(id: settings.id)

        XCTAssertEqual(loginItems.setEnabledCalls, [false])
    }

    @MainActor
    func testAddTunnelForEditingSelectsNewTunnel() {
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: []),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: []
        )

        let tunnel = manager.addTunnelForEditing()

        XCTAssertEqual(manager.settingsSelection, tunnel.id)
        XCTAssertEqual(manager.settingsStore.tunnels.map(\.id), [tunnel.id])
    }

    @MainActor
    func testRemoveTunnelForEditingSelectsFirstRemainingTunnel() async {
        let first = makeTestSettings()
        var second = makeTestSettings()
        second.id = UUID()
        second.name = "Second"
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [first, second]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: []
        )
        manager.settingsSelection = second.id

        await manager.removeTunnelForEditing(id: second.id)

        XCTAssertEqual(manager.settingsSelection, first.id)
        XCTAssertEqual(manager.settingsStore.tunnels.map(\.id), [first.id])
    }

    @MainActor
    func testUpdatingDeletedTunnelDoesNotRecreateIt() async throws {
        let settings = makeTestSettings()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager()
        )

        await manager.removeTunnel(id: settings.id)
        try manager.updateSettings(settings)

        XCTAssertTrue(manager.settingsStore.tunnels.isEmpty)
        XCTAssertNil(manager.controller(for: settings.id))
    }

    @MainActor
    func testRepeatedDeletedTunnelAutosavesStayIgnored() async throws {
        let settings = makeTestSettings()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager()
        )

        await manager.removeTunnelForEditing(id: settings.id)
        var staleDraft = settings
        staleDraft.name = "Stale Draft"
        try manager.updateSettings(staleDraft)
        try manager.updateSettings(staleDraft)

        XCTAssertTrue(manager.settingsStore.tunnels.isEmpty)
        XCTAssertTrue(manager.controllers.isEmpty)
        XCTAssertNil(manager.settingsSelection)
    }

    @MainActor
    func testMoveTunnelsKeepsControllersInSettingsOrder() {
        let first = makeTestSettings()
        var second = makeTestSettings()
        second.id = UUID()
        second.name = "Second"
        var third = makeTestSettings()
        third.id = UUID()
        third.name = "Third"
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [first, second, third]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager()
        )

        manager.moveTunnels(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(manager.settingsStore.tunnels.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(manager.controllers.map(\.id), [third.id, first.id, second.id])
    }

    @MainActor
    func testMoveTunnelsKeepsCurrentSelection() {
        let first = makeTestSettings()
        var second = makeTestSettings()
        second.id = UUID()
        second.name = "Second"
        var third = makeTestSettings()
        third.id = UUID()
        third.name = "Third"
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [first, second, third]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager()
        )
        manager.settingsSelection = second.id

        manager.moveTunnels(fromOffsets: IndexSet(integer: 1), toOffset: 3)

        XCTAssertEqual(manager.settingsSelection, second.id)
        XCTAssertEqual(manager.settingsStore.tunnels.map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(manager.controllers.map(\.id), [first.id, third.id, second.id])
    }
}
