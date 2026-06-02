import Foundation
import Observation
import os

@MainActor
@Observable
final class TunnelController: Identifiable {
    let id: UUID
    var settings: TunnelSettings
    var state: TunnelState = .disconnected {
        didSet {
            guard oldValue != state else { return }
            logger.log(.info, .lifecycle, tunnel: settings.name, "(#\(attemptID)) state \(oldValue.label) -> \(state.label)")
        }
    }
    var lastError: String?
    private(set) var nextReconnectAt: Date?
    private(set) var resolvedOptions: SSHHostOptions?

    var forwardInfos: [ForwardInfo] {
        let quickInfos = settings.quickForwards.compactMap { qf -> ForwardInfo? in
            guard let lp = qf.localPort else { return nil }
            return ForwardInfo(
                localPort: lp,
                remotePort: qf.remotePort,
                label: qf.label.isEmpty ? nil : qf.label
            )
        }
        
        // Merge them, prioritizing quick forwards for the same local port
        var combined: [Int: ForwardInfo] = [:]
        for info in sshConfigForwardInfos {
            combined[info.localPort] = info
        }
        for info in quickInfos {
            combined[info.localPort] = info
        }
        
        return combined.values.sorted { $0.localPort < $1.localPort }
    }

    var sshConfigForwardInfos: [ForwardInfo] {
        let labelsByPort = settings.localForwardLabels.reduce(into: [Int: String]()) { labels, entry in
            labels[entry.localPort] = entry.label
        }
        return (resolvedOptions?.forwardInfos ?? []).map { info in
            ForwardInfo(
                localPort: info.localPort,
                remotePort: info.remotePort,
                label: labelsByPort[info.localPort] ?? info.label
            )
        }
    }

    var forwardedPorts: [Int] {
        forwardInfos.map { $0.localPort }
    }

    /// Path to the control socket as it appears on disk *after* OpenSSH's
    /// `%`-token expansion. Use this for `FileManager` operations. The raw
    /// template (with tokens) is what we pass to `ssh -S` so ssh itself can do
    /// its expansion.
    var filesystemControlPath: String {
        if let opts = resolvedOptions {
            return ControlPathExpander.expand(template: settings.controlPath, options: opts)
        }
        return settings.expandedControlPath
    }

    private let notifier: TunnelNotifying
    private let masterClient: SSHMasterClienting
    private let portChecker: PortAvailabilityChecking
    private let forwardHealthChecker: ForwardHealthChecking
    private let logger: any TunnelLogging
    private let portReleaseGrace: TimeInterval
    private var healthCheckTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var userInitiatedStop = false
    private var hasRequestedConnection = false
    private var reconnectTask: Task<Void, Never>?
    private var masterHandle: SSHLongRunningProcess?
    private var masterWatchTask: Task<Void, Never>?
    private let maxReconnectAttempts: Int

    /// Quick forwards we have successfully pushed onto the *current* live
    /// master. Tracked so we can cancel forwards that later disappear from
    /// settings even when the removal happened while the tunnel wasn't
    /// `.connected` (the immediate cancel is skipped then). On the next connect
    /// or adopt we reconcile this against the desired set and cancel the stale
    /// ones — otherwise an adopted master keeps the orphaned local port open.
    private var appliedQuickForwards: [QuickForward] = []

    /// Instruments signposter for visualising connection timing in Instruments
    /// (Timeline → os_signpost). Intervals span `startTunnel` and its costly
    /// sub-steps so overlapping work (e.g. quick forwards racing the master
    /// becoming ready) is visible.
    private let signposter = OSSignposter(
        subsystem: tunnelLogSubsystem,
        category: "connection"
    )

    /// Short correlation id for the *current* connection attempt. Every log line
    /// of one start/reconnect cycle carries it, so interleaved attempts in a
    /// reconnect loop stay distinguishable.
    private var attemptID: String = "-"


    init(
        settings: TunnelSettings,
        sshRunner: SSHRunning = ProcessSSHRunner(),
        notifier: TunnelNotifying = UserNotificationTunnelNotifier(),
        masterClient: SSHMasterClienting? = nil,
        portChecker: PortAvailabilityChecking = LocalPortAvailabilityChecker(),
        forwardHealthChecker: ForwardHealthChecking = TCPForwardHealthChecker(),
        logger: any TunnelLogging = TunnelLog.shared,
        startsMonitoring: Bool = true,
        portReleaseGrace: TimeInterval = 2,
        maxReconnectAttempts: Int = 10
    ) {
        self.id = settings.id
        self.settings = settings
        self.notifier = notifier
        self.masterClient = masterClient ?? OpenSSHMasterClient(runner: sshRunner)
        self.portChecker = portChecker
        self.forwardHealthChecker = forwardHealthChecker
        self.logger = logger
        self.portReleaseGrace = portReleaseGrace
        self.maxReconnectAttempts = maxReconnectAttempts
        notifier.requestAuthorization()
        if startsMonitoring {
            startHealthCheckTask()
        }
    }

    var isActive: Bool {
        switch state {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    /// Logs scoped to this tunnel, tagged with the current connection
    /// `attemptID` so interleaved start/reconnect cycles can be told apart.
    private func log(_ level: LogLevel, _ category: LogCategory, _ message: @autoclosure () -> String) {
        logger.log(level, category, tunnel: settings.name, "(#\(attemptID)) \(message())")
    }

    /// True iff the user wants this tunnel up: a connection was requested and
    /// has not been manually stopped. Used by [[NetworkMonitor]] to recover
    /// tunnels stuck in `.failed`/`.disconnected` when the network or system
    /// state changes — the in-`isActive` check alone would miss those.
    var wantsToBeConnected: Bool {
        hasRequestedConnection && !userInitiatedStop
    }

    func reconnectCountdownDescription(now: Date = Date()) -> String? {
        guard state == .reconnecting, let nextReconnectAt else { return nil }
        let remaining = max(0, Int(ceil(nextReconnectAt.timeIntervalSince(now))))
        return "Retry in \(remaining)s"
    }

    func prepareForAutostart() {
        hasRequestedConnection = true
        userInitiatedStop = false
        lastError = nil
    }

    func updateSettings(_ newSettings: TunnelSettings) {
        let quickForwardChange = replaceSettings(newSettings)
        if quickForwardChange.shouldApply {
            Task {
                await applyQuickForwardChanges(
                    old: quickForwardChange.old,
                    new: quickForwardChange.new
                )
            }
        }
    }

    func updateSettingsAndApplyChanges(_ newSettings: TunnelSettings) async {
        let quickForwardChange = replaceSettings(newSettings)
        if quickForwardChange.shouldApply {
            await applyQuickForwardChanges(
                old: quickForwardChange.old,
                new: quickForwardChange.new
            )
        }
    }

    private func replaceSettings(_ newSettings: TunnelSettings) -> (old: [QuickForward], new: [QuickForward], shouldApply: Bool) {
        let oldInterval = settings.healthCheckInterval
        let oldHostAlias = settings.hostAlias
        let oldQuickForwards = settings.quickForwards
        settings = newSettings
        if oldInterval != newSettings.healthCheckInterval {
            startHealthCheckTask()
        }
        if oldHostAlias != newSettings.hostAlias {
            // The host alias changed — the previously resolved forwards no
            // longer apply. Drop them so the UI hides this row until the
            // caller re-runs `loadResolvedOptions()`.
            resolvedOptions = nil
        }
        return (
            old: oldQuickForwards,
            new: newSettings.quickForwards,
            shouldApply: state == .connected && oldQuickForwards != newSettings.quickForwards
        )
    }

    private func applyQuickForwardChanges(old: [QuickForward], new: [QuickForward]) async {
        guard state == .connected else {
            log(.notice, .forward, "quick forward change deferred — tunnel not connected (state \(state.label)); will be applied on next connect")
            return
        }

        // 1. Identify forwards to remove: either gone from 'new' or changed (remotePort)
        let toRemove = old.filter { oldF in
            guard let newF = new.first(where: { $0.id == oldF.id }) else { return true }
            return newF.remotePort != oldF.remotePort
        }
        for f in toRemove {
            if let lp = f.localPort {
                _ = await masterClient.removeForward(
                    remotePort: f.remotePort,
                    localPort: lp,
                    target: quickForwardControlTarget,
                    controlPath: settings.expandedControlPath
                )
                appliedQuickForwards.removeAll { $0.localPort == lp && $0.remotePort == f.remotePort }
            }
        }

        // 2. Identify forwards to add: either new or changed (remotePort)
        var updatedNew = new
        var changed = false
        for i in updatedNew.indices {
            let isNew = !old.contains(where: { $0.id == updatedNew[i].id })
            let remoteChanged = old.first(where: { $0.id == updatedNew[i].id })?.remotePort != updatedNew[i].remotePort
            
            if isNew || remoteChanged {
                if updatedNew[i].localPort == nil {
                    if let freePort = await portChecker.findFreePort(in: 1024...65535) {
                        updatedNew[i].localPort = freePort
                        changed = true
                    }
                }
                
                if let lp = updatedNew[i].localPort {
                    _ = await masterClient.addForward(
                        remotePort: updatedNew[i].remotePort,
                        localPort: lp,
                        target: quickForwardControlTarget,
                        controlPath: settings.expandedControlPath
                    )
                    appliedQuickForwards.removeAll { $0.localPort == lp && $0.remotePort == updatedNew[i].remotePort }
                    appliedQuickForwards.append(updatedNew[i])
                }
            }
        }

        if changed {
            var finalSettings = settings
            finalSettings.quickForwards = updatedNew
            settings = finalSettings
            // Notify manager to persist these updated settings (with assigned local ports)
            NotificationCenter.default.post(name: .tunnelSettingsChanged, object: finalSettings)
        }
    }

    private func applyAllQuickForwards() async {
        // Cancel forwards we previously pushed onto this (possibly adopted)
        // master that are no longer desired. Without this an adopted master
        // keeps the orphaned local port open after a quick forward is removed
        // while the tunnel wasn't `.connected`.
        await cancelStaleQuickForwards(desired: settings.quickForwards)

        var updatedForwards = settings.quickForwards
        var changed = false
        var errors: [String] = []

        for i in updatedForwards.indices {
            if updatedForwards[i].localPort == nil {
                if let freePort = await portChecker.findFreePort(in: 1024...65535) {
                    updatedForwards[i].localPort = freePort
                    changed = true
                }
            }

            if let lp = updatedForwards[i].localPort {
                let result = await masterClient.addForward(
                    remotePort: updatedForwards[i].remotePort,
                    localPort: lp,
                    target: quickForwardControlTarget,
                    controlPath: settings.expandedControlPath
                )
                if result.exitCode != 0 {
                    let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    log(.warning, .forward, "quick forward \(lp)->\(updatedForwards[i].remotePort) failed (exit \(result.exitCode)): \(err.isEmpty ? "(no stderr)" : err)")
                    errors.append("Failed to forward remote port \(updatedForwards[i].remotePort) to localhost:\(lp): \(err.isEmpty ? "Unknown error" : err)")
                } else {
                    log(.info, .forward, "quick forward established \(lp)->\(updatedForwards[i].remotePort)")
                }
            }
        }
        appliedQuickForwards = updatedForwards.filter { $0.localPort != nil }
        if changed {
            settings.quickForwards = updatedForwards
            NotificationCenter.default.post(name: .tunnelSettingsChanged, object: settings)
        }
        
        if !errors.isEmpty {
            lastError = errors.joined(separator: "\n")
        }
    }

    /// Cancel forwards present on the current master that are no longer in the
    /// desired set, matching on the concrete local+remote port pair.
    private func cancelStaleQuickForwards(desired: [QuickForward]) async {
        let stale = appliedQuickForwards.filter { applied in
            guard let lp = applied.localPort else { return false }
            return !desired.contains { $0.localPort == lp && $0.remotePort == applied.remotePort }
        }
        for f in stale {
            guard let lp = f.localPort else { continue }
            log(.info, .forward, "cancelling stale quick forward \(lp)->\(f.remotePort) (no longer in settings)")
            _ = await masterClient.removeForward(
                remotePort: f.remotePort,
                localPort: lp,
                target: quickForwardControlTarget,
                controlPath: settings.expandedControlPath
            )
        }
        appliedQuickForwards.removeAll { stale.contains($0) }
    }

    private func assignMissingQuickForwardPorts() async {
        var updatedForwards = settings.quickForwards
        var changed = false
        for i in updatedForwards.indices {
            if updatedForwards[i].localPort == nil {
                if let freePort = await portChecker.findFreePort(in: 1024...65535) {
                    updatedForwards[i].localPort = freePort
                    changed = true
                }
            }
        }
        if changed {
            settings.quickForwards = updatedForwards
            NotificationCenter.default.post(name: .tunnelSettingsChanged, object: settings)
        }
    }

    /// Read `LocalForward` (and other options) from `~/.ssh/config` for this
    /// tunnel's host alias and cache the result, without starting a master.
    /// Idempotent: returns immediately if options are already cached.
    func loadResolvedOptions() async {
        if resolvedOptions != nil { return }
        resolvedOptions = await masterClient.resolveOptions(forHost: settings.hostAlias)
        if resolvedOptions == nil {
            logger.log(.debug, .master, tunnel: settings.name, "loadResolvedOptions: ssh_config not resolvable for \(settings.hostAlias) yet")
        }
    }

    func startTunnel() async {
        await startTunnel(allowRestartWhileActive: false)
    }

    private func startTunnel(allowRestartWhileActive: Bool) async {
        if !allowRestartWhileActive, isActive {
            logger.log(.debug, .lifecycle, tunnel: settings.name, "startTunnel ignored — already active (\(state.label))")
            return
        }

        attemptID = String(UUID().uuidString.prefix(8))
        let signpostState = signposter.beginInterval(
            "startTunnel",
            id: signposter.makeSignpostID(),
            "host: \(self.settings.hostAlias, privacy: .public), attempt: \(self.attemptID, privacy: .public)"
        )
        defer { signposter.endInterval("startTunnel", signpostState) }

        log(.info, .lifecycle, "startTunnel host=\(settings.hostAlias) allowRestartWhileActive=\(allowRestartWhileActive) attempt=\(reconnectAttempt)")
        hasRequestedConnection = true
        userInitiatedStop = false
        reconnectTask?.cancel()
        nextReconnectAt = nil
        // A fresh start (user toggle, autostart, or network/wake recovery) must
        // not be capped by the previous run's backoff counter. Without this
        // reset, a tunnel that exhausted its 10 reconnect attempts during a
        // login-time network outage would refuse to come back up even when the
        // user (or NetworkMonitor) explicitly asks for a new start.
        if !allowRestartWhileActive {
            reconnectAttempt = 0
        }
        state = .connecting
        lastError = nil

        // Resolve effective ssh options first so we can:
        // (a) expand %-tokens in the control path for our own FileManager ops
        // (b) know the LocalForward ports up front
        // (c) detect collision with a ControlPath the user has in ~/.ssh/config
        resolvedOptions = await {
            let interval = signposter.beginInterval(
                "resolveOptions",
                id: signposter.makeSignpostID(),
                "host: \(self.settings.hostAlias, privacy: .public)"
            )
            defer { signposter.endInterval("resolveOptions", interval) }
            return await masterClient.resolveOptions(forHost: settings.hostAlias)
        }()
        if resolvedOptions == nil {
            log(.warning, .master, "resolveOptions returned nil — ssh_config not resolvable yet (common at login before network/DNS is ready)")
        }

        if let collision = detectControlPathCollision() {
            log(.error, .master, "control path collision — refusing to start")
            markFailed(collision)
            return
        }

        // ADOPT-OR-CLEAN. If a master is already alive at our control path —
        // e.g. left behind by a previous app run that didn't quit cleanly —
        // don't kill it. Take it over. This is what stops the app from
        // sniping its own running tunnel on relaunch.
        let preCheck = await masterClient.check(
            host: settings.hostAlias,
            controlPath: settings.expandedControlPath,
            timeout: 2
        )
        if preCheck.exitCode == 0 {
            log(.notice, .master, "adopting existing master at \(settings.expandedControlPath)")
            state = .connected
            reconnectAttempt = 0
            lastError = nil
            nextReconnectAt = nil

            // Apply quick forwards to ensure they are present on the adopted master
            await applyAllQuickForwards()

            // The forwards belong to a process we don't own — probe them so we
            // catch the case where the master is alive but the forwards aren't.
            await reconnectIfForwardsDead()
            return
        }

        // No live master. Wipe any dangling socket file before we spawn.
        try? FileManager.default.removeItem(atPath: filesystemControlPath)
        // A freshly spawned master has no forwards yet — forget anything we
        // tracked against a previous (now dead) master.
        appliedQuickForwards = []

        // Assign local ports to quick forwards if they don't have one yet,
        // so we can check them for conflicts.
        await assignMissingQuickForwardPorts()

        // Preflight: make sure every LocalForward port is actually free.
        // OpenSSH would bail with `bind: Address already in use` and
        // ExitOnForwardFailure would tear the master down — we'd reconnect-loop
        // for nothing. The resolver also reaps orphan ssh processes left over
        // from a previous run of this app.
        let plannedPorts = forwardedPorts
        if !plannedPorts.isEmpty {
            switch await portResolver().resolve(among: plannedPorts) {
            case .free:
                break
            case .transientSshConflict(let conflict):
                log(.notice, .ports, "transient ssh port conflict on \(plannedPorts) — will retry: \(conflict.userMessage)")
                failStartAndMaybeReconnect(
                    conflict.userMessage,
                    isAutomaticReconnect: allowRestartWhileActive
                )
                return
            case .foreignConflict(let conflict):
                log(.error, .ports, "foreign port conflict on \(plannedPorts): \(conflict.userMessage)")
                markFailed(conflict.userMessage)
                return
            }
        }

        let handle: SSHLongRunningProcess
        do {
            handle = try masterClient.startMaster(
                host: settings.hostAlias,
                controlPath: settings.expandedControlPath
            )
        } catch {
            failStartAndMaybeReconnect("Failed to spawn ssh: \(error)", isAutomaticReconnect: allowRestartWhileActive)
            return
        }
        masterHandle = handle

        // Wait for the control socket to become responsive, but bail out early
        // if ssh itself exits (auth failure, ExitOnForwardFailure, etc.).
        let connected = await waitForMasterReady(handle: handle)

        if connected {
            log(.info, .master, "master ready — connection established")
            // Refresh options once the connection is fully established (rare
            // case: -G earlier returned non-zero, e.g. unresolved Match block).
            if resolvedOptions == nil {
                resolvedOptions = await masterClient.resolveOptions(forHost: settings.hostAlias)
            }
            state = .connected
            reconnectAttempt = 0
            lastError = nil
            nextReconnectAt = nil

            // Apply quick forwards
            await applyAllQuickForwards()

            watchMaster(handle: handle)
        } else {
            let stderr = handle.collectStderr().trimmingCharacters(in: .whitespacesAndNewlines)
            log(.warning, .master, "master failed to become ready: \(stderr.isEmpty ? "(no stderr)" : stderr)")
            if handle.isRunning { handle.terminate() }
            masterHandle = nil
            failStartAndMaybeReconnect(
                stderr.isEmpty ? "ssh failed to establish control connection" : stderr,
                isAutomaticReconnect: allowRestartWhileActive
            )
        }
    }

    /// Failure path for `startTunnel` that should be retried. Startup races
    /// against boot-time DNS/agent/VPN warm-up, and a single early ssh failure
    /// is common on cold Mac boots. Transient network errors stay silent while
    /// `scheduleReconnect` handles backoff and the final give-up notification.
    /// If the user has explicitly stopped the tunnel, we just park in `.failed`.
    private func failStartAndMaybeReconnect(_ detail: String, isAutomaticReconnect: Bool) {
        lastError = detail

        let willGiveUp = reconnectAttempt >= maxReconnectAttempts
        if !willGiveUp && shouldNotifyStartFailure(detail, isAutomaticReconnect: isAutomaticReconnect) {
            notifier.sendTunnelFailedNotification(for: settings, detail: detail)
        }

        if userInitiatedStop || !hasRequestedConnection {
            state = .failed
            return
        }
        scheduleReconnect()
    }

    private func shouldNotifyStartFailure(_ detail: String, isAutomaticReconnect: Bool) -> Bool {
        if isAutomaticReconnect { return false }
        return SSHErrorClassifier.isActionableConfigurationError(detail)
    }

    func stopTunnel() async {
        log(.info, .lifecycle, "stopTunnel (user-initiated)")
        hasRequestedConnection = false
        userInitiatedStop = true
        reconnectTask?.cancel()
        masterWatchTask?.cancel()
        masterWatchTask = nil
        nextReconnectAt = nil
        reconnectAttempt = 0  // user took manual control — fresh start next time

        // Best-effort graceful close via control command (with timeout).
        _ = await masterClient.exit(host: settings.hostAlias, controlPath: settings.expandedControlPath)

        if let handle = masterHandle {
            if handle.isRunning {
                handle.terminate()
                _ = await waitWithTimeout(handle: handle, seconds: 2)
                if handle.isRunning {
                    handle.killHard()
                }
            }
        }
        masterHandle = nil
        try? FileManager.default.removeItem(atPath: filesystemControlPath)
        appliedQuickForwards = []
        state = .disconnected
        lastError = nil
    }

    func refreshState() async {
        _ = await refreshState(recordFailure: hasRequestedConnection && !userInitiatedStop)
    }

    @discardableResult
    private func refreshState(recordFailure: Bool) async -> SSHResult {
        let result = await masterClient.check(
            host: settings.hostAlias,
            controlPath: settings.expandedControlPath,
            timeout: 3
        )
        if result.exitCode == 0 {
            // We found a live master — either one we started in this process,
            // or a leftover from a previous app run. In the latter case we have
            // never resolved the host options, so `forwardedPorts` would be
            // empty and the UI would falsely say "no LocalForward configured".
            if resolvedOptions == nil {
                resolvedOptions = await masterClient.resolveOptions(forHost: settings.hostAlias)
            }
            if state != .connected { state = .connected }
            lastError = nil
            nextReconnectAt = nil
        } else {
            if recordFailure, let detail = SSHErrorClassifier.detail(from: result) {
                lastError = detail
            }
            switch state {
            case .connecting, .reconnecting:
                break
            default:
                state = .disconnected
            }
        }
        return result
    }

    func checkTunnelHealth() async {
        await checkTunnelHealth(notifyWhenDisconnected: false)
    }

    func checkNow() async {
        await checkTunnelHealth(notifyWhenDisconnected: true)
        // Always give user feedback for an explicit "Check Now" — even when
        // everything is fine.
        if state == .connected {
            let detail: String
            if forwardedPorts.isEmpty {
                detail = "No forwarded ports configured."
            } else {
                detail = "localhost:" + forwardedPorts.map(String.init).joined(separator: ", ")
            }
            notifier.sendCheckResultNotification(for: settings, ok: true, detail: detail)
        } else {
            let detail = lastError?.isEmpty == false ? lastError! : "Tunnel is not connected."
            notifier.sendCheckResultNotification(for: settings, ok: false, detail: detail)
        }
    }

    func stopMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        reconnectTask?.cancel()
        masterWatchTask?.cancel()
        nextReconnectAt = nil
    }

    /// Synchronous best-effort cleanup for `applicationWillTerminate`. We cannot
    /// await here because the run loop is being torn down.
    func terminateMasterForShutdown() {
        masterWatchTask?.cancel()
        guard isActive || wantsToBeConnected else { return }
        _ = masterClient.exitSynchronously(
            host: settings.hostAlias,
            controlPath: settings.expandedControlPath,
            timeout: 1
        )
        if let handle = masterHandle, handle.isRunning {
            handle.terminate()
        }
        try? FileManager.default.removeItem(atPath: filesystemControlPath)
    }

    /// Kills any handle that's still running, then SIGKILL fallback. Caller is
    /// expected to have allowed a few seconds between the `terminate` call and
    /// this one.
    func killMasterIfStillRunning() {
        if let handle = masterHandle, handle.isRunning {
            handle.killHard()
        }
    }

    var hasRunningMaster: Bool {
        masterHandle?.isRunning ?? false
    }

    private func startHealthCheckTask() {
        healthCheckTask?.cancel()
        let interval = settings.healthCheckInterval
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.checkTunnelHealth()
            }
        }
    }

    private func checkTunnelHealth(notifyWhenDisconnected: Bool) async {
        let wasConnected = (state == .connected)
        let wasFailed = (state == .failed)
        let result = await refreshState(
            recordFailure: notifyWhenDisconnected || (hasRequestedConnection && !userInitiatedStop)
        )

        // Even if `-O check` says OK, probe each forwarded port — the master can
        // be alive while forwards are dead on a half-broken network.
        if state == .connected, !forwardedPorts.isEmpty {
            if let unreachablePort = await forwardHealthChecker.firstUnreachablePort(among: forwardedPorts, timeout: 1) {
                // The master itself is alive (it answered `-O check`), only a
                // forward is dead. Tearing the tunnel down here would schedule a
                // reconnect that just re-adopts the same live master and finds
                // the same dead forward → endless reconnect loop. Instead,
                // re-establish the forwards on the live master and re-probe.
                log(.notice, .forward, "forward port \(unreachablePort) unreachable on live master — re-establishing forwards")
                await repairDeadForwards()
                if let stillDead = await forwardHealthChecker.firstUnreachablePort(among: forwardedPorts, timeout: 1) {
                    state = .disconnected
                    lastError = "Local forward port \(stillDead) is not reachable"
                }
            }
        }

        let needsReconnect = !userInitiatedStop
            && hasRequestedConnection
            && state != .connected
            && (wasConnected || wasFailed)

        if needsReconnect {
            // Only the monitoring-driven drop gets the "interrupted" message.
            // User-initiated checks get their own dedicated notification in
            // checkNow() so the wording matches the situation.
            let detail = lastError ?? SSHErrorClassifier.detail(from: result) ?? ""
            if wasConnected && !SSHErrorClassifier.isTransientNetworkError(detail) {
                notifier.sendTunnelInterruptedNotification(for: settings)
            }
            scheduleReconnect()
        }
    }

    /// Used on adoption: we already know the master answers `-O check` but the
    /// forwards may still be dead. One probe pass; on failure, re-establish the
    /// forwards on the live master and re-probe. Only if a forward is still dead
    /// do we drop the adopted status and schedule a fresh reconnect — otherwise
    /// the reconnect would just re-adopt the same master and loop forever.
    private func reconnectIfForwardsDead() async {
        guard !forwardedPorts.isEmpty else { return }
        if let unreachablePort = await forwardHealthChecker.firstUnreachablePort(among: forwardedPorts, timeout: 1) {
            log(.notice, .forward, "adopted master forward port \(unreachablePort) unreachable — re-establishing forwards")
            await repairDeadForwards()
            if let stillDead = await forwardHealthChecker.firstUnreachablePort(among: forwardedPorts, timeout: 1) {
                lastError = "Local forward port \(stillDead) is not reachable"
                state = .disconnected
                scheduleReconnect()
            }
        }
    }

    /// Re-issues `-O forward` for every known forward on the current live
    /// master. Used to self-heal forwards that died (e.g. a config LocalForward
    /// whose local port was cancelled because it collided with a removed quick
    /// forward) without tearing down the still-healthy master.
    private func repairDeadForwards() async {
        for info in forwardInfos {
            guard let remotePort = info.remotePort else { continue }
            _ = await masterClient.addForward(
                remotePort: remotePort,
                localPort: info.localPort,
                target: quickForwardControlTarget,
                controlPath: settings.expandedControlPath
            )
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        if reconnectAttempt >= maxReconnectAttempts {
            let base = lastError ?? "Tunnel failed"
            log(.error, .reconnect, "giving up after \(maxReconnectAttempts) reconnect attempts")
            markFailed(base + " — gave up after \(maxReconnectAttempts) reconnect attempts. Toggle the tunnel off and on to retry.")
            return
        }
        state = .reconnecting
        let maxBackoff = settings.maxBackoff
        let backoff = min(maxBackoff, 5.0 * pow(2.0, Double(reconnectAttempt)))
        nextReconnectAt = Date().addingTimeInterval(backoff)
        reconnectAttempt += 1
        log(.notice, .reconnect, "scheduling reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(String(format: "%.1f", backoff))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoff))
            guard let self, !Task.isCancelled else { return }
            await self.startTunnel(allowRestartWhileActive: true)
        }
    }

    private func markFailed(_ detail: String, notify: Bool = true) {
        lastError = detail
        state = .failed
        nextReconnectAt = nil
        if notify {
            notifier.sendTunnelFailedNotification(for: settings, detail: detail)
        }
    }

    /// Returns a human-readable error message if the user has a `ControlPath`
    /// in their ~/.ssh/config that resolves to the same file we'd use. In that
    /// case, the existing socket may belong to an interactive `ssh <alias>`
    /// session and we must not touch it.
    private func detectControlPathCollision() -> String? {
        guard let opts = resolvedOptions, !opts.userControlPath.isEmpty else {
            return nil
        }
        let userPath = ControlPathExpander.expand(template: opts.userControlPath, options: opts)
        let ourPath = filesystemControlPath
        guard userPath == ourPath else { return nil }
        return """
        Control Path collision: your ~/.ssh/config also uses
        \(userPath)
        for host \(settings.hostAlias). Starting the tunnel here would interfere with \
        terminal `ssh \(settings.hostAlias)` sessions. Pick a different Control Path \
        in Settings — the default (~/.ssh/control-sshtunnelapp-%C) is namespaced to \
        avoid this.
        """
    }

    private func portResolver() -> PortConflictResolver {
        PortConflictResolver(
            portChecker: portChecker,
            portReleaseGrace: portReleaseGrace,
            hostAlias: settings.hostAlias,
            sshControlPath: settings.expandedControlPath,
            filesystemControlPath: filesystemControlPath
        )
    }

    /// Host spec used for `-O forward`/`-O cancel` control commands. We always
    /// use the *alias* (reading ssh_config), exactly like the master spawn and
    /// the `-O check` probe do. That guarantees ssh recomputes the same
    /// `%C`/`%h` ControlPath tokens — and therefore reaches the very socket the
    /// master created. Using a `-F /dev/null` resolved target instead made ssh
    /// derive a *different* `%C` (and dropped ProxyJump from the hash), so the
    /// forward looked for a socket that doesn't exist ("Control socket
    /// connect(...): No such file or directory").
    private var quickForwardControlTarget: SSHControlTarget {
        .configured(hostAlias: settings.hostAlias)
    }

    private func waitForMasterReady(handle: SSHLongRunningProcess) async -> Bool {
        let interval = signposter.beginInterval(
            "waitForMasterReady",
            id: signposter.makeSignpostID(),
            "host: \(self.settings.hostAlias, privacy: .public)"
        )
        defer { signposter.endInterval("waitForMasterReady", interval) }
        return await waitForMasterReadyLoop(handle: handle)
    }

    private func waitForMasterReadyLoop(handle: SSHLongRunningProcess) async -> Bool {
        let maxWait: TimeInterval = 15
        let pollInterval: TimeInterval = 0.5
        var elapsed: TimeInterval = 0
        while elapsed < maxWait {
            if Task.isCancelled { return false }
            if !handle.isRunning { return false }
            let check = await masterClient.check(
                host: settings.hostAlias,
                controlPath: settings.expandedControlPath,
                timeout: 2
            )
            if check.exitCode == 0 {
                return true
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(pollInterval))
            elapsed += pollInterval
        }
        return false
    }

    private func watchMaster(handle: SSHLongRunningProcess) {
        masterWatchTask?.cancel()
        masterWatchTask = Task { @MainActor [weak self] in
            let exitCode = await handle.waitForExit()
            guard let self else { return }
            guard self.masterHandle === handle else { return }
            self.masterHandle = nil
            if self.userInitiatedStop { return }
            let stderr = handle.collectStderr().trimmingCharacters(in: .whitespacesAndNewlines)
            self.log(.warning, .master, "master exited (code \(exitCode)): \(stderr.isEmpty ? "(no stderr)" : stderr)")
            self.lastError = stderr.isEmpty
                ? "ssh master exited (code \(exitCode))"
                : stderr
            self.state = .disconnected
            // NB: we deliberately keep `resolvedOptions` here. The ssh_config
            // entry hasn't changed just because the master crashed, and
            // dropping it would briefly empty the row's forwarded-port list
            // mid-reconnect.
            if !SSHErrorClassifier.isTransientNetworkError(self.lastError ?? "") {
                self.notifier.sendTunnelInterruptedNotification(for: self.settings)
            }
            self.scheduleReconnect()
        }
    }

    private func waitWithTimeout(handle: SSHLongRunningProcess, seconds: TimeInterval) async -> Bool {
        await withTimeout(seconds: seconds, default: false) {
            _ = await handle.waitForExit()
            return true
        }
    }

}

private enum SSHErrorClassifier {
    static func detail(from result: SSHResult) -> String? {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return nil
    }

    static func isTransientNetworkError(_ detail: String) -> Bool {
        containsAny(detail, transientNetworkPatterns)
    }

    static func isActionableConfigurationError(_ detail: String) -> Bool {
        containsAny(detail, actionableConfigurationPatterns)
    }

    private static func containsAny(_ detail: String, _ patterns: [String]) -> Bool {
        patterns.contains { detail.localizedCaseInsensitiveContains($0) }
    }

    private static let transientNetworkPatterns = [
        "nodename nor servname provided",
        "no route to host",
        "network is unreachable",
        "operation timed out",
        "connection timed out",
        "connect timed out",
        "connection refused",
        "connection closed by remote host",
        "connection reset by peer",
        "could not resolve hostname",
        "temporary failure in name resolution",
        "name or service not known"
    ]

    private static let actionableConfigurationPatterns = [
        "failed to spawn ssh",
        "permission denied",
        "publickey",
        "authentication failed",
        "too many authentication failures",
        "bad configuration option",
        "configuration file",
        "identity file",
        "no such identity",
        "no identities loaded",
        "host key verification failed"
    ]
}
