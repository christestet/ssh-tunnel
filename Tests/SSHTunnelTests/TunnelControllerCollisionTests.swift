import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerCollisionTests: XCTestCase {

    // MARK: - Stale control socket cleanup

    @MainActor
    func testLiveMasterIsAdoptedOnStartWithoutEviction() async throws {
        // App-restart scenario: a previous app run left an ssh master alive at
        // our control path. New startTunnel must adopt that master, not snipe
        // it. No -O exit, no respawn, socket stays put.
        let tmpPath = NSTemporaryDirectory() + "ssh-tunnel-test-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: tmpPath, contents: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        let settings = makeTestSettings(controlPath: tmpPath)
        let runner = StubSSHRunner(results: [
            gEmpty,                                    // resolveOptions
            SSHResult(exitCode: 0, stdout: "", stderr: "") // adopt preCheck: LIVE master
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(runner.longRunningCalls.count, 0,
                       "Adoption path must not spawn a new master")
        let exitCalls = runner.calls.filter { $0.contains("exit") }
        XCTAssertEqual(exitCalls.count, 0,
                       "Adoption path must not send -O exit (would kill the running tunnel)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpPath),
                      "Socket file of the adopted master must be left alone")
    }

    @MainActor
    func testStaleSocketWithoutLiveMasterIsStillRemoved() async throws {
        let tmpPath = NSTemporaryDirectory() + "ssh-tunnel-test-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: tmpPath, contents: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        let settings = makeTestSettings(controlPath: tmpPath)
        let runner = StubSSHRunner(results: [
            gEmpty,                                          // resolveOptions
            SSHResult(exitCode: 1, stdout: "", stderr: ""),  // adopt preCheck: no live master
            masterReady                                      // new master comes up
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        let exitCalls = runner.calls.filter { $0.contains("exit") }
        XCTAssertEqual(exitCalls.count, 0, "If no live master is present, we must not issue -O exit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath),
                       "Stale socket file must be removed even when no live master is present")
    }

    @MainActor
    func testStaleSocketCleanupHonoursPercentHTokenExpansion() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-token-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: baseDir)
        }

        let template = baseDir + "/control-%h"
        let expandedTarget = baseDir + "/control-resolved.example.com"
        FileManager.default.createFile(atPath: expandedTarget, contents: nil)

        var settings = makeTestSettings()
        settings.controlPath = template

        let gOutput = """
        hostname resolved.example.com
        user me
        port 22
        """

        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: ""), // resolveOptions
            SSHResult(exitCode: 1, stdout: "", stderr: ""),       // adopt preCheck (no live master)
            masterReady
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expandedTarget),
                       "The expanded path's file must have been removed")
        XCTAssertEqual(controller.filesystemControlPath, expandedTarget)
    }

    // MARK: - Collision detection with user's ssh_config ControlPath

    @MainActor
    func testCollisionWithUserControlPathAbortsStart() async throws {
        let collidingPath = NSTemporaryDirectory() + "ssh-tunnel-coll-\(UUID().uuidString).sock"
        let settings = makeTestSettings(controlPath: collidingPath)

        let gOutput = """
        hostname remote.example.com
        user me
        port 22
        controlpath \(collidingPath)
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: "")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("collision") ?? false,
                      "lastError should mention the collision")
        XCTAssertEqual(runner.longRunningCalls.count, 0,
                       "Must not spawn ssh master when colliding with user config")
        XCTAssertEqual(runner.calls.filter { $0.contains("exit") }.count, 0,
                       "Must not issue -O exit when colliding (would kill the user's terminal session)")
    }

    @MainActor
    func testCollisionDetectedAfterPercentExpansion() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-coll-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        let toolPath = baseDir + "/control-resolved.example.com"
        var settings = makeTestSettings()
        settings.controlPath = toolPath

        let gOutput = """
        hostname resolved.example.com
        user me
        port 22
        controlpath \(baseDir)/control-%h
        """
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 0, stdout: gOutput, stderr: "")
        ])
        let controller = TunnelController(
            settings: settings, sshRunner: runner, notifier: SpyTunnelNotifier(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.startTunnel()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.lastError?.contains("collision") ?? false)
    }

    @MainActor
    func testNoCollisionWhenPathsDiffer() async throws {
        var settings = makeTestSettings()
        settings.controlPath = "~/.ssh/control-sshtunnelapp-%C"

        let gOutput = """
        hostname resolved.example.com
        user me
        port 22
        controlpath ~/.ssh/control-%h
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

        XCTAssertEqual(controller.state, .connected)
    }
}
