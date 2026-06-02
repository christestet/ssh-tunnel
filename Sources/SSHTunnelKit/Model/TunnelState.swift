import AppKit
import SwiftUI

public enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed

    var listColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    public var menuBarTintColor: NSColor? {
        switch self {
        case .connected: return .systemGreen
        case .connecting, .reconnecting: return .systemYellow
        case .failed: return .systemRed
        case .disconnected: return nil
        }
    }

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
