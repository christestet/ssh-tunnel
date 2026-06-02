import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelSettingsStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "tunnel-tests-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else {
            return (UserDefaults.standard, suite)
        }
        return (d, suite)
    }

    @MainActor
    func testValidationRejectsEmptyFields() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var s = TunnelSettings.makeDefault()
        s.hostAlias = "ok"
        s.name = "   "
        XCTAssertThrowsError(try store.save(s)) { err in
            XCTAssertTrue(err is TunnelSettingsValidationError)
        }

        s.name = "Name"
        s.hostAlias = ""
        XCTAssertThrowsError(try store.save(s)) { err in
            XCTAssertEqual(err as? TunnelSettingsValidationError, .emptyHostAlias)
            XCTAssertEqual((err as? TunnelSettingsValidationError)?.errorDescription, "Host alias cannot be empty.")
        }

        s.hostAlias = "ok"
        s.controlPath = ""
        XCTAssertThrowsError(try store.save(s)) { err in
            XCTAssertTrue(err is TunnelSettingsValidationError)
        }
    }

    @MainActor
    func testValidationRejectsBackoffBelowHealthCheck() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var s = TunnelSettings.makeDefault()
        s.name = "ok"
        s.hostAlias = "ok"
        s.healthCheckInterval = 30
        s.maxBackoff = 10
        XCTAssertThrowsError(try store.save(s)) { err in
            XCTAssertTrue(err is TunnelSettingsValidationError)
        }
    }

    @MainActor
    func testLegacySettingsUnderOldKeyAreIgnored() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacyJSON = """
        {
            "hostAlias": "old-host",
            "controlPath": "~/.ssh/old-control",
            "healthCheckInterval": 15,
            "maxBackoff": 60
        }
        """.data(using: .utf8)!
        defaults.set(legacyJSON, forKey: "TunnelSettings")

        let store = TunnelSettingsStore(defaults: defaults)
        XCTAssertTrue(store.tunnels.isEmpty)
    }

    @MainActor
    func testCurrentSettingsLoadAndMissingAutostartDefaultsToFalse() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString

        let json = """
        [{
            "id": "\(id)",
            "name": "Mixed",
            "hostAlias": "myhost",
            "controlPath": "~/.ssh/c",
            "healthCheckInterval": 15,
            "maxBackoff": 60
        }]
        """.data(using: .utf8)!
        defaults.set(json, forKey: "TunnelSettingsMulti")

        let store = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tunnels.count, 1)
        XCTAssertEqual(store.tunnels.first?.hostAlias, "myhost")
        XCTAssertFalse(store.tunnels.first?.autostartOnLogin ?? true)
        XCTAssertEqual(store.tunnels.first?.autostartReadinessProbeHost, "")
        XCTAssertEqual(store.tunnels.first?.autostartReadinessProbePort, 22)
    }

    @MainActor
    func testValidationRejectsInvalidAutostartReadinessPortWhenHostIsSet() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var s = TunnelSettings.makeDefault()
        s.name = "Ready"
        s.hostAlias = "ready-host"
        s.autostartReadinessProbeHost = "vpn-gateway.internal"
        s.autostartReadinessProbePort = 0

        XCTAssertThrowsError(try store.save(s)) { err in
            XCTAssertEqual(err as? TunnelSettingsValidationError, .invalidAutostartReadinessPort)
            XCTAssertEqual(
                (err as? TunnelSettingsValidationError)?.errorDescription,
                "Startup check port must be between 1 and 65535."
            )
        }
    }

    @MainActor
    func testAutostartReadinessHostIsTrimmedOnSave() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var s = TunnelSettings.makeDefault()
        s.name = "Ready"
        s.hostAlias = "ready-host"
        s.autostartReadinessProbeHost = "  vpn-gateway.internal  "
        s.autostartReadinessProbePort = 443

        let saved = try store.save(s)

        XCTAssertEqual(saved.autostartReadinessProbeHost, "vpn-gateway.internal")
        XCTAssertEqual(store.tunnels.first?.autostartReadinessProbeHost, "vpn-gateway.internal")
    }

    @MainActor
    func testUnsafeLegacyControlPathIsMigrated() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString

        let json = """
        [{
            "id": "\(id)",
            "name": "Old",
            "hostAlias": "myhost",
            "controlPath": "~/.ssh/control-%h",
            "healthCheckInterval": 15,
            "maxBackoff": 60,
            "autostartOnLogin": false
        }]
        """.data(using: .utf8)!
        defaults.set(json, forKey: "TunnelSettingsMulti")

        let store = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tunnels.count, 1)
        XCTAssertEqual(store.tunnels.first?.controlPath, TunnelSettings.makeDefault().controlPath,
                   "Old unsafe default should be upgraded to the hashed namespaced default")

        let store2 = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(store2.tunnels.first?.controlPath, TunnelSettings.makeDefault().controlPath)
    }

    @MainActor
    func testPreviousNamespacedDefaultControlPathIsMigrated() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString

        let json = """
        [{
            "id": "\(id)",
            "name": "Old App Default",
            "hostAlias": "myhost",
            "controlPath": "~/.ssh/control-sshtunnelapp-%h",
            "healthCheckInterval": 15,
            "maxBackoff": 60,
            "autostartOnLogin": false
        }]
        """.data(using: .utf8)!
        defaults.set(json, forKey: "TunnelSettingsMulti")

        let store = TunnelSettingsStore(defaults: defaults)

        XCTAssertEqual(TunnelSettings.makeDefault().controlPath, "~/.ssh/control-sshtunnelapp-%C")
        XCTAssertEqual(store.tunnels.first?.controlPath, TunnelSettings.makeDefault().controlPath)
    }

    @MainActor
    func testCustomControlPathIsNotTouchedByMigration() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString

        let custom = "~/.ssh/my-custom-control-%h"
        let json = """
        [{
            "id": "\(id)",
            "name": "Custom",
            "hostAlias": "myhost",
            "controlPath": "\(custom)",
            "healthCheckInterval": 15,
            "maxBackoff": 60,
            "autostartOnLogin": false
        }]
        """.data(using: .utf8)!
        defaults.set(json, forKey: "TunnelSettingsMulti")

        let store = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tunnels.first?.controlPath, custom)
    }

    @MainActor
    func testSaveRoundTripsThroughDefaults() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store1 = TunnelSettingsStore(defaults: defaults)
        var s = TunnelSettings.makeDefault()
        s.name = "Persisted"
        s.hostAlias = "host"
        s.localForwardLabels = [
            LocalForwardLabel(localPort: 15432, label: "postgres")
        ]
        s.quickForwards = [
            QuickForward(id: UUID(), remotePort: 6333, localPort: 63554, label: "qdrant-stage")
        ]
        _ = try store1.save(s)

        let store2 = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(store2.tunnels.count, 1)
        XCTAssertEqual(store2.tunnels.first?.name, "Persisted")
        XCTAssertEqual(store2.tunnels.first?.quickForwards.first?.label, "qdrant-stage")
        XCTAssertEqual(store2.tunnels.first?.quickForwards.first?.remotePort, 6333)
        XCTAssertEqual(store2.tunnels.first?.localForwardLabels.first?.localPort, 15432)
        XCTAssertEqual(store2.tunnels.first?.localForwardLabels.first?.label, "postgres")
    }

    @MainActor
    func testMoveTunnelsPersistsOrder() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var first = makeTestSettings()
        first.name = "First"
        var second = makeTestSettings()
        second.id = UUID()
        second.name = "Second"
        var third = makeTestSettings()
        third.id = UUID()
        third.name = "Third"
        let store = TunnelSettingsStore(defaults: defaults)
        _ = try store.save(first)
        _ = try store.save(second)
        _ = try store.save(third)

        store.moveTunnels(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(store.tunnels.map(\.id), [third.id, first.id, second.id])
        let reloaded = TunnelSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.tunnels.map(\.id), [third.id, first.id, second.id])
    }

    @MainActor
    func testMoveMultipleTunnelsPreservesRelativeOrder() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var first = makeTestSettings()
        first.name = "First"
        var second = makeTestSettings()
        second.id = UUID()
        second.name = "Second"
        var third = makeTestSettings()
        third.id = UUID()
        third.name = "Third"
        var fourth = makeTestSettings()
        fourth.id = UUID()
        fourth.name = "Fourth"
        let store = TunnelSettingsStore(defaults: defaults)
        _ = try store.save(first)
        _ = try store.save(second)
        _ = try store.save(third)
        _ = try store.save(fourth)

        store.moveTunnels(fromOffsets: IndexSet([1, 2]), toOffset: 4)

        XCTAssertEqual(store.tunnels.map(\.id), [first.id, fourth.id, second.id, third.id])
    }

    @MainActor
    func testMoveTunnelsWithEmptySourceIsNoOp() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = makeTestSettings()
        var second = makeTestSettings()
        second.id = UUID()
        let store = TunnelSettingsStore(defaults: defaults)
        _ = try store.save(first)
        _ = try store.save(second)

        store.moveTunnels(fromOffsets: IndexSet(), toOffset: 0)

        XCTAssertEqual(store.tunnels.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testMoveTunnelsWithOutOfRangeSourceIsNoOp() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = makeTestSettings()
        var second = makeTestSettings()
        second.id = UUID()
        let store = TunnelSettingsStore(defaults: defaults)
        _ = try store.save(first)
        _ = try store.save(second)

        store.moveTunnels(fromOffsets: IndexSet(integer: 99), toOffset: 0)

        XCTAssertEqual(store.tunnels.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testQuickForwardLabelsAreTrimmedOnSave() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var settings = TunnelSettings.makeDefault()
        settings.name = "Labels"
        settings.hostAlias = "labels-host"
        settings.quickForwards = [
            QuickForward(id: UUID(), remotePort: 443, localPort: 1443, label: "  api  ")
        ]

        let saved = try store.save(settings)

        XCTAssertEqual(saved.quickForwards.first?.label, "api")
    }

    @MainActor
    func testLocalForwardLabelsAreTrimmedAndEmptyLabelsDroppedOnSave() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TunnelSettingsStore(defaults: defaults)

        var settings = TunnelSettings.makeDefault()
        settings.name = "Labels"
        settings.hostAlias = "labels-host"
        settings.localForwardLabels = [
            LocalForwardLabel(localPort: 15432, label: "  postgres  "),
            LocalForwardLabel(localPort: 18080, label: "   ")
        ]

        let saved = try store.save(settings)

        XCTAssertEqual(saved.localForwardLabels, [
            LocalForwardLabel(localPort: 15432, label: "postgres")
        ])
    }
}
