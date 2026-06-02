import AppKit
import SwiftUI

/// Root panel for the `MenuBarExtra` in `.window` style. Tahoe gives the
/// MenuBarExtra window an automatic Liquid Glass backdrop, so we layout
/// "content on the base" — tunnel rows — and reserve `.glassEffect()` for the
/// floating action bar at the bottom (custom chrome).
public struct MenuBarView: View {
    @Bindable var manager: TunnelManager
    let updateChecker: UpdateChecker
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    public init(manager: TunnelManager, updateChecker: UpdateChecker) {
        self.manager = manager
        self.updateChecker = updateChecker
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let update = updateChecker.availableUpdate {
                Divider()
                updateBanner(update)
            }
            Divider()
            tunnelList
            Divider()
            actionBar
        }
        .frame(width: Constants.menuBarPanelWidth)
        .frame(minHeight: Constants.menuBarPanelMinHeight)
    }

    /// Surfaces a newer GitHub release. Tapping opens the release page (notes +
    /// DMG) in the browser — the app is un-notarized, so we hand off to the
    /// user's existing download/drag-install flow rather than self-updating.
    private func updateBanner(_ update: UpdateChecker.AvailableUpdate) -> some View {
        Button {
            NSWorkspace.shared.open(update.releaseURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available \(update.version)")
                        .font(.subheadline.weight(.semibold))
                    Text("View release and download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Open the release page for \(update.version)")
        .accessibilityLabel("Update available \(update.version). Open release page.")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SSH Tunnel")
                .font(.headline)
            if let versionBadge = AppVersionDisplay.badge() {
                Text(versionBadge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            OverallStateBadge(state: manager.overallState)
        }
        .accessibilityLabel(AppVersionDisplay.title())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Tunnels we surface in the menu. All configured tunnels are shown
    /// so they don't 'disappear' during startup or when ssh_config is
    /// temporarily unreadable.
    private var visibleControllers: [TunnelController] {
        manager.controllers
    }

    @ViewBuilder
    private var tunnelList: some View {
        if manager.controllers.isEmpty {
            emptyState(
                title: "No tunnels configured",
                buttonTitle: "Add Tunnel…",
                action: {
                    _ = manager.addTunnelForEditing()
                    openSettingsWindow()
                }
            )
        } else if visibleControllers.isEmpty {
            emptyState(
                title: "No forwarded ports found",
                subtitle: "Add a `LocalForward …` line to your ~/.ssh/config so the tunnel has something to expose.",
                buttonTitle: "Open Settings",
                action: { openSettingsWindow() }
            )
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(visibleControllers) { ctrl in
                        TunnelRow(controller: ctrl, manager: manager)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: Constants.menuBarListMaxHeight)
        }
    }

    private func emptyState(
        title: String,
        subtitle: String? = nil,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button(action: action) {
                Label(buttonTitle, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Floating action bar at the bottom of the menu popover. Following
    /// progressive disclosure, only the two immediate-use actions — Add Tunnel
    /// and Settings — are single-tap chips; everything secondary (Help, Copy
    /// Debug Log, Quit) lives behind a standard overflow menu. Manual update
    /// checks intentionally live only in Settings → About & Updates, not here.
    /// The chips share a `GlassEffectContainer` so their `.buttonStyle(.glass)`
    /// refractions blend instead of stacking like flat tiles.
    private var actionBar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    _ = manager.addTunnelForEditing()
                    openSettingsWindow()
                } label: {
                    Label("Add Tunnel", systemImage: "plus")
                }
                .help("Add Tunnel")
                .accessibilityLabel("Add Tunnel")

                Spacer()

                Button {
                    openSettingsWindow()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
                .accessibilityLabel("Settings")

                Menu {
                    Button("Copy Debug Log", systemImage: "doc.on.clipboard") {
                        copyDebugLog()
                    }
                    Button("How to Use SSH Tunnel", systemImage: "questionmark.circle") {
                        openWindow(id: HelpScene.windowID)
                        NSApp.activate()
                    }
                    .keyboardShortcut("?", modifiers: [.command, .shift])

                    Divider()

                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("Quit SSH Tunnel", systemImage: "power")
                    }
                    .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More")
                .accessibilityLabel("More options")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, Constants.menuBarActionBarHorizontalPadding)
            .padding(.vertical, Constants.menuBarActionBarVerticalPadding)
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate()
    }

    /// Copies the recent in-memory debug log to the clipboard so the user can
    /// paste it into a bug report. The full unified log is also available via
    /// Console.app / `log stream --predicate 'subsystem == "com.sshtunnel.app"'`.
    private func copyDebugLog() {
        let log = TunnelLog.recorder.formatted()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log.isEmpty ? "(debug log is empty)" : log, forType: .string)
        // Reveal the persistent log file too, so the user can grab the full
        // history that survives app relaunches.
        NSWorkspace.shared.activateFileViewerSelecting([TunnelLog.fileURL])
    }
}

private struct PortPillItem: Identifiable {
    let id: String
    let localPort: Int?
    let remotePort: Int?
    let label: String?
    let quickForwardID: UUID?

    var sortPort: Int {
        localPort ?? remotePort ?? Int.max
    }
}

private struct PortPill: View {
    let item: PortPillItem
    let isConnected: Bool
    let onDeleteQuickForward: (UUID) -> Void
    let onEditInSettings: (PortPillItem) -> Void

    private var canOpen: Bool {
        isConnected && item.localPort != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                openInBrowser()
            } label: {
                pillContent
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(!canOpen)

            if let quickForwardID = item.quickForwardID {
                Divider()
                    .frame(height: 16)
                    .padding(.trailing, 2)

                Button {
                    onDeleteQuickForward(quickForwardID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove Quick Forward")
                .accessibilityLabel("Remove Quick Forward")
                .padding(.trailing, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    canOpen ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: 1
                )
        )
        .help(helpText)
        .contextMenu {
            Button("Edit in Settings…", systemImage: "slider.horizontal.3") {
                onEditInSettings(item)
            }
            if let quickForwardID = item.quickForwardID {
                Divider()
                Button("Remove Quick Forward", role: .destructive) {
                    onDeleteQuickForward(quickForwardID)
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var pillContent: some View {
        HStack(spacing: 4) {
            if let label = item.label {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 92, alignment: .leading)
            }

            if !hasLabel, let remote = item.remotePort {
                Text("remote " + SettingsNumberDisplay.port(remote))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            Text(localPortText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(item.localPort == nil ? .secondary : .primary)
                .lineLimit(1)
        }
        .foregroundStyle(canOpen ? .primary : .secondary)
        .frame(maxWidth: Constants.menuBarPanelWidth - 72, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, item.quickForwardID == nil ? 8 : 6)
        .padding(.vertical, 4)
    }

    private var hasLabel: Bool {
        guard let label = item.label else { return false }
        return !label.isEmpty
    }

    private var localPortText: String {
        guard let localPort = item.localPort else { return "auto local port" }
        if hasLabel { return SettingsNumberDisplay.port(localPort) }
        return "localhost:" + SettingsNumberDisplay.port(localPort)
    }

    private var helpText: String {
        let base: String
        if let localPort = item.localPort, isConnected {
            base = "Open http://localhost:\(SettingsNumberDisplay.port(localPort)) in your default browser"
        } else if let localPort = item.localPort {
            base = "Tunnel is not connected; start it first to open localhost:\(SettingsNumberDisplay.port(localPort))"
        } else if let remotePort = item.remotePort {
            base = "Remote port \(SettingsNumberDisplay.port(remotePort)) will use the next free local port when the tunnel connects"
        } else {
            base = "Forward will use the next free local port when the tunnel connects"
        }

        if let label = item.label {
            return "\(label): \(base)"
        }
        return base
    }

    private var accessibilityLabel: String {
        if let localPort = item.localPort {
            return "Open local forward port \(SettingsNumberDisplay.port(localPort)) in browser"
        }
        return "Pending quick forward"
    }

    private func openInBrowser() {
        guard canOpen, let localPort = item.localPort else { return }
        guard let url = URL(string: "http://localhost:" + SettingsNumberDisplay.port(localPort)) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Overall state pill

private struct OverallStateBadge: View {
    let state: TunnelState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.listColor)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)
    }
}

// MARK: - Single tunnel row

private struct TunnelRow: View {
    @Bindable var controller: TunnelController
    let manager: TunnelManager
    @State private var isCheckingNow = false
    @State private var isAddingQuickForward = false
    @State private var quickForwardRemotePort = 443
    @State private var quickForwardLabel = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(state: controller.state)
                Text(controller.settings.name.isEmpty ? "Unnamed Tunnel" : controller.settings.name)
                    .font(.system(.body, design: .default).weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                TunnelStateLabel(controller: controller)
            }

            ForwardPortPills(
                items: portPillItems,
                isConnected: controller.state == .connected,
                onDeleteQuickForward: removeQuickForward,
                onEditInSettings: editInSettings
            )

            if let error = controller.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Toggle(isOn: activeBinding) {
                    Text("Active")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Start or stop this tunnel")
                .accessibilityLabel("Start or stop this tunnel")

                Toggle(isOn: autostartBinding) {
                    Text("Start at Login")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                Button {
                    isAddingQuickForward = true
                } label: {
                    Image(systemName: "plus")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .help("Add Quick Forward")
                .accessibilityLabel("Add Quick Forward")
                .popover(isPresented: $isAddingQuickForward) {
                    QuickForwardPopover(
                        remotePort: $quickForwardRemotePort,
                        label: $quickForwardLabel,
                        onAdd: addQuickForward
                    )
                    .padding(14)
                    .frame(width: 260)
                }

                Button {
                    Task {
                        isCheckingNow = true
                        await controller.checkNow()
                        isCheckingNow = false
                    }
                } label: {
                    if isCheckingNow {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .buttonStyle(.borderless)
                .help("Check tunnel now")
                .accessibilityLabel("Check tunnel now")
                .disabled(isCheckingNow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Constants.menuBarRowCornerRadius)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Constants.menuBarRowCornerRadius)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .contextMenu {
            Button(controller.isActive ? "Stop" : "Start") {
                Task {
                    if controller.isActive {
                        await controller.stopTunnel()
                    } else {
                        await controller.startTunnel()
                    }
                }
            }
            Button("Check Now") { Task { await controller.checkNow() } }
            Button("Add Quick Forward…") {
                isAddingQuickForward = true
            }
            Divider()
            Button("Open Settings...") {
                openSettingsWindow()
            }
        }
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { controller.isActive },
            set: { newValue in
                Task {
                    if newValue {
                        await controller.startTunnel()
                    } else {
                        await controller.stopTunnel()
                    }
                }
            }
        )
    }

    private var autostartBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.autostartOnLogin },
            set: { newValue in
                var updated = controller.settings
                updated.autostartOnLogin = newValue
                try? manager.updateSettings(updated)
            }
        )
    }

    private var portPillItems: [PortPillItem] {
        let quickForwardLocalPorts = Set(controller.settings.quickForwards.compactMap(\.localPort))
        let configItems = controller.forwardInfos
            .filter { !quickForwardLocalPorts.contains($0.localPort) }
            .map { info in
                PortPillItem(
                    id: "config-\(info.localPort)",
                    localPort: info.localPort,
                    remotePort: info.remotePort,
                    label: info.label,
                    quickForwardID: nil
                )
            }

        let quickItems = controller.settings.quickForwards.map { forward in
            PortPillItem(
                id: "quick-\(forward.id.uuidString)",
                localPort: forward.localPort,
                remotePort: forward.remotePort,
                label: forward.label.isEmpty ? nil : forward.label,
                quickForwardID: forward.id
            )
        }

        return (configItems + quickItems).sorted {
            if $0.sortPort == $1.sortPort { return $0.id < $1.id }
            return $0.sortPort < $1.sortPort
        }
    }

    private func openSettingsWindow() {
        manager.settingsSelection = controller.id
        openSettings()
        NSApp.activate()
    }

    private func editInSettings(_ item: PortPillItem) {
        manager.settingsSelection = controller.id
        manager.settingsQuickForwardFocus = item.quickForwardID
        openSettings()
        NSApp.activate()
    }

    private func addQuickForward() {
        var forward = QuickForward.makeDefault(remotePort: quickForwardRemotePort)
        forward.label = quickForwardLabel

        var updated = controller.settings
        updated.quickForwards.append(forward)

        do {
            try manager.updateSettings(updated)
            quickForwardRemotePort = 443
            quickForwardLabel = ""
            isAddingQuickForward = false
        } catch {
            controller.lastError = error.localizedDescription
        }
    }

    private func removeQuickForward(id: UUID) {
        Task {
            do {
                try await manager.removeQuickForward(id, from: controller.id)
            } catch {
                controller.lastError = error.localizedDescription
            }
        }
    }
}

private struct QuickForwardPopover: View {
    @Binding var remotePort: Int
    @Binding var label: String
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Forward")
                .font(.headline)

            TextField("Service label", text: $label)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Text("Remote port on SSH host")
                    .foregroundStyle(.secondary)
                TextField("Port", value: $remotePort, formatter: SettingsNumberDisplay.portInputFormatter)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 72)
                    .help("Remote port on SSH host")
                Stepper("", value: $remotePort, in: 1...65535, step: 1)
                    .labelsHidden()
            }
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct TunnelStateLabel: View {
    let controller: TunnelController

    var body: some View {
        Group {
            if controller.state == .reconnecting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(controller.reconnectCountdownDescription(now: context.date) ?? controller.state.label)
                }
            } else {
                Text(controller.state.label)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Forwarded ports as capsule chips

private struct ForwardPortPills: View {
    let items: [PortPillItem]
    let isConnected: Bool
    let onDeleteQuickForward: (UUID) -> Void
    let onEditInSettings: (PortPillItem) -> Void

    var body: some View {
        if !items.isEmpty {
            PortPillFlow(spacing: 4) {
                ForEach(items) { item in
                    PortPill(
                        item: item,
                        isConnected: isConnected,
                        onDeleteQuickForward: onDeleteQuickForward,
                        onEditInSettings: onEditInSettings
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Minimal flow layout — wraps capsules onto multiple lines when the
/// container can't fit them in a single HStack. Built directly on the
/// `Layout` protocol (macOS 13+) so we don't pull in a 3rd-party dep.
private struct PortPillFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(subviews: subviews, maxWidth: maxWidth)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let prospective = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if prospective > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            if !current.items.isEmpty { current.width += spacing }
            current.items.append((i, size))
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Animated status indicator

private struct StatusDot: View {
    let state: TunnelState

    var body: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 10, height: 10)
            .foregroundStyle(state.listColor)
            .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isPulsing)
    }

    private var isPulsing: Bool {
        switch state {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

#Preview {
    let tunnel = TunnelSettings(
        id: UUID(),
        name: "Production DB",
        hostAlias: "prod-db",
        controlPath: "~/.ssh/control-sshtunnelapp-%C",
        healthCheckInterval: 15,
        maxBackoff: 60,
        autostartOnLogin: false
    )
    MenuBarView(
        manager: TunnelManager(settingsStore: TunnelSettingsStore(tunnels: [tunnel])),
        updateChecker: UpdateChecker(settings: UpdateSettingsStore())
    )
}
