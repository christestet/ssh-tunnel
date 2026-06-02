import XCTest
@testable import SSHTunnelKit

final class HelpViewContentTests: XCTestCase {
    func testHelpContentMentionsCurrentTunnelBehavior() {
        let text = HelpContent.sections
            .map { "\($0.title)\n\($0.body)" }
            .joined(separator: "\n")

        XCTAssertTrue(text.contains("TCP LocalForward"))
        XCTAssertTrue(text.contains("adopts it"))
        XCTAssertTrue(text.contains("10 consecutive"))
        XCTAssertTrue(text.contains("Start at Login"))
        XCTAssertTrue(text.contains("Startup Check"))
        XCTAssertTrue(text.contains("SSH Config Forwards"))
        XCTAssertTrue(text.contains("Run Diagnostics"))
        XCTAssertTrue(text.contains("Host Alias"))
        XCTAssertTrue(text.contains("About & Updates"))
    }

    func testHelpContentDoesNotMentionRemovedLegacyFields() {
        let text = HelpContent.sections
            .map { "\($0.title)\n\($0.body)" }
            .joined(separator: "\n")

        XCTAssertFalse(text.contains("dummyHost"))
        XCTAssertFalse(text.contains("localPort"))
        XCTAssertFalse(text.contains("single-tunnel"))
        XCTAssertFalse(text.contains("Auto-Start on Login"))
        XCTAssertFalse(text.contains("Autostart on Login"))
        XCTAssertFalse(text.contains("Detected LocalForwards"))
        XCTAssertFalse(text.contains("Run Diagnostic in"))
        XCTAssertFalse(text.contains("Check Setup"))
        XCTAssertFalse(text.contains("Tunnel Doctor"))
    }
}
