import Foundation
import XCTest

final class BuildMetadataTests: XCTestCase {
    func testBundleMetadataTargetsMacOS26MenuBarApp() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "2.1.5")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "4")
        XCTAssertTrue(
            try XCTUnwrap(plist["CFBundleVersion"] as? String)
                .range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil
        )
    }

    func testAgentInstructionsDocumentSemanticReleaseVersioning() throws {
        let agentsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AGENTS.md")
        let agents = try String(contentsOf: agentsURL, encoding: .utf8)

        XCTAssertTrue(agents.contains("Conventional Commits"))
        XCTAssertTrue(agents.contains("semantic-release"))
        XCTAssertTrue(agents.contains("CFBundleShortVersionString"))
        XCTAssertTrue(agents.contains("CFBundleVersion"))
    }

    func testMakefileTargetsMacOS26() throws {
        let makefileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Makefile")
        let makefile = try String(contentsOf: makefileURL, encoding: .utf8)

        XCTAssertTrue(makefile.contains("-apple-macosx26.0"))
    }
}
