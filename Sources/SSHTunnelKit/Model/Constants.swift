import SwiftUI

/// App-wide UI tunables. Centralised so the menu-bar popover, settings
/// window, and help window stay visually consistent under Liquid Glass.
enum Constants {
    // MARK: Menu bar popover

    static let menuBarPanelWidth: CGFloat = 360
    static let menuBarPanelMinHeight: CGFloat = 220
    static let menuBarListMaxHeight: CGFloat = 420
    static let menuBarRowCornerRadius: CGFloat = 8
    static let menuBarActionBarHorizontalPadding: CGFloat = 14
    static let menuBarActionBarVerticalPadding: CGFloat = 10

    // MARK: Settings window

    static let settingsMinWidth: CGFloat = 700
    static let settingsMinHeight: CGFloat = 500
    static let settingsFormMaxWidth: CGFloat = 760
    static let settingsFormPadding: CGFloat = 28
    static let settingsGroupCornerRadius: CGFloat = 8
    static let settingsGroupPadding: CGFloat = 18

    // MARK: Help window

    static let helpWindowWidth: CGFloat = 560
    static let helpWindowHeight: CGFloat = 620
}
