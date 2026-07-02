import AppKit
import Foundation
import Network

/// Reduced view of an `NWPath` carrying just what the monitor reacts to:
/// overall reachability plus a fingerprint of the interfaces in use. The
/// fingerprint detects "still satisfied, but over a different network"
/// transitions (Wi-Fi → Ethernet, a different Wi-Fi, VPN up/down) that never
/// pass through `.unsatisfied` yet invalidate established connections.
struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let interfaceSignature: String

    init(isSatisfied: Bool, interfaceSignature: String = "") {
        self.isSatisfied = isSatisfied
        self.interfaceSignature = interfaceSignature
    }

    init(path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied,
            interfaceSignature: path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        )
    }
}

/// Abstraction over NWPathMonitor that exposes path changes as an
/// `AsyncStream<NetworkPathSnapshot>`. Enables tests to drive path updates
/// without standing up a real `NWPathMonitor`.
protocol NetworkPathSource: Sendable {
    func paths() -> AsyncStream<NetworkPathSnapshot>
}

/// Real implementation backed by `NWPathMonitor`.
///
/// `NWPathMonitor` now conforms to `AsyncSequence`, so we iterate it directly
/// instead of bridging `pathUpdateHandler` through a `DispatchQueue`. The
/// `AsyncStream` is kept only to adapt `NWPath` to the snapshot the protocol
/// vends; cancelling the consuming task ends iteration and tears the monitor
/// down.
final class SystemNetworkPathSource: NetworkPathSource, Sendable {
    func paths() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                for await path in NWPathMonitor() {
                    continuation.yield(NetworkPathSnapshot(path: path))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Abstraction over the system "machine woke from sleep" signal, exposed as an
/// `AsyncStream<Void>` so tests can drive wake events without an `NSWorkspace`.
protocol SystemWakeSource: Sendable {
    func wakes() -> AsyncStream<Void>
}

/// Real implementation backed by `NSWorkspace.didWakeNotification`.
final class WorkspaceWakeSource: SystemWakeSource, Sendable {
    func wakes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                let stream = NSWorkspace.shared.notificationCenter
                    .notifications(named: NSWorkspace.didWakeNotification)
                for await _ in stream {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Monitors network path changes and system wake events, triggering immediate
/// health checks or connection attempts on tunnels.
@MainActor
final class NetworkMonitor {
    private let tunnelManager: TunnelManager
    private let pathSource: NetworkPathSource
    private let wakeSource: SystemWakeSource
    private let settleDelay: TimeInterval
    private let readinessChecker: NetworkReadinessChecking
    private let readinessRetryDelay: TimeInterval
    private let readinessProbeTimeout: TimeInterval
    private var lastSnapshot: NetworkPathSnapshot?
    private var observationTasks: [Task<Void, Never>] = []
    private var recoveryTask: Task<Void, Never>?

    var isNetworkSatisfied: Bool { lastSnapshot?.isSatisfied ?? false }

    init(
        tunnelManager: TunnelManager,
        pathSource: NetworkPathSource = SystemNetworkPathSource(),
        wakeSource: SystemWakeSource = WorkspaceWakeSource(),
        settleDelay: TimeInterval = 1.5,
        readinessChecker: NetworkReadinessChecking = TCPNetworkReadinessChecker(),
        readinessRetryDelay: TimeInterval = 5,
        readinessProbeTimeout: TimeInterval = 2
    ) {
        self.tunnelManager = tunnelManager
        self.pathSource = pathSource
        self.wakeSource = wakeSource
        self.settleDelay = settleDelay
        self.readinessChecker = readinessChecker
        self.readinessRetryDelay = readinessRetryDelay
        self.readinessProbeTimeout = readinessProbeTimeout

        observationTasks.append(
            Task { @MainActor [weak self, pathSource] in
                for await snapshot in pathSource.paths() {
                    guard let self else { return }
                    self.handlePathUpdate(snapshot)
                }
            }
        )

        observationTasks.append(
            Task { @MainActor [weak self, wakeSource] in
                for await _ in wakeSource.wakes() {
                    guard let self else { return }
                    self.handleSystemWake()
                }
            }
        )
    }

    deinit {
        for task in observationTasks { task.cancel() }
        recoveryTask?.cancel()
    }

    func stop() {
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// Convenience for tests and call sites that only care about reachability.
    func handlePathUpdate(satisfied: Bool) {
        handlePathUpdate(NetworkPathSnapshot(
            isSatisfied: satisfied,
            interfaceSignature: lastSnapshot?.interfaceSignature ?? ""
        ))
    }

    /// Internal so tests can simulate transitions.
    func handlePathUpdate(_ snapshot: NetworkPathSnapshot) {
        let previous = lastSnapshot
        guard snapshot != previous else { return }
        lastSnapshot = snapshot

        let satisfied = snapshot.isSatisfied
        let wasSatisfied = previous?.isSatisfied ?? false
        if satisfied != wasSatisfied {
            TunnelLog.shared.log(.notice, .network, "network path \(satisfied ? "satisfied" : "unsatisfied")")
        }

        // Keep every controller's view of the network current: while the path
        // is down, controllers park pending reconnects instead of burning
        // backoff attempts on ssh processes that cannot succeed.
        for controller in tunnelManager.controllers {
            controller.setNetworkAvailable(satisfied)
        }

        if satisfied && !wasSatisfied {
            recoverDesiredTunnels()
        } else if satisfied, let previous, snapshot.interfaceSignature != previous.interfaceSignature {
            // Still satisfied but over different interfaces (Wi-Fi → Ethernet,
            // another Wi-Fi, VPN up/down): established connections may be dead
            // without any unsatisfied transition — re-verify and resume.
            TunnelLog.shared.log(
                .notice, .network,
                "network interfaces changed (\(previous.interfaceSignature.isEmpty ? "-" : previous.interfaceSignature) -> \(snapshot.interfaceSignature.isEmpty ? "-" : snapshot.interfaceSignature))"
            )
            recoverDesiredTunnels()
        } else if !satisfied {
            recoveryTask?.cancel()
            recoveryTask = nil
        }
    }

    /// Internal so tests can simulate wake events.
    func handleSystemWake() {
        TunnelLog.shared.log(.notice, .network, "system wake")
        if isNetworkSatisfied {
            recoverDesiredTunnels()
        }
    }

    /// Triggers recovery for tunnels that should be connected.
    /// Adds a small delay to ensure the system network stack is fully 'settled'
    /// before firing SSH commands.
    func recoverDesiredTunnels() {
        recoveryTask?.cancel()
        let delay = settleDelay
        recoveryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            if Task.isCancelled { return }
            guard let self, self.isNetworkSatisfied else { return }

            var shouldCheckActiveTunnels = true
            while !Task.isCancelled {
                guard self.isNetworkSatisfied else { return }
                var hasPendingReadiness = false

                for controller in self.tunnelManager.controllers {
                    if Task.isCancelled { return }
                    // A parked reconnect sits in `.reconnecting` (which counts
                    // as active) with no scheduled retry — it must be resumed
                    // here, not health-checked.
                    let needsStart = controller.wantsToBeConnected
                        && (controller.isReconnectParkedForNetwork || !controller.isActive)
                    if needsStart {
                        let canStart = await self.canStartAutomatically(controller)
                        if Task.isCancelled || !self.isNetworkSatisfied { return }

                        if canStart {
                            self.log(.info, .network, controller: controller, "recovery: starting tunnel (network ready)")
                            await controller.resumeAfterNetworkRestored()
                        } else {
                            self.log(.notice, .network, controller: controller, "recovery: deferred — readiness probe to \(controller.settings.autostartReadinessProbeHost):\(controller.settings.autostartReadinessProbePort) not reachable yet")
                            hasPendingReadiness = true
                        }
                    } else if controller.isActive {
                        if shouldCheckActiveTunnels {
                            await controller.checkTunnelHealth()
                        }
                    }
                }

                if !hasPendingReadiness { return }
                shouldCheckActiveTunnels = false
                if self.readinessRetryDelay > 0 {
                    try? await Task.sleep(for: .seconds(self.readinessRetryDelay))
                }
            }
        }
    }

    private func canStartAutomatically(_ controller: TunnelController) async -> Bool {
        let host = controller.settings.autostartReadinessProbeHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return true }
        return await readinessChecker.canReach(
            host: host,
            port: controller.settings.autostartReadinessProbePort,
            timeout: readinessProbeTimeout
        )
    }

    private func log(
        _ level: LogLevel,
        _ category: LogCategory,
        controller: TunnelController,
        _ message: @autoclosure () -> String
    ) {
        TunnelLog.shared.log(level, category, tunnel: controller.settings.name, message())
    }
}
