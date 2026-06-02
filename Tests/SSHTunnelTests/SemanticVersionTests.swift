import XCTest
@testable import SSHTunnelKit

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainVersion() {
        let version = SemanticVersion("2.2.4")
        XCTAssertEqual(version, SemanticVersion(major: 2, minor: 2, patch: 4))
    }

    func testParsesLeadingVPrefix() {
        XCTAssertEqual(SemanticVersion("v2.2.4"), SemanticVersion(major: 2, minor: 2, patch: 4))
        XCTAssertEqual(SemanticVersion("V2.2.4"), SemanticVersion(major: 2, minor: 2, patch: 4))
    }

    func testParsesWhitespace() {
        XCTAssertEqual(SemanticVersion("  v2.2.4 \n"), SemanticVersion(major: 2, minor: 2, patch: 4))
    }

    func testIgnoresPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemanticVersion("2.2.4-beta.1"), SemanticVersion(major: 2, minor: 2, patch: 4))
        XCTAssertEqual(SemanticVersion("v3.0.0+build.7"), SemanticVersion(major: 3, minor: 0, patch: 0))
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(SemanticVersion(nil))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("   "))
        XCTAssertNil(SemanticVersion("2.2"))
        XCTAssertNil(SemanticVersion("2.2.4.1"))
        XCTAssertNil(SemanticVersion("two.2.4"))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("-1.0.0"))
    }

    func testOrdering() {
        XCTAssertLessThan(SemanticVersion("2.2.4")!, SemanticVersion("2.10.0")!)
        XCTAssertLessThan(SemanticVersion("2.10.0")!, SemanticVersion("3.0.0")!)
        XCTAssertLessThan(SemanticVersion("2.2.4")!, SemanticVersion("2.2.5")!)
        XCTAssertGreaterThan(SemanticVersion("3.0.0")!, SemanticVersion("2.99.99")!)
    }

    func testEquality() {
        XCTAssertEqual(SemanticVersion("v2.2.4"), SemanticVersion("2.2.4"))
        XCTAssertFalse(SemanticVersion("2.2.4")! < SemanticVersion("2.2.4")!)
    }

    func testDescriptionDropsPrefixAndSuffix() {
        XCTAssertEqual(SemanticVersion("v2.2.4-beta.1")?.description, "2.2.4")
    }
}
