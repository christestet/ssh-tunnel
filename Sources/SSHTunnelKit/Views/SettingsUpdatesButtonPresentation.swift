struct SettingsUpdatesButtonPresentation: Equatable {
    let symbolName: String
    let usesAccentTint: Bool
    let accessibilityLabel = "About & Updates"
    let help = "About & Updates"

    init(hasUpdate: Bool) {
        symbolName = hasUpdate ? "arrow.down.circle.fill" : "info.circle.fill"
        usesAccentTint = hasUpdate
    }
}
