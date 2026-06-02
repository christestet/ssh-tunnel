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
