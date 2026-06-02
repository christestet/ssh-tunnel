import XCTest
@testable import SSHTunnelKit

final class SingleInstanceGuardTests: XCTestCase {
    private func uniqueIdentifier() -> String {
        "com.sshtunnel.tests.\(UUID().uuidString)"
    }

    func testFirstAcquirerWinsAndSecondIsRejected() {
        let identifier = uniqueIdentifier()
        let first = SingleInstanceGuard()
        let second = SingleInstanceGuard()
        defer { first.release(); second.release() }

        XCTAssertTrue(first.acquire(identifier: identifier), "first instance must win the lock")
        XCTAssertFalse(second.acquire(identifier: identifier), "a second instance must be rejected")
    }

    func testLockIsReleasedForNextInstance() {
        let identifier = uniqueIdentifier()

        let first = SingleInstanceGuard()
        XCTAssertTrue(first.acquire(identifier: identifier))
        first.release()

        // Once released, a fresh instance can take over.
        let second = SingleInstanceGuard()
        defer { second.release() }
        XCTAssertTrue(second.acquire(identifier: identifier), "lock must be reclaimable after release")
    }

    func testAcquireIsIdempotentForSameGuard() {
        let identifier = uniqueIdentifier()
        let guard1 = SingleInstanceGuard()
        defer { guard1.release() }

        XCTAssertTrue(guard1.acquire(identifier: identifier))
        XCTAssertTrue(guard1.acquire(identifier: identifier), "re-acquiring on the holder must stay true")
    }
}
