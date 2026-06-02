import Foundation
import Observation

@MainActor
@Observable
public final class LogSettingsStore {
    static let defaultMinimumLevel: LogLevel = .warning

    var minimumLevel: LogLevel {
        didSet {
            defaults.set(minimumLevel.rawValue, forKey: key)
            TunnelLog.levelGate.minimumLevel = minimumLevel
        }
    }

    private let defaults: UserDefaults
    private let key = "LogMinimumLevel"

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.object(forKey: key) as? Int,
           let level = LogLevel(rawValue: rawValue) {
            minimumLevel = level
        } else {
            minimumLevel = Self.defaultMinimumLevel
        }
        TunnelLog.levelGate.minimumLevel = minimumLevel
    }
}