import SwiftUI

/// SwiftUI ID under which the help scene is registered in
/// `SSHTunnelApp.body`. Centralised so the menu bar's "Help" button and the
/// scene declaration cannot drift apart.
public enum HelpScene {
    public static let windowID = "help"
}

public struct HelpView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SSH Tunnel — Quick Guide")
                    .font(.title2.bold())

                ForEach(HelpContent.sections) { section in
                    HelpSectionView(title: section.title, text: section.body)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .containerBackground(.regularMaterial, for: .window)
    }
}

private struct HelpSectionView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HelpSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let body: String
}

enum HelpContent {
    static let sections: [HelpSection] = [
        HelpSection(
            title: "Overview",
            body: """
            This app maintains one or more SSH master tunnels from the menu bar. It reads TCP LocalForward ports from ~/.ssh/config via ssh -G, checks both the master socket and each forwarded TCP port, and reconnects when a tunnel drops.
            """
        ),
        HelpSection(
            title: "Getting Started",
            body: """
            1. In ~/.ssh/config, define a Host entry with one or more TCP LocalForward directives.
            2. Open Settings and add a tunnel for that Host alias. Add, delete, and reorder tunnels from the settings sidebar.
            3. Toggle Active in the menu bar. Forwarded ports are discovered from ssh_config and shown as localhost port pills.
            """
        ),
        HelpSection(
            title: "Settings",
            body: """
            Changes are autosaved after editing. The sidebar manages tunnel order; the menu uses the same order.
            • Name — The label shown in the menu and settings list.
            • Host Alias — The SSH config host entry to connect to.
            • Control Path — Socket path for the app's SSH master connection.
            • SSH Config Forwards — TCP ports derived from ssh -G <alias>; add service labels here for clearer localhost port pills.
            • Quick Forwards — Add remote ports to be forwarded on the fly. The app assigns a free local port automatically, saves it, and lets you remove saved quick forwards.
            • Health Check — Seconds between automatic connectivity checks.
            • Max Backoff — Maximum delay between reconnect attempts.
            • Log Level — Global minimum level written to the app's debug logs. Use Debug before reproducing subtle issues.
            """
        ),
        HelpSection(
            title: "Menu Rows",
            body: """
            Each tunnel row has an Active switch, Start at Login switch, Add Quick Forward button, and Check Now button. The row also shows the latest error when a start, check, or reconnect fails. The bottom action bar adds tunnels, checks for updates, copies the debug log, opens Settings or Help, and quits the app. State colors include Connected, Connecting, Reconnecting, Failed, and Idle (disconnected).
            """
        ),
        HelpSection(
            title: "Updates",
            body: """
            SSH Tunnel checks GitHub Releases for a newer version automatically — at most once every 24 hours — and on demand with the Check for Updates button in the action bar. When a newer release is available, an Update available banner appears at the top of the menu and a notification is posted; both open the release page so you can download the new DMG and drag it to Applications. Because the app is not notarized, updates are installed manually and there is no silent self-update. Turn automatic checks on or off in the About & Updates popover, opened from the info button in the settings sidebar footer.
            """
        ),
        HelpSection(
            title: "Lifecycle",
            body: """
            The SSH master runs as this app's child process, so quitting the app tears down masters it started. On launch or restart, if the app finds a live master at its own control path, it adopts it instead of killing it. If no master is alive, stale socket files are removed before a new master starts. Launching a second app copy activates the existing one and exits the new copy.
            """
        ),
        HelpSection(
            title: "Terminal SSH",
            body: """
            The default Control Path is namespaced (~/.ssh/control-sshtunnelapp-%C), so terminal ssh <alias> sessions use a separate master socket. If you deliberately point the app at the same ControlPath your ssh_config uses, the app refuses to start rather than closing your terminal session.
            """
        ),
        HelpSection(
            title: "Health Checks",
            body: """
            Check Now runs ssh -O check and probes each forwarded TCP port on 127.0.0.1. Automatic health checks do the same on the configured interval, and network or wake events trigger recovery work instead of waiting for the timer. If a live master has a dead forward, the app tries to re-establish the forward before reconnecting.
            """
        ),
        HelpSection(
            title: "Diagnostics",
            body: """
            Run Diagnostics in Settings validates the saved or drafted tunnel configuration before you start it. It checks required fields, ssh -G, SSH config forwards, Quick Forwards with assigned local ports, ControlPath safety, and local port availability. When the tunnel is already connected, ports held by that tunnel's own ssh process are treated as expected.
            """
        ),
        HelpSection(
            title: "Reconnects",
            body: """
            Reconnect backoff starts at 5 seconds and doubles up to Max Backoff. While waiting, the menu row shows the retry countdown. A previously connected tunnel sends an interruption notification before reconnecting. After 10 consecutive failed reconnect attempts, the app stops and leaves the tunnel failed until you toggle it off and on.
            """
        ),
        HelpSection(
            title: "Port Conflicts",
            body: """
            Before starting, the app checks whether any forwarded port is already bound. It reports the holder's PID and command for foreign processes, and it may clean up an obvious orphan SSH process only when its arguments match this tunnel's host alias or control path.
            """
        ),
        HelpSection(
            title: "Start at Login",
            body: """
            Enable Start at Login for any tunnel that should connect when the app launches. The macOS login item is enabled while at least one tunnel has Start at Login enabled. The app waits until macOS reports a satisfied network path, applies a short settle delay, and then connects. If a Startup Check host is configured, the app retries until a TCP connection to that host and port succeeds.
            """
        ),
        HelpSection(
            title: "Quick Forward",
            body: """
            Use Add Quick Forward (+) in a tunnel row to forward a remote port on the SSH host. You can add a service label, and the app finds a free local port on 127.0.0.1 and establishes the forward on the active tunnel using ssh -O forward. Quick forwards are saved in Settings, removed with ssh -O cancel, and reapplied automatically on reconnect or app restart.
            """
        ),
        HelpSection(
            title: "Port Pills",
            body: """
            SSH Config Forwards and Quick Forward ports appear as localhost port pills in each tunnel row. When the tunnel is connected, click a pill to open http://localhost:<port> in your default browser. Use a pill's context menu to jump to that tunnel in Settings; Quick Forward pills also have a remove button.
            """
        ),
        HelpSection(
            title: "Keyboard Shortcuts",
            body: """
            While the menu is open:
            • ⌘, — Open Settings
            • ⌘? — Open Help
            • ⌘Q — Quit App
            """
        ),
        HelpSection(
            title: "Troubleshooting",
            body: """
            • Verify the alias works in Terminal: ssh <alias>.
            • Make sure your SSH key is loaded: ssh-add -l.
            • Confirm the control path directory exists.
            • Set Log Level to Debug before reproducing timing or reconnect problems.
            • Use Copy Debug Log to copy recent entries and reveal the persistent log file.
            • Use Check Now for an immediate notification with the current failure reason.
            • If a forwarded port is unreachable, try nc -vz 127.0.0.1 <port>.
            • If notifications are missing, allow alerts in System Settings > Notifications > SSH Tunnel.
            """
        )
    ]
}
