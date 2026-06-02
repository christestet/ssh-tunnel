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
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "2.1.5") // x-release-please-version
        XCTAssertTrue(
            try XCTUnwrap(plist["CFBundleVersion"] as? String)
                .range(of: #"^\d+$"#, options: .regularExpression) != nil
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

    func testReleasePleaseManifestTracksCurrentSemanticVersion() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = rootURL.appendingPathComponent(".release-please-manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        XCTAssertEqual(manifest["."], "2.1.5")
    }

    func testReadmeDocumentsUnsignedGitHubReleaseOpening() throws {
        let readmeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)

        XCTAssertTrue(readme.contains("GitHub Releases"))
        XCTAssertTrue(readme.contains("unsigned"))
        XCTAssertTrue(readme.contains("right-click"))
        XCTAssertTrue(readme.contains("Open"))
    }

    func testDependabotUpdatesGitHubActions() throws {
        let dependabotURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/dependabot.yml")
        let dependabot = try String(contentsOf: dependabotURL, encoding: .utf8)

        XCTAssertTrue(dependabot.contains("package-ecosystem: \"github-actions\""))
        XCTAssertTrue(dependabot.contains("directory: \"/\""))
        XCTAssertTrue(dependabot.contains("interval: \"weekly\""))
    }
}
