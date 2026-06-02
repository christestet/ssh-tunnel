import Foundation
import Observation

struct QuickForward: Codable, Equatable, Identifiable {
    var id: UUID
    var remotePort: Int
    var localPort: Int?
    var label: String

    private enum CodingKeys: String, CodingKey {
        case id, remotePort, localPort, label
    }

    init(id: UUID, remotePort: Int, localPort: Int?, label: String = "") {
        self.id = id
        self.remotePort = remotePort
        self.localPort = localPort
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        remotePort = try container.decode(Int.self, forKey: .remotePort)
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    static func makeDefault(remotePort: Int) -> QuickForward {
        QuickForward(id: UUID(), remotePort: remotePort, localPort: nil, label: "")
    }
}

struct LocalForwardLabel: Codable, Equatable, Identifiable {
    var localPort: Int
    var label: String

    var id: Int { localPort }
}

struct TunnelSettings: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var hostAlias: String
    var controlPath: String
    var healthCheckInterval: TimeInterval
    var maxBackoff: TimeInterval
    var autostartOnLogin: Bool
    var autostartReadinessProbeHost: String = ""
    var autostartReadinessProbePort: Int = 22
    var localForwardLabels: [LocalForwardLabel] = []
    var quickForwards: [QuickForward] = []

    static func makeDefault() -> TunnelSettings {
        TunnelSettings(
            id: UUID(),
            name: "New Tunnel",
            hostAlias: "",
            // App-specific namespace so we never collide with the user's own
            // ControlPath in ~/.ssh/config (which is typically
            // `~/.ssh/control-%C` or `~/.ssh/control-%r@%h:%p`). The %C hash
            // also separates same-host tunnels that differ by user or port.
            controlPath: "~/.ssh/control-sshtunnelapp-%C",
            healthCheckInterval: 15,
            maxBackoff: 60,
            autostartOnLogin: false,
            quickForwards: []
        )
    }

    var expandedControlPath: String {
        NSString(string: controlPath).expandingTildeInPath
    }

    var normalized: TunnelSettings {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hostAlias = hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.controlPath = controlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.autostartReadinessProbeHost = autostartReadinessProbeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.localForwardLabels = localForwardLabels.reduce(into: [LocalForwardLabel]()) { labels, entry in
            let trimmed = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let index = labels.firstIndex(where: { $0.localPort == entry.localPort }) {
                labels[index].label = trimmed
            } else {
                labels.append(LocalForwardLabel(localPort: entry.localPort, label: trimmed))
            }
        }
        copy.quickForwards = quickForwards.map { forward in
            var normalizedForward = forward
            normalizedForward.label = forward.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedForward
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostAlias, controlPath, healthCheckInterval, maxBackoff, autostartOnLogin
        case autostartReadinessProbeHost, autostartReadinessProbePort, localForwardLabels, quickForwards
    }
}

// Defined in an extension so the synthesized memberwise initializer survives.
extension TunnelSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostAlias = try container.decode(String.self, forKey: .hostAlias)
        controlPath = try container.decode(String.self, forKey: .controlPath)
        healthCheckInterval = try container.decode(TimeInterval.self, forKey: .healthCheckInterval)
        maxBackoff = try container.decode(TimeInterval.self, forKey: .maxBackoff)
        // Pre-1.x settings predate this flag — default it rather than fail.
        autostartOnLogin = try container.decodeIfPresent(Bool.self, forKey: .autostartOnLogin) ?? false
        autostartReadinessProbeHost = try container.decodeIfPresent(String.self, forKey: .autostartReadinessProbeHost) ?? ""
        autostartReadinessProbePort = try container.decodeIfPresent(Int.self, forKey: .autostartReadinessProbePort) ?? 22
        localForwardLabels = try container.decodeIfPresent([LocalForwardLabel].self, forKey: .localForwardLabels) ?? []
        quickForwards = try container.decodeIfPresent([QuickForward].self, forKey: .quickForwards) ?? []
    }
}

extension Notification.Name {
    static let tunnelSettingsChanged = Notification.Name("tunnelSettingsChanged")
    static let saveCurrentTunnelSettings = Notification.Name("saveCurrentTunnelSettings")
}

@MainActor
@Observable
public final class TunnelSettingsStore {
    var tunnels: [TunnelSettings]

    private let defaults: UserDefaults
    private let key = "TunnelSettingsMulti"
    /// Old default before we namespaced the control path. Settings that still
    /// have this exact value get upgraded transparently — the old default
    /// collides with the typical user ssh_config and we have no business
    /// preserving an unsafe value.
    private static let unsafeLegacyControlPath = "~/.ssh/control-%h"
    private static let previousNamespacedDefaultControlPath = "~/.ssh/control-sshtunnelapp-%h"

    /// Test-only initializer that skips UserDefaults entirely.
    init(tunnels: [TunnelSettings]) {
        self.defaults = UserDefaults()
        self.tunnels = tunnels
    }

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded: [TunnelSettings]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([TunnelSettings].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }

        let (migrated, didChange) = Self.upgradeLegacyControlPaths(loaded)
        tunnels = migrated
        if didChange {
            persist()
        }
    }

    private static func upgradeLegacyControlPaths(_ tunnels: [TunnelSettings]) -> ([TunnelSettings], Bool) {
        let newDefault = TunnelSettings.makeDefault().controlPath
        var changed = false
        let migrated = tunnels.map { tunnel -> TunnelSettings in
            guard tunnel.controlPath == unsafeLegacyControlPath
                    || tunnel.controlPath == previousNamespacedDefaultControlPath else { return tunnel }
            changed = true
            var updated = tunnel
            updated.controlPath = newDefault
            return updated
        }
        return (migrated, changed)
    }

    @discardableResult
    func save(_ settings: TunnelSettings) throws -> TunnelSettings {
        let normalized = settings.normalized
        try validate(normalized)
        if let idx = tunnels.firstIndex(where: { $0.id == normalized.id }) {
            tunnels[idx] = normalized
        } else {
            tunnels.append(normalized)
        }
        persist()
        return normalized
    }

    func addTunnel() -> TunnelSettings {
        let tunnel = TunnelSettings.makeDefault()
        tunnels.append(tunnel)
        persist()
        return tunnel
    }

    func removeTunnel(id: UUID) {
        tunnels.removeAll { $0.id == id }
        persist()
    }

    func moveTunnels(fromOffsets source: IndexSet, toOffset destination: Int) {
        tunnels.moveElements(fromOffsets: source, toOffset: destination)
        persist()
    }

    func tunnel(for id: UUID) -> TunnelSettings? {
        tunnels.first { $0.id == id }
    }

    var autostartTunnels: [TunnelSettings] {
        tunnels.filter(\.autostartOnLogin)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tunnels) {
            defaults.set(data, forKey: key)
        }
    }

    func validate(_ candidate: TunnelSettings) throws {
        if candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TunnelSettingsValidationError.emptyName
        }
        let trimmedHostAlias = candidate.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHostAlias.isEmpty {
            throw TunnelSettingsValidationError.emptyHostAlias
        }
        // A host alias is passed positionally to `ssh`, which has no `--` to end
        // option parsing. An alias beginning with `-` would be interpreted as an
        // ssh option (argument injection), so reject it up front.
        if trimmedHostAlias.hasPrefix("-") {
            throw TunnelSettingsValidationError.hostAliasLooksLikeOption
        }
        if candidate.controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TunnelSettingsValidationError.emptyControlPath
        }
        if candidate.healthCheckInterval <= 0 {
            throw TunnelSettingsValidationError.invalidHealthCheckInterval
        }
        if candidate.maxBackoff <= 0 {
            throw TunnelSettingsValidationError.invalidMaxBackoff
        }
        if candidate.maxBackoff < candidate.healthCheckInterval {
            throw TunnelSettingsValidationError.backoffBelowHealthCheck
        }
        if !candidate.autostartReadinessProbeHost.isEmpty,
           !(1...65535).contains(candidate.autostartReadinessProbePort) {
            throw TunnelSettingsValidationError.invalidAutostartReadinessPort
        }
    }
}

private extension Array {
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let indexes = source.sorted()
        guard !indexes.isEmpty, indexes.allSatisfy(indices.contains) else { return }

        let moving = indexes.map { self[$0] }
        for index in indexes.reversed() {
            remove(at: index)
        }

        let removedBeforeDestination = indexes.filter { $0 < destination }.count
        let adjustedDestination = Swift.max(0, Swift.min(count, destination - removedBeforeDestination))
        insert(contentsOf: moving, at: adjustedDestination)
    }
}

enum TunnelSettingsValidationError: LocalizedError, Equatable {
    case emptyName
    case emptyHostAlias
    case hostAliasLooksLikeOption
    case emptyControlPath
    case invalidHealthCheckInterval
    case invalidMaxBackoff
    case backoffBelowHealthCheck
    case invalidAutostartReadinessPort

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Tunnel name cannot be empty."
        case .emptyHostAlias:
            return "Host alias cannot be empty."
        case .hostAliasLooksLikeOption:
            return "Host alias cannot start with “-” (it would be read as an ssh option)."
        case .emptyControlPath:
            return "Control path cannot be empty."
        case .invalidHealthCheckInterval:
            return "Health check interval must be greater than 0 seconds."
        case .invalidMaxBackoff:
            return "Max reconnect backoff must be greater than 0 seconds."
        case .backoffBelowHealthCheck:
            return "Max reconnect backoff cannot be lower than the health check interval."
        case .invalidAutostartReadinessPort:
            return "Startup check port must be between 1 and 65535."
        }
    }
}
