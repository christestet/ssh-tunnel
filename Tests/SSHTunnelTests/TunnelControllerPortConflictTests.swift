import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerPortConflictTests: XCTestCase {

    @MainActor
    func testCancellingConfigForwardConflictPromptFailsStart() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        user me
        port 22
        localforward 6333 backend:6333
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss
        ])
        let checker = StubPortChecker()
        checker.conflictsByPort[6333] = PortConflict(port: 6333, pid: 42, command: "qdrant")
        checker.freePorts = [7777]
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false
        )

        let task = Task { await controller.startTunnel() }
        let appeared = await waitUntil { controller.pendingPortConflict != nil }
        XCTAssertTrue(appeared, "a prompt must be raised for the busy config-forward port")
        XCTAssertEqual(controller.pendingPortConflict?.forward.localPort, 6333)
        XCTAssertEqual(controller.pendingPortConflict?.suggestedPort, 7777)
        XCTAssertEqual(controller.pendingPortConflict?.conflict.command, "qdrant")

        controller.resolvePortConflict(localPort: nil) // cancel
        await task.value

        XCTAssertEqual(controller.state, .failed)
        XCTAssertNil(controller.pendingPortConflict)
        XCTAssertEqual(runner.longRunningCalls.count, 0, "ssh master must NOT be spawned when the user cancels")
        XCTAssertTrue(controller.lastError?.contains("6333") ?? false)
        XCTAssertTrue(controller.lastError?.contains("qdrant") ?? false)
        XCTAssertTrue(controller.lastError?.contains("42") ?? false, "PID should be surfaced")
    }

    @MainActor
    func testAcceptingConfigForwardConflictPromptRemapsForwardAndConnects() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        localforward 6333 backend:5432
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss,
            masterReady,
            gEmpty // addForward (config forward on override port)
        ])
        let checker = StubPortChecker()
        checker.conflictsByPort[6333] = PortConflict(port: 6333, pid: 42, command: "qdrant")
        checker.freePorts = [7000]
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false
        )

        let task = Task { await controller.startTunnel() }
        _ = await waitUntil { controller.pendingPortConflict != nil }
        controller.resolvePortConflict(localPort: 7000) // accept the remap
        await task.value

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [7000],
                       "the effective (remapped) port must be surfaced, not the configured 6333")
        XCTAssertEqual(controller.activeConfigForwardOverrides[6333], 7000)

        // Master must be started with ClearAllForwardings so ssh binds nothing.
        XCTAssertTrue(runner.longRunningCalls.first?.contains("ClearAllForwardings=yes") ?? false)
        // The config forward is applied on the override port, to its remote host.
        XCTAssertTrue(runner.calls.contains { $0.contains("-L") && $0.contains("7000:backend:5432") },
                      "config forward must be re-applied on the override port to backend:5432")
    }

    @MainActor
    func testStartTunnelWaitsForShortLivedSshLeftoverToReleasePort() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        localforward 6333 backend:6333
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss,
            masterReady
        ])
        let checker = StubPortChecker()
        // First query: ssh leftover (no argv → not "ours") still on the port.
        // Grace-loop re-queries: port now free.
        checker.conflictResults = [
            PortConflict(port: 6333, pid: 42, command: "ssh"),
            nil
        ]
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false,
            portReleaseGrace: 0.05
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(checker.queries, [[6333], [6333]],
                       "Grace-wait must re-query the port once after the first conflict")
    }

    @MainActor
    func testStartTunnelProceedsWhenAllPortsFree() async throws {
        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        localforward 1443 backend:443
        localforward 8080 db:5432
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss,
            masterReady
        ])
        let checker = StubPortChecker()
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(checker.queries, [[1443, 8080]],
                       "Preflight must ask about exactly the discovered ports, in order")
    }

    @MainActor
    func testPortPreflightWithRealLoopbackListenerDetectsConflict() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }

        let settings = makeTestSettings()
        let gOutput = """
        hostname host
        localforward \(listener.port) backend:443
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            preCheckMiss
        ])
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: LocalPortAvailabilityChecker(),
            startsMonitoring: false
        )

        // The real listener occupies a config-forward port → prompt; cancel and
        // verify the conflict (incl. the busy port) is surfaced as a failure.
        let task = Task { await controller.startTunnel() }
        let appeared = await waitUntil { controller.pendingPortConflict != nil }
        XCTAssertTrue(appeared)
        XCTAssertEqual(controller.pendingPortConflict?.forward.localPort, listener.port)
        controller.resolvePortConflict(localPort: nil)
        await task.value

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("\(listener.port)") ?? false)
    }

    func testLsofOutputParserExtractsPidAndCommand() {
        let raw = "p12345\ncqdrant\np67890\ncnginx\n"
        let (pid, cmd) = LocalPortAvailabilityChecker.parseLsofOutput(raw)
        XCTAssertEqual(pid, 12345)
        XCTAssertEqual(cmd, "qdrant")
    }

    func testLsofOutputParserReturnsNilsForEmptyOutput() {
        let (pid, cmd) = LocalPortAvailabilityChecker.parseLsofOutput("")
        XCTAssertNil(pid)
        XCTAssertNil(cmd)
    }

    func testLsofOpenFileParserExtractsNames() {
        let raw = "p12345\nfcwd\nn/Users/me\nf12\nn/Users/me/.ssh/control-sshtunnelapp-abc\n"
        XCTAssertEqual(
            LocalPortAvailabilityChecker.parseOpenFileNames(raw),
            ["/Users/me", "/Users/me/.ssh/control-sshtunnelapp-abc"]
        )
    }
}
