import XCTest
@testable import SSHTunnelKit

final class SettingsUpdatesButtonPresentationTests: XCTestCase {
    func testIdleUpdateButtonUsesReadableFilledInfoSymbol() {
        let presentation = SettingsUpdatesButtonPresentation(hasUpdate: false)

        XCTAssertEqual(presentation.symbolName, "info.circle.fill")
        XCTAssertFalse(presentation.usesAccentTint)
        XCTAssertEqual(presentation.accessibilityLabel, "About & Updates")
        XCTAssertEqual(presentation.help, "About & Updates")
    }

    func testAvailableUpdateButtonUsesAccentDownloadSymbol() {
        let presentation = SettingsUpdatesButtonPresentation(hasUpdate: true)

        XCTAssertEqual(presentation.symbolName, "arrow.down.circle.fill")
        XCTAssertTrue(presentation.usesAccentTint)
    }
}
