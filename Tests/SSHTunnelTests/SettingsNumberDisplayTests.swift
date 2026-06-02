import XCTest
@testable import SSHTunnelKit

final class SettingsNumberDisplayTests: XCTestCase {
    func testPortDisplayUsesRawDigitsWithoutLocaleGrouping() {
        XCTAssertEqual(SettingsNumberDisplay.port(1443), "1443")
        XCTAssertEqual(SettingsNumberDisplay.port(65535), "65535")
    }

    func testSecondDisplayRoundsToWholeSecondsWithoutFractionDigits() {
        XCTAssertEqual(SettingsNumberDisplay.seconds(15), "15 sec")
        XCTAssertEqual(SettingsNumberDisplay.seconds(60), "60 sec")
        XCTAssertEqual(SettingsNumberDisplay.seconds(12.6), "13 sec")
    }
}