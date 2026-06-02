import Foundation
import XCTest
@testable import SSHTunnelKit

final class TunnelControllerForwardResolveTests: XCTestCase {

    @MainActor
    func testLoadResolvedOptionsPopulatesForwardedPortsWithoutStartingTunnel() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "h",
                user: "u",
                port: "22",
                forwardInfos: [ForwardInfo(localPort: 1443), ForwardInfo(localPort: 8080)],
                userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.loadResolvedOptions()

        XCTAssertEqual(controller.forwardedPorts, [1443, 8080])
        XCTAssertEqual(controller.sshConfigForwardInfos, [ForwardInfo(localPort: 1443), ForwardInfo(localPort: 8080)])
        XCTAssertEqual(controller.state, .disconnected, "Resolving options must NOT change the tunnel state")
        XCTAssertEqual(masterClient.resolveHosts, ["test-host"])
    }

    @MainActor
    func testSSHConfigForwardInfosExcludeQuickForwardLocalPorts() async throws {
        var settings = makeTestSettings()
        settings.quickForwards = [
            QuickForward(id: UUID(), remotePort: 443, localPort: 65432, label: "Docs")
        ]
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "h",
                user: "u",
                port: "22",
                forwardInfos: [ForwardInfo(localPort: 15432, remotePort: 5432)],
                userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.loadResolvedOptions()

        XCTAssertEqual(controller.sshConfigForwardInfos, [ForwardInfo(localPort: 15432, remotePort: 5432)])
        XCTAssertEqual(controller.forwardedPorts, [15432, 65432])
    }

    @MainActor
    func testLocalForwardLabelsApplyToMenuForwardInfos() async throws {
        var settings = makeTestSettings()
        settings.localForwardLabels = [
            LocalForwardLabel(localPort: 15432, label: "Postgres")
        ]
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "h",
                user: "u",
                port: "22",
                forwardInfos: [ForwardInfo(localPort: 15432, remotePort: 5432)],
                userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings,
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.loadResolvedOptions()

        XCTAssertEqual(controller.sshConfigForwardInfos, [
            ForwardInfo(localPort: 15432, remotePort: 5432, label: "Postgres")
        ])
        XCTAssertEqual(controller.forwardInfos, [
            ForwardInfo(localPort: 15432, remotePort: 5432, label: "Postgres")
        ])
    }

    @MainActor
    func testForwardedPortsEmptyUntilOptionsResolved() {
        let settings = makeTestSettings()
        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: StubSSHMasterClient(),
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        XCTAssertTrue(controller.forwardedPorts.isEmpty)
    }

    @MainActor
    func testUpdatingHostAliasInvalidatesAndReresolvesForwards() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "old", user: "u", port: "22",
                forwardInfos: [ForwardInfo(localPort: 1234)], userControlPath: ""
            ),
            SSHHostOptions(
                hostname: "new", user: "u", port: "22",
                forwardInfos: [ForwardInfo(localPort: 5678), ForwardInfo(localPort: 9090)], userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )

        await controller.loadResolvedOptions()
        XCTAssertEqual(controller.forwardedPorts, [1234])

        var changed = settings
        changed.hostAlias = "different-host"
        controller.updateSettings(changed)

        await controller.loadResolvedOptions()

        XCTAssertEqual(controller.forwardedPorts, [5678, 9090])
        XCTAssertEqual(masterClient.resolveHosts, ["test-host", "different-host"])
    }

    @MainActor
    func testUpdatingUnrelatedSettingDoesNotReresolve() async throws {
        let settings = makeTestSettings()
        let masterClient = StubSSHMasterClient()
        masterClient.resolvedOptions = [
            SSHHostOptions(
                hostname: "h", user: "u", port: "22",
                forwardInfos: [ForwardInfo(localPort: 1111)], userControlPath: ""
            )
        ]
        let controller = TunnelController(
            settings: settings, sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            masterClient: masterClient,
            portChecker: StubPortChecker(),
            startsMonitoring: false
        )
        await controller.loadResolvedOptions()
        XCTAssertEqual(masterClient.resolveHosts.count, 1)

        // Toggling autostart should NOT re-trigger a resolve.
        var changed = settings
        changed.autostartOnLogin.toggle()
        controller.updateSettings(changed)
        await controller.loadResolvedOptions()

        XCTAssertEqual(masterClient.resolveHosts.count, 1,
                       "loadResolvedOptions must be a no-op if options are already known and host alias unchanged")
    }
}
