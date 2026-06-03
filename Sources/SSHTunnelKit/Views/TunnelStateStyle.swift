import AppKit
import SwiftUI

/// UI styling for `TunnelState`. Kept out of the model layer so the model stays
/// free of AppKit/SwiftUI types.
extension TunnelState {
    /// Status dot colour used in the menu bar list and settings.
    var listColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    /// Tint for the menu bar glyph.
    public var menuBarTintColor: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting, .reconnecting: return .systemYellow
        case .failed: return .systemRed
        case .disconnected: return .systemGray
        }
    }
}
