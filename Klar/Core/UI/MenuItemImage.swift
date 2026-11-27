import AppKit

extension NSMenuItem {
    /// Sets the image shown beside the item's title, and keeps it shown:
    /// built with the macOS 27 SDK, AppKit decides whether a menu item's
    /// image shows and hides most of them, symbols and other images alike,
    /// unless the item asks for it (`preferredImageVisibility`). For items
    /// whose image says what they are or tells them apart: a space's or a
    /// group's icon, an extension's, and the + menu's.
    func setVisibleImage(_ image: NSImage?) {
        self.image = image
        if #available(macOS 27.0, *) {
            preferredImageVisibility = image == nil ? .automatic : .visible
        }
    }

    /// An SF Symbol as the item's image, kept shown (`setVisibleImage`)
    func setVisibleSymbol(_ name: String) {
        setVisibleImage(NSImage(systemSymbolName: name, accessibilityDescription: nil))
    }
}
