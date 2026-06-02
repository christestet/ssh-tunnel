import Foundation
import CryptoKit
import XCTest
@testable import SSHTunnelKit

final class ControlPathExpanderTests: XCTestCase {

    func testReplacesAllSshTokens() {
        let opts = SSHHostOptions(
            hostname: "host.example.com",
            user: "alice",
            port: "2222",
            forwardInfos: [],
            userControlPath: ""
        )
        let template = "~/.ssh/control-%r@%h:%p"
        let result = ControlPathExpander.expand(template: template, options: opts)
        XCTAssertTrue(result.hasSuffix("/.ssh/control-alice@host.example.com:2222"))
        XCTAssertFalse(result.contains("~"), "Tilde must be expanded")
        XCTAssertFalse(result.contains("%"), "All SSH tokens must be expanded")
    }

    func testPreservesLiteralPercent() {
        let opts = SSHHostOptions(hostname: "h", user: "u", port: "22", forwardInfos: [], userControlPath: "")
        let result = ControlPathExpander.expand(template: "/tmp/100%%-control-%h", options: opts)
        XCTAssertEqual(result, "/tmp/100%-control-h")
    }

    func testLeavesUnknownTokensVisible() {
        let opts = SSHHostOptions(hostname: "h", user: "u", port: "22", forwardInfos: [], userControlPath: "")
        let result = ControlPathExpander.expand(template: "/tmp/%h-%z-tail", options: opts)
        XCTAssertEqual(result, "/tmp/h-%z-tail")
    }

    func testHandlesTrailingPercent() {
        let opts = SSHHostOptions(hostname: "h", user: "u", port: "22", forwardInfos: [], userControlPath: "")
        let result = ControlPathExpander.expand(template: "/tmp/foo-%", options: opts)
        XCTAssertEqual(result, "/tmp/foo-%")
    }

    func testExpandsPercentCHashLikeOpenSSH() {
        let opts = SSHHostOptions(
            hostname: "example.com",
            user: "testuser",
            port: "2222",
            forwardInfos: [],
            userControlPath: ""
        )
        let localHost = ProcessInfo.processInfo.hostName
        let expectedHash = Insecure.SHA1
            .hash(data: Data((localHost + opts.hostname + opts.port + opts.user).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let result = ControlPathExpander.expand(template: "/tmp/control-%C", options: opts)

        XCTAssertEqual(result, "/tmp/control-\(expectedHash)")
    }

    func testPercentCSeparatesSameHostWithDifferentUsersOrPorts() {
        let alice = SSHHostOptions(hostname: "same.example.com", user: "alice", port: "22", forwardInfos: [], userControlPath: "")
        let bob = SSHHostOptions(hostname: "same.example.com", user: "bob", port: "22", forwardInfos: [], userControlPath: "")
        let altPort = SSHHostOptions(hostname: "same.example.com", user: "alice", port: "2222", forwardInfos: [], userControlPath: "")

        let alicePath = ControlPathExpander.expand(template: "/tmp/control-%C", options: alice)
        let bobPath = ControlPathExpander.expand(template: "/tmp/control-%C", options: bob)
        let altPortPath = ControlPathExpander.expand(template: "/tmp/control-%C", options: altPort)

        XCTAssertNotEqual(alicePath, bobPath)
        XCTAssertNotEqual(alicePath, altPortPath)
        XCTAssertFalse(alicePath.contains("%C"))
    }
}
