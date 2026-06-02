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

    /// Timestamp of the last *successful* automatic/manual check. This is the
    /// 24h gate: a successful check suppresses further automatic checks for a
    /// day. A failed check does NOT update this, so we retry sooner (see
    /// `lastAttemptDate`).
    var lastSuccessDate: Date? {
        didSet { persist(lastSuccessDate, forKey: lastSuccessKey) }
    }

    /// Timestamp of the last check *attempt* (success or failure). Used both for
    /// the UI's "last checked" label and as a short retry floor so a failing
    /// check can't hammer the API.
    var lastAttemptDate: Date? {
        didSet { persist(lastAttemptDate, forKey: lastAttemptKey) }
    }

    /// The most recent version we already posted an "Update available"
    /// notification for. Persisted so a relaunch doesn't re-notify for a release
    /// the user has already seen.
    var lastNotifiedVersion: String? {
        didSet {
            if let lastNotifiedVersion {
                defaults.set(lastNotifiedVersion, forKey: lastNotifiedVersionKey)
            } else {
                defaults.removeObject(forKey: lastNotifiedVersionKey)
            }
        }
    }

    private let defaults: UserDefaults
    private let automaticChecksKey = "UpdateAutomaticChecksEnabled"
    private let lastSuccessKey = "UpdateLastSuccessDate"
    private let lastAttemptKey = "UpdateLastAttemptDate"
    private let lastNotifiedVersionKey = "UpdateLastNotifiedVersion"

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
        lastSuccessDate = Self.readDate(from: defaults, key: lastSuccessKey)
        lastAttemptDate = Self.readDate(from: defaults, key: lastAttemptKey)
        lastNotifiedVersion = defaults.string(forKey: lastNotifiedVersionKey)
    }

    private func persist(_ date: Date?, forKey key: String) {
        if let date {
            defaults.set(date.timeIntervalSinceReferenceDate, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func readDate(from defaults: UserDefaults, key: String) -> Date? {
        guard let stamp = defaults.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: stamp)
    }
}
