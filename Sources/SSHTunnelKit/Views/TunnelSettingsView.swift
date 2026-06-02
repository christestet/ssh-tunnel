import Foundation
import SwiftUI

enum SettingsNumberDisplay {
    static let portInputFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }()

    static func seconds(_ value: TimeInterval) -> String {
        "\(Int(value.rounded())) sec"
    }

    static func port(_ value: Int) -> String {
        String(value)
    }
}

public struct TunnelListSettingsView: View {
    @Bindable var manager: TunnelManager

    @State private var selectedId: UUID?
    @State private var isConfirmingDelete = false

    public init(manager: TunnelManager, initialSelection: UUID?) {
        self.manager = manager
        _selectedId = State(initialValue: initialSelection)
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(manager.settingsStore.tunnels) { tunnel in
                        HStack {
                            stateIndicator(for: tunnel.id)
                            Text(tunnel.name)
                        }
                        .tag(tunnel.id)
                    }
                    .onMove { source, destination in
                        manager.moveTunnels(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 10) {
                    Button {
                        let tunnel = manager.addTunnelForEditing()
                        selectedId = tunnel.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Tunnel")
                    .help("New Tunnel")

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete Tunnel")
                    .disabled(selectedId == nil)
                    .help("Delete Tunnel")

                    Button {
                        moveSelectedTunnel(by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .accessibilityLabel("Move Tunnel Up")
                    .disabled(!canMoveSelectedTunnel(by: -1))
                    .help("Move Tunnel Up")

                    Button {
                        moveSelectedTunnel(by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .accessibilityLabel("Move Tunnel Down")
                    .disabled(!canMoveSelectedTunnel(by: 1))
                    .help("Move Tunnel Down")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            if let id = selectedId,
               let tunnel = manager.settingsStore.tunnel(for: id),
               let controller = manager.controller(for: id) {
                TunnelSettingsView(
                    tunnel: tunnel,
                    controller: controller,
                    manager: manager
                )
                .id(id)
            } else {
                Text("Select a tunnel or add a new one.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: Constants.settingsMinWidth, minHeight: Constants.settingsMinHeight)
        .toolbar(removing: .sidebarToggle)
        .confirmationDialog(
            "Delete this tunnel?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Tunnel", role: .destructive) {
                guard let selectedId else { return }
                Task {
                    await manager.removeTunnelForEditing(id: selectedId)
                    self.selectedId = manager.settingsSelection
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            selectedId = manager.settingsSelection ?? selectedId ?? manager.settingsStore.tunnels.first?.id
        }
        .onChange(of: manager.settingsSelection) { _, newValue in
            if let newValue {
                selectedId = newValue
            }
        }
        .onChange(of: manager.settingsStore.tunnels.map(\.id)) { _, ids in
            guard let selectedId, ids.contains(selectedId) else {
                self.selectedId = ids.first
                return
            }
        }
    }

    @ViewBuilder
    private func stateIndicator(for id: UUID) -> some View {
        let ctrl = manager.controller(for: id)
        let state = ctrl?.state ?? .disconnected
        Circle()
            .fill(state.listColor)
            .frame(width: 8, height: 8)
    }

    private func selectedIndex() -> Int? {
        guard let selectedId else { return nil }
        return manager.settingsStore.tunnels.firstIndex { $0.id == selectedId }
    }

    private func canMoveSelectedTunnel(by offset: Int) -> Bool {
        guard let index = selectedIndex() else { return false }
        return manager.settingsStore.tunnels.indices.contains(index + offset)
    }

    private func moveSelectedTunnel(by offset: Int) {
        guard let index = selectedIndex(), canMoveSelectedTunnel(by: offset) else { return }
        let destination = offset < 0 ? index - 1 : index + 2
        manager.moveTunnels(fromOffsets: IndexSet(integer: index), toOffset: destination)
    }
}

struct TunnelSettingsView: View {
    @Bindable var controller: TunnelController
    let manager: TunnelManager

    @State private var draft: TunnelSettings
    @State private var message: String?
    @State private var isError = false
    @State private var detectedForwards: [ForwardInfo] = []
    @State private var isProbingPorts = false
    @State private var diagnosticReport: TunnelDiagnosticReport?
    @State private var isRunningDiagnostic = false
    @State private var autosaveTask: Task<Void, Never>?

    init(tunnel: TunnelSettings, controller: TunnelController, manager: TunnelManager) {
        self.controller = controller
        self.manager = manager
        _draft = State(initialValue: tunnel)
    }

    var body: some View {
        TunnelSettingsForm(
            draft: $draft,
            logLevel: Binding(
                get: { manager.logSettingsStore.minimumLevel },
                set: { manager.logSettingsStore.minimumLevel = $0 }
            ),
            detectedForwards: detectedForwards,
            isProbingPorts: isProbingPorts,
            message: message,
            isError: isError,
            diagnosticReport: diagnosticReport,
            isRunningDiagnostic: isRunningDiagnostic,
            focusedQuickForwardID: manager.settingsQuickForwardFocus,
            onRefreshPorts: { Task { await refreshPorts() } },
            onRunDiagnostic: { Task { await runDiagnostic() } },
            onDeleteQuickForward: removeQuickForward,
            onFocusHandled: { manager.settingsQuickForwardFocus = nil }
        )
        .onAppear {
            detectedForwards = controller.sshConfigForwardInfos
        }
        .onChange(of: draft) { _, _ in
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            persistDraft()
        }
    }

    private func refreshPorts() async {
        isProbingPorts = true
        defer { isProbingPorts = false }
        await controller.loadResolvedOptions()
        detectedForwards = controller.sshConfigForwardInfos
    }

    private func runDiagnostic() async {
        isRunningDiagnostic = true
        defer { isRunningDiagnostic = false }
        diagnosticReport = await TunnelDiagnosticRunner().diagnose(
            draft,
            isTunnelConnected: controller.state == .connected
        )
    }

    private func removeQuickForward(id: UUID) {
        draft.quickForwards.removeAll { $0.id == id }
        Task {
            do {
                try await manager.removeQuickForward(id, from: draft.id)
                detectedForwards = controller.sshConfigForwardInfos
                if isError {
                    message = nil
                }
                isError = false
            } catch {
                showError(error)
            }
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            persistDraft()
        }
    }

    private func persistDraft() {
        do {
            try manager.updateSettings(draft)
            if let saved = manager.settingsStore.tunnel(for: draft.id) {
                draft = saved
            }
            detectedForwards = controller.sshConfigForwardInfos
            if isError {
                message = nil
            }
            isError = false
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        message = error.localizedDescription
        isError = true
    }
}

/// SettingsForm using native grouped form style (Tahoe 26 standard)
/// No custom glass effects - just native form styling with proper spacing
struct TunnelSettingsForm: View {
    @Binding var draft: TunnelSettings
    @Binding var logLevel: LogLevel
    let detectedForwards: [ForwardInfo]
    let isProbingPorts: Bool
    let message: String?
    let isError: Bool
    let diagnosticReport: TunnelDiagnosticReport?
    let isRunningDiagnostic: Bool
    var focusedQuickForwardID: UUID? = nil
    let onRefreshPorts: () -> Void
    let onRunDiagnostic: () -> Void
    let onDeleteQuickForward: (UUID) -> Void
    var onFocusHandled: () -> Void = {}

    @State private var highlightedQuickForwardID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { focusIfNeeded(proxy: proxy) }
            .onChange(of: focusedQuickForwardID) { _, _ in
                focusIfNeeded(proxy: proxy)
            }
        }
    }

    private func focusIfNeeded(proxy: ScrollViewProxy) {
        guard let target = focusedQuickForwardID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(target, anchor: .center)
                highlightedQuickForwardID = target
            }
            onFocusHandled()
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.4)) {
                    if highlightedQuickForwardID == target {
                        highlightedQuickForwardID = nil
                    }
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 20) {
            if let message = message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .primary)
                    .padding(.horizontal, 16)
            }

            GroupBox(label: Text("Logging")) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow("Log Level") {
                        Picker("Log Level", selection: $logLevel) {
                            ForEach(LogLevel.allCases, id: \.self) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox(label: Text("Tunnel Configuration")) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow("Name") {
                        TextField("Tunnel name", text: $draft.name)
                            .textFieldStyle(.plain)
                    }

                    SettingsRow("Host Alias") {
                        TextField("Host alias from ~/.ssh/config", text: $draft.hostAlias)
                            .textFieldStyle(.plain)
                    }

                    SettingsRow("Control Path") {
                        TextField("SSH control path", text: $draft.controlPath)
                            .textFieldStyle(.plain)
                    }

                    SettingsRow("Health Check Interval") {
                        Stepper(value: $draft.healthCheckInterval, in: 5...300, step: 5) {
                            Text(verbatim: SettingsNumberDisplay.seconds(draft.healthCheckInterval))
                        }
                        .controlSize(.small)
                    }

                    SettingsRow("Max Backoff") {
                        Stepper(value: $draft.maxBackoff, in: 10...300, step: 10) {
                            Text(verbatim: SettingsNumberDisplay.seconds(draft.maxBackoff))
                        }
                        .controlSize(.small)
                    }

                    SettingsRow("Start at Login") {
                        Toggle("Connect this tunnel when you log in", isOn: $draft.autostartOnLogin)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if draft.autostartOnLogin {
                        HStack(alignment: .top, spacing: 16) {
                            Text("Startup Check")
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                                .frame(width: 144, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Host or address to check before connecting", text: $draft.autostartReadinessProbeHost)
                                    .textFieldStyle(.plain)
                                HStack(spacing: 8) {
                                    Text("Port:")
                                        .font(.caption)
                                    Stepper(value: $draft.autostartReadinessProbePort, in: 1...65535, step: 1) {
                                        Text(verbatim: SettingsNumberDisplay.port(draft.autostartReadinessProbePort))
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DetectedLocalForwardsSection(
                forwards: detectedForwards,
                labels: $draft.localForwardLabels,
                isProbingPorts: isProbingPorts,
                onRefreshPorts: onRefreshPorts
            )

            QuickForwardsSection(
                forwards: $draft.quickForwards,
                highlightedID: highlightedQuickForwardID,
                onDelete: onDeleteQuickForward
            )

            if let report = diagnosticReport {
                GroupBox(label: Text("Diagnostics")) {
                    DiagnosticReportView(report: report)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onRunDiagnostic()
            } label: {
                Label(isRunningDiagnostic ? "Running Diagnostics…" : "Run Diagnostics", systemImage: "stethoscope")
            }
            .disabled(isRunningDiagnostic)
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickForwardsSection: View {
    @Binding var forwards: [QuickForward]
    var highlightedID: UUID? = nil
    let onDelete: (UUID) -> Void

    var body: some View {
        GroupBox(label: Text("Quick Forwards")) {
            VStack(alignment: .leading, spacing: 10) {
                if forwards.isEmpty {
                    Text("No quick forwards configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach($forwards) { $forward in
                            QuickForwardRow(
                                forward: $forward,
                                onDelete: {
                                    onDelete(forward.id)
                                }
                            )
                            .id(forward.id)
                            .background(
                                RoundedRectangle(cornerRadius: Constants.settingsGroupCornerRadius)
                                    .fill(Color.accentColor.opacity(highlightedID == forward.id ? 0.18 : 0))
                            )
                        }
                    }
                }

                Button {
                    forwards.append(QuickForward.makeDefault(remotePort: 443))
                } label: {
                    Label("Add Quick Forward", systemImage: "plus")
                }
                .controlSize(.small)
                .padding(.top, forwards.isEmpty ? 2 : 6)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetectedLocalForwardsSection: View {
    let forwards: [ForwardInfo]
    @Binding var labels: [LocalForwardLabel]
    let isProbingPorts: Bool
    let onRefreshPorts: () -> Void

    var body: some View {
        GroupBox(label: Text("SSH Config Forwards")) {
            VStack(alignment: .leading, spacing: 10) {
                if forwards.isEmpty {
                    Text("No SSH config forwards detected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(forwards) { forward in
                            DetectedLocalForwardRow(
                                forward: forward,
                                label: labelBinding(for: forward.localPort)
                            )
                        }
                    }
                }

                Button {
                    onRefreshPorts()
                } label: {
                    Label("Refresh Forwards", systemImage: "arrow.clockwise")
                }
                .disabled(isProbingPorts)
                .controlSize(.small)
                .padding(.top, forwards.isEmpty ? 2 : 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelBinding(for localPort: Int) -> Binding<String> {
        Binding(
            get: {
                labels.first(where: { $0.localPort == localPort })?.label ?? ""
            },
            set: { newValue in
                if let index = labels.firstIndex(where: { $0.localPort == localPort }) {
                    if newValue.isEmpty {
                        labels.remove(at: index)
                    } else {
                        labels[index].label = newValue
                    }
                } else if !newValue.isEmpty {
                    labels.append(LocalForwardLabel(localPort: localPort, label: newValue))
                }
            }
        )
    }
}

private struct DetectedLocalForwardRow: View {
    let forward: ForwardInfo
    @Binding var label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Service label", text: $label)
                .textFieldStyle(.plain)
                .frame(minWidth: 110)

            HStack(spacing: 6) {
                Text("Local")
                    .foregroundStyle(.secondary)
                PortBadge(number: forward.localPort)

                if let remotePort = forward.remotePort {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("Remote")
                        .foregroundStyle(.secondary)
                    PortBadge(number: remotePort)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Constants.settingsGroupCornerRadius)
                .fill(.quinary)
        )
    }
}

private struct QuickForwardRow: View {
    @Binding var forward: QuickForward
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TextField("Service label", text: $forward.label)
                .textFieldStyle(.plain)
                .frame(minWidth: 110)

            HStack(spacing: 6) {
                Text("Remote port on SSH host")
                    .foregroundStyle(.secondary)
                TextField("Port", value: $forward.remotePort, formatter: SettingsNumberDisplay.portInputFormatter)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 64)
                    .help("Remote port on SSH host")
                Stepper("", value: $forward.remotePort, in: 1...65535, step: 1)
                    .labelsHidden()
            }
            .controlSize(.small)
            .frame(width: 164, alignment: .leading)

            Text(localPortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 118, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove Quick Forward")
            .help("Remove Quick Forward")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Constants.settingsGroupCornerRadius)
                .fill(.quinary)
        )
    }

    private var localPortDescription: String {
        guard let localPort = forward.localPort else { return "Local: auto" }
        return "Local " + SettingsNumberDisplay.port(localPort)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .frame(width: 160, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PortBadge: View {
    let number: Int

    var body: some View {
        Text(verbatim: SettingsNumberDisplay.port(number))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.tertiary, lineWidth: 1)
                    )
            )
    }
}

private struct DiagnosticReportView: View {
    let report: TunnelDiagnosticReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.status.symbolName)
                        .foregroundStyle(item.status.color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct DiagnosticStatusBadge: View {
    let status: TunnelDiagnosticStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
    }
}

private extension TunnelDiagnosticStatus {
    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .warning: return "Warnings"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

#Preview("Empty") {
    @Previewable @State var draft = TunnelSettings.makeDefault()
    @Previewable @State var logLevel = LogLevel.warning
    TunnelSettingsForm(
        draft: $draft,
        logLevel: $logLevel,
        detectedForwards: [],
        isProbingPorts: false,
        message: nil,
        isError: false,
        diagnosticReport: nil,
        isRunningDiagnostic: false,
        onRefreshPorts: {},
        onRunDiagnostic: {},
        onDeleteQuickForward: { _ in }
    )
    .frame(width: 760, height: 640)
}

#Preview("Populated") {
    @Previewable @State var logLevel = LogLevel.warning
    @Previewable @State var draft = TunnelSettings(
        id: UUID(),
        name: "Production DB",
        hostAlias: "prod-db",
        controlPath: "~/.ssh/control-sshtunnelapp-%C",
        healthCheckInterval: 15,
        maxBackoff: 60,
        autostartOnLogin: true,
        autostartReadinessProbeHost: "vpn-gateway.internal",
        autostartReadinessProbePort: 443
    )
    TunnelSettingsForm(
        draft: $draft,
        logLevel: $logLevel,
        detectedForwards: [
            ForwardInfo(localPort: 15432, remotePort: 5432),
            ForwardInfo(localPort: 16379, remotePort: 6379),
            ForwardInfo(localPort: 18080, remotePort: 8080)
        ],
        isProbingPorts: false,
        message: "Settings saved.",
        isError: false,
        diagnosticReport: nil,
        isRunningDiagnostic: false,
        onRefreshPorts: {},
        onRunDiagnostic: {},
        onDeleteQuickForward: { _ in }
    )
    .frame(width: 760, height: 640)
}

#Preview("Error") {
    @Previewable @State var draft = TunnelSettings.makeDefault()
    @Previewable @State var logLevel = LogLevel.warning
    TunnelSettingsForm(
        draft: $draft,
        logLevel: $logLevel,
        detectedForwards: [],
        isProbingPorts: true,
        message: "Host alias cannot be empty.",
        isError: true,
        diagnosticReport: TunnelDiagnosticReport(
            tunnelName: "New Tunnel",
            hostAlias: "",
            items: [
                TunnelDiagnosticItem(
                    id: "required-fields",
                    title: "Required fields",
                    status: .failed,
                    detail: "Host alias is empty."
                )
            ]
        ),
        isRunningDiagnostic: false,
        onRefreshPorts: {},
        onRunDiagnostic: {},
        onDeleteQuickForward: { _ in }
    )
    .frame(width: 760, height: 640)
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
    let store = TunnelSettingsStore(tunnels: [tunnel])
    let manager = TunnelManager(settingsStore: store)
    TunnelSettingsView(
        tunnel: tunnel,
        controller: manager.controller(for: tunnel.id)!,
        manager: manager
    )
}
