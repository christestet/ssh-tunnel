import XCTest
@testable import SSHTunnelKit

final class MenuBarMoreMenuPresentationTests: XCTestCase {
    func testRepositoryMenuItemUsesLinkSymbolAndGitHubRepositoryURL() throws {
        let item = MenuBarMoreMenuPresentation.repository

        XCTAssertEqual(item.title, "GitHub Repository")
        XCTAssertEqual(item.systemImage, "link")
        XCTAssertEqual(item.url, URL(string: "https://github.com/christestet/ssh-tunnel"))
    }
}
