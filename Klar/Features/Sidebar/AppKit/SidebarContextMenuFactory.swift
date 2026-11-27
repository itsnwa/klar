import AppKit

@MainActor
enum SidebarContextMenuFactory {
    /// The menu for a saved tab (or its peek row), folder or collection
    /// header. Regular tabs use `SidebarRegularTabContextMenuFactory`.
    static func menu(
        for key: SidebarRowKey,
        sidebarManager: SidebarManager,
        tabManager: TabManager,
        anchor: NSView
    ) -> NSMenu {
        let menu = NSMenu()
        // Honor explicit `isEnabled = false` on items (Reading List for
        // non-web pages, Update to Current URL when not applicable).
        // Without this, NSMenu auto-enables anything whose target responds
        // to its action selector — overriding our gating.
        menu.autoenablesItems = false
        switch key {
        case .tab(let id), .peekTab(let id, _):
            buildTabMenu(menu, tabID: id, sidebarManager: sidebarManager, tabManager: tabManager, anchor: anchor)
        case .folder(let id):
            buildFolderMenu(menu, folderID: id, sidebarManager: sidebarManager)
        case .collectionHeader(let id):
            buildCollectionMenu(menu, collectionID: id, sidebarManager: sidebarManager)
        case .regularTab, .divider, .newTabButton, .dropSlot:
            break
        }
        return menu
    }

    private static func buildTabMenu(
        _ menu: NSMenu,
        tabID: UUID,
        sidebarManager: SidebarManager,
        tabManager: TabManager,
        anchor: NSView
    ) {
        guard let tab = sidebarManager.sidebarStructure.tabs[tabID] else { return }

        // Sections as the library's menus have them: opening it, then
        // passing its page on (the only items with icons, so they read as
        // one), then naming and placing it, then putting it away

        // In this window
        let isOpenHere = sidebarManager.isOpenHere(tabID)
        if !isOpenHere {
            addItem(menu, title: "Load Tab") { sidebarManager.loadTab(withID: tabID) }
        }
        addSplitItems(menu, itemID: tabID, tabManager: tabManager)
        // Its page as it's saved; the saved tab stays as it is
        if !tab.url.isEmpty {
            addItem(menu, title: "Open in Private Tab") {
                tabManager.createNewTab(url: tab.url, inSpace: tab.collectionID, isPrivate: true)
            }
        }

        menu.addItem(.separator())

        addCopyLinkItem(menu, url: tab.url, tabManager: tabManager)
        addShareItem(menu, url: tab.url, title: tab.displayTitle, anchor: anchor)
        addReadingListItem(menu, url: tab.url, title: tab.displayTitle, tabManager: tabManager)

        menu.addItem(.separator())

        addItem(menu, title: "Rename") { sidebarManager.startRenaming(tabID) }
        if tab.customTitle != nil {
            addItem(menu, title: "Clear Custom Title") {
                // `updateCustomTitle` treats an empty string as "clear",
                // i.e. sets `customTitle = nil`. Passing `tab.title` would
                // instead set the custom title equal to the original — the
                // displayed title would look right but `customTitle`
                // wouldn't actually be cleared, and the menu item would
                // continue to appear.
                sidebarManager.updateCustomTitle(for: tabID, title: "")
            }
        }
        addEditSavedPageSubmenu(menu, tabID: tabID, sidebarManager: sidebarManager)

        menu.addItem(.separator())

        addGroupItems(menu, itemID: tabID, sidebarManager: sidebarManager)
        addMoveToSubmenu(menu, draggedID: tabID, sidebarManager: sidebarManager)
        addMoveToSpaceSubmenu(menu, itemID: tabID, currentSpaceID: tab.collectionID, spaceSelection: sidebarManager.spaceSelection)
        addItem(menu, title: "Pin Tab") { sidebarManager.pin(itemID: tabID) }

        menu.addItem(.separator())

        if isOpenHere {
            addItem(menu, title: "Unload Tab") { sidebarManager.unloadTab(withID: tabID) }
        }
        addItem(menu, title: "Remove from Sidebar") { sidebarManager.removeTab(withID: tabID) }
    }

    /// "Edit saved page" submenu — mirrors the SwiftUI sidebar on main.
    /// Two related operations on the bookmarked URL of a saved tab or
    /// pinned site:
    ///  • Update to Current URL — rewrites the bookmark to match where
    ///    the live browser tab is now (only meaningful when the tab is
    ///    loaded AND the browser has navigated away from the saved URL).
    ///  • Edit URL… — opens a sheet for free-form URL editing.
    static func addEditSavedPageSubmenu(_ menu: NSMenu, tabID: UUID, sidebarManager: SidebarManager) {
        guard let tab = sidebarManager.sidebarStructure.tabs[tabID] else { return }
        let editParent = NSMenuItem(title: "Edit saved page", action: nil, keyEquivalent: "")
        let editSub = NSMenu(title: "Edit saved page")
        editSub.autoenablesItems = false
        let updateItem = NSMenuItem(title: "Update to Current URL", action: #selector(MenuTarget.invoke), keyEquivalent: "")
        let updateTarget = MenuTarget {
            NotificationCenter.default.post(
                name: NSNotification.Name("UpdateSavedTabToCurrentState"),
                object: sidebarManager,
                userInfo: ["tabID": tabID.uuidString]
            )
        }
        updateItem.target = updateTarget
        updateItem.representedObject = updateTarget
        // Disabled when the saved tab is unloaded (no live browser tab to
        // pull current state from) or when the browser tab hasn't navigated
        // away from the bookmarked URL — same gate the SwiftUI version used.
        updateItem.isEnabled = sidebarManager.isOpenHere(tabID) && sidebarManager.shouldShowReturnToSavedPage(for: tabID)
        editSub.addItem(updateItem)

        addItem(editSub, title: "Edit URL\u{2026}") {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowEditURLDialog"),
                object: sidebarManager,
                userInfo: ["tabID": tabID, "url": tab.url]
            )
        }
        editParent.submenu = editSub
        menu.addItem(editParent)
    }

    private static func buildFolderMenu(
        _ menu: NSMenu,
        folderID: UUID,
        sidebarManager: SidebarManager
    ) {
        addItem(menu, title: "Rename") { sidebarManager.startRenaming(folderID) }

        addItem(menu, title: "Change Icon\u{2026}") {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowFolderIconPicker"),
                object: sidebarManager,
                userInfo: ["folderID": folderID]
            )
        }

        if let icon = sidebarManager.sidebarStructure.folders[folderID]?.icon,
           !icon.isEmpty, icon != FolderIcons.defaultIcon {
            // Back to its tabs' favicons
            addItem(menu, title: "Remove Icon") {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChangeFolderIcon"),
                    object: nil,
                    userInfo: [
                        "folderID": folderID.uuidString,
                        "icon": FolderIcons.defaultIcon
                    ]
                )
            }
        }

        addMoveToSubmenu(menu, draggedID: folderID, sidebarManager: sidebarManager)
        addMoveToSpaceSubmenu(menu, itemID: folderID, currentSpaceID: sidebarManager.sidebarStructure.folders[folderID]?.collectionID, spaceSelection: sidebarManager.spaceSelection)

        addItem(menu, title: "New Subgroup") {
            // Call the manager directly. The legacy CreateSubfolder
            // notification handler expects a `parentID` String key — our
            // menu was posting `parentFolderID` (UUID), so the
            // notification round-trip silently dropped the request.
            let newID = sidebarManager.createFolder(title: OpenTabGroup.defaultTitle, in: folderID)
            sidebarManager.expandedFolders.insert(folderID)
            sidebarManager.isRenaming = newID
        }

        menu.addItem(.separator())

        let contents = sidebarManager.sidebarStructure.contents(ofFolder: folderID)
        let isEmpty = contents.tabIDs.isEmpty && contents.folderIDs.isEmpty
        addItem(menu, title: isEmpty ? "Delete Group" : "Delete Group\u{2026}") {
            if isEmpty {
                sidebarManager.deleteFolder(folderID, includingContents: false)
            } else {
                confirmDeleteFolder(folderID, sidebarManager: sidebarManager)
            }
        }
    }

    /// Asks before deleting a group with something in it, with a checkbox
    /// to delete its tabs and groups too; otherwise they take its place.
    private static func confirmDeleteFolder(_ folderID: UUID, sidebarManager: SidebarManager) {
        let structure = sidebarManager.sidebarStructure
        guard let folder = structure.folders[folderID] else { return }
        let contents = structure.contents(ofFolder: folderID)

        var counts: [String] = []
        if !contents.tabIDs.isEmpty {
            counts.append(contents.tabIDs.count == 1 ? "1 tab" : "\(contents.tabIDs.count) tabs")
        }
        if !contents.folderIDs.isEmpty {
            counts.append(contents.folderIDs.count == 1 ? "1 group" : "\(contents.folderIDs.count) groups")
        }

        let alert = NSAlert()
        alert.messageText = "Delete “\(folder.displayTitle)”?"
        alert.informativeText = "What’s in it takes its place in the sidebar, unless you delete it too. Deleted tabs that are open close."
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also delete its \(counts.joined(separator: " and "))"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let delete = {
            let includingContents = alert.suppressionButton?.state == .on
            sidebarManager.deleteFolder(folderID, includingContents: includingContents)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    delete()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete()
        }
    }

    private static func buildCollectionMenu(
        _ menu: NSMenu,
        collectionID: UUID,
        sidebarManager: SidebarManager
    ) {
        addItem(menu, title: "Rename Space") { sidebarManager.startRenaming(collectionID) }
        addItem(menu, title: "Space Settings\u{2026}") {
            SettingsWindowController.shared.showSettings(category: .spaces, spaceID: collectionID)
        }
        menu.addItem(.separator())
        addItem(menu, title: "New Group") {
            // No `CreateFolder` notification handler exists on
            // SidebarManager; call the public API directly. Top-level
            // folders are created with no parent.
            let newID = sidebarManager.createFolder(title: OpenTabGroup.defaultTitle, in: nil as UUID?)
            sidebarManager.isRenaming = newID
        }
        menu.addItem(.separator())
        addItem(menu, title: "Clean Up Saved Tabs\u{2026}") {
            sidebarManager.showCleanUp()
        }
    }

    @discardableResult
    static func addItem(_ menu: NSMenu, title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.invoke), keyEquivalent: "")
        if let symbol {
            item.setVisibleSymbol(symbol)
        }
        let target = MenuTarget(handler: action)
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return item
    }

    /// Split Tab (beside the page on screen), and Remove from Split for a
    /// tab in a split view. `itemID` is a saved tab's or a regular tab's.
    static func addSplitItems(_ menu: NSMenu, itemID: UUID, tabManager: TabManager) {
        let splitItem = addItem(menu, title: "Split Tab") { tabManager.splitTab(sidebarItem: itemID) }
        splitItem.isEnabled = tabManager.canSplitTab(sidebarItem: itemID)
        if tabManager.isInSplitView(sidebarItem: itemID) {
            addItem(menu, title: "Remove from Split") { tabManager.removeFromSplitView(sidebarItem: itemID) }
        }
    }

    // MARK: - Groups

    /// New Group with Tab, and Remove from Group for a tab in one. `itemID`
    /// is a saved tab's or a regular tab's.
    static func addGroupItems(_ menu: NSMenu, itemID: UUID, sidebarManager: SidebarManager) {
        if sidebarManager.canGroup(itemID) {
            addItem(menu, title: "New Group with Tab") { sidebarManager.newGroup(withTabs: [itemID]) }
        }
        if sidebarManager.isInGroup(itemID) {
            addItem(menu, title: "Remove from Group") { sidebarManager.removeFromGroup(itemID) }
        }
    }

    /// The menu for several tabs selected together (⌘-click), top to
    /// bottom: saved tabs' and regular tabs' IDs.
    static func menu(forTabs itemIDs: [UUID], sidebarManager: SidebarManager, tabManager: TabManager) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let groupItem = addItem(menu, title: "New Group with \(itemIDs.count) Tabs") {
            sidebarManager.newGroup(withTabs: itemIDs)
        }
        groupItem.isEnabled = itemIDs.contains(where: sidebarManager.canGroup)
        menu.addItem(.separator())
        addItem(menu, title: "Close \(itemIDs.count) Tabs") { sidebarManager.closeTabs(itemIDs) }
        return menu
    }

    /// The menu for a group of regular tabs (`OpenTabGroup`)
    static func menu(forRegularGroup groupID: UUID, sidebarManager: SidebarManager, tabManager: TabManager) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let group = OpenTabStore.shared.group(withID: groupID)
        let pages = sidebarManager.pages(inRegularGroup: groupID)

        addItem(menu, title: "Rename") { sidebarManager.startRenaming(groupID) }
        addItem(menu, title: "Change Icon\u{2026}") {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowFolderIconPicker"),
                object: sidebarManager,
                userInfo: ["folderID": groupID]
            )
        }
        if let icon = group?.icon, !icon.isEmpty {
            // Back to its tabs' favicons
            addItem(menu, title: "Remove Icon") { OpenTabStore.shared.updateGroup(groupID, icon: "") }
        }

        menu.addItem(.separator())

        // Its tabs saved, in a saved group at the end of the space's
        addItem(menu, title: "Save Group") {
            sidebarManager.saveRegularGroup(groupID, in: nil, at: sidebarManager.sidebarStructure.rootItems.count)
        }
        addMoveToSpaceSubmenu(menu, itemID: groupID, currentSpaceID: pages.first.flatMap { SpaceManager.shared.spaceID(of: $0) },
                              spaceSelection: sidebarManager.spaceSelection)

        menu.addItem(.separator())

        addItem(menu, title: "Ungroup") { sidebarManager.ungroupRegularGroup(groupID) }
        // Its tabs close, everywhere
        addItem(menu, title: "Close Group") { sidebarManager.closeRegularGroup(groupID) }
        return menu
    }

    // MARK: - "Move to Space" submenu

    /// The other spaces, to move a saved tab, folder or regular tab to.
    /// Moved from the window `spaceSelection` is for, which follows the
    /// active tab there.
    static func addMoveToSpaceSubmenu(_ menu: NSMenu, itemID: UUID, currentSpaceID: UUID?, spaceSelection: SpaceSelection?) {
        let spaces = SpaceManager.shared.spaces.filter { $0.id != currentSpaceID }
        guard !spaces.isEmpty else { return }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for space in spaces {
            let item = NSMenuItem(title: space.name, action: #selector(MenuTarget.invoke), keyEquivalent: "")
            let target = MenuTarget { spaceSelection?.move(itemID: itemID, toSpace: space.id) }
            item.target = target
            item.representedObject = target
            item.setVisibleImage(space.icon.image(name: space.name, pointSize: 13))
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: - "Move to…" submenu

    /// Add a "Move to…" item with a hierarchical folder submenu. Each
    /// folder shows up as a leaf "Move to <name>" when it has no
    /// subfolders, or as its own submenu (with a leading "Move to <name>"
    /// option, then nested subfolders) when it does.
    ///
    /// The folder being moved (and its descendants, if it's a folder) are
    /// excluded from the targets so the user can't drop into themselves.
    private static func addMoveToSubmenu(_ menu: NSMenu, draggedID: UUID, sidebarManager: SidebarManager) {
        let structure = sidebarManager.sidebarStructure
        // Folders of the item's own space
        let spaceID = structure.collectionID(ofItem: draggedID)
        let topLevelFolderIDs = structure.rootItems.compactMap { id -> UUID? in
            structure.folders[id].map { $0.collectionID == spaceID } == true ? id : nil
        }
        let candidateFolders = topLevelFolderIDs.compactMap { structure.folders[$0] }
        // Don't bother showing the menu if there are no possible
        // destinations after filtering out self/descendants.
        let usable = candidateFolders.filter { !isSelfOrDescendant($0.id, of: draggedID, structure: structure) }
        guard !usable.isEmpty else { return }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for folder in usable {
            submenu.addItem(makeMoveToItem(folder: folder, draggedID: draggedID, sidebarManager: sidebarManager))
        }

        let parent = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private static func makeMoveToItem(folder: SidebarFolder, draggedID: UUID, sidebarManager: SidebarManager) -> NSMenuItem {
        let structure = sidebarManager.sidebarStructure
        let subfolders = folder.childrenIds.compactMap { childID -> SidebarFolder? in
            guard let sub = structure.folders[childID] else { return nil }
            return isSelfOrDescendant(sub.id, of: draggedID, structure: structure) ? nil : sub
        }

        let icon = folderMenuIcon(for: folder, in: structure)

        if subfolders.isEmpty {
            let item = NSMenuItem(title: folder.displayTitle, action: #selector(MenuTarget.invoke), keyEquivalent: "")
            let target = MenuTarget {
                let count = structure.folders[folder.id]?.childrenIds.count ?? 0
                sidebarManager.moveItemToPosition(draggedID, containerID: folder.id, index: count)
            }
            item.target = target
            item.representedObject = target
            item.setVisibleImage(icon)
            return item
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        // First option: drop directly into this folder.
        let here = NSMenuItem(title: "Move to \(folder.displayTitle)", action: #selector(MenuTarget.invoke), keyEquivalent: "")
        here.setVisibleImage(icon)
        let hereTarget = MenuTarget {
            let count = structure.folders[folder.id]?.childrenIds.count ?? 0
            sidebarManager.moveItemToPosition(draggedID, containerID: folder.id, index: count)
        }
        here.target = hereTarget
        here.representedObject = hereTarget
        submenu.addItem(here)
        submenu.addItem(.separator())
        for sub in subfolders {
            submenu.addItem(makeMoveToItem(folder: sub, draggedID: draggedID, sidebarManager: sidebarManager))
        }

        let parent = NSMenuItem(title: folder.displayTitle, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.setVisibleImage(icon)
        return parent
    }

    private static func isSelfOrDescendant(_ folderID: UUID, of draggedID: UUID, structure: SidebarStructure) -> Bool {
        if folderID == draggedID { return true }
        // If draggedID isn't a folder, only the self-check applies.
        guard structure.folders[draggedID] != nil else { return false }
        var cursor: UUID? = folderID
        var seen: Set<UUID> = []  // cycle protection — corrupt parent chains shouldn't loop forever
        while let id = cursor {
            if seen.contains(id) { return false }
            seen.insert(id)
            if let folder = structure.folders[id] {
                if folder.parentID == draggedID { return true }
                cursor = folder.parentID
            } else {
                break
            }
        }
        return false
    }

    /// As its row shows it: the icon picked for it, else its favicons
    private static func folderMenuIcon(for folder: SidebarFolder, in structure: SidebarStructure) -> NSImage? {
        SidebarGroupIcon.menuImage(icon: folder.icon, faviconURLs: structure.faviconURLs(inFolder: folder.id))
    }

    // MARK: - Shared menu fragments

    /// Copy a URL to the pasteboard with tracking-parameter removal and a
    /// toast notification — same UX as `URLUtilities.removeTrackingParameters`
    /// + `tabManager.toastManager.showToast` on `main`'s SwiftUI menus.
    static func addCopyLinkItem(_ menu: NSMenu, url: String, tabManager: TabManager) {
        addItem(menu, title: "Copy Link", symbol: "link") {
            let result = URLUtilities.removeTrackingParameters(from: url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.cleanURL, forType: .string)
            let message = result.trackersDetected ? "Copied clean link without trackers" : "Copied link"
            let icon = result.trackersDetected ? "checkmark.shield.fill" : "clipboard.fill"
            tabManager.toastManager.showToast(message: message, type: .info, icon: icon)
        }
    }

    /// Open the standard macOS share sheet (`NSSharingServicePicker`) for a
    /// URL, anchored to a view in the sidebar so the popover points at the
    /// row that originated the menu.
    static func addShareItem(_ menu: NSMenu, url: String, title: String, anchor: NSView) {
        // Anchor weakly — long-lived menu items shouldn't keep the cell
        // alive past its layout-pool lifetime.
        addItem(menu, title: "Share\u{2026}", symbol: "square.and.arrow.up") { [weak anchor] in
            guard let anchor = anchor else { return }
            SharingService.shareURL(url, title: title, from: anchor)
        }
    }

    /// Add to / Remove from Safari's Reading List, depending on the URL's
    /// current membership. Adding is disabled for anything but web pages.
    static func addReadingListItem(_ menu: NSMenu, url: String, title: String, tabManager: TabManager) {
        let manager = SafariReadingListManager.shared
        let inList = manager.contains(url: url)

        let label = inList ? "Remove from Reading List" : "Add to Reading List"
        let item = NSMenuItem(title: label, action: #selector(MenuTarget.invoke), keyEquivalent: "")
        item.setVisibleSymbol("eyeglasses")
        let target = MenuTarget {
            // `MenuTarget`'s `handler` is a non-isolated `() -> Void` so
            // inheriting `Task` doesn't get the main actor for free —
            // pin explicitly via `Task { @MainActor in … }` since
            // `SafariReadingListManager` is main-actor-isolated.
            Task { @MainActor in
                if inList {
                    manager.removeFromReadingList(url: url, reportingTo: tabManager.toastManager)
                } else {
                    manager.addToReadingList(url: url, title: title, reportingTo: tabManager.toastManager)
                }
            }
        }
        item.target = target
        item.representedObject = target
        item.isEnabled = inList || SafariReadingListManager.canAdd(url: url)
        menu.addItem(item)
    }

    /// "Save to" submenu — turns a regular browser tab into a saved
    /// sidebar tab inside the chosen folder. Mirrors SwiftUI's `MoveToMenu`
    /// for the `.browserTab` case, which posts `SaveTabToSidebar` and lets
    /// `SidebarManager.handleSaveTabToSidebarNotification` do the actual
    /// add. Folders only — collections aren't shown in the SwiftUI version
    /// either, and saving directly into a collection root would need
    /// extra plumbing.
    static func addSaveToSubmenu(_ menu: NSMenu, browserTab: BrowserTab, sidebarManager: SidebarManager) {
        let structure = sidebarManager.sidebarStructure
        // Folders of the tab's own space
        let spaceID = SpaceManager.shared.spaceID(of: browserTab)
        let topLevelFolders = structure.rootItems.compactMap { structure.folders[$0] }
            .filter { $0.collectionID == spaceID }
        guard !topLevelFolders.isEmpty else { return }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for folder in topLevelFolders {
            submenu.addItem(makeSaveToFolderItem(folder: folder, browserTab: browserTab, sidebarManager: sidebarManager))
        }

        let parent = NSMenuItem(title: "Save to", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private static func makeSaveToFolderItem(
        folder: SidebarFolder,
        browserTab: BrowserTab,
        sidebarManager: SidebarManager
    ) -> NSMenuItem {
        let structure = sidebarManager.sidebarStructure
        let subfolders = folder.childrenIds.compactMap { structure.folders[$0] }
        let icon = folderMenuIcon(for: folder, in: structure)

        if subfolders.isEmpty {
            let item = NSMenuItem(title: folder.displayTitle, action: #selector(MenuTarget.invoke), keyEquivalent: "")
            let target = MenuTarget { postSaveTabToSidebar(browserTabID: browserTab.id, parentID: folder.id) }
            item.target = target
            item.representedObject = target
            item.setVisibleImage(icon)
            return item
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let here = NSMenuItem(title: "Save to \(folder.displayTitle)", action: #selector(MenuTarget.invoke), keyEquivalent: "")
        here.setVisibleImage(icon)
        let hereTarget = MenuTarget { postSaveTabToSidebar(browserTabID: browserTab.id, parentID: folder.id) }
        here.target = hereTarget
        here.representedObject = hereTarget
        submenu.addItem(here)
        submenu.addItem(.separator())
        for sub in subfolders {
            submenu.addItem(makeSaveToFolderItem(folder: sub, browserTab: browserTab, sidebarManager: sidebarManager))
        }
        let parent = NSMenuItem(title: folder.displayTitle, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.setVisibleImage(icon)
        return parent
    }

    /// Post the same `SaveTabToSidebar` notification that the SwiftUI
    /// `MoveToMenu.saveTabToSidebar` posts. The handler is registered in
    /// `SidebarManager.setupNotificationListeners`.
    private static func postSaveTabToSidebar(browserTabID: UUID, parentID: UUID) {
        NotificationCenter.default.post(
            name: NSNotification.Name("SaveTabToSidebar"),
            object: nil,
            userInfo: [
                "tabID": browserTabID.uuidString,
                "parentID": parentID.uuidString,
                "collectionID": NSNull()
            ]
        )
    }
}

// MARK: - Library

/// The menus of the library's items: the same in their lists and on the
/// overview's cards (`View.libraryContextMenu`). `open` opens the page,
/// in a background tab or not, as the list or card does on a click.
@MainActor
enum SidebarLibraryMenus {
    static func addItems(
        to menu: NSMenu,
        for entry: HistoryEntryData,
        history: HistoryManager,
        tabManager: TabManager,
        anchor: NSView,
        open: @escaping (_ inBackground: Bool) -> Void
    ) {
        addOpenItems(menu, open: open)
        menu.addItem(.separator())
        SidebarContextMenuFactory.addCopyLinkItem(menu, url: entry.url, tabManager: tabManager)
        SidebarContextMenuFactory.addShareItem(menu, url: entry.url, title: entry.title, anchor: anchor)
        SidebarContextMenuFactory.addReadingListItem(menu, url: entry.url, title: entry.title, tabManager: tabManager)
        menu.addItem(.separator())
        // `MenuTarget` handlers aren't main-actor-isolated; hop explicitly.
        SidebarContextMenuFactory.addItem(menu, title: "Remove from History") { [weak history] in
            Task { @MainActor in history?.removeEntry(entry) }
        }
    }

    static func addItems(
        to menu: NSMenu,
        for item: ReadingListItem,
        tabManager: TabManager,
        anchor: NSView,
        open: @escaping (_ inBackground: Bool) -> Void
    ) {
        let readingList = SafariReadingListManager.shared
        let toastManager = tabManager.toastManager

        addOpenItems(menu, open: open)
        menu.addItem(.separator())
        SidebarContextMenuFactory.addCopyLinkItem(menu, url: item.url, tabManager: tabManager)
        SidebarContextMenuFactory.addShareItem(menu, url: item.url, title: item.title, anchor: anchor)
        menu.addItem(.separator())
        // The list shows these succeeding, so only failures get a toast.
        SidebarContextMenuFactory.addItem(menu, title: item.isUnread ? "Mark as Read" : "Mark as Unread") {
            Task { @MainActor in
                do {
                    try await readingList.markAs(read: item.isUnread, url: item.url)
                } catch {
                    SafariReadingListManager.reportFailure(error, to: toastManager)
                }
            }
        }
        SidebarContextMenuFactory.addItem(menu, title: "Remove from Reading List") {
            Task { @MainActor in
                do {
                    try await readingList.removeFromReadingList(url: item.url)
                } catch {
                    SafariReadingListManager.reportFailure(error, to: toastManager)
                }
            }
        }
    }

    /// `open` opens a finished download's file.
    static func addItems(
        to menu: NSMenu,
        for download: DownloadItem,
        tabManager: TabManager,
        open: @escaping () -> Void
    ) {
        let manager = DownloadManager.shared

        switch download.state {
        case .downloading:
            // Only servers that accept range requests let a download pick up
            // where it stopped.
            if download.canPause {
                SidebarContextMenuFactory.addItem(menu, title: "Pause") {
                    manager.pauseDownload(download)
                }
            }
            SidebarContextMenuFactory.addItem(menu, title: "Cancel") {
                manager.cancelDownload(download)
            }
        case .paused:
            SidebarContextMenuFactory.addItem(menu, title: "Resume") {
                manager.resumeDownload(download)
            }
            SidebarContextMenuFactory.addItem(menu, title: "Cancel") {
                manager.cancelDownload(download)
            }
        case .completed:
            SidebarContextMenuFactory.addItem(menu, title: "Open", action: open)
            SidebarContextMenuFactory.addItem(menu, title: "Show in Finder") {
                manager.revealInFinder(download)
            }
        case .failed:
            // Interrupted downloads can often continue where they stopped.
            if download.resumeData != nil {
                SidebarContextMenuFactory.addItem(menu, title: "Resume") {
                    manager.resumeDownload(download)
                }
            }
        case .cancelled:
            break
        }

        // Where it came from, unless it was made by the page (a data: or blob: URL)
        if let scheme = download.url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let address = download.url.absoluteString
            let toastManager = tabManager.toastManager
            SidebarContextMenuFactory.addItem(menu, title: "Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
                toastManager.showToast(message: "Copied download address", type: .info, icon: "clipboard.fill")
            }
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        SidebarContextMenuFactory.addItem(menu, title: "Remove from List") {
            manager.removeDownload(download)
        }
    }

    private static func addOpenItems(_ menu: NSMenu, open: @escaping (_ inBackground: Bool) -> Void) {
        SidebarContextMenuFactory.addItem(menu, title: "Open") { open(false) }
        SidebarContextMenuFactory.addItem(menu, title: "Open in Background Tab") { open(true) }
    }
}

private final class MenuTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

/// Context menu for a regular (unorganized) browser tab in the footer table.
/// Mirrors the SwiftUI `RegularTabItem.contextMenu` on `main`.
@MainActor
enum SidebarRegularTabContextMenuFactory {
    static func menu(
        for browserTab: BrowserTab,
        sidebarManager: SidebarManager,
        tabManager: TabManager,
        anchor: NSView
    ) -> NSMenu {
        let menu = NSMenu()
        // See comment in `SidebarContextMenuFactory.menu(...)` — explicit
        // `isEnabled` (e.g. on the Reading List item for a non-web page)
        // needs `autoenablesItems = false` to take effect.
        menu.autoenablesItems = false

        // In the saved tabs' sections (`buildTabMenu`)
        SidebarContextMenuFactory.addSplitItems(menu, itemID: browserTab.id, tabManager: tabManager)
        if !browserTab.isEmpty {
            SidebarContextMenuFactory.addItem(menu, title: browserTab.isPrivate ? "Reload Outside Private Browsing" : "Reload in Private Tab") {
                tabManager.reopenTab(browserTab, isPrivate: !browserTab.isPrivate)
            }
        }

        menu.addItem(.separator())

        SidebarContextMenuFactory.addCopyLinkItem(menu, url: browserTab.url, tabManager: tabManager)
        SidebarContextMenuFactory.addShareItem(menu, url: browserTab.url, title: browserTab.title, anchor: anchor)
        SidebarContextMenuFactory.addReadingListItem(menu, url: browserTab.url, title: browserTab.title, tabManager: tabManager)

        menu.addItem(.separator())

        SidebarContextMenuFactory.addGroupItems(menu, itemID: browserTab.id, sidebarManager: sidebarManager)
        SidebarContextMenuFactory.addSaveToSubmenu(menu, browserTab: browserTab, sidebarManager: sidebarManager)
        SidebarContextMenuFactory.addMoveToSpaceSubmenu(menu, itemID: browserTab.id, currentSpaceID: SpaceManager.shared.spaceID(of: browserTab), spaceSelection: tabManager.spaceSelection)
        SidebarContextMenuFactory.addItem(menu, title: "Pin Tab") { sidebarManager.pin(itemID: browserTab.id) }

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(MenuTarget.invoke), keyEquivalent: "")
        let closeTarget = MenuTarget { tabManager.closeTabUndoably(browserTab) }
        closeItem.target = closeTarget
        closeItem.representedObject = closeTarget
        menu.addItem(closeItem)

        return menu
    }
}
