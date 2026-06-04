import Foundation
import XCTest
@testable import SSHTunnelKit

/// Guards the checked-in `Resources/Info.plist` version fields. Release Please
/// rewrites `CFBundleShortVersionString` on every release; a malformed value
/// (stray `v`, a pre-release suffix, a non-numeric segment) would only surface
/// downstream in tags/UI. We parse the real plist via the test's own source
/// location so the guard tracks the file CI actually ships.
final class VersionPlistTests: XCTestCase {

    private func infoPlist(file: StaticString = #filePath) throws -> [String: Any] {
        // <repo>/Tests/SSHTunnelTests/VersionPlistTests.swift → <repo>
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // SSHTunnelTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist must be a dictionary")
    }

    func testShortVersionIsCleanSemVer() throws {
        let plist = try infoPlist()
        let shortVersion = try XCTUnwrap(
            plist["CFBundleShortVersionString"] as? String,
            "CFBundleShortVersionString must be present"
        )

        let parsed = try XCTUnwrap(
            SemanticVersion(shortVersion),
            "CFBundleShortVersionString '\(shortVersion)' must be a MAJOR.MINOR.PATCH SemVer"
        )
        // AGENTS.md: the plist value carries no leading `v` and no suffix.
        XCTAssertEqual(
            parsed.description, shortVersion,
            "plist version must be bare MAJOR.MINOR.PATCH (no leading v / pre-release suffix)"
        )
    }

    func testBundleVersionIsAMonotonicInteger() throws {
        let plist = try infoPlist()
        let build = try XCTUnwrap(
            plist["CFBundleVersion"] as? String,
            "CFBundleVersion must be present"
        )
        let numeric = try XCTUnwrap(
            Int(build),
            "CFBundleVersion '\(build)' must be a plain integer build number"
        )
        XCTAssertGreaterThan(numeric, 0, "build number must be positive")
    }
}
