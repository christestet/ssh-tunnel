import Foundation
import XCTest
@testable import SSHTunnelKit

final class PortConflictResolverTests: XCTestCase {
    func testResolveReturnsFreeWhenNoPortsAreBound() async {
        let checker = StubPortChecker()
        let resolver = makeResolver(checker: checker)

        let result = await resolver.resolve(among: [6333])

        XCTAssertEqual(result, .free)
    }

    func testResolveClassifiesForeignHolder() async {
        let checker = StubPortChecker()
        let conflict = PortConflict(port: 6333, pid: 42, command: "qdrant")
        checker.conflicts[6333] = conflict
        let resolver = makeResolver(checker: checker)

        let result = await resolver.resolve(among: [6333])

        XCTAssertEqual(result, .foreignConflict(conflict))
    }

    func testResolveClassifiesUnidentifiedSshHolderAsTransient() async {
        let checker = StubPortChecker()
        let conflict = PortConflict(port: 6333, pid: 42, command: "ssh")
        checker.conflicts[6333] = conflict
        let resolver = makeResolver(checker: checker)

        let result = await resolver.resolve(among: [6333])

        XCTAssertEqual(result, .transientSshConflict(conflict))
    }

    func testResolveClassifiesDifferentSshTunnelAsForeign() async {
        let checker = StubPortChecker()
        let conflict = PortConflict(
            port: 6333,
            pid: 42,
            command: "ssh",
            commandArgs: ["/usr/bin/ssh", "-N", "different-host"],
            openFiles: ["/tmp/different-control.sock"]
        )
        checker.conflicts[6333] = conflict
        let resolver = makeResolver(checker: checker)

        let result = await resolver.resolve(among: [6333])

        XCTAssertEqual(result, .foreignConflict(conflict))
    }

    func testResolveKillsOurOrphanAndReturnsFree() async throws {
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

        let checker = StubPortChecker()
        checker.conflictResults = [
            PortConflict(
                port: 6333,
                pid: victimPid,
                command: "ssh",
                commandArgs: ["/usr/bin/ssh", "-N", "-M", "-S", "/tmp/x", "test-host"]
            ),
            nil
        ]
        let resolver = makeResolver(checker: checker, portReleaseGrace: 0)

        let result = await resolver.resolve(among: [6333])

        XCTAssertEqual(result, .free)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(sleepProc.isRunning)
    }

    private func makeResolver(
        checker: StubPortChecker,
        portReleaseGrace: TimeInterval = 0
    ) -> PortConflictResolver {
        PortConflictResolver(
            portChecker: checker,
            portReleaseGrace: portReleaseGrace,
            hostAlias: "test-host",
            sshControlPath: "/tmp/test-control",
            filesystemControlPath: "/tmp/test-control"
        )
    }
}
