import AppKit
import SwiftUI

/// App-level update controls: current version, latest-check status, the
/// automatic-check toggle, and a manual "Check Now" button. Presented as a
/// popover from the settings sidebar footer, separate from the per-tunnel
/// configuration in the detail pane.
struct UpdatesSettingsView: View {
    @Bindable var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            status
            Toggle("Automatically check for updates", isOn: $updateChecker.automaticChecksEnabled)
                .toggleStyle(.switch)
            HStack {
                Button {
                    Task { await updateChecker.checkForUpdates() }
                } label: {
                    if updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check Now")
                    }
                }
                .disabled(updateChecker.isChecking)
                Spacer()
                if let date = updateChecker.lastCheckDate {
                    Text("Last checked \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = updateChecker.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Updates").font(.headline)
                if let badge = AppVersionDisplay.badge(for: updateChecker.currentVersion) {
                    if let releaseURL = AppVersionDisplay.releaseURL(for: updateChecker.currentVersion) {
                        Link("Current version \(badge)", destination: releaseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .pointerStyle(.link)
                            .help("Open \(badge) on GitHub Releases")
                            .accessibilityLabel("Open current version \(badge) on GitHub Releases")
                    } else {
                        Text("Current version \(badge)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let update = updateChecker.availableUpdate {
            VStack(alignment: .leading, spacing: 6) {
                Label("Update available \(update.version)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("SSH Tunnel ships as an un-notarized DMG, so updates are installed manually: open the release page, download the DMG, and drag the app to Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(update.releaseURL)
                } label: {
                    Label("View Release & Download", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
