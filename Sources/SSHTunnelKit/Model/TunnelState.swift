public enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Failed"
        case .disconnected: return "Idle"
        }
    }
}

public struct ForwardInfo: Identifiable, Equatable {
    public var id: String { "\(localPort)" }
    public let localPort: Int
    public let remotePort: Int?
    /// Remote endpoint the forward connects to on the far side of the tunnel.
    /// `localhost` for quick forwards; config `LocalForward` lines may point at
    /// any host (e.g. `LocalForward 8080 db.internal:5432`). Defaults to
    /// `localhost` so quick-forward call sites need no change.
    public let remoteHost: String
    public let label: String?

    public init(localPort: Int, remotePort: Int? = nil, remoteHost: String = "localhost", label: String? = nil) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.remoteHost = remoteHost
        self.label = label
    }
}
