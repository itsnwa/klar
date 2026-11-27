import Foundation

/// Groups of tabs: of saved tabs (a `SidebarFolder` in the structure) and of
/// regular tabs below the divider (an `OpenTabGroup` on their open tabs,
/// `OpenTabStore`). A group moved from one to the other keeps its ID, name,
/// icon and whether it's open.
extension SidebarManager {

    // MARK: - New groups

    /// A new group with these tabs (saved tabs' and regular tabs' IDs, top
    /// to bottom), where the first one is, open and being named: among the
    /// saved tabs when any of them is one, the regular tabs among them saved
    /// in it; otherwise among the regular tabs. Nil when none can be in one.
    @discardableResult
    func newGroup(withTabs itemIDs: [UUID]) -> UUID? {
        if !extraSelectedItems.isEmpty {
            extraSelectedItems.removeAll()
        }
        let hasSavedTab = itemIDs.contains { sidebarStructure.tabs[$0] != nil }
        guard let groupID = hasSavedTab ? newSavedGroup(withTabs: itemIDs) : newRegularGroup(withTabs: itemIDs) else {
            return nil
        }
        expandedFolders.insert(groupID)
        isRenaming = groupID
        return groupID
    }

    /// Whether a group of tabs can be made with this one: a saved tab, or a
    /// regular tab that is (or becomes) an open tab
    func canGroup(_ itemID: UUID) -> Bool {
        if sidebarStructure.tabs[itemID] != nil { return true }
        guard let tabManager, let page = tabManager.tabs.first(where: { $0.id == itemID }) else { return false }
        return OpenTabStore.shared.canGroup(page, in: tabManager)
    }

    private func newSavedGroup(withTabs itemIDs: [UUID]) -> UUID? {
        guard let first = itemIDs.first(where: { sidebarStructure.tabs[$0] != nil }) else { return nil }
        var structure = sidebarStructure
        guard let location = findItemLocation(itemID: first, in: structure), var index = location.index else { return nil }
        // In the group the first one is in, unless that's as deep as groups
        // go: then beside the group it's in
        var parentID = location.parentID
        while let id = parentID, !Self.canCreateGroup(in: id, structure: structure) {
            let outer = findItemLocation(itemID: id, in: structure)
            parentID = outer?.parentID
            index = (outer?.index ?? structure.rootItems.count) + 1
        }
        let collectionID = structure.collectionID(ofItem: first) ?? collectionIDForNewItem(in: parentID)
        var folder = SidebarFolder(title: OpenTabGroup.defaultTitle, parentID: parentID, collectionID: collectionID,
                                   icon: SidebarConfiguration.defaultFolderIcon)

        // The saved tabs out of where they are, into it
        for id in itemIDs where structure.tabs[id] != nil {
            if let from = findItemLocation(itemID: id, in: structure), let position = from.index {
                if let container = from.parentID {
                    structure.folders[container]?.childrenIds.remove(at: position)
                } else {
                    structure.rootItems.remove(at: position)
                }
                if from.parentID == parentID, position < index {
                    index -= 1
                }
            }
            structure.tabs[id]?.parentID = folder.id
            folder.childrenIds.append(id)
        }
        structure.folders[folder.id] = folder
        var siblings = parentID.flatMap { structure.folders[$0]?.childrenIds } ?? structure.rootItems
        siblings.insert(folder.id, at: min(max(0, index), siblings.count))
        structure.reorderItems(siblings, in: parentID)
        structure.reorderItems(folder.childrenIds, in: folder.id)
        structure.assignCollection(collectionID, toItemAndDescendants: folder.id)
        structure.lastUpdated = Date()
        sidebarStructure = structure
        saveSidebarStructure()

        // The regular tabs among them, saved in it after the saved ones
        if let tabManager {
            for id in itemIDs where sidebarStructure.tabs[id] == nil {
                guard let page = tabManager.tabs.first(where: { $0.id == id }) else { continue }
                let wasSelected = selectedItem == id
                let count = sidebarStructure.folders[folder.id]?.childrenIds.count ?? 0
                let tabID = addTabAtPosition(page, to: folder.id, at: count)
                if wasSelected, !page.isPrivate {
                    selectedItem = tabID
                    selectionManager.addToTabHistory(tabID)
                }
            }
        }
        logInfo(.sidebar, "New group with \(itemIDs.count) tab(s)")
        return folder.id
    }

    private func newRegularGroup(withTabs itemIDs: [UUID]) -> UUID? {
        guard let tabManager else { return nil }
        let store = OpenTabStore.shared
        let pages = itemIDs.compactMap { id in tabManager.tabs.first { $0.id == id } }
            .filter { store.canGroup($0, in: tabManager) }
        guard let first = pages.first else { return nil }
        let group = OpenTabGroup(id: UUID(), title: OpenTabGroup.defaultTitle, icon: "")
        // Where the first one is: before what comes after it
        store.movePages(pages.map(\.id), before: first.id, into: group, in: tabManager)
        logInfo(.sidebar, "New group with \(pages.count) regular tab(s)")
        return group.id
    }

    private static func canCreateGroup(in parentID: UUID?, structure: SidebarStructure) -> Bool {
        if case .success = SidebarValidation.validateFolderOperation(.create(parentID: parentID), in: structure) {
            return true
        }
        return false
    }

    // MARK: - Leaving groups

    /// Whether a tab is in a group: a saved tab in a saved group, or a
    /// regular tab in a group of them
    func isInGroup(_ itemID: UUID) -> Bool {
        if let tab = sidebarStructure.tabs[itemID] {
            return tab.parentID.flatMap { sidebarStructure.folders[$0] } != nil
        }
        guard let page = tabManager?.tabs.first(where: { $0.id == itemID }) else { return false }
        return OpenTabStore.shared.group(ofPage: page) != nil
    }

    /// Takes a tab out of its group, to just after it
    func removeFromGroup(_ itemID: UUID) {
        if let tab = sidebarStructure.tabs[itemID] {
            guard let folderID = tab.parentID, let folder = sidebarStructure.folders[folderID],
                  let location = findItemLocation(itemID: folderID, in: sidebarStructure) else { return }
            moveItemToPosition(itemID, containerID: folder.parentID, index: (location.index ?? 0) + 1)
            return
        }
        guard let tabManager, let page = tabManager.tabs.first(where: { $0.id == itemID }),
              let group = OpenTabStore.shared.group(ofPage: page) else { return }
        let memberIDs = Set(pages(inRegularGroup: group.id).map(\.id))
        let after = tabManager.tabs.lastIndex { memberIDs.contains($0.id) }.flatMap { index in
            tabManager.tabs.indices.contains(index + 1) ? tabManager.tabs[index + 1].id : nil
        }
        OpenTabStore.shared.movePages([page.id], before: after, into: nil, in: tabManager)
    }

    // MARK: - Groups of regular tabs

    /// This window's pages of a group of regular tabs, in their order
    func pages(inRegularGroup groupID: UUID) -> [BrowserTab] {
        guard let tabManager else { return [] }
        let groups = OpenTabStore.shared.groups(ofPages: tabManager.tabs)
        return tabManager.tabs.filter { groups[$0.id]?.id == groupID }
    }

    /// Moves a group of regular tabs to just before `beforeTabID` (the end
    /// with none), its tabs in their order; from another space, to this one.
    func moveRegularGroup(_ groupID: UUID, before beforeTabID: UUID?) {
        guard let tabManager, let group = OpenTabStore.shared.group(withID: groupID) else { return }
        if let selection = spaceSelection, let spaceID = selection.currentSpaceID {
            for page in pages(inRegularGroup: groupID) where !selection.isInActiveSpace(page) {
                selection.move(itemID: page.id, toSpace: spaceID, keepingGroup: true)
            }
        }
        // Again: a tab moved to another profile is a new tab
        let pageIDs = pages(inRegularGroup: groupID).map(\.id)
        OpenTabStore.shared.movePages(pageIDs, before: beforeTabID, into: group, in: tabManager)
    }

    /// A group of regular tabs saved: its tabs saved in a saved group with
    /// its ID, name and icon, at `index` in `parentID` (the space's top
    /// level with nil). Whether it could be.
    @discardableResult
    func saveRegularGroup(_ groupID: UUID, in parentID: UUID?, at index: Int) -> Bool {
        guard let group = OpenTabStore.shared.group(withID: groupID), sidebarStructure.folders[groupID] == nil,
              Self.canCreateGroup(in: parentID, structure: sidebarStructure) else { return false }
        let pages = self.pages(inRegularGroup: groupID)
        guard !pages.isEmpty else { return false }
        let collectionID = collectionIDForNewItem(in: parentID)
        let activeTabID = tabManager?.activeTabId

        var structure = sidebarStructure
        var folder = SidebarFolder(id: groupID, title: group.title, parentID: parentID, collectionID: collectionID,
                                   icon: group.icon.isEmpty ? SidebarConfiguration.defaultFolderIcon : group.icon)
        var selectedTabID: UUID?
        for (order, page) in pages.enumerated() {
            let tab = SidebarTab(from: page, parentID: groupID, collectionID: collectionID, order: order)
            // Its page is this window's page of the saved tab now
            sidebarToBrowserTabMapping[tab.id] = page.id
            browserToSidebarTabMapping[page.id] = tab.id
            structure.tabs[tab.id] = tab
            folder.childrenIds.append(tab.id)
            if page.id == activeTabID {
                selectedTabID = tab.id
            }
        }
        structure.folders[groupID] = folder
        var siblings = parentID.flatMap { structure.folders[$0]?.childrenIds } ?? structure.rootItems
        siblings.insert(groupID, at: min(max(0, index), siblings.count))
        structure.reorderItems(siblings, in: parentID)
        structure.lastUpdated = Date()
        sidebarStructure = structure
        saveSidebarStructure()

        if let selectedTabID {
            selectedItem = selectedTabID
            selectionManager.addToTabHistory(selectedTabID)
        }
        logInfo(.sidebar, "Saved a group of \(pages.count) regular tab(s)")
        return true
    }

    /// A saved group among the regular tabs: a group of regular tabs with
    /// its ID, name and icon, just before `beforeTabID` (the end with none).
    /// Its saved tabs' pages are its tabs (a new one, not loaded until it's
    /// shown, for each open in no window), those of groups in it too. They
    /// go to this space. Whether it could: it needs a tab.
    @discardableResult
    func moveSavedGroupToRegularTabs(_ folderID: UUID, before beforeTabID: UUID?) -> Bool {
        guard let tabManager, let selection = spaceSelection,
              let folder = sidebarStructure.folders[folderID] else { return false }
        let structure = sidebarStructure
        let tabIDs = structure.tabIDsInOrder(inFolder: folderID)
        guard !tabIDs.isEmpty else { return false }
        let subfolderIDs = structure.contents(ofFolder: folderID).folderIDs
        let group = OpenTabGroup(id: folderID, title: folder.displayTitle,
                                 icon: folder.icon == FolderIcons.defaultIcon ? "" : folder.icon)

        // Each saved tab's page here; one open only in another window stays
        // there as a regular tab, which this window gets a page of
        var pageIDs: [UUID] = []
        var otherWindowsPages: [BrowserTab] = []
        for tabID in tabIDs {
            if let pageID = sidebarToBrowserTabMapping[tabID] {
                pageIDs.append(pageID)
            } else if store.isOpenInAnyWindow(tabID) {
                for other in store.sidebarManagers where other !== self {
                    if let pageID = other.sidebarToBrowserTabMapping[tabID],
                       let page = other.tabManager?.tabs.first(where: { $0.id == pageID }) {
                        otherWindowsPages.append(page)
                    }
                }
            } else if let tab = structure.tabs[tabID] {
                let page = tabManager.addUnloadedTab(url: tab.url, title: tab.displayTitle, inSpace: selection.currentSpaceID)
                // The open tab another Mac with it open makes of its page too
                OpenTabStore.shared.pagesWillBecomeOpenTab([page.id], ofSavedTab: tabID)
                pageIDs.append(page.id)
            }
        }

        // Out of the saved tabs, with the groups in it: their pages stay
        removeTabs(withIDs: tabIDs) { structure in
            for subfolderID in subfolderIDs {
                structure.folders[subfolderID] = nil
            }
            structure.removeItem(withID: folderID)
        }
        expandedFolders.subtract(subfolderIDs)

        if let spaceID = selection.currentSpaceID {
            for pageID in pageIDs {
                guard let page = tabManager.tabs.first(where: { $0.id == pageID }), !selection.isInActiveSpace(page) else { continue }
                selection.move(itemID: pageID, toSpace: spaceID)
            }
        }
        // A tab moved to another profile is a new tab
        let pagesHere = pageIDs.filter { id in tabManager.tabs.contains { $0.id == id } }
        let openTabs = OpenTabStore.shared
        openTabs.movePages(pagesHere, before: beforeTabID, into: group, in: tabManager)
        if !otherWindowsPages.isEmpty {
            openTabs.setGroup(group, forPages: otherWindowsPages)
            // Once they're open tabs, with a page here: with the others
            DispatchQueue.main.async { [weak self] in
                self?.moveRegularGroup(folderID, before: beforeTabID)
            }
        }
        logInfo(.sidebar, "Moved a saved group of \(tabIDs.count) tab(s) to the regular tabs")
        return true
    }

    /// Renames a group of regular tabs; empty keeps its name
    func renameRegularGroup(_ groupID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        OpenTabStore.shared.updateGroup(groupID, title: title)
    }

    /// Its tabs stay where they are, in no group
    func ungroupRegularGroup(_ groupID: UUID) {
        OpenTabStore.shared.ungroup(groupID)
        expandedFolders.remove(groupID)
    }

    /// Closes a group's tabs, in every window, and so the group
    func closeRegularGroup(_ groupID: UUID) {
        closeTabs(pages(inRegularGroup: groupID).map(\.id))
        expandedFolders.remove(groupID)
    }

    // MARK: - Several tabs

    /// Closes tabs, as ⌘W does: a regular tab closes, a saved tab's page
    /// here is unloaded. The active one last, so the selection doesn't go
    /// through the others on the way.
    func closeTabs(_ itemIDs: [UUID]) {
        if !extraSelectedItems.isEmpty {
            extraSelectedItems.removeAll()
        }
        guard let tabManager else { return }
        let activeID = selectedItem
        let ordered = itemIDs.filter { $0 != activeID } + itemIDs.filter { $0 == activeID }
        for id in ordered {
            if sidebarStructure.tabs[id] != nil {
                if isOpenHere(id) {
                    unloadTab(withID: id)
                }
            } else if let page = tabManager.tabs.first(where: { $0.id == id }) {
                tabManager.closeTab(page)
            }
        }
    }

    // MARK: - Links

    /// Where a link opened from a tab goes, with Settings › General › Open
    /// links in the tab's group on: the group the tab is in. A saved group's
    /// ID, or a group of regular tabs.
    enum LinkGroup {
        case saved(UUID)
        case regular(OpenTabGroup)
    }

    func groupForLink(openedFrom pageID: UUID) -> LinkGroup? {
        guard TOMLSettingsManager.shared.openLinksInGroup else { return nil }
        if let savedTabID = browserToSidebarTabMapping[pageID] {
            // A pinned site, or a saved tab at a space's top level, has none
            guard let folderID = sidebarStructure.tabs[savedTabID]?.parentID,
                  sidebarStructure.folders[folderID] != nil else { return nil }
            return .saved(folderID)
        }
        guard let page = tabManager?.tabs.first(where: { $0.id == pageID }),
              let group = OpenTabStore.shared.group(ofPage: page) else { return nil }
        return .regular(group)
    }

    /// A link's new tab, from a tab in a group, put at the end of that group
    func addLinkTab(_ page: BrowserTab, to group: LinkGroup) {
        guard let tabManager else { return }
        switch group {
        case .saved(let folderID):
            // Selected as the saved tab once it's shown: the page is its
            guard let folder = sidebarStructure.folders[folderID] else { return }
            let tabID = addTabAtPosition(page, to: folderID, at: folder.childrenIds.count)
            adoptFirstLoad(ofSavedTab: tabID, page: page)
        case .regular(let group):
            guard OpenTabStore.shared.canGroup(page, in: tabManager) else { return }
            let memberIDs = Set(pages(inRegularGroup: group.id).map(\.id))
            let after = tabManager.tabs.lastIndex { memberIDs.contains($0.id) }.flatMap { index in
                tabManager.tabs.indices.contains(index + 1) ? tabManager.tabs[index + 1].id : nil
            }
            OpenTabStore.shared.movePages([page.id], before: after, into: group, in: tabManager)
        }
    }

    /// A link's saved tab, saved before its page loaded, takes the page's
    /// address and title once it has: where the link went, past redirects,
    /// and its name for when it's unloaded, not "New Tab". Not once its page
    /// is another saved tab's or none's.
    private func adoptFirstLoad(ofSavedTab tabID: UUID, page: BrowserTab, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak page] in
            guard let self, let page, var tab = self.sidebarStructure.tabs[tabID],
                  self.browserToSidebarTabMapping[page.id] == tabID else { return }
            guard page.hasLoadedContent, !page.isLoading else {
                if attempt < 30 {
                    self.adoptFirstLoad(ofSavedTab: tabID, page: page, attempt: attempt + 1)
                }
                return
            }
            guard !page.isShowingErrorPage else { return }
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                tab.title = title
                tab.originalTitle = title
            }
            if let scheme = URL(string: page.url)?.scheme, scheme == "http" || scheme == "https" {
                tab.url = page.url
            }
            guard tab.title != self.sidebarStructure.tabs[tabID]?.title
                    || tab.originalTitle != self.sidebarStructure.tabs[tabID]?.originalTitle
                    || tab.url != self.sidebarStructure.tabs[tabID]?.url else { return }
            self.sidebarStructure.tabs[tabID] = tab
            self.sidebarStructure.lastUpdated = Date()
            self.saveSidebarStructure()
        }
    }
}

nonisolated extension SidebarStructure {
    /// The saved tabs in a group, in the order its rows show them, those in
    /// groups in it too
    func tabIDsInOrder(inFolder folderID: UUID) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = [folderID]
        func visit(_ id: UUID) {
            guard seen.insert(id).inserted else { return }
            if tabs[id] != nil {
                result.append(id)
            } else if let folder = folders[id] {
                folder.childrenIds.forEach(visit)
            }
        }
        folders[folderID]?.childrenIds.forEach(visit)
        return result
    }
}
