import Foundation
import XCTest
@testable import SSHTunnelKit

final class SSHMasterClientTests: XCTestCase {
    func testCheckBuildsControlCommand() async {
        let runner = StubSSHRunner(results: [masterReady])
        let client = OpenSSHMasterClient(runner: runner)

        _ = await client.check(host: "test-host", controlPath: "~/.ssh/test-control", timeout: 2)

        XCTAssertEqual(runner.calls, [[
            "-S", "~/.ssh/test-control",
            "-O", "check",
            "test-host"
        ]])
    }

    func testExitBuildsControlCommand() async {
        let runner = StubSSHRunner(results: [gEmpty])
        let client = OpenSSHMasterClient(runner: runner)

        _ = await client.exit(host: "test-host", controlPath: "~/.ssh/test-control")

        XCTAssertEqual(runner.calls, [[
            "-S", "~/.ssh/test-control",
            "-O", "exit",
            "test-host"
        ]])
    }

    func testStartMasterBuildsHardenedForegroundMasterCommand() throws {
        let runner = StubSSHRunner(results: [])
        let client = OpenSSHMasterClient(runner: runner)

        _ = try client.startMaster(host: "test-host", controlPath: "~/.ssh/test-control")

        XCTAssertEqual(runner.longRunningCalls, [[
            "-N", "-M",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-S", "~/.ssh/test-control",
            "test-host"
        ]])
    }

    func testStartMasterWithClearConfigForwardsAddsClearAllForwardings() throws {
        let runner = StubSSHRunner(results: [])
        let client = OpenSSHMasterClient(runner: runner)

        _ = try client.startMaster(host: "test-host", controlPath: "~/.ssh/test-control", clearConfigForwards: true)

        XCTAssertEqual(runner.longRunningCalls, [[
            "-N", "-M",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "ClearAllForwardings=yes",
            "-S", "~/.ssh/test-control",
            "test-host"
        ]])
    }

    func testAddForwardWithRemoteHostBuildsNonLocalForwardSpec() async {
        let runner = StubSSHRunner(results: [gEmpty])
        let client = OpenSSHMasterClient(runner: runner)
        let target = SSHControlTarget.configured(hostAlias: "test-host")

        _ = await client.addForward(
            remotePort: 5432,
            localPort: 8080,
            remoteHost: "db.internal",
            target: target,
            controlPath: "/tmp/control.sock"
        )

        XCTAssertEqual(runner.calls, [[
            "-S", "/tmp/control.sock",
            "-O", "forward",
            "-L", "8080:db.internal:5432",
            "test-host"
        ]])
    }

    func testAddForwardBuildsControlCommandWithoutConfigForwards() async {
        let runner = StubSSHRunner(results: [gEmpty])
        let client = OpenSSHMasterClient(runner: runner)
        let target = SSHControlTarget(
            host: "resolved.example.com",
            user: "me",
            port: "2222",
            readsSSHConfig: false
        )

        _ = await client.addForward(
            remotePort: 8080,
            localPort: 9000,
            target: target,
            controlPath: "/tmp/control.sock"
        )

        XCTAssertEqual(runner.calls, [[
            "-S", "/tmp/control.sock",
            "-O", "forward",
            "-L", "9000:localhost:8080",
            "-F", "/dev/null",
            "-l", "me",
            "-p", "2222",
            "resolved.example.com"
        ]])
    }

    func testRemoveForwardBuildsControlCommandWithoutConfigForwards() async {
        let runner = StubSSHRunner(results: [gEmpty])
        let client = OpenSSHMasterClient(runner: runner)
        let target = SSHControlTarget(
            host: "resolved.example.com",
            user: "me",
            port: "2222",
            readsSSHConfig: false
        )

        _ = await client.removeForward(
            remotePort: 8080,
            localPort: 9000,
            target: target,
            controlPath: "/tmp/control.sock"
        )

        XCTAssertEqual(runner.calls, [[
            "-S", "/tmp/control.sock",
            "-O", "cancel",
            "-L", "9000:localhost:8080",
            "-F", "/dev/null",
            "-l", "me",
            "-p", "2222",
            "resolved.example.com"
        ]])
    }

    func testResolveOptionsDelegatesToSSHConfigInspector() async {
        let output = """
        hostname backend.example.com
        user me
        port 2222
        localforward 1443 backend:443
        controlpath ~/.ssh/user-control-%h
        """
        let runner = StubSSHRunner(results: [SSHResult(exitCode: 0, stdout: output, stderr: "")])
        let client = OpenSSHMasterClient(runner: runner)

        let options = await client.resolveOptions(forHost: "test-host")

        XCTAssertEqual(options?.hostname, "backend.example.com")
        XCTAssertEqual(options?.user, "me")
        XCTAssertEqual(options?.port, "2222")
        XCTAssertEqual(options?.forwardedPorts, [1443])
        XCTAssertEqual(options?.userControlPath, "~/.ssh/user-control-%h")
        XCTAssertEqual(runner.calls, [["-G", "test-host"]])
    }
}
