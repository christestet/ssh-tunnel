import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerStartStopTests: XCTestCase {

    // MARK: - Happy path & basic state machine

    @MainActor
    func testForwardedPortsAppearInStatusDescription() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname backend.example.com
        user me
        port 22
        localforward 1443 backend.internal:443
        localforward 8080 db.internal:5432
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss,
            masterReady
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.forwardedPorts, [1443, 8080])
        XCTAssertEqual(controller.state, .connected)
    }

    @MainActor
    func testManualStopDoesNotSendNotification() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,         // resolveOptions
            preCheckMiss,   // adopt preCheck: no live master
            masterReady,    // master ready
            gEmpty,         // -O exit during stop
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing") // health check
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        await controller.stopTunnel()
        await controller.checkTunnelHealth()

        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
        XCTAssertEqual(controller.state, .disconnected)
    }

    // MARK: - isActive state machine

    @MainActor
    func testIsActiveForEachState() {
        let settings = makeTestSettings()
        let ctrl = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(), startsMonitoring: false
        )

        ctrl.state = .disconnected
        XCTAssertFalse(ctrl.isActive)
        ctrl.state = .connecting
        XCTAssertTrue(ctrl.isActive)
        ctrl.state = .reconnecting
        XCTAssertTrue(ctrl.isActive)
        ctrl.state = .failed
        XCTAssertFalse(ctrl.isActive)
        ctrl.state = .connected
        XCTAssertTrue(ctrl.isActive)
    }

    // MARK: - SSH master client coordination

    @MainActor
    func testStartDelegatesToMasterClientWithHostAliasAndControlPath() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "host", user: "me", port: "22", forwardInfos: [], userControlPath: "")
        ]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(masterClient.resolveHosts, ["test-host"])
        XCTAssertEqual(masterClient.startCalls.count, 1)
        XCTAssertEqual(masterClient.startCalls.first?.host, "test-host")
        XCTAssertEqual(masterClient.startCalls.first?.controlPath, settings.expandedControlPath)
    }

    @MainActor
    func testStopUsesHostAliasNotLegacyDummyHost() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "host", user: "me", port: "22", forwardInfos: [], userControlPath: "")
        ]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        await controller.stopTunnel()

        XCTAssertEqual(masterClient.exitCalls.count, 1, "stopTunnel must issue an `-O exit` call")
        XCTAssertEqual(masterClient.exitCalls.first?.host, "test-host")
        XCTAssertEqual(masterClient.exitCalls.first?.controlPath, settings.expandedControlPath)
    }

    @MainActor
    func testShutdownUsesControlExitBeforeTerminatingOwnedMaster() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "host", user: "me", port: "22", forwardInfos: [], userControlPath: "")
        ]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let fake = FakeLongRunning()
        masterClient.masterFactory = { fake }
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        controller.terminateMasterForShutdown()

        XCTAssertEqual(masterClient.synchronousExitCalls.count, 1)
        XCTAssertEqual(masterClient.synchronousExitCalls.first?.host, "test-host")
        XCTAssertEqual(masterClient.synchronousExitCalls.first?.controlPath, settings.expandedControlPath)
        XCTAssertFalse(fake.isRunning)
    }

    @MainActor
    func testShutdownUsesControlExitForAdoptedMasterWithoutOwnedHandle() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "host", user: "me", port: "22", forwardInfos: [], userControlPath: "")
        ]
        masterClient.checkResults = [masterReady]
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(controller.hasRunningMaster)

        controller.terminateMasterForShutdown()

        XCTAssertEqual(masterClient.synchronousExitCalls.count, 1)
        XCTAssertEqual(masterClient.synchronousExitCalls.first?.host, "test-host")
        XCTAssertEqual(masterClient.synchronousExitCalls.first?.controlPath, settings.expandedControlPath)
    }

    @MainActor
    func testManualStopKeepsResolvedForwardsForMenuRow() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "host",
                user: "me",
                port: "22",
                forwardInfos: [ForwardInfo(localPort: 1443)],
                userControlPath: ""
            )
        ]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.forwardedPorts, [1443])

        await controller.stopTunnel()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(
            controller.forwardedPorts, [1443],
            "Stopping an active tunnel must not drop the ssh_config-derived forwards from the menu row"
        )
        XCTAssertEqual(masterClient.resolveHosts, ["test-host"])
    }

    // MARK: - Master exit preserves menu-bar visibility

    @MainActor
    func testUnexpectedMasterExitKeepsResolvedForwardsForMenuVisibility() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(hostname: "host", user: "me", port: "22", forwardInfos: [ForwardInfo(localPort: 1443)], userControlPath: "")
        ]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let fake = FakeLongRunning()
        masterClient.masterFactory = { fake }
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [1443])

        fake.simulateUnexpectedExit(code: 255, stderr: "Connection reset by peer")

        // Allow watchMaster to observe the exit.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(controller.state, .connected)
        XCTAssertEqual(
            controller.forwardedPorts, [1443],
            "Master crash must not erase the ssh_config-derived forwards mid-reconnect"
        )
    }

    // MARK: - Unhappy paths

    @MainActor
    func testMasterSpawnFailureMarksFailedWhenNoAttemptsRemain() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty])
        struct SpawnError: Error {}
        runner.startLongRunningError = SpawnError()
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("Failed to spawn") ?? false)
        XCTAssertGreaterThanOrEqual(notifier.failedResults.count, 1)
    }

    @MainActor
    func testMasterSpawnFailureSchedulesReconnectWhenAttemptsRemain() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty])
        struct SpawnError: Error {}
        runner.startLongRunningError = SpawnError()
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        // The first startup failure must not strand the tunnel in .failed —
        // boot-time DNS/agent/VPN delays routinely make the first ssh attempt
        // fail. We retry via backoff, just like a mid-session drop.
        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(controller.wantsToBeConnected)
        XCTAssertTrue(controller.lastError?.contains("Failed to spawn") ?? false)
        XCTAssertEqual(notifier.failedResults.count, 1, "User still gets the failure notification")
    }

    @MainActor
    func testShortLivedSshPortConflictSchedulesReconnectOnRestart() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        localforward 6333 backend:6333
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss
        ])
        let checker = StubPortChecker()
        checker.conflictResults = [
            PortConflict(port: 6333, pid: 42, command: "ssh")
        ]
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false,
            portReleaseGrace: 0
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(controller.wantsToBeConnected)
        XCTAssertTrue(controller.lastError?.contains("6333") ?? false)
    }

    @MainActor
    func testMasterEarlyExitDuringStartMarksFailedWhenNoAttemptsRemain() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss])
        let notifier = SpyTunnelNotifier()
        runner.longRunningFactory = { _ in
            let h = FakeLongRunning()
            h.stderr = "Permission denied (publickey).\n"
            h.terminate()
            return h
        }
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("Permission denied") ?? false)
        XCTAssertTrue(controller.lastError?.contains("gave up") ?? false)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
    }

    @MainActor
    func testMasterEarlyExitDuringStartSchedulesReconnectWhenAttemptsRemain() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss])
        let notifier = SpyTunnelNotifier()
        runner.longRunningFactory = { _ in
            let h = FakeLongRunning()
            h.stderr = "Connection refused\n"
            h.terminate()
            return h
        }
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertEqual(controller.lastError, "Connection refused")
        XCTAssertTrue(controller.wantsToBeConnected)
        XCTAssertTrue(notifier.failedResults.isEmpty)
    }

    @MainActor
    func testForwardedPortsEmptyWhenSshGFails() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "no host"), // resolveOptions fails
            preCheckMiss,
            masterReady,
            SSHResult(exitCode: 1, stdout: "", stderr: "no host")  // retry after master up still fails
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [])
    }

    // MARK: - Double start / stop safety

    @MainActor
    func testDoubleStartDoesNotSpawnTwoMasters() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,        // resolveOptions for 1st start
            preCheckMiss,  // adopt preCheck: no live master
            masterReady    // waitForMasterReady for 1st start
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(runner.longRunningCalls.count, 1,
                       "Second start must not spawn another master while the tunnel is already active")
    }

    @MainActor
    func testStopTunnelWhenDisconnectedIsNoOp() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty  // -O exit (best effort, may fail)
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        XCTAssertEqual(controller.state, .disconnected)
        await controller.stopTunnel()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.lastError)
    }

    @MainActor
    func testStopTunnelCancelsReconnectAndResetsState() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,         // resolveOptions
            preCheckMiss,   // adopt preCheck: no live master
            masterReady,    // waitForMasterReady
            SSHResult(exitCode: 1, stdout: "", stderr: ""), // health check → disconnected
            gEmpty          // -O exit during stopTunnel
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        await controller.checkTunnelHealth()
        XCTAssertEqual(controller.state, .reconnecting)

        await controller.stopTunnel()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.lastError)
        XCTAssertNil(controller.nextReconnectAt)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state, .disconnected,
                       "Reconnect task must have been cancelled by stopTunnel")
    }
}
