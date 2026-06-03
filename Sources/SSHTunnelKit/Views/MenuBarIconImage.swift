import AppKit

public enum MenuBarIconImage {
    public static let defaultSize = NSSize(width: 18, height: 18)

    public static func image(baseIcon: NSImage, state: TunnelState) -> NSImage {
        tintedImage(baseIcon: baseIcon, color: state.menuBarTintColor, size: defaultSize)
    }

    private static func tintedImage(baseIcon: NSImage, color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            baseIcon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}
