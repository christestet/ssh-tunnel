import AppKit
import SwiftUI
import SSHTunnelKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TunnelManager?

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
            Image(nsImage: Self.icon(for: manager.overallState))
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

    private static let baseIcon: NSImage = {
        let img = NSImage(named: "MenuBarIcon") ?? NSImage()
        img.size = NSSize(width: 18, height: 18)
        return img
    }()

    private static func icon(for state: TunnelState) -> NSImage {
        guard let tint = state.menuBarTintColor else {
            let img = (baseIcon.copy() as? NSImage) ?? baseIcon
            img.isTemplate = true
            return img
        }
        return baseIcon.tinted(with: tint)
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
