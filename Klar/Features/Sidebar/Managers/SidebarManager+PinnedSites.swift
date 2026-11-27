import Combine
import Foundation

/// Pinned sites: the grid of saved tabs at the top of the sidebar, shared
/// by every space (`SidebarStructure.pinnedItems`). A pinned site is a saved
/// tab of no space or folder: it keeps a tab of its own, opened with the
/// shared profile, and selecting it doesn't switch spaces. That tab is
/// always loaded, so the site shows at once.
extension SidebarManager {
    /// Whether a browser tab is a pinned site's.
    func isPinnedSite(browserTabID: UUID) -> Bool {
        guard let sidebarTabID = browserToSidebarTabMapping[browserTabID] else { return false }
        return sidebarStructure.pinnedItems.contains(sidebarTabID)
    }

    /// A saved tab or an open tab (in any window) can be pinned; a folder can't.
    func canPin(_ itemID: UUID) -> Bool {
        sidebarStructure.tabs[itemID] != nil || BrowserWindowSession.owner(ofTab: itemID) != nil
    }

    /// Puts a saved tab or an open tab at `index` of the pinned sites (the
    /// end by default), or moves a pinned one there.
    func pin(itemID: UUID, at index: Int? = nil) {
        if sidebarStructure.tabs[itemID] != nil {
            pinSavedTab(itemID, at: index)
        } else if let browserTab = browserTabBroughtHere(itemID) {
            pinBrowserTab(browserTab, at: index)
        }
    }

    /// A link dropped on the pinned sites: pinned, and opened.
    func pin(url: String, at index: Int? = nil) {
        let title = URL(string: url)?.host() ?? url
        let tab = SidebarTab(title: title, url: url, isUnloaded: true)
        insertPinned(tab, at: index)
        selectItem(tab.id)
    }

    /// Moves a pinned site to the end of the active space's saved tabs.
    func unpin(_ tabID: UUID) {
        guard sidebarStructure.pinnedItems.contains(tabID) else { return }
        moveItemToPosition(tabID, containerID: nil, index: sidebarStructure.rootItems.count)
        SpaceManager.shared.reopenSavedItemIfProfileChanged(tabID, from: nil)
    }

    // MARK: - Always loaded

    /// From now on every pinned site has a loaded tab: at launch, once pinned,
    /// and again whenever its tab goes (unloaded from the command palette,
    /// a profile change). Checked once per turn after the saved tabs or the
    /// browser tabs change. Each window keeps a tab of its own for each.
    func keepPinnedSitesLoaded() {
        guard pinnedSitesCancellables.isEmpty, let tabManager else { return }
        sidebarStructurePublisher
            .sink { [weak self] _ in self?.scheduleLoadingPinnedSites() }
            .store(in: &pinnedSitesCancellables)
        tabManager.$tabs
            .sink { [weak self] _ in self?.scheduleLoadingPinnedSites() }
            .store(in: &pinnedSitesCancellables)
    }

    private func scheduleLoadingPinnedSites() {
        guard !isPinnedSitesLoadScheduled else { return }
        isPinnedSitesLoadScheduled = true
        // Published before they change
        DispatchQueue.main.async { [weak self] in
            self?.isPinnedSitesLoadScheduled = false
            self?.loadPinnedSites()
        }
    }

    private func loadPinnedSites() {
        guard let tabManager else { return }
        let browserTabIDs = Set(tabManager.tabs.map(\.id))
        for id in sidebarStructure.pinnedItems where sidebarStructure.tabs[id] != nil {
            if let browserTabID = sidebarToBrowserTabMapping[id], browserTabIDs.contains(browserTabID) { continue }
            sidebarTabManager.loadInBackground(withID: id)
        }
    }

    /// Closing a pinned site's tab (⌘W) leaves it, loaded, for the next tab,
    /// with what played in it paused where it was. (Only switching away, it
    /// keeps playing.)
    func leavePinnedSite(_ tabID: UUID) {
        guard let tabManager, let browserTabID = sidebarToBrowserTabMapping[tabID] else { return }
        MediaControlManager.shared.pauseMedia(for: browserTabID)
        let isActive = tabManager.activeTabId == browserTabID
        guard isActive || selectedItem == tabID else { return }
        // Left, it's no longer a tab to come back to: it stays loaded, so
        // ⌘W on the next pinned site would otherwise pick this one again,
        // back and forth between the two, never reaching the other tabs.
        selectionManager.removeFromTabHistory(tabID)
        selectionManager.removeFromTabHistory(browserTabID)
        selectionManager.moveSelectionToNextActiveTab(excluding: tabID)
        if tabManager.activeTabId == browserTabID {
            tabManager.activeTabId = nil
        }
        if selectedItem == tabID {
            selectedItem = nil
        }
    }

    // MARK: - Pinning

    private func pinSavedTab(_ tabID: UUID, at index: Int?) {
        var structure = sidebarStructure
        let oldSpaceID = structure.collectionID(ofItem: tabID)
        // Within the pinned sites, `index` is where it ends up
        let insertIndex = index ?? structure.pinnedItems.count

        if let current = structure.pinnedItems.firstIndex(of: tabID) {
            structure.pinnedItems.remove(at: current)
        } else if let location = findItemLocation(itemID: tabID, in: structure), let currentIndex = location.index {
            var siblings = location.parentID.flatMap { structure.folders[$0]?.childrenIds } ?? structure.rootItems
            siblings.remove(at: currentIndex)
            structure.reorderItems(siblings, in: location.parentID)
        }

        structure.tabs[tabID]?.parentID = nil
        structure.tabs[tabID]?.collectionID = nil
        structure.pinnedItems.insert(tabID, at: min(max(0, insertIndex), structure.pinnedItems.count))
        Self.renumberPinned(&structure)
        structure.lastUpdated = Date()
        sidebarStructure = structure
        saveSidebarStructure()

        // From a space with a profile of its own: its page reopens with the shared one
        SpaceManager.shared.reopenSavedItemIfProfileChanged(tabID, from: oldSpaceID)
    }

    private func pinBrowserTab(_ browserTab: BrowserTab, at index: Int?) {
        guard let tabManager else { return }
        // Its page has its space's own profile, or is private: the pinned
        // site opens anew with the shared one.
        let reopens = browserTab.isPrivate || SpaceManager.shared.profileID(of: browserTab) != nil
        var tab = SidebarTab(from: browserTab)
        tab.isUnloaded = reopens

        if !reopens {
            sidebarToBrowserTabMapping[tab.id] = browserTab.id
            browserToSidebarTabMapping[browserTab.id] = tab.id
        }
        insertPinned(tab, at: index)

        if reopens {
            let wasActive = tabManager.activeTabId == browserTab.id
            if wasActive {
                selectItem(tab.id)
            }
            // After the pinned site has opened in its place
            DispatchQueue.main.async {
                tabManager.closeTab(browserTab)
            }
        } else if selectedItem == browserTab.id {
            selectedItem = tab.id
        }
    }

    private func insertPinned(_ tab: SidebarTab, at index: Int?) {
        var structure = sidebarStructure
        structure.tabs[tab.id] = tab
        let insertIndex = min(max(0, index ?? structure.pinnedItems.count), structure.pinnedItems.count)
        structure.pinnedItems.insert(tab.id, at: insertIndex)
        Self.renumberPinned(&structure)
        structure.lastUpdated = Date()
        sidebarStructure = structure
        saveSidebarStructure()
    }

    private static func renumberPinned(_ structure: inout SidebarStructure) {
        for (index, id) in structure.pinnedItems.enumerated() {
            structure.tabs[id]?.order = index
        }
    }
}
