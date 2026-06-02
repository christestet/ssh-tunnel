import Foundation
import Synchronization
import UserNotifications

protocol TunnelNotifying {
    func sendTunnelInterruptedNotification(for settings: TunnelSettings)
    func sendTunnelFailedNotification(for settings: TunnelSettings, detail: String)
    func sendCheckResultNotification(for settings: TunnelSettings, ok: Bool, detail: String)
}

struct UserNotificationTunnelNotifier: TunnelNotifying {
    func sendTunnelInterruptedNotification(for settings: TunnelSettings) {
        deliver(
            title: "SSH tunnel disconnected",
            body: "Tunnel to \(settings.hostAlias) was interrupted. Reconnecting...",
            sound: true,
            idPrefix: "ssh-tunnel-disconnected"
        )
    }

    func sendTunnelFailedNotification(for settings: TunnelSettings, detail: String) {
        deliver(
            title: "SSH tunnel failed",
            body: "Tunnel to \(settings.hostAlias): \(detail)",
            sound: true,
            idPrefix: "ssh-tunnel-failed"
        )
    }

    func sendCheckResultNotification(for settings: TunnelSettings, ok: Bool, detail: String) {
        if ok {
            deliver(
                title: "SSH tunnel healthy",
                body: "Tunnel to \(settings.hostAlias) is up. \(detail)",
                sound: false,
                idPrefix: "ssh-tunnel-ok"
            )
        } else {
            deliver(
                title: "SSH tunnel check failed",
                body: "Tunnel to \(settings.hostAlias): \(detail)",
                sound: true,
                idPrefix: "ssh-tunnel-check-failed"
            )
        }
    }

    private func deliver(title: String, body: String, sound: Bool, idPrefix: String) {
        guard isRunningFromApplicationBundle else { return }
        // Build the content/request *inside* the Task: `UNMutableNotificationContent`
        // and `UNNotificationRequest` aren't `Sendable`, so capturing only plain
        // values (Strings/Bool) keeps this clean under Swift 6.
        Task {
            // Authorization is requested lazily, the first time we actually have
            // something to show, rather than per-controller at launch. The
            // system only prompts once; subsequent calls are no-ops.
            guard await NotificationAuthorization.ensure() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: "\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            // The request is built here inside the Task, so there's no
            // non-Sendable hop — use the async `add(_:)` directly.
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// Posts a user notification when a background update check finds a newer
/// release. The release URL is carried in `userInfo` so the app's notification
/// delegate can open it on tap.
public struct UserNotificationUpdateNotifier: UpdateNotifying {
    /// `userInfo` key holding the release page URL string. Public so the app's
    /// notification delegate can read it to open the release page on tap.
    public static let releaseURLKey = "releaseURL"

    public init() {}

    public func sendUpdateAvailableNotification(version: String, releaseURL: URL) {
        guard isRunningFromApplicationBundle else { return }
        let urlString = releaseURL.absoluteString
        Task {
            guard await NotificationAuthorization.ensure() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Update available"
            content.body = "SSH Tunnel \(version) is available. Click to view the release."
            content.userInfo = [Self.releaseURLKey: urlString]
            let request = UNNotificationRequest(
                identifier: "ssh-tunnel-update-\(version)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// Requests notification authorization at most once for the process. Requesting
/// contextually (on the first real notification) rather than at launch follows
/// the HIG and avoids prompting the user before they understand why.
enum NotificationAuthorization {
    private static let hasRequested = Mutex(false)

    /// Ensures authorization has been requested, returning whether the app is
    /// allowed to post notifications.
    static func ensure() async -> Bool {
        let alreadyRequested = hasRequested.withLock { requested -> Bool in
            if requested { return true }
            requested = true
            return false
        }
        let center = UNUserNotificationCenter.current()
        if !alreadyRequested {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }
}
