import Foundation
import XCTest
@testable import SSHTunnelKit

final class SSHConfigInspectorTests: XCTestCase {

    func testParsesAllForms() {
        let output = """
        user me
        localforward 1443 host:443
        localforward 127.0.0.1:8080 db:5432
        LocalForward [::1]:9090 srv:80
        localforward 1443 dup:1
        localforward bogus notaport
        """
        let infos = SSHConfigInspector.parseLocalForwardPorts(from: output)
        XCTAssertEqual(infos, [
            ForwardInfo(localPort: 1443, remotePort: 443),
            ForwardInfo(localPort: 8080, remotePort: 5432),
            ForwardInfo(localPort: 9090, remotePort: 80)
        ])
    }

    func testParsesTCPPortsAndIgnoresUnixSocketForwards() {
        let output = """
        localforward 1443 host:443
        localforward 127.0.0.1:8080 db:5432
        localforward *:9090 metrics:9090
        localforward [::1]:7000 api:7000
        localforward /tmp/app.sock service:80
        localforward 1443 duplicate:443
        """

        XCTAssertEqual(SSHConfigInspector.parseLocalForwardPorts(from: output), [
            ForwardInfo(localPort: 1443, remotePort: 443),
            ForwardInfo(localPort: 8080, remotePort: 5432),
            ForwardInfo(localPort: 9090, remotePort: 9090),
            ForwardInfo(localPort: 7000, remotePort: 7000)
        ])
    }

    func testIgnoresMalformedAndEmptyInput() {
        XCTAssertEqual(SSHConfigInspector.parseLocalForwardPorts(from: ""), [])
        XCTAssertEqual(SSHConfigInspector.parseLocalForwardPorts(from: "user me\nhostname x\n"), [])
        XCTAssertEqual(SSHConfigInspector.parseLocalForwardPorts(from: "localforward"), [])
        XCTAssertEqual(SSHConfigInspector.parseLocalForwardPorts(from: "localforward abc xyz"), [])
        XCTAssertEqual(
            SSHConfigInspector.parseLocalForwardPorts(from: "  LocalForward   42   remote:1\n"),
            [ForwardInfo(localPort: 42, remotePort: 1)],
            "Leading/extra whitespace should not break parsing"
        )
    }

    func testParsesOptionsAndPortsTogether() {
        let output = """
        hostname proxy.example.com
        user sshproxy
        port 2222
        localforward 1443 backend:443
        localforward 9090 metrics:9090
        """
        let opts = SSHConfigInspector.parseOptions(from: output)
        XCTAssertEqual(opts.hostname, "proxy.example.com")
        XCTAssertEqual(opts.user, "sshproxy")
        XCTAssertEqual(opts.port, "2222")
        XCTAssertEqual(opts.forwardInfos, [
            ForwardInfo(localPort: 1443, remotePort: 443),
            ForwardInfo(localPort: 9090, remotePort: 9090)
        ])
    }

    func testParseOptionsDefaultsPortTo22() {
        let opts = SSHConfigInspector.parseOptions(from: "hostname x\nuser y\n")
        XCTAssertEqual(opts.port, "22")
        XCTAssertEqual(opts.userControlPath, "")
    }

    func testReadsUserControlPath() {
        let output = """
        hostname host
        user me
        port 22
        controlpath /tmp/control-host
        """
        let opts = SSHConfigInspector.parseOptions(from: output)
        XCTAssertEqual(opts.userControlPath, "/tmp/control-host")
    }

    func testTreatsControlPathNoneAsAbsent() {
        let output = """
        hostname host
        controlpath none
        """
        let opts = SSHConfigInspector.parseOptions(from: output)
        XCTAssertEqual(opts.userControlPath, "")
    }
}
