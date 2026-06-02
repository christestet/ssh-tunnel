import ServiceManagement

@MainActor
protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

@MainActor
final class LoginItemManager: LoginItemManaging {
    private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TunnelLog.shared.log(.error, .lifecycle, "login item toggle failed: \(error)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
