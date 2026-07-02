import Foundation
import XCTest
@testable import SSHTunnelKit

/// Reconnect behaviour around network loss.
///
/// Two invariants keep a desired tunnel from requiring the "toggle off, wait,
/// toggle on" workaround:
/// 1. Transient network failures never permanently give up — the attempt cap
///    only applies to actionable errors (auth, config, spawn).
/// 2. While the network path is down, a pending reconnect is *parked* (no ssh
///    churn, no burned attempts) and resumed by NetworkMonitor once the path
///    returns.
final class TunnelControllerNetworkParkingTests: XCTestCase {

    private struct SpawnError: Error {}

    /// Controller whose start fails because the master cannot be spawned —
    /// a non-transient failure used to drive the reconnect scheduler.
    @MainActor
    private func makeFailingController(
        masterClient: StubSSHMasterClient = StubSSHMasterClient()
    ) -> (TunnelController, StubSSHMasterClient) {
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [preCheckMiss]
        masterClient.startMasterError = SpawnError()
        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        return (controller, masterClient)
    }

    // MARK: - Transient errors never give up permanently

    @MainActor
    func testTransientNetworkErrorKeepsReconnectingBeyondAttemptCap() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss])
        runner.longRunningFactory = { _ in
            let h = FakeLongRunning()
            h.stderr = "connect to host example.com port 22: Operation timed out\n"
            h.terminate()
            return h
        }
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()

        XCTAssertEqual(
            controller.state, .reconnecting,
            "a transient network failure must keep retrying instead of parking in .failed"
        )
        XCTAssertFalse(controller.lastError?.contains("gave up") ?? false)
    }

    @MainActor
    func testNonTransientErrorStillGivesUpAfterAttemptCap() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty, preCheckMiss])
        runner.longRunningFactory = { _ in
            let h = FakeLongRunning()
            h.stderr = "Permission denied (publickey).\n"
            h.terminate()
            return h
        }
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("gave up") ?? false)
    }

    // MARK: - Parking while the network is down

    @MainActor
    func testStartFailureWhileNetworkUnavailableParksReconnect() async throws {
        let (controller, _) = makeFailingController()
        controller.setNetworkAvailable(false)

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(controller.isReconnectParkedForNetwork)
        XCTAssertNil(
            controller.nextReconnectAt,
            "a parked reconnect must not run a countdown — there is no network to retry on"
        )
    }

    @MainActor
    func testNetworkLossParksPendingReconnectAndCancelsCountdown() async throws {
        let (controller, _) = makeFailingController()

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertNotNil(controller.nextReconnectAt)
        XCTAssertFalse(controller.isReconnectParkedForNetwork)

        controller.setNetworkAvailable(false)

        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(controller.isReconnectParkedForNetwork)
        XCTAssertNil(controller.nextReconnectAt)
    }

    @MainActor
    func testResumeAfterNetworkRestoredReconnectsParkedTunnel() async throws {
        let (controller, masterClient) = makeFailingController()
        controller.setNetworkAvailable(false)
        await controller.startTunnel()
        XCTAssertTrue(controller.isReconnectParkedForNetwork)

        // Network comes back and the master can now be spawned.
        masterClient.startMasterError = nil
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [preCheckMiss, masterReady]
        controller.setNetworkAvailable(true)

        await controller.resumeAfterNetworkRestored()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(controller.isReconnectParkedForNetwork)
    }

    @MainActor
    func testUserStopClearsParkedReconnect() async throws {
        let (controller, _) = makeFailingController()
        controller.setNetworkAvailable(false)
        await controller.startTunnel()
        XCTAssertTrue(controller.isReconnectParkedForNetwork)

        await controller.stopTunnel()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertFalse(controller.isReconnectParkedForNetwork)
        XCTAssertFalse(controller.wantsToBeConnected)
    }

    @MainActor
    func testNetworkLossLeavesConnectedTunnelUntouched() async throws {
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        // A connected master may well survive a brief path flap — parking only
        // applies to a *pending* reconnect.
        controller.setNetworkAvailable(false)

        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(controller.isReconnectParkedForNetwork)
    }
}
