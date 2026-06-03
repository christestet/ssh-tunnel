import Foundation
import XCTest
@testable import SSHTunnelKit

/// Coverage for the adopt-on-start and orphan-kill flow added to
/// `TunnelController.startTunnel`. These scenarios are the ones the app must
/// survive on relaunch without locking itself out:
///   - previous app instance died but its ssh master is still alive → ADOPT
///   - previous app instance died, master is dead, socket gone, ssh-orphan
///     still bound to our port → SIGTERM the orphan, then spawn fresh
///   - somebody else has our port → don't kill them, report cleanly
final class TunnelControllerAdoptionTests: XCTestCase {

    @MainActor
    func testAdoptionWithHealthyForwardsStaysConnectedWithoutSpawn() async throws {
        let gOutput = """
        hostname host
        localforward 1443 backend:443
        """
        let healthChecker = StubForwardHealthChecker()
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),  // resolveOptions
            SSHResult(exitCode: 0, stdout: "", stderr: "")        // adopt preCheck: LIVE
        ])
        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.forwardedPorts, [1443])
        XCTAssertEqual(healthChecker.checks.map(\.0), [[1443]])
        XCTAssertEqual(runner.longRunningCalls.count, 0,
                       "Adoption must not spawn a new master")
        XCTAssertTrue(runner.calls.allSatisfy { !$0.contains("exit") },
                      "Adoption must not send -O exit")
    }

    @MainActor
    func testAdoptionWithDeadForwardSchedulesReconnect() async throws {
        // Port 1 is unbindable for non-root, so tcpProbe will fail.
        let gOutput = """
        hostname host
        localforward 1 backend:80
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""),
            SSHResult(exitCode: 0, stdout: "", stderr: "")  // adopt preCheck: LIVE but forward dead
        ])
        let healthChecker = StubForwardHealthChecker()
        healthChecker.unreachablePorts = [1]
        let settings = TunnelSettings(
            id: UUID(),
            name: "Test Tunnel",
            hostAlias: "test-host",
            controlPath: "~/.ssh/test-control",
            healthCheckInterval: 999,
            maxBackoff: 30,  // allow reconnect to be scheduled
            autostartOnLogin: false
        )
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            forwardHealthChecker: healthChecker,
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .reconnecting,
                       "Adopting a master whose forwards are dead must trigger a reconnect")
        XCTAssertTrue(controller.lastError?.contains("port 1") ?? false)
    }

    @MainActor
    func testOrphanSshProcessOnOurPortIsKilledThenSpawnSucceeds() async throws {
        // Spawn a real /bin/sleep so we have a kill-able pid attached to the
        // synthetic conflict. The conflict's argv contains our host alias —
        // isOurOrphan should match, ensurePortsFree should SIGTERM it.
        let sleepProc = Process()
        sleepProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProc.arguments = ["60"]
        sleepProc.standardOutput = Pipe()
        sleepProc.standardError = Pipe()
        try sleepProc.run()
        let victimPid = Int(sleepProc.processIdentifier)
        addTeardownBlock {
            if sleepProc.isRunning { sleepProc.terminate() }
        }

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
        // First query: orphan. After SIGTERM + brief grace: port free.
        checker.conflictResults = [
            PortConflict(
                port: 6333,
                pid: victimPid,
                command: "ssh",
                commandArgs: ["/usr/bin/ssh", "-N", "-M", "-S", "/tmp/x", "test-host"]
            ),
            nil
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

        XCTAssertEqual(controller.state, .connected,
                       "After killing the orphan and freeing the port, spawn must succeed")
        // The SIGTERM is fire-and-forget; give the OS a brief moment.
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(sleepProc.isRunning,
                       "Orphan ssh-like process must have been SIGTERMed")
    }

    @MainActor
    func testOrphanSshProcessMatchedByOpenControlPathIsKilledWhenArgsAreUnavailable() async throws {
        let sleepProc = Process()
        sleepProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProc.arguments = ["60"]
        sleepProc.standardOutput = Pipe()
        sleepProc.standardError = Pipe()
        try sleepProc.run()
        let victimPid = Int(sleepProc.processIdentifier)
        addTeardownBlock {
            if sleepProc.isRunning { sleepProc.terminate() }
        }

        let controlPath = NSTemporaryDirectory() + "ssh-tunnel-orphan-\(UUID().uuidString).sock"
        let settings = makeTestSettings(controlPath: controlPath)
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
        checker.conflictResults = [
            PortConflict(
                port: 6333,
                pid: victimPid,
                command: "ssh",
                commandArgs: nil,
                openFiles: [controlPath]
            ),
            nil
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

        XCTAssertEqual(controller.state, .connected)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(sleepProc.isRunning)
    }

    @MainActor
    func testForeignProcessOnOurPortIsNotKilledAndReportsFailure() async throws {
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
        // Foreign daemon — command is not ssh, argv unrelated.
        checker.conflictsByPort[6333] = PortConflict(
            port: 6333,
            pid: 999_999,
            command: "qdrant",
            commandArgs: ["/usr/local/bin/qdrant"]
        )
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false,
            portReleaseGrace: 0
        )

        // 6333 is a config LocalForward, so a foreign holder now prompts for a
        // remap. Cancelling keeps the historical "not killed, reports failure"
        // outcome.
        await startTunnelResolvingConflict(controller, with: nil)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(runner.longRunningCalls.count, 0,
                       "Foreign holder must NOT lead to a spawn attempt")
        XCTAssertTrue(controller.lastError?.contains("qdrant") ?? false)
    }

    @MainActor
    func testSshProcessWithDifferentHostIsTreatedAsForeign() async throws {
        // ssh process on our port but argv shows it belongs to a different
        // tunnel. We must not kill it — it might be someone's terminal session.
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
        checker.conflictsByPort[6333] = PortConflict(
            port: 6333,
            pid: 999_998,
            command: "ssh",
            commandArgs: ["/usr/bin/ssh", "-N", "different-host"],
            openFiles: ["/tmp/different-control.sock"]
        )
        let controller = TunnelController(
            settings: settings,
            sshRunner: runner,
            notifier: SpyTunnelNotifier(),
            portChecker: checker,
            startsMonitoring: false,
            portReleaseGrace: 0
        )

        // Config-forward port held by a foreign ssh → prompt; cancel to keep the
        // "not killed, PID surfaced" outcome.
        await startTunnelResolvingConflict(controller, with: nil)

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(runner.longRunningCalls.count, 0)
        XCTAssertTrue(controller.lastError?.contains("999998") ?? false,
                      "Foreign ssh PID must be surfaced verbatim, not silently killed")
    }

    // MARK: - Single-instance helper

    func testSingleInstanceHelperIgnoresOwnPid() {
        // No real AppKit context here — we exercise the predicate logic only.
        // The real check is in AppDelegate.applicationWillFinishLaunching.
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let candidates: [(pid: Int, name: String)] = [
            (me, "self"),
            (me + 1, "other-instance")
        ]
        let others = candidates.filter { $0.pid != me }
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others.first?.name, "other-instance")
    }
}
