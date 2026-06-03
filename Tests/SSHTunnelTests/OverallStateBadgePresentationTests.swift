import XCTest
@testable import SSHTunnelKit

final class OverallStateBadgePresentationTests: XCTestCase {
    func testConnectedStateShowsConnectedCountWhenPositive() {
        let presentation = OverallStateBadgePresentation(state: .connected, connectedCount: 2)

        XCTAssertEqual(presentation.label, "2 Connected")
        XCTAssertEqual(presentation.accessibilityLabel, "2 tunnels connected")
    }

    func testConnectedStateWithoutCountFallsBackToStateLabel() {
        let presentation = OverallStateBadgePresentation(state: .connected, connectedCount: 0)

        XCTAssertEqual(presentation.label, "Connected")
        XCTAssertEqual(presentation.accessibilityLabel, "Connected")
    }

    func testNonConnectedStatesDoNotShowConnectedCount() {
        let presentation = OverallStateBadgePresentation(state: .connecting, connectedCount: 2)

        XCTAssertEqual(presentation.label, "Connecting")
        XCTAssertEqual(presentation.accessibilityLabel, "Connecting")
    }
}
