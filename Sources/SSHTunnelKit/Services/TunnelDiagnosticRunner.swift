import Foundation

enum TunnelDiagnosticStatus: Equatable, Sendable {
    case ok
    case warning
    case failed
    case skipped
}

struct TunnelDiagnosticItem: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let status: TunnelDiagnosticStatus
    let detail: String
}

struct TunnelDiagnosticReport: Equatable, Sendable {
    let tunnelName: String
    let hostAlias: String
    let items: [TunnelDiagnosticItem]

    var overallStatus: TunnelDiagnosticStatus {
        if items.contains(where: { $0.status == .failed }) { return .failed }
        if items.contains(where: { $0.status == .warning }) { return .warning }
        return .ok
    }
}

protocol ControlPathDirectoryChecking: Sendable {
    func directoryExists(atPath path: String) -> Bool
}

struct LocalControlPathDirectoryChecker: ControlPathDirectoryChecking {
    func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct TunnelDiagnosticRunner: Sendable {
    private let sshRunner: any SSHRunning
    private let portChecker: any PortAvailabilityChecking
    private let directoryChecker: any ControlPathDirectoryChecking

    init(
        sshRunner: any SSHRunning = ProcessSSHRunner(),
        portChecker: any PortAvailabilityChecking = LocalPortAvailabilityChecker(),
        directoryChecker: any ControlPathDirectoryChecking = LocalControlPathDirectoryChecker()
    ) {
        self.sshRunner = sshRunner
        self.portChecker = portChecker
        self.directoryChecker = directoryChecker
    }

    func diagnose(_ settings: TunnelSettings, isTunnelConnected: Bool = false) async -> TunnelDiagnosticReport {
        let normalized = settings.normalized
        var items: [TunnelDiagnosticItem] = []

        let fieldProblems = requiredFieldProblems(for: normalized)
        if fieldProblems.isEmpty {
            items.append(item("required-fields", "Required fields", .ok, "Name, Host Alias, control path, and timing settings look valid."))
        } else {
            items.append(item("required-fields", "Required fields", .failed, fieldProblems.joined(separator: " ")))
            return report(settings: normalized, items: items)
        }

        let config = await sshRunner.run(arguments: ["-G", normalized.hostAlias], timeout: 5)
        guard config.exitCode == 0 else {
            items.append(item("ssh-config", "SSH config", .failed, diagnosticDetail(from: config, fallback: "ssh -G failed.")))
            items.append(item("local-forwards", "SSH config forwards", .skipped, "Skipped because SSH config could not be resolved."))
            items.append(item("control-path", "Control path", .skipped, "Skipped because SSH config could not be resolved."))
            items.append(item("port-availability", "Port availability", .skipped, "Skipped because SSH config forwards are unknown."))
            return report(settings: normalized, items: items)
        }

        let options = SSHConfigInspector.parseOptions(from: config.stdout)
        let endpoint = resolvedEndpointDescription(options: options, hostAlias: normalized.hostAlias)
        items.append(item("ssh-config", "SSH config", .ok, "ssh -G resolved \(normalized.hostAlias) as \(endpoint)."))

        if options.forwardedPorts.isEmpty {
            items.append(item("local-forwards", "SSH config forwards", .failed, "No SSH config forwards were found for this host. Add TCP LocalForward directives in ~/.ssh/config."))
        } else {
            let ports = options.forwardedPorts.map(String.init).joined(separator: ", ")
            items.append(item("local-forwards", "SSH config forwards", .ok, "Found localhost ports: \(ports)."))
        }

        let filesystemControlPath = ControlPathExpander.expand(template: normalized.controlPath, options: options)
        let parentDirectory = NSString(string: filesystemControlPath).deletingLastPathComponent
        if directoryChecker.directoryExists(atPath: parentDirectory) {
            items.append(item("control-path", "Control path", .ok, filesystemControlPath))
        } else {
            items.append(item("control-path", "Control path", .failed, "Parent directory does not exist: \(parentDirectory)"))
        }

        if let collision = controlPathCollision(settings: normalized, options: options, filesystemControlPath: filesystemControlPath) {
            items.append(item("control-path-collision", "Control path collision", .failed, collision))
        } else {
            items.append(item("control-path-collision", "Control path collision", .ok, "No collision with the ControlPath resolved from ~/.ssh/config."))
        }

        let allPorts = Array(Set(options.forwardedPorts + normalized.quickForwards.compactMap { $0.localPort })).sorted()

        guard !allPorts.isEmpty else {
            items.append(item("port-availability", "Port availability", .skipped, "Skipped because there are no SSH config forwards or Quick Forward ports."))
            return report(settings: normalized, items: items)
        }

        if let conflict = await portChecker.firstConflict(among: allPorts) {
            let identity = TunnelProcessIdentity(
                hostAlias: normalized.hostAlias,
                sshControlPath: normalized.expandedControlPath,
                filesystemControlPath: filesystemControlPath
            )
            switch PortConflictClassifier.resolution(for: conflict, identity: identity) {
            case .free:
                items.append(item("port-availability", "Port availability", .ok, "All forwarded ports are currently free."))
            case .transientSshConflict where isTunnelConnected:
                items.append(item(
                    "port-availability",
                    "Port availability",
                    .ok,
                    "Local port \(conflict.port) is already held by the connected tunnel's ssh process\(pidDescription(conflict))."
                ))
            case .transientSshConflict, .foreignConflict:
                items.append(item("port-availability", "Port availability", .failed, conflict.userMessage))
            }
        } else {
            items.append(item("port-availability", "Port availability", .ok, "All forwarded ports are currently free."))
        }

        return report(settings: normalized, items: items)
    }

    private func requiredFieldProblems(for settings: TunnelSettings) -> [String] {
        var problems: [String] = []
        if settings.name.isEmpty { problems.append("Name is empty.") }
        if settings.hostAlias.isEmpty { problems.append("Host Alias cannot be empty.") }
        if settings.controlPath.isEmpty { problems.append("Control path is empty.") }
        if settings.healthCheckInterval <= 0 { problems.append("Health check interval must be greater than 0 seconds.") }
        if settings.maxBackoff <= 0 { problems.append("Max backoff must be greater than 0 seconds.") }
        if settings.maxBackoff > 0, settings.healthCheckInterval > 0, settings.maxBackoff < settings.healthCheckInterval {
            problems.append("Max backoff cannot be lower than the health check interval.")
        }
        return problems
    }

    private func controlPathCollision(
        settings: TunnelSettings,
        options: SSHHostOptions,
        filesystemControlPath: String
    ) -> String? {
        guard !options.userControlPath.isEmpty else { return nil }
        let userPath = ControlPathExpander.expand(template: options.userControlPath, options: options)
        guard userPath == filesystemControlPath else { return nil }
        return "The app Control Path and your ssh_config ControlPath resolve to the same file: \(userPath). Pick a different Control Path before starting \(settings.hostAlias)."
    }

    private func pidDescription(_ conflict: PortConflict) -> String {
        guard let pid = conflict.pid else { return "" }
        return " (PID \(pid))"
    }

    private func resolvedEndpointDescription(options: SSHHostOptions, hostAlias: String) -> String {
        let user = options.user.isEmpty ? "<default-user>" : options.user
        let host = options.hostname.isEmpty ? hostAlias : options.hostname
        return "\(user)@\(host):\(options.port)"
    }

    private func diagnosticDetail(from result: SSHResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return fallback
    }

    private func report(settings: TunnelSettings, items: [TunnelDiagnosticItem]) -> TunnelDiagnosticReport {
        TunnelDiagnosticReport(
            tunnelName: settings.name,
            hostAlias: settings.hostAlias,
            items: items
        )
    }

    private func item(
        _ id: String,
        _ title: String,
        _ status: TunnelDiagnosticStatus,
        _ detail: String
    ) -> TunnelDiagnosticItem {
        TunnelDiagnosticItem(id: id, title: title, status: status, detail: detail)
    }
}
