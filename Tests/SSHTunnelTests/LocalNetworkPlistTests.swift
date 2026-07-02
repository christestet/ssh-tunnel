import Foundation
import XCTest
@testable import SSHTunnelKit

/// Guards the local-network privacy declaration in `Resources/Info.plist`.
/// Since macOS 15 the system silently denies connections to local-network
/// hosts (readiness probes via NWConnection, and the ssh child processes TCC
/// attributes to this app) unless the bundle declares
/// `NSLocalNetworkUsageDescription` — only then does the permission prompt
/// appear at all. Losing the key would bring back "tunnels never come up on
/// the home network and no prompt is shown".
final class LocalNetworkPlistTests: XCTestCase {

    private func infoPlist(file: StaticString = #filePath) throws -> [String: Any] {
        // <repo>/Tests/SSHTunnelTests/LocalNetworkPlistTests.swift → <repo>
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // SSHTunnelTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist must be a dictionary")
    }

    func testLocalNetworkUsageDescriptionIsPresentAndNonEmpty() throws {
        let plist = try infoPlist()
        let description = try XCTUnwrap(
            plist["NSLocalNetworkUsageDescription"] as? String,
            "NSLocalNetworkUsageDescription must be declared — without it macOS never shows the Local Network prompt and silently blocks local connections"
        )
        XCTAssertFalse(
            description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the usage description shown in the permission prompt must not be empty"
        )
    }
}
