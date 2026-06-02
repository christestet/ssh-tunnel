import Foundation
import Observation

// MARK: - GitHub release model

/// The subset of the GitHub "latest release" payload we care about.
/// https://docs.github.com/en/rest/releases/releases#get-the-latest-release
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let htmlURL: String
    public let body: String?
    public let prerelease: Bool
    public let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case prerelease
        case draft
    }

    public init(tagName: String, name: String? = nil, htmlURL: String, body: String? = nil, prerelease: Bool = false, draft: Bool = false) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.body = body
        self.prerelease = prerelease
        self.draft = draft
    }
}

// MARK: - Fetching

/// Abstracts the network call so tests can inject a fake without touching the
/// network.
public protocol ReleaseFetching: Sendable {
    func fetchLatestRelease() async throws -> GitHubRelease
}

public enum UpdateCheckError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The update server returned an unexpected response."
        case let .httpStatus(code):
            return "The update server returned HTTP \(code)."
        }
    }
}

/// Queries the GitHub Releases REST API for the latest published release.
public struct GitHubReleaseFetcher: ReleaseFetching {
    /// The repository releases are published to — the single source of truth
    /// shared with the README and the release workflow.
    public static let defaultOwner = "christestet"
    public static let defaultRepo = "ssh-tunnel"

    let owner: String
    let repo: String
    private let session: URLSession

    public init(owner: String = defaultOwner, repo: String = defaultRepo, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    /// Builds the `releases/latest` endpoint via `URLComponents` so the path is
    /// percent-encoded rather than force-unwrapped from string interpolation.
    public static func latestReleaseURL(owner: String, repo: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/releases/latest"
        return components.url
    }

    public func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = Self.latestReleaseURL(owner: owner, repo: repo) else {
            throw UpdateCheckError.invalidResponse
        }
        var request = URLRequest(url: url)
        // GitHub requires a User-Agent and recommends pinning the API version
        // and Accept header.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SSHTunnel (+https://github.com/\(owner)/\(repo))", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

// MARK: - Update notifications

/// A user notification posted when a background check discovers a new release.
public protocol UpdateNotifying: Sendable {
    func sendUpdateAvailableNotification(version: String, releaseURL: URL)
}

// MARK: - Update checker

/// Owns the update-check state for the app. Compares the running
/// `CFBundleShortVersionString` against the latest GitHub release and exposes an
/// `availableUpdate` for the UI to surface.
@MainActor
@Observable
public final class UpdateChecker {
    /// A release newer than the running build, ready to surface to the user.
    public struct AvailableUpdate: Equatable, Sendable {
        public let version: String     // display form, e.g. "v2.3.0"
        public let releaseURL: URL
    }

    /// Hard gate for automatic checks — at most one *successful* check per 24h.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    /// After a failed check we may retry this soon (rather than waiting the full
    /// 24h), but no sooner — so a persistent failure can't hammer the API.
    static let failureRetryInterval: TimeInterval = 60 * 60
    /// How long the periodic loop sleeps while automatic checks are disabled,
    /// so re-enabling them is picked up reasonably promptly.
    static let disabledPollInterval: Duration = .seconds(60 * 60)

    public private(set) var availableUpdate: AvailableUpdate?
    public private(set) var isChecking = false
    public private(set) var lastErrorMessage: String?

    /// The running app version, e.g. "2.2.4".
    public let currentVersion: String

    /// Surfaced for the Settings "last checked" label — the most recent attempt
    /// (success or failure), which is what the user thinks of as "last checked".
    public var lastCheckDate: Date? { settings.lastAttemptDate }
    public var automaticChecksEnabled: Bool {
        get { settings.automaticChecksEnabled }
        set { settings.automaticChecksEnabled = newValue }
    }

    private let fetcher: ReleaseFetching
    private let settings: UpdateSettingsStore
    private let notifier: UpdateNotifying?
    private let now: @Sendable () -> Date

    public convenience init(
        settings: UpdateSettingsStore,
        currentVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    ) {
        self.init(
            fetcher: GitHubReleaseFetcher(),
            settings: settings,
            currentVersion: currentVersion,
            notifier: UserNotificationUpdateNotifier()
        )
    }

    init(
        fetcher: ReleaseFetching,
        settings: UpdateSettingsStore,
        currentVersion: String,
        notifier: UpdateNotifying? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.settings = settings
        self.currentVersion = currentVersion
        self.notifier = notifier
        self.now = now
    }

    /// Single guarded entry point for automatic checks. Returns immediately
    /// without any network access unless automatic checks are enabled *and* a
    /// check is due. The 24h success window and the failure-retry floor are the
    /// only gates, so neither launch nor the periodic loop can bypass them.
    public func automaticCheckIfDue() async {
        guard settings.automaticChecksEnabled, nextDueDate() <= now() else { return }
        await performCheck(isAutomatic: true)
    }

    /// User-initiated check. Always runs regardless of the gate.
    public func checkForUpdates() async {
        await performCheck(isAutomatic: false)
    }

    /// How long the periodic loop should sleep before the next automatic check
    /// is due. Returns a short poll interval while checks are disabled so the
    /// loop keeps re-evaluating (e.g. after the user re-enables them).
    public func nextAutomaticCheckDelay() -> Duration {
        guard settings.automaticChecksEnabled else { return Self.disabledPollInterval }
        let seconds = max(0, nextDueDate().timeIntervalSince(now()))
        return .seconds(seconds)
    }

    /// The earliest moment an automatic check is allowed: after both the 24h
    /// success window and the failure-retry floor have elapsed. Missing
    /// timestamps are treated as already-elapsed (check is due now).
    private func nextDueDate() -> Date {
        var due = now()
        if let lastSuccess = settings.lastSuccessDate {
            due = max(due, lastSuccess.addingTimeInterval(Self.automaticCheckInterval))
        }
        if let lastAttempt = settings.lastAttemptDate {
            due = max(due, lastAttempt.addingTimeInterval(Self.failureRetryInterval))
        }
        return due
    }

    private func performCheck(isAutomatic: Bool) async {
        isChecking = true
        // Every attempt updates the UI's "last checked" and the failure-retry
        // floor; only a *successful* fetch advances the 24h success window.
        settings.lastAttemptDate = now()
        defer { isChecking = false }

        do {
            let release = try await fetcher.fetchLatestRelease()
            settings.lastSuccessDate = now()
            lastErrorMessage = nil
            apply(release: release, isAutomatic: isAutomatic)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func apply(release: GitHubRelease, isAutomatic: Bool) {
        guard !release.draft, !release.prerelease,
              let latest = SemanticVersion(release.tagName),
              let current = SemanticVersion(currentVersion),
              latest > current,
              let url = URL(string: release.htmlURL) else {
            availableUpdate = nil
            return
        }

        let displayVersion = AppVersionDisplay.badge(for: release.tagName) ?? release.tagName
        availableUpdate = AvailableUpdate(version: displayVersion, releaseURL: url)

        // Only nudge with a notification for background discoveries, and only
        // once per version across relaunches (the seen version is persisted). A
        // manual check already shows the result inline.
        if isAutomatic, settings.lastNotifiedVersion != displayVersion {
            settings.lastNotifiedVersion = displayVersion
            notifier?.sendUpdateAvailableNotification(version: displayVersion, releaseURL: url)
        }
    }
}
