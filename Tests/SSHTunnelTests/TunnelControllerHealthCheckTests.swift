import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerHealthCheckTests: XCTestCase {

    // MARK: - Health check & notifications

    @MainActor
    func testUnexpectedDisconnectSendsNotificationAndReconnects() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,         // resolveOptions (ssh -G)
            preCheckMiss,   // adopt preCheck: no live master
            masterReady,    // waitForMasterReady (-O check)
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing") // health check
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        await controller.checkTunnelHealth()

        XCTAssertTrue(notifier.didRequestAuthorization)
        XCTAssertEqual(notifier.interruptedHosts, ["test-host"])
        XCTAssertEqual(controller.state, .reconnecting)
    }

    @MainActor
    func testTransientHealthCheckFailureReconnectsWithoutInterruptedNotification() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,
            preCheckMiss,
            masterReady,
            SSHResult(exitCode: 1, stdout: "", stderr: "ssh: connect to host example port 22: No route to host")
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        await controller.checkTunnelHealth()

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
        XCTAssertTrue(notifier.failedResults.isEmpty)
    }

    @MainActor
    func testCheckNowOnBrokenTunnelSendsFailureNotification() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing")
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.checkNow()

        XCTAssertEqual(notifier.checkResults.count, 1)
        XCTAssertEqual(notifier.checkResults.first?.host, "test-host")
        XCTAssertEqual(notifier.checkResults.first?.ok, false)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty,
                      "Explicit Check Now must NOT send the monitoring-style 'interrupted' notification")
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testCheckNowReportsTransientNetworkError() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "nodename nor servname provided, or not known")
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.checkNow()

        let result = try XCTUnwrap(notifier.checkResults.first)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.localizedCaseInsensitiveContains("nodename nor servname"))
        XCTAssertTrue(notifier.failedResults.isEmpty)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
    }

    @MainActor
    func testHealthCheckDoesNotStartNeverActivatedTunnel() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        XCTAssertEqual(controller.state, .disconnected)
        await controller.checkTunnelHealth()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(runner.longRunningCalls.count, 0)
    }

    @MainActor
    func testCheckNowOnHealthyTunnelSendsOkNotification() async throws {
        let gOutput = """
        hostname host
        user me
        port 22
        localforward 1443 backend:443
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss,
            masterReady,
            SSHResult(exitCode: 0, stdout: "", stderr: "") // -O check during checkNow
        ])
        let healthChecker = StubForwardHealthChecker()
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: runner,
            notifier: notifier,
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        await controller.checkNow()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(notifier.checkResults.count, 1)
        let result = try XCTUnwrap(notifier.checkResults.first)
        XCTAssertEqual(result.host, "test-host")
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.detail.contains("1443"),
                      "OK notification must mention the forwarded port(s)")
        XCTAssertEqual(healthChecker.checks.map(\.0), [[1443]])
    }

    @MainActor
    func testCheckNowOnHealthyTunnelWithoutPortsReportsNoForwardedPorts() async throws {
        let runner = StubSSHRunner(results: [
            gEmpty,
            preCheckMiss,
            masterReady,
            SSHResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: runner,
            notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        await controller.checkNow()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(notifier.checkResults.first?.detail, "No forwarded ports configured.")
    }

    @MainActor
    func testHealthCheckDetectsUnreachableForwardPort() async throws {
        let settings = makeTestSettings()
        let gWithBadPort = "localforward 1 nowhere:80\n"
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gWithBadPort, stderr: ""), // resolveOptions
            preCheckMiss,
            masterReady,
            SSHResult(exitCode: 0, stdout: "", stderr: "") // -O check during healthcheck
        ])
        let healthChecker = StubForwardHealthChecker()
        healthChecker.unreachablePorts = [1]
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [1])

        await controller.checkTunnelHealth()

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertNotNil(controller.lastError)
        XCTAssertTrue(controller.lastError?.contains("port 1") ?? false)
        XCTAssertEqual(notifier.interruptedHosts, ["test-host"])
    }

    @MainActor
    func testReconnectScheduledFromFailedState() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,
            preCheckMiss,
            SSHResult(exitCode: 1, stdout: "", stderr: "")
        ])
        struct SpawnError: Error {}
        runner.startLongRunningError = SpawnError()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 5
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .reconnecting)
    }

    @MainActor
    func testReconnectCountdownIsScheduledAndFormatted() async throws {
        var settings = makeTestSettings()
        settings.maxBackoff = 60
        let runner = StubSSHRunner(results: [
            gEmpty,
            preCheckMiss,
            SSHResult(exitCode: 1, stdout: "", stderr: "")
        ])
        struct SpawnError: Error {}
        runner.startLongRunningError = SpawnError()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 5
        )

        await controller.startTunnel()

        let retryAt = try XCTUnwrap(controller.nextReconnectAt)
        XCTAssertEqual(controller.reconnectCountdownDescription(now: retryAt.addingTimeInterval(-17)), "Retry in 17s")
        XCTAssertEqual(controller.reconnectCountdownDescription(now: retryAt.addingTimeInterval(1)), "Retry in 0s")
    }

    // MARK: - Reconnect cap

    @MainActor
    func testReconnectGivesUpAfterCap() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,
            preCheckMiss,
            SSHResult(exitCode: 1, stdout: "", stderr: "")
        ])
        struct SpawnError: Error {}
        runner.startLongRunningError = SpawnError()
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 1
        )

        await controller.startTunnel()
        // First attempt failed, reconnectAttempt=0 < 1, so state is now .reconnecting
        XCTAssertEqual(controller.state, .reconnecting)

        // Force another failure by pretending a health check failed from a "connected" state
        // (which bypasses the 'already reconnecting' guard)
        controller.state = .connected
        await controller.checkTunnelHealth()

        // Now reconnectAttempt=1 >= 1, so it should land in .failed
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("gave up") ?? false)
    }

    // MARK: - watchMaster process exit

    @MainActor
    func testWatchMasterTriggersReconnectOnUnexpectedExit() async throws {
        let settings = makeTestSettings()
        let fakeMaster = FakeLongRunning()
        let runner = StubSSHRunner(results: [
            gEmpty,        // resolveOptions (ssh -G)
            preCheckMiss,  // adopt preCheck: no live master
            masterReady    // waitForMasterReady (-O check)
        ])
        runner.longRunningFactory = { _ in fakeMaster }
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        fakeMaster.simulateUnexpectedExit(code: 255, stderr: "ssh master exited unexpectedly\n")
        await waitUntil { controller.state == .reconnecting }

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertEqual(controller.lastError, "ssh master exited unexpectedly")
        XCTAssertNotNil(controller.resolvedOptions, "resolvedOptions are kept for UI stability")
        XCTAssertEqual(notifier.interruptedHosts, ["test-host"])
    }

    @MainActor
    func testTransientMasterExitReconnectsWithoutInterruptedNotification() async throws {
        let settings = makeTestSettings()
        let fakeMaster = FakeLongRunning()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss, masterReady])
        runner.longRunningFactory = { _ in fakeMaster }
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        fakeMaster.simulateUnexpectedExit(code: 255, stderr: "No route to host\n")
        await waitUntil { controller.state == .reconnecting }

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
        XCTAssertTrue(notifier.failedResults.isEmpty)
    }

    @MainActor
    func testWatchMasterWithEmptyStderrUsesGenericMessage() async throws {
        let settings = makeTestSettings()
        let fakeMaster = FakeLongRunning()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss, masterReady])
        runner.longRunningFactory = { _ in fakeMaster }
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        fakeMaster.simulateUnexpectedExit(code: 1, stderr: "")
        await waitUntil { controller.lastError != nil }

        XCTAssertEqual(controller.lastError, "ssh master exited (code 1)")
    }

    @MainActor
    func testWatchMasterIgnoresExitWhenUserStoppedTunnel() async throws {
        let settings = makeTestSettings()
        let fakeMaster = FakeLongRunning()
        let runner = StubSSHRunner(results: [
            gEmpty,        // resolveOptions
            preCheckMiss,  // adopt preCheck: no live master
            masterReady,   // waitForMasterReady
            gEmpty         // -O exit during stopTunnel
        ])
        runner.longRunningFactory = { _ in fakeMaster }
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        await controller.stopTunnel()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(notifier.interruptedHosts.isEmpty)
    }

    // MARK: - refreshState races

    @MainActor
    func testRefreshStateResolvesOptionsWhenNilAndMasterIsAlive() async throws {
        let gOutput = """
        hostname backend.example.com
        user me
        port 22
        localforward 1443 backend:443
        localforward 8080 db:5432
        """
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: "", stderr: ""),  // -O check → master alive
            SSHResult(exitCode: 0, stdout: gOutput, stderr: "") // ssh -G to resolve options
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        XCTAssertNil(controller.resolvedOptions)
        await controller.refreshState()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [1443, 8080])
    }

    @MainActor
    func testRefreshStateDoesNotReResolveWhenOptionsAlreadyPresent() async throws {
        let gOutput = """
        hostname h
        user u
        port 22
        localforward 9999 backend:9999
        """
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),  // resolveOptions during startTunnel
            preCheckMiss,                                          // adopt preCheck: no live master
            masterReady,                                           // waitForMasterReady
            SSHResult(exitCode: 0, stdout: "", stderr: ""),       // -O check during refreshState
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.forwardedPorts, [9999])
        let callCountAfterStart = runner.calls.count

        await controller.refreshState()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [9999], "Existing options must not be overwritten")
        XCTAssertEqual(runner.calls.count, callCountAfterStart + 1)
        XCTAssertTrue(runner.calls.last?.contains("check") ?? false)
    }

    @MainActor
    func testRefreshStateDoesNotResolveWhenMasterIsDead() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.refreshState()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.resolvedOptions)
        XCTAssertEqual(runner.calls.count, 1, "Only the -O check call, no ssh -G")
    }

    @MainActor
    func testRefreshStateDoesNotOverrideConnectingState() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "no socket")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.state = .connecting

        await controller.refreshState()

        XCTAssertEqual(controller.state, .connecting,
                       "refreshState must not overwrite .connecting with .disconnected")
    }

    @MainActor
    func testRefreshStateDoesNotOverrideReconnectingState() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 1, stdout: "", stderr: "no socket")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.state = .reconnecting

        await controller.refreshState()

        XCTAssertEqual(controller.state, .reconnecting,
                       "refreshState must not overwrite .reconnecting with .disconnected")
    }
}
