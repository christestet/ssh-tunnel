import AppKit
import XCTest
@testable import SSHTunnelKit

final class MenuBarIconImageTests: XCTestCase {
    func testMenuBarIconUsesConcreteTintedImagesForEveryState() {
        let baseIcon = NSImage(size: NSSize(width: 18, height: 18))
        baseIcon.isTemplate = true

        for state in [TunnelState.disconnected, .connecting, .connected, .reconnecting, .failed] {
            let image = MenuBarIconImage.image(baseIcon: baseIcon, state: state)

            XCTAssertFalse(image.isTemplate, "\(state.label) should not rely on MenuBarExtra template tinting")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }

    func testMenuBarIconTintColorsMatchTunnelStates() {
        XCTAssertEqual(TunnelState.disconnected.menuBarTintColor, .systemGray)
        XCTAssertEqual(TunnelState.connecting.menuBarTintColor, .systemYellow)
        XCTAssertEqual(TunnelState.connected.menuBarTintColor, .systemGreen)
        XCTAssertEqual(TunnelState.reconnecting.menuBarTintColor, .systemYellow)
        XCTAssertEqual(TunnelState.failed.menuBarTintColor, .systemRed)
    }
}
