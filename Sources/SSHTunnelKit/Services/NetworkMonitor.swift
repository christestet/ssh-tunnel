import AppKit
import Foundation
import Network

/// Abstraction over NWPathMonitor that exposes path changes as an
/// `AsyncStream<Bool>` (`true` = path satisfied). Enables tests to drive
/// path updates without standing up a real `NWPathMonitor`.
protocol NetworkPathSource: Sendable {
    func paths() -> AsyncStream<Bool>
}

/// Real implementation backed by `NWPathMonitor`.
///
/// `NWPathMonitor` now conforms to `AsyncSequence`, so we iterate it directly
/// instead of bridging `pathUpdateHandler` through a `DispatchQueue`. The
/// `AsyncStream` is kept only to adapt `NWPath` to the `Bool` the protocol
/// vends; cancelling the consuming task ends iteration and tears the monitor
/// down.
final class SystemNetworkPathSource: NetworkPathSource, Sendable {
    func paths() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await path in NWPathMonitor() {
                    continuation.yield(path.status == .satisfied)
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
    private let settleDelay: TimeInterval
    private let readinessChecker: NetworkReadinessChecking
    private let readinessRetryDelay: TimeInterval
    private let readinessProbeTimeout: TimeInterval
    private var lastSatisfied: Bool = false
    private var observationTasks: [Task<Void, Never>] = []
    private var recoveryTask: Task<Void, Never>?

    var isNetworkSatisfied: Bool { lastSatisfied }

    init(
        tunnelManager: TunnelManager,
        pathSource: NetworkPathSource = SystemNetworkPathSource(),
        settleDelay: TimeInterval = 1.5,
        readinessChecker: NetworkReadinessChecking = TCPNetworkReadinessChecker(),
        readinessRetryDelay: TimeInterval = 5,
        readinessProbeTimeout: TimeInterval = 2
    ) {
        self.tunnelManager = tunnelManager
        self.pathSource = pathSource
        self.settleDelay = settleDelay
        self.readinessChecker = readinessChecker
        self.readinessRetryDelay = readinessRetryDelay
        self.readinessProbeTimeout = readinessProbeTimeout

        observationTasks.append(
            Task { @MainActor [weak self, pathSource] in
                for await satisfied in pathSource.paths() {
                    guard let self else { return }
                    self.handlePathUpdate(satisfied: satisfied)
                }
            }
        )

        observationTasks.append(
            Task { @MainActor [weak self] in
                let stream = NSWorkspace.shared.notificationCenter
                    .notifications(named: NSWorkspace.didWakeNotification)
                for await _ in stream {
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

    /// Internal so tests can simulate transitions.
    func handlePathUpdate(satisfied: Bool) {
        let transitionToSatisfied = satisfied && !lastSatisfied
        if satisfied != lastSatisfied {
            TunnelLog.shared.log(.notice, .network, "network path \(satisfied ? "satisfied" : "unsatisfied")")
        }
        lastSatisfied = satisfied

        if transitionToSatisfied {
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
                    if controller.isActive {
                        if shouldCheckActiveTunnels {
                            await controller.checkTunnelHealth()
                        }
                    } else if controller.wantsToBeConnected {
                        let canStart = await self.canStartAutomatically(controller)
                        if Task.isCancelled || !self.isNetworkSatisfied { return }

                        if canStart {
                            self.log(.info, .network, controller: controller, "recovery: starting tunnel (network ready)")
                            await controller.startTunnel()
                        } else {
                            self.log(.notice, .network, controller: controller, "recovery: deferred — readiness probe to \(controller.settings.autostartReadinessProbeHost):\(controller.settings.autostartReadinessProbePort) not reachable yet")
                            hasPendingReadiness = true
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
