import XCTest
@testable import SSHTunnelKit

final class TunnelControllerQuickForwardTests: XCTestCase {

    @MainActor
    func testRemovingQuickForwardViaMenuDoesNotReAddViaStaleNotification() async throws {
        // Faithful repro of the real-app menu flow:
        //   - add quick forward via `manager.updateSettings` (menu "+" path),
        //     which assigns a local port asynchronously and re-broadcasts the
        //     updated settings via `.tunnelSettingsChanged`.
        //   - remove it via `manager.removeQuickForward` (menu trash path).
        //   - a periodic health check then probes the forwarded ports.
        // The bug: the stale broadcast (still carrying the forward) is applied
        // after the removal, re-adding the forward to `forwardedPorts`. The
        // health probe then finds that cancelled port dead → reconnect loop.
        var settings = makeTestSettings()
        settings.quickForwards = []

        let store = TunnelSettingsStore(tunnels: [settings])
        let masterClient = StubSSHMasterClient()
        let healthChecker = StubForwardHealthChecker()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )
        let manager = TunnelManager(
            settingsStore: store,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            loginItemManager: SpyLoginItemManager(),
            controllers: [controller]
        )

        masterClient.checkResults = [preCheckMiss, masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        // Menu add: localPort nil → controller assigns one asynchronously.
        var added = controller.settings
        let forwardId = UUID()
        added.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: nil)]
        try manager.updateSettings(added)

        // Let the async port assignment + notification round-trip settle.
        try? await Task.sleep(for: .milliseconds(200))
        let assignedPort = controller.settings.quickForwards.first?.localPort
        XCTAssertNotNil(assignedPort)
        XCTAssertEqual(controller.forwardedPorts, [assignedPort!])

        // Menu remove.
        try await manager.removeQuickForward(forwardId, from: settings.id)

        // Allow any stale `.tunnelSettingsChanged` broadcasts to be delivered.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.settings.quickForwards, [], "forward must stay removed")
        XCTAssertEqual(controller.forwardedPorts, [], "removed port must not linger")
        XCTAssertEqual(store.tunnel(for: settings.id)?.quickForwards, [])

        // The cancelled port is now dead; a health check must NOT tear down the
        // otherwise-healthy master.
        healthChecker.unreachablePorts = assignedPort.map { [$0] } ?? []
        masterClient.checkResults = [masterReady]
        await controller.checkTunnelHealth()

        XCTAssertEqual(controller.state, .connected, "healthy master must stay connected after removal")
    }

    @MainActor
    func testDeadForwardOnLiveMasterIsRepairedInsteadOfLoopingReconnect() async {
        // Repro of the real-app reconnect loop: a quick forward shared a local
        // port with a config LocalForward. Removing the quick forward cancels
        // the port on the master, leaving the config forward dead while it is
        // still advertised in `forwardedPorts`. The master still answers
        // `-O check`, so every reconnect just re-adopts the same live master and
        // finds the same dead port → endless reconnecting → failed.
        var settings = makeTestSettings()
        settings.quickForwards = []
        let hostOptions = SSHHostOptions(
            hostname: "host", user: "u", port: "22",
            forwardInfos: [ForwardInfo(localPort: 9871, remotePort: 4001)],
            userControlPath: ""
        )
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [hostOptions, hostOptions, hostOptions]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let healthChecker = StubForwardHealthChecker()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [9871])

        // Dead on the first probe, healthy again after the controller
        // re-establishes the forward on the live master.
        healthChecker.unreachableSequence = [[9871], []]
        masterClient.checkResults = [masterReady]

        await controller.checkTunnelHealth()

        XCTAssertEqual(controller.state, .connected,
                       "a dead forward on a live master must be repaired, not looped into reconnect")
        XCTAssertTrue(masterClient.addForwardCalls.contains { $0.localPort == 9871 },
                      "controller must re-establish the dead forward on the live master")
    }

    @MainActor
    func testAddingQuickForwardToConnectedTunnelAppliesImmediately() async {

        let settings = makeTestSettings()
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        // Given a connected tunnel
        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        
        // When adding a quick forward
        var updated = controller.settings
        updated.quickForwards.append(QuickForward.makeDefault(remotePort: 8080))
        portChecker.freePorts = [9000]
        
        controller.updateSettings(updated)
        
        // Then it should find a free port and apply it
        try? await Task.sleep(for: .milliseconds(200))
        
        XCTAssertEqual(masterClient.addForwardCalls.count, 1)
        let call = masterClient.addForwardCalls.first
        XCTAssertEqual(call?.remotePort, 8080)
        XCTAssertEqual(call?.localPort, 9000)
        
        XCTAssertEqual(controller.forwardedPorts, [9000])
    }

    @MainActor
    func testRemovingQuickForwardFromConnectedTunnelCancelsImmediately() async {
        var settings = makeTestSettings()
        let forwardId = UUID()
        settings.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: 9000)]
        
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        
        // When removing the quick forward
        var updated = controller.settings
        updated.quickForwards.removeAll()
        
        controller.updateSettings(updated)
        
        // Then it should cancel the forward
        try? await Task.sleep(for: .milliseconds(200))
        
        XCTAssertEqual(masterClient.removeForwardCalls.count, 1)
        let call = masterClient.removeForwardCalls.first
        XCTAssertEqual(call?.remotePort, 8080)
        XCTAssertEqual(call?.localPort, 9000)
        
        XCTAssertEqual(controller.forwardedPorts, [])
    }

    @MainActor
    func testRemovingQuickForwardThroughManagerPersistsAndCancelsBeforeReturning() async throws {
        var settings = makeTestSettings()
        let forwardId = UUID()
        settings.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: 9000)]

        let store = TunnelSettingsStore(tunnels: [settings])
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
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

        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        try await manager.removeQuickForward(forwardId, from: settings.id)

        XCTAssertEqual(store.tunnel(for: settings.id)?.quickForwards, [])
        XCTAssertEqual(controller.settings.quickForwards, [])
        XCTAssertEqual(controller.forwardedPorts, [])
        XCTAssertEqual(masterClient.removeForwardCalls.count, 1)
        XCTAssertEqual(masterClient.removeForwardCalls.first?.remotePort, 8080)
        XCTAssertEqual(masterClient.removeForwardCalls.first?.localPort, 9000)
    }

    @MainActor
    func testQuickForwardRemovalUsesMasterControlPathTemplate() async throws {
        var settings = makeTestSettings(controlPath: "/tmp/control-%h")
        let forwardId = UUID()
        settings.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: 9000)]

        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "resolved.example.com",
                user: "me",
                port: "22",
                forwardInfos: [ForwardInfo(localPort: 1443, remotePort: 443)],
                userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        masterClient.checkResults = [preCheckMiss, masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected, controller.lastError ?? "")

        var updated = controller.settings
        updated.quickForwards.removeAll()
        await controller.updateSettingsAndApplyChanges(updated)

        XCTAssertEqual(masterClient.removeForwardCalls.count, 1)
        // The forward command must reuse the *unexpanded* template + the alias,
        // exactly like the master spawn and `-O check`, so ssh derives the same
        // ControlPath socket. Pre-expanding tokens ourselves (or using a
        // `-F /dev/null` resolved target) would target a non-existent socket.
        XCTAssertEqual(masterClient.removeForwardCalls.first?.controlPath, "/tmp/control-%h")
        XCTAssertEqual(
            masterClient.removeForwardCalls.first?.target,
            .configured(hostAlias: "test-host")
        )
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [1443])
    }

    @MainActor
    func testQuickForwardAddUsesUnexpandedControlPathTemplate() async {
        // Reproduces the `%C` mismatch: the master socket is created by ssh
        // expanding `%C` itself, so the forward must pass the raw template and
        // the alias — never a pre-hashed filesystem path.
        var settings = makeTestSettings(controlPath: "~/.ssh/control-sshtunnelapp-%C")
        settings.quickForwards = []

        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        var updated = controller.settings
        updated.quickForwards = [QuickForward(id: UUID(), remotePort: 3030, localPort: 37039)]
        await controller.updateSettingsAndApplyChanges(updated)

        XCTAssertEqual(masterClient.addForwardCalls.count, 1)
        let call = masterClient.addForwardCalls.first
        // The `%C` token survives into the ssh argument so ssh expands it to
        // the same socket the master created.
        XCTAssertTrue(call?.controlPath.contains("%C") == true,
                      "expected raw %C template, got \(call?.controlPath ?? "nil")")
        XCTAssertEqual(call?.target, .configured(hostAlias: "test-host"))
    }

    @MainActor
    func testQuickForwardRemovedWhileDisconnectedIsCancelledOnAdopt() async {        // Repro: the user removes a quick forward while the tunnel is briefly
        // not `.connected` (e.g. during a network blip). The immediate cancel
        // is skipped, but the ssh master is still alive and keeps the local
        // port open. On recovery the controller re-adopts that live master —
        // it must cancel the now-stale forward instead of leaving it open.
        var settings = makeTestSettings()
        let forwardId = UUID()
        settings.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: 9000)]

        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        // Fresh start spawns a master and establishes the forward.
        masterClient.checkResults = [preCheckMiss, masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(masterClient.addForwardCalls.count, 1)

        // Network blip: the path drops but the ssh master stays alive.
        controller.state = .disconnected

        // User removes the quick forward while not connected — the immediate
        // cancel is deferred (state != .connected).
        var updated = controller.settings
        updated.quickForwards.removeAll()
        controller.updateSettings(updated)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(masterClient.removeForwardCalls.count, 0,
                       "removal is deferred while not connected")

        // Recovery: fresh start adopts the still-alive master.
        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        // The stale forward must be cancelled on the adopted master.
        XCTAssertEqual(masterClient.removeForwardCalls.count, 1)
        XCTAssertEqual(masterClient.removeForwardCalls.first?.remotePort, 8080)
        XCTAssertEqual(masterClient.removeForwardCalls.first?.localPort, 9000)
        XCTAssertEqual(controller.forwardedPorts, [])
    }

    @MainActor
    func testChangingRemotePortCancelsOldAndAddsNew() async {
        var settings = makeTestSettings()
        let forwardId = UUID()
        settings.quickForwards = [QuickForward(id: forwardId, remotePort: 8080, localPort: 9000)]
        
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        
        // When changing the remote port
        var updated = controller.settings
        updated.quickForwards[0].remotePort = 8081
        
        controller.updateSettings(updated)
        
        // Then it should cancel 8080 and add 8081
        try? await Task.sleep(for: .milliseconds(200))
        
        XCTAssertEqual(masterClient.removeForwardCalls.count, 1)
        XCTAssertEqual(masterClient.removeForwardCalls.first?.remotePort, 8080)
        
        XCTAssertEqual(masterClient.addForwardCalls.count, 2) // One from start, one from update
        XCTAssertEqual(masterClient.addForwardCalls.last?.remotePort, 8081)
    }

    @MainActor
    func testQuickForwardPortAssignedOnStartIfMissing() async {
        var settings = makeTestSettings()
        settings.quickForwards = [QuickForward(id: UUID(), remotePort: 8080, localPort: nil)]
        
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        portChecker.freePorts = [9500]
        masterClient.checkResults = [preCheckMiss, masterReady]
        
        await controller.startTunnel()
        
        XCTAssertEqual(controller.settings.quickForwards.first?.localPort, 9500)
        XCTAssertEqual(masterClient.addForwardCalls.first?.localPort, 9500)
    }

    @MainActor
    func testQuickForwardDoesNotCollideWithConfigPorts() async {
        let settings = makeTestSettings()
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "h", user: "u", port: "22", forwardInfos: [ForwardInfo(localPort: 8080)], userControlPath: "")
        ]
        
        var updated = settings
        updated.quickForwards = [QuickForward(id: UUID(), remotePort: 8080, localPort: 9000)]
        controller.updateSettings(updated)
        
        masterClient.checkResults = [masterReady]
        await controller.startTunnel()
        
        XCTAssertTrue(controller.forwardedPorts.contains(8080))
        XCTAssertTrue(controller.forwardedPorts.contains(9000))
    }

    @MainActor
    func testFindFreePortFailureHandlesGracefully() async {
        let settings = makeTestSettings()
        let portChecker = StubPortChecker()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: portChecker,
            forwardHealthChecker: StubForwardHealthChecker(),
            startsMonitoring: false
        )

        portChecker.shouldFailFindFreePort = true
        masterClient.checkResults = [masterReady]
        await controller.startTunnel()

        var updated = settings
        updated.quickForwards.append(QuickForward.makeDefault(remotePort: 8080))
        controller.updateSettings(updated)
        
        try? await Task.sleep(for: .milliseconds(200))
        
        XCTAssertEqual(masterClient.addForwardCalls.count, 0)
        XCTAssertNil(controller.settings.quickForwards.first?.localPort)
    }
}
