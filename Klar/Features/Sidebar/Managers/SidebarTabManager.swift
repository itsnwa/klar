import Foundation
import SwiftUI

/// Manages all tab-specific operations for the sidebar
class SidebarTabManager {
    private weak var sidebarManager: SidebarManager?
    
    init(sidebarManager: SidebarManager) {
        self.sidebarManager = sidebarManager
    }
    
    // MARK: - Tab Management
    
    @discardableResult
    func addTab(_ browserTab: BrowserTab, to parentID: UUID? = nil) -> UUID {
        guard let manager = sidebarManager else { return UUID() }
        
        // The folder's space, else the active one
        let defaultCollectionID = manager.collectionIDForNewItem(in: parentID)
        
        // Create sidebar tab with new UUID
        var sidebarTab = SidebarTab(from: browserTab, parentID: parentID, 
                                   collectionID: defaultCollectionID,
                                   order: manager.getNextOrderValue(in: parentID))
        sidebarTab.isUnloaded = browserTab.isPrivate
        
        logDebug(.sidebar, "Adding tab '\(browserTab.title)' to organized section (browser ID: \(browserTab.id), sidebar ID: \(sidebarTab.id))")
        
        // Check if tab already exists in structure (using new sidebar tab ID)
        if manager.sidebarStructure.tabs[sidebarTab.id] != nil {
            logWarning(.sidebar, "Tab \(sidebarTab.id) already exists in structure!")
            return sidebarTab.id
        }
        
        // Establish mapping between sidebar tab and browser tab FIRST
        if !browserTab.isPrivate {
            manager.sidebarToBrowserTabMapping[sidebarTab.id] = browserTab.id
            manager.browserToSidebarTabMapping[browserTab.id] = sidebarTab.id
            logDebug(.sidebar, "Established mapping: browser \(browserTab.id) -> sidebar \(sidebarTab.id)")
        }

        // Modify the structure atomically
        var newStructure = manager.sidebarStructure
        newStructure.addItem(sidebarTab, to: parentID, collectionID: defaultCollectionID)
        
        // Trigger @Published update - this will cause UI to recompute getRegularTabs()
        manager.sidebarStructure = newStructure
        
        // Save immediately
        manager.saveSidebarStructure()
        reopenIfPrivate(browserTab, as: sidebarTab.id)
        
        logDebug(.sidebar, "Successfully added tab to organized section")
        return sidebarTab.id
    }
    
    @discardableResult
    func addTabAtPosition(_ browserTab: BrowserTab, to parentID: UUID?, at index: Int) -> UUID {
        guard let manager = sidebarManager else { return UUID() }
        
        // The folder's space, else the active one
        let defaultCollectionID = manager.collectionIDForNewItem(in: parentID)
        
        var sidebarTab = SidebarTab(from: browserTab, parentID: parentID,
                                   collectionID: defaultCollectionID,
                                   order: manager.getNextOrderValue(in: parentID))
        sidebarTab.isUnloaded = browserTab.isPrivate
        
        logDebug(.sidebar, "Adding tab '\(browserTab.title)' at position \(index) (browser ID: \(browserTab.id), sidebar ID: \(sidebarTab.id))")
        
        // Establish mapping between sidebar tab and browser tab FIRST
        if !browserTab.isPrivate {
            manager.sidebarToBrowserTabMapping[sidebarTab.id] = browserTab.id
            manager.browserToSidebarTabMapping[browserTab.id] = sidebarTab.id
            logDebug(.sidebar, "Established mapping: browser \(browserTab.id) -> sidebar \(sidebarTab.id)")
        }

        // Get current items in the target container
        var currentItems: [UUID]
        if let parentID = parentID {
            currentItems = manager.sidebarStructure.folders[parentID]?.childrenIds ?? []
        } else {
            currentItems = manager.sidebarStructure.rootItems
        }
        
        // Insert at the specified position
        let insertIndex = min(max(0, index), currentItems.count)
        currentItems.insert(sidebarTab.id, at: insertIndex)
        
        // Create new structure with the item added atomically
        var newStructure = manager.sidebarStructure
        
        // Add the tab to the tabs dictionary with collection assignment
        var tabWithCollection = sidebarTab
        tabWithCollection.collectionID = defaultCollectionID
        newStructure.tabs[sidebarTab.id] = tabWithCollection
        
        // Update the parent container with the new order
        if let parentID = parentID {
            newStructure.folders[parentID]?.childrenIds = currentItems
        } else {
            newStructure.rootItems = currentItems
        }
        
        // Update order properties for all items in container
        newStructure.reorderItems(currentItems, in: parentID)
        
        newStructure.lastUpdated = Date()
        
        // Trigger @Published update - this will cause UI to recompute getRegularTabs()
        manager.sidebarStructure = newStructure
        
        // Save immediately
        manager.saveSidebarStructure()
        reopenIfPrivate(browserTab, as: sidebarTab.id)
        
        logDebug(.sidebar, "Successfully added tab at position \(index)")
        return sidebarTab.id
    }
    
    /// Saving a private tab's page takes it out of private browsing: the
    /// saved tab (left unloaded) opens it anew with the space's data store,
    /// in the private tab's place, and the private tab closes.
    private func reopenIfPrivate(_ browserTab: BrowserTab, as savedTabID: UUID) {
        guard browserTab.isPrivate, let manager = sidebarManager, let tabManager = manager.tabManager else { return }
        if tabManager.activeTabId == browserTab.id {
            manager.selectItem(savedTabID)
        }
        DispatchQueue.main.async {
            tabManager.closeTab(browserTab)
        }
    }

    func removeTab(withID id: UUID) {
        removeTabs(withIDs: [id])
    }

    /// Removes saved tabs, and whatever else `change` takes out of the
    /// structure (a folder, a space), in one change: published and saved
    /// once. With `closingTheirTabs`, their open tabs close too, the
    /// selection first moving past all of them, so none deleted next is
    /// shown on the way. Otherwise their open tabs become regular tabs.
    func removeTabs(withIDs ids: [UUID], closingTheirTabs: Bool = false,
                    alongWith change: ((inout SidebarStructure) -> Void)? = nil) {
        guard let manager = sidebarManager else { return }

        let ids = ids.filter { id in
            guard manager.sidebarStructure.tabs[id] != nil else {
                logWarning(.sidebar, "Attempted to remove non-existent tab: \(id)")
                return false
            }
            return true
        }
        guard !ids.isEmpty || change != nil else { return }
        let removedIDs = Set(ids)
        let wasSelected = manager.selectedItem.map { removedIDs.contains($0) } ?? false

        // Clean up history and mappings BEFORE updating structure.
        // This ensures getOrganizedBrowserTabIDs() returns the correct set
        // when the UI updates, so a browser tab left open appears in
        // regular tabs section
        var browserTabIDs: [UUID] = []
        // The selected saved tab's page, which stays selected as a regular tab
        var selectedBrowserTabID: UUID?
        // Each one's pages, in this window and others
        var pagesBySavedTab: [UUID: [UUID]] = [:]
        for id in ids {
            manager.selectionManager.removeFromTabHistory(id)
            if let browserTabId = manager.sidebarToBrowserTabMapping.removeValue(forKey: id) {
                manager.browserToSidebarTabMapping.removeValue(forKey: browserTabId)
                browserTabIDs.append(browserTabId)
                pagesBySavedTab[id, default: []].append(browserTabId)
                if manager.selectedItem == id {
                    selectedBrowserTabID = browserTabId
                }
            }
        }
        // Their pages in other windows, which close with them or stay as
        // regular tabs there, selected if they were
        for other in manager.store.sidebarManagers where other !== manager {
            for id in ids {
                let page = other.sidebarToBrowserTabMapping.removeValue(forKey: id)
                if let page {
                    other.browserToSidebarTabMapping.removeValue(forKey: page)
                    pagesBySavedTab[id, default: []].append(page)
                    if closingTheirTabs {
                        other.tabManager?.closeTab(withId: page)
                    }
                }
                other.savedTabWasRemoved(id, leaving: closingTheirTabs ? nil : page)
            }
        }
        // Left open, in one window or several: one regular tab, which every
        // window has, with the saved tab's ID, as on every Mac it's open on
        if !closingTheirTabs {
            for (savedTabID, pageIDs) in pagesBySavedTab {
                OpenTabStore.shared.pagesWillBecomeOpenTab(pageIDs, ofSavedTab: savedTabID)
            }
        }

        // Remove from one copy of the structure (triggers one @Published update and UI refresh)
        var newStructure = manager.sidebarStructure
        for id in ids {
            newStructure.removeItem(withID: id)
        }
        change?(&newStructure)
        newStructure.lastUpdated = Date()
        manager.sidebarStructure = newStructure

        // Save changes immediately
        manager.saveSidebarStructure()

        // If one of them was selected, move selection to the next available tab.
        // Do this after all cleanup to avoid race conditions
        if closingTheirTabs, let tabManager = manager.tabManager {
            let closingIDs = Set(browserTabIDs)
            let isActiveClosing = tabManager.activeTabId.map { closingIDs.contains($0) } ?? false
            if wasSelected || isActiveClosing {
                manager.selectionManager.moveSelectionToNextActiveTab(excluding: removedIDs.union(closingIDs))
                // Nothing else to show: the space is left empty
                if let activeTabId = tabManager.activeTabId, closingIDs.contains(activeTabId) {
                    tabManager.activeTabId = nil
                }
            }
            for browserTabId in browserTabIDs {
                tabManager.closeTab(withId: browserTabId)
            }
        } else if wasSelected {
            // Its page on screen stays there, now a regular tab. (A saved
            // tab loaded from the sidebar shares its ID with its page, so
            // moving past the removed IDs would show another tab, leaving
            // the page open in the background.)
            if let browserTabId = selectedBrowserTabID, manager.tabManager?.activeTabId == browserTabId {
                manager.selectedItem = browserTabId
                manager.selectionManager.addToTabHistory(browserTabId)
            } else {
                manager.selectionManager.moveSelectionToNextActiveTab(excluding: removedIDs)
            }
        }

        logInfo(.sidebar, "Removed \(ids.count) saved tab(s)")
    }
    
    /// Lets go of the saved tab's page in this window. It stays open in
    /// any other window that has a page of it.
    func unloadTab(withID id: UUID) {
        guard let manager = sidebarManager else { return }
        guard var tab = manager.sidebarStructure.tabs[id] else { 
            logWarning(.sidebar, "Attempted to unload non-existent tab: \(id)")
            return 
        }
        
        // Out of its split view, the pane beside it taking over
        if let browserTabId = manager.sidebarToBrowserTabMapping[id] {
            manager.tabManager?.leaveSplitView(browserTabId)
        }

        let wasSelected = manager.selectedItem == id
        
        // If tab has a corresponding browser tab, save its current state before unloading
        if let browserTabId = manager.sidebarToBrowserTabMapping[id],
           let tabManager = manager.tabManager,
           let browserTab = tabManager.tabs.first(where: { $0.id == browserTabId }) {

            // Determine the correct title to show when unloading based on tab's state
            if tab.customTitle == nil {
                // No custom title set by user
                if browserTab.url != tab.url {
                    // Browser tab has navigated away from saved URL - restore the original saved page title
                    if let originalTitle = tab.originalTitle {
                        tab.title = originalTitle
                        logDebug(.sidebar, "Browser tab navigated away from saved URL, restoring original saved title: \(originalTitle)")
                    }
                } else {
                    // Browser tab is still on the saved URL - keep the current title (might have been updated)
                    // This handles the case where the saved page's title changed but the URL is the same
                }
            } else {
                // Custom title is set - displayTitle will show the custom title automatically
            }
            
            // WebView cleanup will be handled by the closeTab method
            
                    // Clean up mappings first
        manager.sidebarToBrowserTabMapping.removeValue(forKey: id)
        manager.browserToSidebarTabMapping.removeValue(forKey: browserTabId)
        
        // Close the browser tab directly without going through closeTab to avoid recursion
        // Use main queue to ensure thread safety for UI updates
        DispatchQueue.main.async {
            // Re-verify tab exists and get current index (defensive against rapid operations)
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == browserTabId }) else {
                logWarning(.sidebar, "Browser tab \(browserTabId.uuidString.prefix(8)) already removed during unload")
                return
            }
            
            // Force immediate coordinator cleanup
            NotificationCenter.default.post(
                name: NSNotification.Name("ForceCoordinatorCleanup"),
                object: nil,
                userInfo: ["tabId": browserTabId.uuidString]
            )
            
            // Remove the tab
            tabManager.tabs.remove(at: index)
            
            // If this was the active tab, we need to handle selection immediately
            if tabManager.activeTabId == browserTabId {
                // Move selection to next active tab - this will set activeTabId via switchToTab if successful
                manager.selectionManager.moveSelectionToNextActiveTab(excluding: id)

                // Only set to nil if moveSelectionToNextActiveTab didn't find a new tab
                // (e.g., all tabs are unloaded or no tabs remain)
                if tabManager.activeTabId == browserTabId {
                    tabManager.activeTabId = nil
                }
            }
        }
        } else {
            logDebug(.sidebar, "No corresponding browser tab found for sidebar tab \(id.uuidString.prefix(8))")
            if let staleID = manager.sidebarToBrowserTabMapping.removeValue(forKey: id) {
                manager.browserToSidebarTabMapping.removeValue(forKey: staleID)
            }
            
            // If there was no browser tab but this sidebar tab was selected, handle selection
            if wasSelected {
                manager.selectionManager.moveSelectionToNextActiveTab(excluding: id)
            }
        }
        
        // Unloaded unless another window has it open; update timestamp
        tab.isUnloaded = manager.isUnloadedAfterClosingHere(id)
        tab.lastActiveAt = Date()
        
        // If no browser tab mapping existed, still restore the original title when unloading (but preserve custom titles)
        if tab.isUnloaded, tab.customTitle == nil, let originalTitle = tab.originalTitle {
            tab.title = originalTitle
        }
        
        manager.sidebarStructure.tabs[id] = tab
        
        // Save the changes
        manager.saveSidebarStructure()
        
        // Notify command palette if it's open that the tab list has changed
        if let tabManager = manager.tabManager, tabManager.showCommandPalette {
            NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: tabManager)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .commandPaletteRefocus, object: tabManager)
            }
        }
    }
    
    /// Opens the saved tab's page in this window, or shows the one it has
    /// here. Open in another window too, it gets a page of its own here.
    func loadTab(withID id: UUID) {
        guard let manager = sidebarManager else { return }
        guard var tab = manager.sidebarStructure.tabs[id] else { return }
        guard let tabManager = manager.tabManager else { return }
        
        // First, check if a browser tab with the same URL already exists in
        // the saved tab's space (another space's may have another profile).
        // A pinned site opens a tab of its own, in the space on screen.
        let isPinned = manager.sidebarStructure.pinnedItems.contains(id)
        // Loaded in the background already (pinned sites always are): shown
        if isPinned, let browserTabId = manager.sidebarToBrowserTabMapping[id],
           tabManager.tabs.contains(where: { $0.id == browserTabId }) {
            tabManager.activeTabId = browserTabId
            manager.selectedItem = id
            if tab.isUnloaded {
                tab.isUnloaded = false
                manager.sidebarStructure.tabs[id] = tab
                manager.exposeSaveSidebarStructureDebounced()
            }
            return
        }
        let tabSpaceID = isPinned
            ? manager.spaceSelection?.currentSpaceID
            : tab.collectionID ?? SpaceManager.shared.defaultSpaceID
        // Not a private tab: saving one opens its page anew outside private
        // browsing (reopenIfPrivate), and taking the private tab itself
        // closed the page instead. Nor another saved tab's: two saved tabs
        // with the same address shared one, and closing it left the other
        // marked as loaded with nothing open.
        if !isPinned, let existingBrowserTab = tabManager.tabs.first(where: {
            let savedTabID = manager.browserToSidebarTabMapping[$0.id]
            return $0.url == tab.url && !$0.isPrivate && (savedTabID == nil || savedTabID == id)
                && SpaceManager.shared.spaceID(of: $0) == tabSpaceID
        }) {
            
            // Establish mapping between sidebar tab and existing browser tab
            manager.sidebarToBrowserTabMapping[id] = existingBrowserTab.id
            manager.browserToSidebarTabMapping[existingBrowserTab.id] = id
            
            // Switch to the existing browser tab immediately for fast UI response
            tabManager.activeTabId = existingBrowserTab.id
            
            // Update sidebar selection immediately
            manager.selectedItem = id
            
            // Defer heavy operations (save) to avoid blocking UI
            DispatchQueue.main.async {
                // Mark tab as not unloaded, as it is now: renamed, moved
                // or removed meanwhile, it's left that way
                guard var tab = manager.sidebarStructure.tabs[id] else { return }
                tab.isUnloaded = false
                tab.lastActiveAt = Date()
                manager.sidebarStructure.tabs[id] = tab
                manager.exposeSaveSidebarStructureDebounced()
                
                // Schedule originalTitle refresh after page loads
                self.scheduleOriginalTitleRefresh(for: id, browserTabId: existingBrowserTab.id)
            }
            
            return
        }
        
        // Create new BrowserTab from sidebar data
        let browserTab = tab.toBrowserTab()
        browserTab.spaceID = tabSpaceID
        
        // Establish mapping between sidebar tab and browser tab
        manager.sidebarToBrowserTabMapping[id] = browserTab.id
        manager.browserToSidebarTabMapping[browserTab.id] = id
        
        // Restore favicon asynchronously from new cache system
        let tabURL = tab.url
        Task { @MainActor in
            if let faviconImage = await FaviconCacheManager.shared.getFavicon(for: tabURL) {
                browserTab.favicon = faviconImage
            }
        }
        
        // Add to TabManager and switch immediately for fast UI response
        tabManager.tabs.append(browserTab)
        tabManager.activeTabId = browserTab.id
        
        // Update sidebar selection immediately
        manager.selectedItem = id
        
        // Schedule delayed focus to ensure WebView is ready
        scheduleDelayedFocus(for: browserTab.id)
        
        // Defer heavy operations (save) to avoid blocking UI
        DispatchQueue.main.async {
            // Update sidebar tab, as it is now: renamed, moved or removed
            // meanwhile, it's left that way
            guard var tab = manager.sidebarStructure.tabs[id] else { return }
            tab.isUnloaded = false
            tab.lastActiveAt = Date()
            
            // Record the tab load as activity in persistent tracking
            TabActivityManager.shared.recordTabActivity(for: id)
            
            var newStructure = manager.sidebarStructure
            newStructure.tabs[id] = tab
            manager.sidebarStructure = newStructure
            manager.exposeSaveSidebarStructureDebounced()
            
            // Schedule originalTitle refresh after page loads
            self.scheduleOriginalTitleRefresh(for: id, browserTabId: browserTab.id)
        }
    }
    
    /// Gives a saved tab a browser tab of its own, loading behind the
    /// active one (a pinned site, so it's ready when it's selected). It
    /// doesn't start playing sound on its own.
    func loadInBackground(withID id: UUID) {
        guard let manager = sidebarManager,
              var tab = manager.sidebarStructure.tabs[id],
              let tabManager = manager.tabManager else { return }

        let browserTab = tab.toBrowserTab()
        browserTab.spaceID = manager.sidebarStructure.pinnedItems.contains(id)
            ? manager.spaceSelection?.currentSpaceID
            : tab.collectionID ?? SpaceManager.shared.defaultSpaceID
        browserTab.isLoadedInBackground = true

        manager.sidebarToBrowserTabMapping[id] = browserTab.id
        manager.browserToSidebarTabMapping[browserTab.id] = id

        let tabURL = tab.url
        Task { @MainActor in
            if let faviconImage = await FaviconCacheManager.shared.getFavicon(for: tabURL) {
                browserTab.favicon = faviconImage
            }
        }

        tabManager.tabs.append(browserTab)

        tab.isUnloaded = false
        manager.sidebarStructure.tabs[id] = tab
        manager.exposeSaveSidebarStructureDebounced()
        scheduleOriginalTitleRefresh(for: id, browserTabId: browserTab.id)
    }

    /// Takes back the pages saved tabs had open in this window at quit (the
    /// last session's browser tabs), each at the page it was on. They get
    /// their web view when first shown, as restored tabs do, except pinned
    /// sites, which are always loaded. A saved tab removed meanwhile, or
    /// with a page here already, leaves its page out.
    func restoreTabs(_ pages: [(browserTab: BrowserTab, savedTabID: UUID)]) {
        guard let manager = sidebarManager, let tabManager = manager.tabManager else { return }
        var structure = manager.sidebarStructure
        var restored: [BrowserTab] = []
        var wasUnloaded = false

        for (browserTab, id) in pages {
            guard var tab = structure.tabs[id], manager.sidebarToBrowserTabMapping[id] == nil else { continue }
            let isPinned = structure.pinnedItems.contains(id)
            browserTab.spaceID = isPinned
                ? manager.spaceSelection?.currentSpaceID
                : tab.collectionID ?? SpaceManager.shared.defaultSpaceID
            if isPinned {
                browserTab.isLoadedInBackground = true
            } else if !browserTab.isEmpty {
                browserTab.markSuspended()
            }

            manager.sidebarToBrowserTabMapping[id] = browserTab.id
            manager.browserToSidebarTabMapping[browserTab.id] = id

            wasUnloaded = wasUnloaded || tab.isUnloaded
            tab.isUnloaded = false
            if tab.customTitle == nil, !browserTab.title.isEmpty {
                tab.title = browserTab.title
            }
            structure.tabs[id] = tab
            restored.append(browserTab)

            if !browserTab.isEmpty {
                tabManager.updateFavicon(for: browserTab, url: browserTab.url)
            }
        }

        guard !restored.isEmpty else { return }
        manager.sidebarStructure = structure
        tabManager.tabs += restored
        if wasUnloaded {
            manager.exposeSaveSidebarStructureDebounced()
        }
    }

    // MARK: - Tab State Management
    
    func updateTabState(for tabID: UUID, title: String? = nil, url: String? = nil, 
                       isLoading: Bool? = nil, progress: Double? = nil, isActiveTab: Bool = true) {
        guard let manager = sidebarManager else { return }
        guard var tab = manager.sidebarStructure.tabs[tabID] else { return }
        
        // Update title only if no custom title is set (preserves user-defined custom titles)
        var titleChanged = false
        if let title = title, !title.isEmpty, tab.customTitle == nil, tab.title != title {
            tab.title = title
            titleChanged = true
        }
        
        var hasChanges = false
        
        if let isLoading = isLoading, tab.isLoading != isLoading {
            tab.isLoading = isLoading
            hasChanges = true
        }
        
        if let progress = progress, tab.estimatedProgress != progress {
            tab.estimatedProgress = progress
            hasChanges = true
        }
        
        guard titleChanged || hasChanges else { return }
        // A background tab retitling itself (e.g. an unread counter)
        // isn't user activity — don't let it skew recency ordering.
        if isActiveTab {
            tab.lastActiveAt = Date()
        }
        manager.sidebarStructure.tabs[tabID] = tab
        
        // The live page title alone neither reloads the sidebar nor is
        // saved: only its row updates, and an unloaded tab shows
        // `originalTitle`. Pages retitle themselves often (unread counters,
        // blinking titles).
        if titleChanged {
            manager.savedTabTitleDidChange.send(tabID)
        }
        guard hasChanges else { return }
        
        // Bump `lastUpdated` so the controller's `removeDuplicates(by:)`
        // dedupe filter on `sidebarStructurePublisher` lets the publish through.
        manager.sidebarStructure.lastUpdated = Date()
        
        // Use debounced save for frequent tab state updates
        manager.exposeSaveSidebarStructureDebounced()
    }
    
    func markTabAsActive(_ tabID: UUID) {
        guard let manager = sidebarManager else { return }
        guard var tab = manager.sidebarStructure.tabs[tabID] else { return }
        
        // Always record in persistent activity manager
        TabActivityManager.shared.recordTabActivity(for: tabID)
        
        // Only update sidebar structure if significant time has passed to avoid constant updates
        if Date().timeIntervalSince(tab.lastActiveAt) > 60 { // 1 minute threshold
            tab.lastActiveAt = Date()
            manager.sidebarStructure.tabs[tabID] = tab
            // Use debounced save for frequent activity updates
            manager.exposeSaveSidebarStructureDebounced()
        }
    }
    
    func updateSavedTabToCurrentState(for sidebarTabID: UUID) {
        guard let manager = sidebarManager else { return }
        guard var sidebarTab = manager.sidebarStructure.tabs[sidebarTabID],
              let browserTabId = manager.sidebarToBrowserTabMapping[sidebarTabID],
              let browserTab = manager.browserTab(withID: browserTabId) else {
            logWarning(.sidebar, "Could not find browser tab to update saved tab state")
            return
        }

        logDebug(.sidebar, "Updating saved tab to current browser state: \(browserTab.title)")

        // Update the saved tab with current browser tab state
        sidebarTab.title = browserTab.title
        sidebarTab.url = browserTab.url
        sidebarTab.originalTitle = browserTab.title // Update the original title to match the new saved state
        sidebarTab.lastActiveAt = Date()

        // Clear custom title since we're updating to current state
        sidebarTab.customTitle = nil

        manager.sidebarStructure.tabs[sidebarTabID] = sidebarTab
        // Bump `lastUpdated` so the structure publisher's dedupe filter
        // lets the change through and the cell re-configures with the
        // updated title/URL/favicon-cache-key.
        manager.sidebarStructure.lastUpdated = Date()
        manager.saveSidebarStructure()

        logInfo(.sidebar, "Updated saved tab '\(sidebarTab.displayTitle)' to current URL: \(sidebarTab.url)")
    }

    func updateTabURL(for sidebarTabID: UUID, newURL: String) {
        guard let manager = sidebarManager else { return }
        guard var sidebarTab = manager.sidebarStructure.tabs[sidebarTabID] else {
            logWarning(.sidebar, "Could not find saved tab to update URL")
            return
        }

        let trimmedURL = newURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty else {
            logWarning(.sidebar, "Cannot update to empty URL")
            return
        }

        logDebug(.sidebar, "Updating saved tab URL manually: \(sidebarTab.url) -> \(trimmedURL)")

        // Update the saved tab URL
        sidebarTab.url = trimmedURL
        sidebarTab.lastActiveAt = Date()

        // Its pages, in every window it's open in, go to the new URL
        for other in manager.store.sidebarManagers {
            guard let browserTabId = other.sidebarToBrowserTabMapping[sidebarTabID],
                  let browserTab = other.browserTab(withID: browserTabId) else { continue }

            // Navigate to new URL
            browserTab.navigateToURL(trimmedURL)

            // Post navigation notification to the WebView coordinator
            NotificationCenter.default.post(
                name: NSNotification.Name("NavigateWebView"),
                object: nil,
                userInfo: ["tabId": browserTab.id.uuidString, "url": trimmedURL]
            )

            logDebug(.sidebar, "Navigated active browser tab to new URL: \(trimmedURL)")
        }

        manager.sidebarStructure.tabs[sidebarTabID] = sidebarTab
        // Bump `lastUpdated` so the controller's `removeDuplicates(by:)`
        // dedupe filter on `sidebarStructurePublisher` lets the publish through —
        // the cell needs to re-configure to pick up the new URL (favicon
        // reload) and any title that the upcoming navigation will mirror in.
        manager.sidebarStructure.lastUpdated = Date()
        manager.saveSidebarStructure()

        logInfo(.sidebar, "Updated saved tab '\(sidebarTab.displayTitle)' URL to: \(trimmedURL)")
    }

    // MARK: - Return to Saved Page
    
    func returnToSavedPage(for itemID: UUID) -> Bool {
        guard let manager = sidebarManager else { return false }
        guard let tab = manager.sidebarStructure.tabs[itemID],
              !tab.isUnloaded,
              let browserTabId = manager.sidebarToBrowserTabMapping[itemID],
              let browserTab = manager.browserTab(withID: browserTabId) else {
            return false
        }
        
        // Check if the browser tab's current URL is different from the saved URL
        if browserTab.url != tab.url {
            logDebug(.sidebar, "Returning to saved page: \(browserTab.url) → \(tab.url)")
            
            // Navigate directly within the current browser tab instead of using tabManager.navigateToURL
            // to avoid triggering new tab creation logic
            browserTab.navigateToURL(tab.url)
            
            // Post navigation notification to the WebView coordinator for this specific tab
            NotificationCenter.default.post(
                name: NSNotification.Name("NavigateWebView"),
                object: nil,
                userInfo: ["tabId": browserTab.id.uuidString, "url": tab.url]
            )
            
            return true
        }
        
        return false
    }
    
    func shouldShowReturnToSavedPage(for itemID: UUID) -> Bool {
        guard let manager = sidebarManager else { return false }
        guard let tab = manager.sidebarStructure.tabs[itemID],
              !tab.isUnloaded,
              let browserTabId = manager.sidebarToBrowserTabMapping[itemID],
              let browserTab = manager.browserTab(withID: browserTabId) else {
            return false
        }
        
        // Return true if the current browser URL is different from the saved URL
        return browserTab.url != tab.url
    }
    
    // MARK: - Focus Management
    
    /// Schedule delayed focus for a newly loaded tab to ensure WebView is ready
    private func scheduleDelayedFocus(for browserTabId: UUID) {
        // Try immediate focus first
        attemptFocus(for: browserTabId, attempt: 1)
    }
    
    /// Attempt to focus a WebView with retries if coordinator isn't ready
    private func attemptFocus(for browserTabId: UUID, attempt: Int) {
        let maxAttempts = 5
        let delays: [TimeInterval] = [0.0, 0.05, 0.1, 0.2, 0.3]
        
        guard attempt <= maxAttempts else {
            logWarning(.sidebar, "Failed to focus WebView after \(maxAttempts) attempts for tab \(browserTabId.uuidString.prefix(8))")
            return
        }
        
        let delay = attempt <= delays.count ? delays[attempt - 1] : 0.3
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Check if coordinator exists
            if TabWebViewCoordinator.coordinator(for: browserTabId) != nil {
                NotificationCenter.default.post(
                    name: NSNotification.Name("FocusWebView"),
                    object: nil,
                    userInfo: ["tabId": browserTabId.uuidString]
                )
            } else {
                // Coordinator not ready yet, try again
                logDebug(.sidebar, "Coordinator not ready for tab \(browserTabId.uuidString.prefix(8)), retrying focus (attempt \(attempt))")
                self?.attemptFocus(for: browserTabId, attempt: attempt + 1)
            }
        }
    }
    
    // MARK: - Original Title Refresh
    
    /// Schedule a refresh of the originalTitle after the page has finished loading
    private func scheduleOriginalTitleRefresh(for sidebarTabId: UUID, browserTabId: UUID) {
        // Wait for the page to finish loading, then update originalTitle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshOriginalTitleIfNeeded(sidebarTabId: sidebarTabId, browserTabId: browserTabId)
        }
    }
    
    /// Check if the browser tab has finished loading and update originalTitle
    private func refreshOriginalTitleIfNeeded(sidebarTabId: UUID, browserTabId: UUID) {
        guard let manager = sidebarManager else { return }
        guard var sidebarTab = manager.sidebarStructure.tabs[sidebarTabId] else { return }
        guard let browserTab = manager.browserTab(withID: browserTabId) else { return }
        
        // Only update if the browser tab has finished loading, is on the saved URL, and is not showing an error page
        if !browserTab.isLoading && browserTab.url == sidebarTab.url && !browserTab.isShowingErrorPage {
            let newTitle = browserTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Update originalTitle if the page title has changed
            if !newTitle.isEmpty && sidebarTab.originalTitle != newTitle {
                sidebarTab.originalTitle = newTitle
                manager.sidebarStructure.tabs[sidebarTabId] = sidebarTab
                manager.exposeSaveSidebarStructureDebounced()
                
                logDebug(.sidebar, "Refreshed originalTitle for saved tab '\(sidebarTab.displayTitle)': '\(newTitle)'")
            }
        } else if browserTab.isShowingErrorPage {
            logDebug(.sidebar, "Skipping originalTitle update - browser tab is showing error page")
        } else if browserTab.isLoading {
            // If still loading, try again later
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshOriginalTitleIfNeeded(sidebarTabId: sidebarTabId, browserTabId: browserTabId)
            }
        }
    }
} 
