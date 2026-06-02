import Foundation
import Darwin

enum PortConflictResolution: Equatable, Sendable {
    case free
    case transientSshConflict(PortConflict)
    case foreignConflict(PortConflict)
}

struct TunnelProcessIdentity: Equatable, Sendable {
    let hostAlias: String
    let sshControlPath: String
    let filesystemControlPath: String

    func matches(_ values: [String]?) -> Bool {
        guard let values else { return false }
        return values.contains { value in
            value == sshControlPath
                || value == filesystemControlPath
                || value == hostAlias
                || value.contains(filesystemControlPath)
        }
    }
}

enum PortConflictClassifier {
    static func resolution(
        for conflict: PortConflict,
        identity: TunnelProcessIdentity
    ) -> PortConflictResolution {
        if isTransientSshHolder(conflict, identity: identity) {
            return .transientSshConflict(conflict)
        }
        return .foreignConflict(conflict)
    }

    static func isSshHolder(_ conflict: PortConflict) -> Bool {
        guard let command = conflict.command else { return false }
        return command.localizedCaseInsensitiveContains("ssh")
    }

    private static func isTransientSshHolder(
        _ conflict: PortConflict,
        identity: TunnelProcessIdentity
    ) -> Bool {
        guard isSshHolder(conflict) else { return false }
        if conflict.commandArgs == nil, conflict.openFiles == nil { return true }
        return identity.matches(conflict.commandArgs)
            || identity.matches(conflict.openFiles)
    }
}

/// Pre-flight gate for local forward ports. Distinguishes between:
///  - app-owned orphans, which are terminated so the app can re-bind
///  - transient ssh holders, which should be retried through reconnect backoff
///  - foreign holders, which become user-visible failures
struct PortConflictResolver {
    let portChecker: PortAvailabilityChecking
    let portReleaseGrace: TimeInterval
    let hostAlias: String
    let sshControlPath: String
    let filesystemControlPath: String

    private var identity: TunnelProcessIdentity {
        TunnelProcessIdentity(
            hostAlias: hostAlias,
            sshControlPath: sshControlPath,
            filesystemControlPath: filesystemControlPath
        )
    }

    /// Returns a semantic resolution after orphan reaping and, for ssh holders,
    /// a short grace wait for the port to be released.
    func resolve(among ports: [Int]) async -> PortConflictResolution {
        guard var conflict = await portChecker.firstConflict(among: ports) else {
            return .free
        }

        if let pid = conflict.pid, isOurOrphan(conflict) {
            kill(pid_t(pid), SIGTERM)
            try? await Task.sleep(for: .milliseconds(800))
            if let still = await portChecker.firstConflict(among: ports), still.pid == pid {
                kill(pid_t(pid), SIGKILL)
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let after = await portChecker.firstConflict(among: ports) else {
                return .free
            }
            conflict = after
        }

        guard shouldWaitForPortRelease(conflict) else {
            return resolution(for: conflict)
        }

        let deadline = Date().addingTimeInterval(portReleaseGrace)
        let retryInterval = min(0.2, max(0.01, portReleaseGrace / 4))
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(retryInterval))
            guard let next = await portChecker.firstConflict(among: ports) else {
                return .free
            }
            conflict = next
        }
        return resolution(for: conflict)
    }

    private func isOurOrphan(_ conflict: PortConflict) -> Bool {
        guard PortConflictClassifier.isSshHolder(conflict) else { return false }
        return identity.matches(conflict.commandArgs)
            || identity.matches(conflict.openFiles)
    }

    private func shouldWaitForPortRelease(_ conflict: PortConflict) -> Bool {
        guard portReleaseGrace > 0 else { return false }
        if conflict.command == nil { return true }
        return PortConflictClassifier.isSshHolder(conflict)
    }

    private func resolution(for conflict: PortConflict) -> PortConflictResolution {
        PortConflictClassifier.resolution(for: conflict, identity: identity)
    }
}
