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

    /// Opens the release page when the user taps an "Update available"
    /// notification. The URL travels in `userInfo` from
    /// `UserNotificationUpdateNotifier`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let urlString = userInfo[UserNotificationUpdateNotifier.releaseURLKey] as? String,
              let url = URL(string: urlString) else { return }
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TunnelManager?
    weak var updateChecker: UpdateChecker?
    private let notificationPresenter = NotificationPresenter()
    private let instanceGuard = SingleInstanceGuard()
    private var updateLoopTask: Task<Void, Never>?

    /// Single-instance enforcement via an advisory file lock — race-free, unlike
    /// enumerating peers and terminating them (which can make both instances
    /// quit when launched simultaneously).
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        if instanceGuard.acquire(identifier: bundleId) { return }

        // Another instance holds the lock; surface it and exit.
        let me = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first { $0.processIdentifier != me }
        existing?.activate()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TunnelLog.shared.log(.notice, .lifecycle, "app launched")
        UNUserNotificationCenter.current().delegate = notificationPresenter
        Task { @MainActor [weak self] in
            await self?.manager?.start()
        }
        startUpdateLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelLog.shared.log(.notice, .lifecycle, "app terminating")
        updateLoopTask?.cancel()
        manager?.stopSynchronously()
    }

    /// Runs an initial gated update check at launch, then sleeps until the
    /// checker reports the next one is due (≈24h after a success, sooner after
    /// a failure). The gate guarantees at most one successful network request
    /// per day; this just avoids waking pointlessly in between.
    private func startUpdateLoop() {
        updateLoopTask?.cancel()
        updateLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let checker = self?.updateChecker else { return }
                await checker.automaticCheckIfDue()
                let delay = checker.nextAutomaticCheckDelay()
                try? await Task.sleep(for: delay)
            }
        }
    }
}

@main
struct SSHTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var manager: TunnelManager
    @State private var updateChecker: UpdateChecker

    init() {
        let settingsStore = TunnelSettingsStore()
        let manager = TunnelManager(settingsStore: settingsStore)
        let updateChecker = UpdateChecker(settings: UpdateSettingsStore())
        _manager = State(initialValue: manager)
        _updateChecker = State(initialValue: updateChecker)
        appDelegate.manager = manager
        appDelegate.updateChecker = updateChecker
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager, updateChecker: updateChecker)
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
                updateChecker: updateChecker,
                initialSelection: manager.settingsSelection
            )
            // Matches Constants.settingsMinWidth/Height; the NavigationSplitView
            // inside needs a floor or it opens uncomfortably small.
            .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)

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
