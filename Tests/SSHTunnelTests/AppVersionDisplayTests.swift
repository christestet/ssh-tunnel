import XCTest
@testable import SSHTunnelKit

final class AppVersionDisplayTests: XCTestCase {
    func testBadgePrefixesSemanticVersionWithV() {
        XCTAssertEqual(AppVersionDisplay.badge(for: "2.1.5"), "v2.1.5")
    }

    func testBadgeDoesNotDoublePrefixVersionThatAlreadyHasV() {
        XCTAssertEqual(AppVersionDisplay.badge(for: "v2.3.4"), "v2.3.4")
    }

    func testTitleShowsAppNameAndVersionWhenVersionExists() {
        XCTAssertEqual(
            AppVersionDisplay.title(appName: "SSH Tunnel", shortVersion: "2.1.5"),
            "SSH Tunnel v2.1.5"
        )
    }

    func testTitleFallsBackToAppNameWhenVersionIsMissing() {
        XCTAssertEqual(
            AppVersionDisplay.title(appName: "SSH Tunnel", shortVersion: "   "),
            "SSH Tunnel"
        )
    }
}
