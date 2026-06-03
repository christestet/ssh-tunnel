import XCTest
@testable import SSHTunnelKit

final class PortAvailabilityTests: XCTestCase {

    func testFindFreePortReturnsPortWithinRange() async {
        let checker = LocalPortAvailabilityChecker()
        let range = 49152...65535 // ephemeral range — plenty free
        let port = await checker.findFreePort(in: range)
        XCTAssertNotNil(port)
        if let port {
            XCTAssertTrue(range.contains(port), "returned port \(port) must be inside the requested range")
        }
    }

    func testConflictsReportsAllBoundPortsAndFirstConflictIsLowest() async {
        let a = try! LoopbackListener()
        let b = try! LoopbackListener()
        defer { a.close(); b.close() }
        let checker = LocalPortAvailabilityChecker()

        guard let free = await checker.findFreePort(in: 49152...65535) else {
            return XCTFail("expected a free port")
        }
        // Mix bound and free ports in arbitrary order.
        let ports = [b.port, free, a.port].sorted()
        let conflicts = await checker.conflicts(among: ports)

        XCTAssertEqual(Set(conflicts.map(\.port)), [a.port, b.port],
                       "conflicts(among:) must report every bound port")
        XCTAssertFalse(conflicts.contains { $0.port == free },
                       "a genuinely free port must not appear")

        let first = await checker.firstConflict(among: ports)
        XCTAssertEqual(first?.port, min(a.port, b.port),
                       "firstConflict must be the lowest-numbered bound port")
    }

    func testFindFreePortReturnsAGenuinelyFreePort() async {
        let checker = LocalPortAvailabilityChecker()
        guard let port = await checker.findFreePort(in: 49152...65535) else {
            return XCTFail("expected a free port in the ephemeral range")
        }
        // Nothing is listening on a port we just probed as free, so a conflict
        // check must come back empty.
        let conflict = await checker.firstConflict(among: [port])
        XCTAssertNil(conflict, "findFreePort must hand back a port with no listener")
    }
}
