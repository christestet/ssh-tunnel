import Foundation
import UserNotifications

protocol TunnelNotifying {
    func requestAuthorization()
    func sendTunnelInterruptedNotification(for settings: TunnelSettings)
    func sendTunnelFailedNotification(for settings: TunnelSettings, detail: String)
    func sendCheckResultNotification(for settings: TunnelSettings, ok: Bool, detail: String)
}

struct UserNotificationTunnelNotifier: TunnelNotifying {
    func requestAuthorization() {
        guard isRunningFromApplicationBundle else { return }
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func sendTunnelInterruptedNotification(for settings: TunnelSettings) {
        guard isRunningFromApplicationBundle else { return }

        let content = UNMutableNotificationContent()
        content.title = "SSH tunnel disconnected"
        content.body = "Tunnel to \(settings.hostAlias) was interrupted. Reconnecting..."
        content.sound = .default

        deliver(content: content, idPrefix: "ssh-tunnel-disconnected")
    }

    func sendTunnelFailedNotification(for settings: TunnelSettings, detail: String) {
        guard isRunningFromApplicationBundle else { return }

        let content = UNMutableNotificationContent()
        content.title = "SSH tunnel failed"
        content.body = "Tunnel to \(settings.hostAlias): \(detail)"
        content.sound = .default

        deliver(content: content, idPrefix: "ssh-tunnel-failed")
    }

    func sendCheckResultNotification(for settings: TunnelSettings, ok: Bool, detail: String) {
        guard isRunningFromApplicationBundle else { return }

        let content = UNMutableNotificationContent()
        if ok {
            content.title = "SSH tunnel healthy"
            content.body = "Tunnel to \(settings.hostAlias) is up. \(detail)"
        } else {
            content.title = "SSH tunnel check failed"
            content.body = "Tunnel to \(settings.hostAlias): \(detail)"
            content.sound = .default
        }

        deliver(content: content, idPrefix: ok ? "ssh-tunnel-ok" : "ssh-tunnel-check-failed")
    }

    private func deliver(content: UNMutableNotificationContent, idPrefix: String) {
        let request = UNNotificationRequest(
            identifier: "\(idPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        // `add(_:)` is the legacy completion-handler form (default nil). The
        // async variant requires sending `UNNotificationRequest` across an
        // actor hop, but that type isn't Sendable, so this remains the
        // simplest correct call.
        UNUserNotificationCenter.current().add(request)
    }

    private var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
