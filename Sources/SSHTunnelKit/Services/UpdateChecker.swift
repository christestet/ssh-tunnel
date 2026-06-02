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
    let owner: String
    let repo: String
    private let session: URLSession

    public init(owner: String = "christestet", repo: String = "ssh-tunnel", session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    public func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
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

    /// Hard gate for automatic checks — at most one per 24h.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    public private(set) var availableUpdate: AvailableUpdate?
    public private(set) var isChecking = false
    public private(set) var lastErrorMessage: String?

    /// The running app version, e.g. "2.2.4".
    public let currentVersion: String

    /// Surfaced for the Settings "last checked" label.
    public var lastCheckDate: Date? { settings.lastCheckDate }
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
    /// without any network access unless automatic checks are enabled *and* it
    /// has been at least 24h since the last check. This is the only place the
    /// 24h rule lives, so neither launch nor the periodic loop can bypass it.
    public func automaticCheckIfDue() async {
        guard settings.automaticChecksEnabled else { return }
        if let last = settings.lastCheckDate,
           now().timeIntervalSince(last) < Self.automaticCheckInterval {
            return
        }
        await performCheck(isAutomatic: true)
    }

    /// User-initiated check. Always runs regardless of the 24h gate.
    public func checkForUpdates() async {
        await performCheck(isAutomatic: false)
    }

    private func performCheck(isAutomatic: Bool) async {
        isChecking = true
        // Stamp the attempt up front so the 24h gate counts every automatic
        // check (success or failure) and the UI's "last checked" stays honest.
        settings.lastCheckDate = now()
        defer { isChecking = false }

        do {
            let release = try await fetcher.fetchLatestRelease()
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
        let update = AvailableUpdate(version: displayVersion, releaseURL: url)
        let isNewlyDiscovered = availableUpdate != update
        availableUpdate = update

        // Only nudge with a notification for background discoveries; a manual
        // check already shows the result inline.
        if isAutomatic, isNewlyDiscovered {
            notifier?.sendUpdateAvailableNotification(version: displayVersion, releaseURL: url)
        }
    }
}
