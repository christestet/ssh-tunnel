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
