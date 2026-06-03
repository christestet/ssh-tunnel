import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelDiagnosticRunnerTests: XCTestCase {

    @MainActor
    func testEmptyRequiredFieldsFailBeforeShellingOut() async {
        let runner = StubSSHRunner(results: [])
        let doctor = TunnelDiagnosticRunner(
            sshRunner: runner,
            portChecker: StubPortChecker()
        )

        let report = await doctor.diagnose(TunnelSettings.makeDefault())

        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(item(in: report, "required-fields")?.status, .failed)
        XCTAssertTrue(item(in: report, "required-fields")?.detail.contains("Host Alias cannot be empty.") ?? false)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    @MainActor
    func testHealthySetupPassesAllChecks() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        var settings = makeTestSettings(controlPath: baseDir + "/control-%C")
        settings.name = "Prod DB"
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: sshGOutput(), stderr: "")])
        let checker = StubPortChecker()
        let doctor = TunnelDiagnosticRunner(sshRunner: runner, portChecker: checker)

        let report = await doctor.diagnose(settings)

        XCTAssertEqual(report.overallStatus, .ok)
        XCTAssertEqual(item(in: report, "ssh-config")?.status, .ok)
        XCTAssertEqual(item(in: report, "local-forwards")?.status, .ok)
        XCTAssertEqual(item(in: report, "local-forwards")?.title, "SSH config forwards")
        XCTAssertTrue(item(in: report, "local-forwards")?.detail.contains("Found localhost ports: 1443, 8080.") ?? false)
        XCTAssertEqual(item(in: report, "control-path")?.status, .ok)
        XCTAssertEqual(item(in: report, "port-availability")?.status, .ok)
        XCTAssertEqual(checker.queries, [[1443, 8080]])
    }

    @MainActor
    func testSSHConfigFailureSkipsDependentChecks() async {
        var settings = makeTestSettings(controlPath: "/tmp/control-%C")
        settings.name = "Broken"
        let runner = StubSSHRunner(results: [
            SSHResult(exitCode: 255, stdout: "", stderr: "bad configuration option")
        ])
        let checker = StubPortChecker()
        let doctor = TunnelDiagnosticRunner(sshRunner: runner, portChecker: checker)

        let report = await doctor.diagnose(settings)

        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(item(in: report, "ssh-config")?.status, .failed)
        XCTAssertEqual(item(in: report, "local-forwards")?.status, .skipped)
        XCTAssertEqual(item(in: report, "local-forwards")?.title, "SSH config forwards")
        XCTAssertEqual(item(in: report, "port-availability")?.detail, "Skipped because SSH config forwards are unknown.")
        XCTAssertTrue(checker.queries.isEmpty)
    }

    @MainActor
    func testControlPathCollisionFails() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        var settings = makeTestSettings(controlPath: baseDir + "/shared-%h")
        settings.name = "Collision"
        let output = sshGOutput(extra: "controlpath \(baseDir)/shared-%h")
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: output, stderr: "")])
        let doctor = TunnelDiagnosticRunner(
            sshRunner: runner,
            portChecker: StubPortChecker()
        )

        let report = await doctor.diagnose(settings)

        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(item(in: report, "control-path-collision")?.status, .failed)
        XCTAssertTrue(item(in: report, "control-path-collision")?.detail.contains("same file") ?? false)
    }

    @MainActor
    func testPortConflictFailsWithHolderDetail() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        var settings = makeTestSettings(controlPath: baseDir + "/control-%C")
        settings.name = "Ports"
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: sshGOutput(), stderr: "")])
        let checker = StubPortChecker()
        checker.conflictsByPort[8080] = PortConflict(port: 8080, pid: 42, command: "node")
        let doctor = TunnelDiagnosticRunner(sshRunner: runner, portChecker: checker)

        let report = await doctor.diagnose(settings)

        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(item(in: report, "port-availability")?.status, .failed)
        XCTAssertTrue(item(in: report, "port-availability")?.detail.contains("PID 42") ?? false)
    }

    @MainActor
    func testConnectedTunnelTreatsSSHPortHolderAsExpected() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        var settings = makeTestSettings(controlPath: baseDir + "/control-%C")
        settings.name = "Connected"
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: sshGOutput(), stderr: "")])
        let checker = StubPortChecker()
        checker.conflictsByPort[1443] = PortConflict(
            port: 1443,
            pid: 49091,
            command: "ssh",
            commandArgs: ["/usr/bin/ssh", "-N", "-M", "-S", settings.expandedControlPath, settings.hostAlias]
        )
        let doctor = TunnelDiagnosticRunner(sshRunner: runner, portChecker: checker)

        let report = await doctor.diagnose(settings, isTunnelConnected: true)

        XCTAssertEqual(report.overallStatus, .ok)
        XCTAssertEqual(item(in: report, "port-availability")?.status, .ok)
        XCTAssertTrue(item(in: report, "port-availability")?.detail.contains("connected tunnel") ?? false)
    }

    @MainActor
    func testConnectedTunnelDoesNotAcceptDifferentSSHPortHolder() async throws {
        let baseDir = NSTemporaryDirectory() + "ssh-tunnel-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: baseDir) }

        var settings = makeTestSettings(controlPath: baseDir + "/control-%C")
        settings.name = "Connected"
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: sshGOutput(), stderr: "")])
        let checker = StubPortChecker()
        checker.conflictsByPort[1443] = PortConflict(
            port: 1443,
            pid: 49091,
            command: "ssh",
            commandArgs: ["/usr/bin/ssh", "-N", "different-host"],
            openFiles: ["/tmp/different-control.sock"]
        )
        let doctor = TunnelDiagnosticRunner(sshRunner: runner, portChecker: checker)

        let report = await doctor.diagnose(settings, isTunnelConnected: true)

        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(item(in: report, "port-availability")?.status, .failed)
        XCTAssertTrue(item(in: report, "port-availability")?.detail.contains("PID 49091") ?? false)
    }

    private func item(in report: TunnelDiagnosticReport, _ id: String) -> TunnelDiagnosticItem? {
        report.items.first { $0.id == id }
    }

    private func sshGOutput(extra: String = "") -> String {
        """
        hostname resolved.example.com
        user me
        port 2222
        localforward 1443 backend:443
        localforward 8080 db:5432
        \(extra)
        """
    }
}
