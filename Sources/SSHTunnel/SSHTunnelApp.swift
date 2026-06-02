import AppKit
import SwiftUI
import SSHTunnelKit
import UserNotifications

/// Presents notifications even while the app is frontmost. Without a delegate
/// returning presentation options from `willPresent`, the system suppresses
/// banners whenever the app is active.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TunnelManager?
    private let notificationPresenter = NotificationPresenter()

    /// Single-instance enforcement.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).filter { $0.processIdentifier != me }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TunnelLog.shared.log(.notice, .lifecycle, "app launched")
        UNUserNotificationCenter.current().delegate = notificationPresenter
        Task { @MainActor [weak self] in
            await self?.manager?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelLog.shared.log(.notice, .lifecycle, "app terminating")
        manager?.stopSynchronously()
    }
}

@main
struct SSHTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var manager: TunnelManager

    init() {
        let settingsStore = TunnelSettingsStore()
        let manager = TunnelManager(settingsStore: settingsStore)
        _manager = State(initialValue: manager)
        appDelegate.manager = manager
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            // Template image + SwiftUI tint: the glyph adapts to light/dark and
            // the Tahoe menu-bar appearance automatically, and state is conveyed
            // by `foregroundStyle` rather than a baked-in bitmap fill.
            Image(nsImage: Self.baseIcon)
                .foregroundStyle(Self.menuBarTint(for: manager.overallState))
        }
        .menuBarExtraStyle(.window)

        Settings {
            TunnelListSettingsView(
                manager: manager,
                initialSelection: manager.settingsSelection
            )
        }

        Window("How To Use SSH Tunnel", id: HelpScene.windowID) {
            HelpView()
                .frame(
                    minWidth: 480,
                    idealWidth: 560,
                    minHeight: 480,
                    idealHeight: 620
                )
        }
        .windowResizability(.contentSize)
    }

    /// The menu bar glyph as a *template* image so macOS renders it correctly
    /// for the current appearance (light/dark, increased contrast, and the
    /// Tahoe transparent menu bar). Colour comes from SwiftUI's
    /// `foregroundStyle`, never a baked-in fill.
    private static let baseIcon: NSImage = {
        let img = NSImage(named: "MenuBarIcon") ?? NSImage()
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    private static func menuBarTint(for state: TunnelState) -> Color {
        if let nsColor = state.menuBarTintColor {
            return Color(nsColor: nsColor)
        }
        // Idle: defer to the system so the glyph tracks the menu-bar appearance.
        return .primary
    }
}
