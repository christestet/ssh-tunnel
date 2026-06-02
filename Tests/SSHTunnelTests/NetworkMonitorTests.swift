import Foundation
import Synchronization
import XCTest
@testable import SSHTunnelKit

final class NetworkMonitorTests: XCTestCase {

    // MARK: - Network path change triggers immediate health check

    @MainActor
    func testNetworkBecomesSatisfiedTriggersHealthCheckOnActiveTunnels() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,       // resolveOptions
            masterReady,  // waitForMasterReady
            // After network change: health check (-O check) succeeds
            SSHResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        // Simulate: network goes down, then comes back up
        monitor.handlePathUpdate(satisfied: false)
        monitor.handlePathUpdate(satisfied: true)

        // Give the async health check a moment to run
        try await Task.sleep(nanoseconds: 50_000_000)

        // The controller should still be connected (health check passed)
        XCTAssertEqual(controller.state, .connected)
        // Verify health check was actually triggered (the -O check call)
        XCTAssertTrue(runner.calls.contains { $0.contains("-O") && $0.contains("check") })
    }

    @MainActor
    func testNetworkBecomesSatisfiedReconnectsDeadTunnel() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,       // resolveOptions for initial start
            masterReady,  // waitForMasterReady for initial start
            // After network change: health check (-O check) FAILS → tunnel is dead
            SSHResult(exitCode: 1, stdout: "", stderr: "control socket missing"),
        ])
        let notifier = SpyTunnelNotifier()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: notifier,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: runner,
            notifier: notifier,
            controllers: [controller]
        )

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        // Simulate: network goes down, then restored
        monitor.handlePathUpdate(satisfied: false)
        monitor.handlePathUpdate(satisfied: true)

        try await Task.sleep(nanoseconds: 50_000_000)

        // The health check detected a dead tunnel → should be reconnecting
        XCTAssertEqual(controller.state, .reconnecting)
    }

    @MainActor
    func testNetworkBecomesSatisfiedStartsAutostartTunnelAfterPreparation() async throws {
        var settings = makeTestSettings()
        settings.autostartOnLogin = true
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [preCheckMiss, masterReady]
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
            controllers: [controller]
        )
        await manager.start()

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)
        monitor.handlePathUpdate(satisfied: true)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(masterClient.startCalls.count, 1)
    }

    @MainActor
    func testAutostartWaitsForConfiguredReadinessHostBeforeStarting() async throws {
        var settings = makeTestSettings()
        settings.autostartOnLogin = true
        settings.autostartReadinessProbeHost = "vpn-gateway.internal"
        settings.autostartReadinessProbePort = 443
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [preCheckMiss, masterReady]
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.prepareForAutostart()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )
        let readiness = FakeReadinessChecker(isReachable: false)
        let monitor = NetworkMonitor(
            tunnelManager: manager,
            pathSource: FakePathSource(),
            settleDelay: 0,
            readinessChecker: readiness,
            readinessRetryDelay: 0.05,
            readinessProbeTimeout: 0.01
        )

        monitor.handlePathUpdate(satisfied: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(masterClient.startCalls.isEmpty)
        XCTAssertEqual(readiness.probes.first, .init(host: "vpn-gateway.internal", port: 443, timeout: 0.01))

        readiness.setReachable(true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(masterClient.startCalls.count, 1)
        XCTAssertGreaterThanOrEqual(readiness.probes.count, 2)
    }

    @MainActor
    func testNetworkDropCancelsPendingReadinessRetry() async throws {
        var settings = makeTestSettings()
        settings.autostartOnLogin = true
        settings.autostartReadinessProbeHost = "vpn-gateway.internal"
        settings.autostartReadinessProbePort = 443
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.prepareForAutostart()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )
        let readiness = FakeReadinessChecker(isReachable: false)
        let monitor = NetworkMonitor(
            tunnelManager: manager,
            pathSource: FakePathSource(),
            settleDelay: 0,
            readinessChecker: readiness,
            readinessRetryDelay: 0.05,
            readinessProbeTimeout: 0.01
        )

        monitor.handlePathUpdate(satisfied: true)
        await waitUntil { !readiness.probes.isEmpty }
        monitor.handlePathUpdate(satisfied: false)
        readiness.setReachable(true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(masterClient.startCalls.isEmpty)
    }

    @MainActor
    func testSettleDelayPreventsStartIfNetworkDropsBeforeRecoveryRuns() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.prepareForAutostart()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )
        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0.05)

        monitor.handlePathUpdate(satisfied: true)
        monitor.handlePathUpdate(satisfied: false)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(masterClient.startCalls.isEmpty)
    }

    @MainActor
    func testNetworkUnsatisfiedDoesNotTriggerHealthCheck() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,
            masterReady,
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        let callCountBefore = runner.calls.count

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        // Network goes DOWN — no point running health checks
        monitor.handlePathUpdate(satisfied: false)

        try await Task.sleep(nanoseconds: 50_000_000)

        // No additional SSH calls should have been made
        XCTAssertEqual(runner.calls.count, callCountBefore)
    }

    @MainActor
    func testNetworkChangeIgnoresDisconnectedTunnels() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [gEmpty])
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        // Controller stays disconnected (never started)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertFalse(controller.wantsToBeConnected)

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        // Simulate network down then up — shouldn't trigger anything for
        // a tunnel the user never asked to be active.
        monitor.handlePathUpdate(satisfied: false)
        monitor.handlePathUpdate(satisfied: true)

        try await Task.sleep(nanoseconds: 100_000_000)

        // No startMaster call should have happened — recovery must only
        // touch tunnels with `wantsToBeConnected == true`.
        XCTAssertTrue(masterClient.startCalls.isEmpty)
        XCTAssertEqual(controller.state, .disconnected)
    }

    // MARK: - System wake triggers immediate health check

    @MainActor
    func testSystemWakeTriggersHealthCheckOnActiveTunnels() async throws {
        let settings = makeTestSettings()
        let runner = StubSSHRunner(results: [
            gEmpty,
            masterReady,
            // Health check after network satisfaction succeeds
            SSHResult(exitCode: 0, stdout: "", stderr: ""),
            // Health check after wake succeeds
            SSHResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .connected)

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )

        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        monitor.handlePathUpdate(satisfied: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate: system woke from sleep
        monitor.handleSystemWake()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .connected)
        XCTAssertTrue(runner.calls.contains { $0.contains("-O") && $0.contains("check") })
    }

    @MainActor
    func testSystemWakeDoesNotStartDesiredTunnelWhenNetworkIsUnsatisfied() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        let controller = TunnelController(
            settings: settings,
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        controller.prepareForAutostart()
        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )
        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)

        monitor.handleSystemWake()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(masterClient.startCalls.isEmpty)
    }

    // MARK: - Failed tunnels are recovered on network/wake events

    @MainActor
    func testNetworkRecoveryRestartsFailedTunnelThatWantsToBeConnected() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [SSHResult(exitCode: 1, stdout: "", stderr: "no master")]
        struct SpawnError: Error {}
        masterClient.startMasterError = SpawnError()

        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.wantsToBeConnected)

        // Prime the master client for the recovery start.
        masterClient.startMasterError = nil
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [
            SSHResult(exitCode: 1, stdout: "", stderr: "no master"), // pre-check miss
            SSHResult(exitCode: 0, stdout: "", stderr: "")            // waitForMasterReady success
        ]

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )

        let pathSource = FakePathSource()
        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: pathSource, settleDelay: 0)
        _ = monitor

        pathSource.emit(satisfied: false)
        pathSource.emit(satisfied: true)

        // Allow the recovery Task to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .connected)
    }

    @MainActor
    func testSystemWakeRecoversFailedTunnel() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [SSHResult(exitCode: 1, stdout: "", stderr: "no master")]
        struct SpawnError: Error {}
        masterClient.startMasterError = SpawnError()

        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false,
            maxReconnectAttempts: 0
        )

        await controller.startTunnel()
        XCTAssertEqual(controller.state, .failed)

        masterClient.startMasterError = nil
        masterClient.resolvedOptions = [nil]
        masterClient.checkResults = [
            SSHResult(exitCode: 1, stdout: "", stderr: "no master"),
            SSHResult(exitCode: 0, stdout: "", stderr: ""),
            SSHResult(exitCode: 0, stdout: "", stderr: "")
        ]

        let manager = TunnelManager(
            settingsStore: TunnelSettingsStore(tunnels: [settings]),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            controllers: [controller]
        )
        let monitor = NetworkMonitor(tunnelManager: manager, pathSource: FakePathSource(), settleDelay: 0)
        monitor.handlePathUpdate(satisfied: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        monitor.handleSystemWake()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state, .connected)
    }
}

// MARK: - Test doubles for NetworkMonitor

final class FakePathSource: NetworkPathSource, @unchecked Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        var c: AsyncStream<Bool>.Continuation!
        self.stream = AsyncStream<Bool> { c = $0 }
        self.continuation = c
    }

    func paths() -> AsyncStream<Bool> { stream }

    func emit(satisfied: Bool) {
        continuation.yield(satisfied)
    }
}

private func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

final class FakeReadinessChecker: NetworkReadinessChecking, @unchecked Sendable {
    struct Probe: Equatable {
        let host: String
        let port: Int
        let timeout: TimeInterval
    }

    private struct State {
        var reachable: Bool
        var probes: [Probe] = []
    }

    private let state: Mutex<State>

    init(isReachable: Bool) {
        self.state = Mutex(State(reachable: isReachable))
    }

    var probes: [Probe] {
        state.withLock { $0.probes }
    }

    func setReachable(_ isReachable: Bool) {
        state.withLock { state in
            state.reachable = isReachable
        }
    }

    func canReach(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        state.withLock { state in
            state.probes.append(Probe(host: host, port: port, timeout: timeout))
            return state.reachable
        }
    }
}
