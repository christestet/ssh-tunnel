import Foundation

enum AppVersionDisplay {
    static let appName = "SSH Tunnel"

    static func title(
        appName: String = appName,
        shortVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) -> String {
        guard let badge = badge(for: shortVersion) else { return appName }
        return "\(appName) \(badge)"
    }

    static func badge(
        for shortVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) -> String? {
        guard let trimmed = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.lowercased().hasPrefix("v") { return trimmed }
        return "v\(trimmed)"
    }

    static func releaseURL(
        for shortVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) -> URL? {
        guard let tagName = badge(for: shortVersion) else { return nil }
        return GitHubReleaseFetcher.releasePageURL(
            owner: GitHubReleaseFetcher.defaultOwner,
            repo: GitHubReleaseFetcher.defaultRepo,
            tagName: tagName
        )
    }
}
