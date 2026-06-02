import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerPortConflictTests: XCTestCase {

    @MainActor
    func testStartTunnelAbortsWhenForwardPortIsAlreadyBound() async throws {
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
        checker.conflicts[6333] = PortConflict(port: 6333, pid: 42, command: "qdrant")
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(runner.longRunningCalls.count, 0, "ssh master must NOT be spawned when port is busy")
        XCTAssertTrue(controller.lastError?.contains("6333") ?? false)
        XCTAssertTrue(controller.lastError?.contains("qdrant") ?? false)
        XCTAssertTrue(controller.lastError?.contains("42") ?? false, "PID should be surfaced")
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

        await controller.startTunnel()

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
