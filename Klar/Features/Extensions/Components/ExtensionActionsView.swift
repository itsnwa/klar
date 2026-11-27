import AppKit
import SwiftUI
import WebKit

/// The extensions' end of the URL bar: pinned extensions' toolbar buttons
/// (icon and badge, for the active tab), then the puzzle button listing
/// every running extension. Popups hang from these buttons, so they're
/// AppKit views (ExtensionManager.presentActionPopup anchors to them).
/// Nothing shows while no extension is running.
struct ExtensionActionsView: View {
    @ObservedObject private var manager = ExtensionManager.shared
    /// The active tab decides each action's icon and badge.
    let activeTabID: UUID?

    var body: some View {
        let running = manager.runningItems
        if !running.isEmpty {
            HStack(spacing: 2) {
                ForEach(running.filter(\.record.isPinned)) { item in
                    ExtensionActionButton(
                        extensionID: item.id,
                        revision: manager.actionsRevision,
                        activeTabID: activeTabID
                    )
                    .frame(width: 22, height: 22)
                }
                ExtensionsMenuButton()
                    .frame(width: 20, height: 22)
            }
        }
    }
}

// MARK: - Pinned action button

private struct ExtensionActionButton: NSViewRepresentable {
    let extensionID: String
    /// Not read; changing it makes SwiftUI call updateNSView.
    let revision: Int
    let activeTabID: UUID?

    func makeNSView(context: Context) -> ExtensionActionButtonView {
        let view = ExtensionActionButtonView(extensionID: extensionID)
        ExtensionManager.shared.registerActionAnchor(view, for: extensionID)
        return view
    }

    func updateNSView(_ view: ExtensionActionButtonView, context: Context) {
        view.refresh()
    }
}

final class ExtensionActionButtonView: NSButton {
    let extensionID: String
    private let badge = NSTextField(labelWithString: "")

    init(extensionID: String) {
        self.extensionID = extensionID
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        target = self
        action = #selector(runAction)

        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.systemGray.cgColor
        badge.isHidden = true
        addSubview(badge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let manager = ExtensionManager.shared
        let action = manager.action(for: extensionID)
        let item = manager.items.first { $0.id == extensionID }
        let icon = action?.icon(for: NSSize(width: 16, height: 16))
            ?? item?.webExtension?.actionIcon(for: NSSize(width: 16, height: 16))
            ?? item?.webExtension?.icon(for: NSSize(width: 16, height: 16))
        if image !== icon { image = icon }

        let label = action?.label.isEmpty == false ? action!.label : (item?.name ?? "")
        if toolTip != label { toolTip = label }
        setAccessibilityLabel(label)
        appearsDisabled = action.map { !$0.isEnabled } ?? false

        let badgeText = action?.badgeText ?? ""
        if badge.stringValue != badgeText { badge.stringValue = badgeText }
        badge.isHidden = badgeText.isEmpty
        if !badgeText.isEmpty {
            let width = max(12, min(bounds.width, badge.intrinsicContentSize.width + 4))
            badge.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: 10)
            badge.layer?.backgroundColor = (action?.hasUnreadBadgeText == true ? NSColor.controlAccentColor : NSColor.systemGray).cgColor
        }
    }

    /// Dimmed rather than disabled, so a right-click still gets its menu.
    private var appearsDisabled = false {
        didSet { if alphaValue != (appearsDisabled ? 0.4 : 1) { alphaValue = appearsDisabled ? 0.4 : 1 } }
    }

    @objc private func runAction() {
        guard !appearsDisabled else { return }
        ExtensionManager.shared.performAction(for: extensionID)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ExtensionMenus.actionMenu(for: extensionID)
    }
}

// MARK: - Puzzle button

private struct ExtensionsMenuButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = PuzzleButton()
        ExtensionManager.shared.puzzleAnchor = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {}

    private final class PuzzleButton: NSButton {
        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 22))
            isBordered = false
            imagePosition = .imageOnly
            focusRingType = .none
            image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            contentTintColor = .secondaryLabelColor
            toolTip = "Extensions"
            target = self
            action = #selector(showMenu)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func showMenu() {
            // Below the button, whichever way its coordinates run.
            let below = isFlipped ? bounds.maxY + 4 : bounds.minY - 4
            ExtensionMenus.puzzleMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: self)
        }
    }
}

// MARK: - Menus

@MainActor
enum ExtensionMenus {
    /// Every running extension (click runs its action), then pinning and
    /// the ways to manage and find extensions.
    static func puzzleMenu() -> NSMenu {
        let manager = ExtensionManager.shared
        let menu = NSMenu()
        let running = manager.runningItems

        for item in running {
            let action = manager.action(for: item.id)
            let menuItem = ClosureMenuItem(title: item.name) { manager.performAction(for: item.id) }
            menuItem.setVisibleImage(action?.icon(for: NSSize(width: 16, height: 16))
                ?? item.webExtension?.icon(for: NSSize(width: 16, height: 16)))
            menuItem.isEnabled = action?.isEnabled ?? true
            menu.addItem(menuItem)
        }

        if !running.isEmpty {
            menu.addItem(.separator())
            let pinItem = NSMenuItem(title: "Pin to URL Bar", action: nil, keyEquivalent: "")
            let pinMenu = NSMenu()
            for item in running {
                let toggle = ClosureMenuItem(title: item.name) {
                    manager.setPinned(!item.record.isPinned, for: item.id)
                }
                toggle.state = item.record.isPinned ? .on : .off
                pinMenu.addItem(toggle)
            }
            pinItem.submenu = pinMenu
            menu.addItem(pinItem)
        }

        menu.addItem(ClosureMenuItem(title: "Manage Extensions…") {
            SettingsWindowController.shared.showSettings(category: .extensions)
        })
        menu.addItem(ClosureMenuItem(title: "Chrome Web Store") {
            manager.showExtensionPage(ExtensionInstaller.webStoreURL)
        })
        return menu
    }

    /// The right-click menu of a pinned extension's button: the extension's
    /// own items (contextMenus with the "action" context), then Klar's.
    static func actionMenu(for id: String) -> NSMenu {
        let manager = ExtensionManager.shared
        let menu = NSMenu()
        if let action = manager.action(for: id) {
            let ownItems = action.menuItems
            ownItems.forEach { menu.addItem($0) }
            if !ownItems.isEmpty { menu.addItem(.separator()) }
        }
        if manager.context(for: id)?.optionsPageURL != nil {
            menu.addItem(ClosureMenuItem(title: "Options") { manager.openOptionsPage(for: id) })
        }
        menu.addItem(ClosureMenuItem(title: "Unpin from URL Bar") { manager.setPinned(false, for: id) })
        menu.addItem(ClosureMenuItem(title: "Manage Extensions…") {
            SettingsWindowController.shared.showSettings(category: .extensions)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove from Klar…") {
            Task { await manager.confirmAndRemove(id: id) }
        })
        return menu
    }
}

/// A menu item that runs a closure.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Menu actions run on the main thread.
    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
