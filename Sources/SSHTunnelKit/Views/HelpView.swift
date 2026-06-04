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
            VStack(alignment: .leading, spacing: 16) {
                Text("SSH Tunnel — Quick Guide")
                    .font(.title2.bold())

                DocumentationLink()

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(HelpContent.sections) { section in
                        HelpSectionView(title: section.title, text: section.body)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .containerBackground(.regularMaterial, for: .window)
    }
}

/// Prominent link to the full online documentation. This quick guide keeps only
/// the essentials; in-depth topics (health checks, reconnects, diagnostics,
/// terminal coexistence, updates, lifecycle) live on the docs site.
private struct DocumentationLink: View {
    var body: some View {
        Link(destination: HelpContent.documentationURL) {
            HStack(spacing: 10) {
                Image(systemName: "book")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Documentation")
                        .font(.headline)
                    Text("Guides, FAQ, and command reference at \(HelpContent.documentationURLString)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Open the full documentation at \(HelpContent.documentationURLString)")
        .accessibilityLabel("Open the full documentation in your browser")
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
    /// Canonical GitHub Pages documentation site. Surfaced both as a clickable
    /// link in the UI and inline below so the essentials here can defer depth to
    /// the full guides.
    static let documentationURLString = "christestet.github.io/ssh-tunnel"
    static let documentationURL = URL(string: "https://christestet.github.io/ssh-tunnel/")!

    static let sections: [HelpSection] = [
        HelpSection(
            title: "Overview",
            body: """
            SSH Tunnel maintains one or more SSH master tunnels from the menu bar. It reads TCP LocalForward ports from ~/.ssh/config via ssh -G, monitors the master socket and each forwarded port, and reconnects automatically when a tunnel drops.
            """
        ),
        HelpSection(
            title: "Getting Started",
            body: """
            1. In ~/.ssh/config, define a Host entry with one or more TCP LocalForward directives.
            2. Open Settings and add a tunnel, setting its Host Alias to that Host entry. Add, delete, and reorder tunnels from the sidebar.
            3. Toggle Active in the menu bar. Forwarded ports are discovered from ssh_config and shown as clickable localhost port pills.
            """
        ),
        HelpSection(
            title: "Settings",
            body: """
            Edits autosave. Key fields are Name, Host Alias, Control Path, Health Check interval, and Max Backoff. SSH Config Forwards lists ports from ssh -G — add labels for clearer pills. Quick Forwards add app-managed remote ports with auto-assigned local ports. Enable Start at Login per tunnel, and use Run Diagnostics to validate a tunnel before starting it. See the documentation for each field in depth.
            """
        ),
        HelpSection(
            title: "Menu & Port Pills",
            body: """
            Each tunnel row has Active and Start at Login switches, Add Quick Forward and Check Now buttons, and shows the latest error. SSH Config and Quick Forward ports appear as localhost pills — click one while connected to open http://localhost:<port>. The bottom bar holds Add Tunnel, Settings, and a More (…) menu (Copy Debug Log, How to Use, GitHub Repository, Quit).
            """
        ),
        HelpSection(
            title: "Quick Forwards",
            body: """
            Add Quick Forward (+) forwards a remote port on the SSH host. The app picks a free local port, applies it on the live master, saves it, and reapplies it after reconnects or restarts. Remove it from the pill or in Settings.
            """
        ),
        HelpSection(
            title: "Port Conflicts",
            body: """
            Before starting, the app checks that every forwarded local port is free. If a config LocalForward port is already in use, it shows the holding process and offers a free port to use instead for this session — accept to connect on the suggested port (shown in the pills) or cancel. Your ~/.ssh/config is never changed, and the original port is re-checked on the next start.
            """
        ),
        HelpSection(
            title: "Keyboard Shortcuts",
            body: """
            While the menu is open:
            • ⌘, — Open Settings
            • ⇧⌘? — Open Help (How to Use)
            • ⌘Q — Quit App
            """
        ),
        HelpSection(
            title: "Troubleshooting",
            body: """
            • Verify the alias works in Terminal: ssh <alias>.
            • Make sure your SSH key is loaded: ssh-add -l.
            • Set Log Level to Debug, then use Copy Debug Log to share recent entries.
            • Use Check Now for an immediate notification with the current status.
            • If a forwarded port is unreachable, try nc -vz 127.0.0.1 <port>.
            See the documentation at \(documentationURLString) for the full FAQ and troubleshooting guide.
            """
        )
    ]
}
