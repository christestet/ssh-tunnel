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
    public let label: String?

    public init(localPort: Int, remotePort: Int? = nil, label: String? = nil) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.label = label
    }
}
