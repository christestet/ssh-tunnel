import Foundation
import Observation

/// UserDefaults-backed preferences for the in-app update check. Mirrors
/// `LogSettingsStore`: an `@Observable` so SwiftUI views can bind directly, with
/// each property persisting on `didSet`.
@MainActor
@Observable
public final class UpdateSettingsStore {
    static let defaultAutomaticChecksEnabled = true

    /// When `false`, no automatic (launch or periodic) check ever runs; the user
    /// can still trigger a manual "Check for Updates…".
    var automaticChecksEnabled: Bool {
        didSet { defaults.set(automaticChecksEnabled, forKey: automaticChecksKey) }
    }

    /// Timestamp of the last successful automatic check. Used as the hard 24h
    /// gate so repeated relaunches never exceed one request per day.
    var lastCheckDate: Date? {
        didSet {
            if let lastCheckDate {
                defaults.set(lastCheckDate.timeIntervalSinceReferenceDate, forKey: lastCheckKey)
            } else {
                defaults.removeObject(forKey: lastCheckKey)
            }
        }
    }

    private let defaults: UserDefaults
    private let automaticChecksKey = "UpdateAutomaticChecksEnabled"
    private let lastCheckKey = "UpdateLastCheckDate"

    public convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: automaticChecksKey) != nil {
            automaticChecksEnabled = defaults.bool(forKey: automaticChecksKey)
        } else {
            automaticChecksEnabled = Self.defaultAutomaticChecksEnabled
        }

        if let stamp = defaults.object(forKey: lastCheckKey) as? Double {
            lastCheckDate = Date(timeIntervalSinceReferenceDate: stamp)
        } else {
            lastCheckDate = nil
        }
    }
}
