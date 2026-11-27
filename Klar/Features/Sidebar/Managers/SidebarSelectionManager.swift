import Foundation
import SwiftUI
import Combine

/// Manages selection, navigation, and tab history for the sidebar
class SidebarSelectionManager {
    private weak var sidebarManager: SidebarManager?
    
    // Tab history tracking - stores tab IDs in order of most recent activation (most recent first)
    private var tabHistory: [UUID] = []
    private let maxHistorySize = SidebarConfiguration.tabHistorySize
    
    init(sidebarManager: SidebarManager) {
        self.sidebarManager = sidebarManager
    }
    
    // MARK: - Selection and Navigation
    
    func selectItem(_ itemID: UUID) {
        guard let manager = sidebarManager else { return }
        
        // FAST PATH: Skip if already selected to prevent unnecessary work
        if manager.selectedItem == itemID {
            addToTabHistory(itemID)
            return
        }
        
        manager.selectedItem = itemID
        
        // FAST PATH FOR ORGANIZED TABS: Handle sidebar tabs efficiently
        if let tab = manager.sidebarStructure.tabs[itemID],
           !tab.isUnloaded,
           let tabManager = manager.tabManager,
           let browserTabId = manager.sidebarToBrowserTabMapping[itemID],
           tabManager.tabs.contains(where: { $0.id == browserTabId }) {
            
            // Only proceed if we're actually switching tabs
            if tabManager.activeTabId != browserTabId {
                // Temporarily prevent sync to avoid cycles
                manager.setManuallySelecting(true)
                
                // Switch tab immediately for fast UI response
                tabManager.activeTabId = browserTabId
                
                // Defer heavy operations to avoid blocking UI
                DispatchQueue.main.async { [weak self] in
                    self?.addToTabHistory(itemID)
                    manager.setManuallySelecting(false)
                }
                
                return
            } else {
                // Same tab, just add to history without heavy operations
                DispatchQueue.main.async { [weak self] in
                    self?.addToTabHistory(itemID)
                }
                return
            }
        }
        
        // FAST PATH FOR REGULAR TABS: Handle non-organized browser tabs quickly
        if let tabManager = manager.tabManager,
           let _ = tabManager.tabs.first(where: { $0.id == itemID }),
           manager.sidebarStructure.tabs[itemID] == nil { // Not an organized tab
            
            // Only proceed if we're actually switching tabs
            if tabManager.activeTabId != itemID {
                // Temporarily prevent sync to avoid cycles
                manager.setManuallySelecting(true)
                
                // Switch tab immediately for fast UI response
                tabManager.activeTabId = itemID
                
                // Defer heavy operations to avoid blocking UI
                DispatchQueue.main.async { [weak self] in
                    self?.addToTabHistory(itemID)
                    manager.setManuallySelecting(false)
                }
                
                return
            } else {
                // Same tab, just add to history without heavy operations
                DispatchQueue.main.async { [weak self] in
                    self?.addToTabHistory(itemID)
                }
                return
            }
        }
        
        // Set flag to prevent sync interference for slow path
        manager.setManuallySelecting(true)
        
        // SLOW PATH: For unloaded tabs, missing mappings, or edge cases
        // Add to tab history immediately for UI responsiveness
        addToTabHistory(itemID)
        
        // Handle heavy operations asynchronously but minimize delays
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Handle the complex selection logic
            self.handleComplexSelection(itemID)
            
            // Clear flag after operations complete
            manager.setManuallySelecting(false)
        }
    }
    
    private func handleComplexSelection(_ itemID: UUID) {
        guard let manager = sidebarManager else { return }
        
        if let tab = manager.sidebarStructure.tabs[itemID] {
            if let tabManager = manager.tabManager,
               let browserTabId = manager.sidebarToBrowserTabMapping[itemID] {
                // Its page in this window
                if let browserTab = tabManager.tabs.first(where: { $0.id == browserTabId }) {
                    // Add the browser tab to history as well
                    addToTabHistory(browserTabId)

                    // Simply switch to the tab - don't try to navigate
                    // URL mismatches between saved and browser tabs should be handled elsewhere
                    if tabManager.activeTabId != browserTabId {
                        tabManager.switchToTab(browserTab)
                    }
                } else if tabManager.isSidebarMappedTab(browserTabId) {
                    // This is a legitimate sidebar-mapped tab - load it properly
                    logDebug(.sidebar, "Found sidebar-mapped tab '\(tab.displayTitle)' - loading it")
                    manager.sidebarTabManager.loadTab(withID: itemID)
                } else {
                    // Browser tab doesn't exist and it's not a sidebar-mapped tab
                    logWarning(.sidebar, "Browser tab \(browserTabId.uuidString.prefix(8)) no longer exists - loading the saved tab again")
                    manager.sidebarToBrowserTabMapping.removeValue(forKey: itemID)
                    manager.browserToSidebarTabMapping.removeValue(forKey: browserTabId)
                    manager.sidebarTabManager.loadTab(withID: itemID)
                }
            } else {
                // No page in this window (unloaded, or open in other windows
                // only): one of its own here, or a tab here with its address
                // (loadTab)
                manager.sidebarTabManager.loadTab(withID: itemID)
            }
        } else if let tabManager = manager.tabManager,
                  let regularTab = tabManager.tabs.first(where: { $0.id == itemID }) {
            
            // Add the regular tab to history
            addToTabHistory(itemID)
            
            // Only switch tabs if it's not already the active tab
            if tabManager.activeTabId != itemID {
                tabManager.switchToTab(regularTab)
            }
        } else {
            logWarning(.sidebar, "No sidebar tab or regular tab found with ID \(itemID)")
        }
    }
    
    func moveSelectionToNextActiveTab(excluding excludedID: UUID? = nil) {
        let excludedIDs: Set<UUID> = excludedID.map { [$0] } ?? []
        moveSelectionToNextActiveTab(excluding: excludedIDs)
    }
    
    /// Past several tabs at once (saved tabs' and browser tabs' IDs), as when
    /// a folder's tabs are deleted together.
    func moveSelectionToNextActiveTab(excluding excludedIDs: Set<UUID>) {
        guard let manager = sidebarManager else { return }
        
        // Clean up stale entries in history first
        cleanupTabHistory()
        
        // First, try to find the most recently active tab from history
        if let historyTabID = getNextTabFromHistory(excluding: excludedIDs) {
            // If it's an organized tab, use mapping to switch browser tabs
            if manager.sidebarStructure.tabs[historyTabID] != nil {
                if let tabManager = manager.tabManager,
                   let browserTabId = manager.sidebarToBrowserTabMapping[historyTabID],
                   let browserTab = tabManager.tabs.first(where: { $0.id == browserTabId }) {
                    manager.selectedItem = historyTabID
                    tabManager.switchToTab(browserTab)
                    return  // Only return if switchToTab was actually called
                }
                // Fall through to try other options if mapping is missing
                logDebug(.sidebar, "History tab \(historyTabID.uuidString.prefix(8)) has no browser tab mapping, trying fallback")
            } else if let tabManager = manager.tabManager,
                     let browserTab = tabManager.tabs.first(where: { $0.id == historyTabID }) {
                // It's a regular tab
                manager.selectedItem = historyTabID
                tabManager.switchToTab(browserTab)
                return  // Only return if switchToTab was actually called
            }
            // Fall through to fallback logic if we couldn't switch to the history tab
        }
        
        // Fallback: use the previous logic if no suitable tab found in history
        // FIXED: Search through ALL sidebar tabs, not just getDisplayItems which only returns root items
        // Only the active space's: closing its last tab leaves the space empty.
        // Not the pinned sites either, which are always loaded.
        let spaces = manager.spaceSelection
        let pinnedItems = Set(manager.sidebarStructure.pinnedItems)
        let activeOrganizedTabs = manager.sidebarStructure.tabs.values.compactMap { tab -> SidebarTab? in
            if manager.isOpenHere(tab.id) && !excludedIDs.contains(tab.id) && !pinnedItems.contains(tab.id)
                && spaces?.isItemInActiveSpace(tab.id) != false {
                return tab
            }
            return nil
        }.sorted { $0.lastActiveAt > $1.lastActiveAt } // Sort by most recently active
        
        // Try active organized tabs (sorted by most recently active)
        // Only return if we successfully switch to one
        for activeTab in activeOrganizedTabs {
            if let tabManager = manager.tabManager,
               let browserTabId = manager.sidebarToBrowserTabMapping[activeTab.id],
               let browserTab = tabManager.tabs.first(where: { $0.id == browserTabId }) {
                manager.selectedItem = activeTab.id
                tabManager.switchToTab(browserTab)
                return  // Only return if switchToTab was actually called
            }
            // Try the next organized tab if this one has no browser tab mapping
            logDebug(.sidebar, "Active organized tab \(activeTab.id.uuidString.prefix(8)) has no browser tab mapping, trying next")
        }
        
        // No active organized tabs, try to select from regular tabs
        guard let tabManager = manager.tabManager else {
            manager.selectedItem = nil
            return
        }
        
        // Get regular tabs (browser tabs not organized in sidebar)
        let organizedBrowserTabIDs = manager.getOrganizedBrowserTabIDs()
        let regularTabs = tabManager.tabs.filter { tab in
            !tab.isEmpty && !organizedBrowserTabIDs.contains(tab.id) && !excludedIDs.contains(tab.id)
                && spaces?.isInActiveSpace(tab) != false
        }.sorted { $0.createdAt > $1.createdAt }
        
        // If we have regular tabs, select the first one (most recent)
        if let firstRegularTab = regularTabs.first {
            // For regular tabs, we need to use the browser tab ID directly since they're not in sidebar structure
            manager.selectedItem = firstRegularTab.id
            tabManager.switchToTab(firstRegularTab)
        } else {
            // No tabs available at all, clear selection
            manager.selectedItem = nil
        }
    }
    
    // MARK: - Tab History Management
    
    func addToTabHistory(_ tabID: UUID) {
        // Record in persistent activity tracking
        TabActivityManager.shared.recordTabActivity(for: tabID)
        
        // Only add if it's not already the most recent entry (performance optimization)
        if tabHistory.first != tabID {
            // Remove existing entry if present
            tabHistory.removeAll { $0 == tabID }
            
            // Add to front (most recent)
            tabHistory.insert(tabID, at: 0)
            
            // Trim to max size
            if tabHistory.count > maxHistorySize {
                tabHistory = Array(tabHistory.prefix(maxHistorySize))
            }
        }
    }
    
    func removeFromTabHistory(_ tabID: UUID) {
        tabHistory.removeAll { $0 == tabID }
    }

    /// For a saved tab that took another ID (matched to iCloud's copy).
    func replaceInTabHistory(_ oldID: UUID, with newID: UUID) {
        if let index = tabHistory.firstIndex(of: oldID) {
            tabHistory[index] = newID
        }
    }

    /// Gets the most recent active tab from history that is still available
    func getMostRecentActiveTab() -> UUID? {
        return getNextTabFromHistory()
    }
    
    /// Gets the position of a tab in the history (lower index = more recent)
    /// Returns nil if the tab is not in history
    func getTabHistoryPosition(_ tabID: UUID) -> Int? {
        return tabHistory.firstIndex(of: tabID)
    }
    
    private func getNextTabFromHistory(excluding excludedIDs: Set<UUID> = []) -> UUID? {
        guard let manager = sidebarManager,
              let tabManager = manager.tabManager else { return nil }
        
        let organizedBrowserTabIDs = manager.getOrganizedBrowserTabIDs()
        let spaces = manager.spaceSelection
        
        // Go through history and find the first available tab in the active space
        for tabID in tabHistory {
            // Skip the excluded tabs
            if excludedIDs.contains(tabID) { continue }
            
            // Check if it's an organized tab that's still active (be defensive)
            if manager.sidebarStructure.tabs[tabID] != nil {
                if manager.isOpenHere(tabID) && spaces?.isItemInActiveSpace(tabID) != false {
                    return tabID
                }
            }
            
            // Check if it's a regular tab that still exists (be defensive about access)
            if !organizedBrowserTabIDs.contains(tabID) {
                // Use contains instead of first(where:) to avoid potential crashes
                let tabExists = tabManager.tabs.contains { tab in
                    tab.id == tabID && !tab.isEmpty && spaces?.isInActiveSpace(tab) != false
                }
                if tabExists {
                    return tabID
                }
            }
        }
        return nil
    }
    
    private func cleanupTabHistory() {
        guard let manager = sidebarManager else { 
            // Clear history if manager is gone
            tabHistory.removeAll()
            return 
        }
        
        guard let tabManager = manager.tabManager else { 
            // Clear history if tab manager is gone
            tabHistory.removeAll()
            return 
        }
        
        let organizedBrowserTabIDs = manager.getOrganizedBrowserTabIDs()
        let activeBrowserTabIDs = Set(tabManager.tabs.filter { !$0.isEmpty }.map { $0.id })
        
        // Remove tabs that no longer exist - be defensive about accessing data
        tabHistory = tabHistory.filter { tabID in
            // Keep if it's a sidebar tab (both active and unloaded should be kept for history)
            if let _ = manager.sidebarStructure.tabs[tabID] {
                return true  // Keep all sidebar tabs in history (both active and unloaded)
            }
            
            // Keep if it's an active regular tab
            if !organizedBrowserTabIDs.contains(tabID) && activeBrowserTabIDs.contains(tabID) {
                return true
            }
            
            return false
        }
    }
    
    // MARK: - Selection Sync
    
    func syncSelectionWithActiveTab(activeTabId: UUID?) {
        guard let manager = sidebarManager else { return }
        
        // Don't sync during initialization or manual selection
        guard !manager.isInitializing && !manager.isManuallySelecting else {
            return
        }
        
        // Prevent recursive calls
        guard !manager.isSyncing else {
            return
        }
        
        manager.setIsSyncing(true)
        defer { 
                    // Clear sync flag immediately for better performance
        manager.setIsSyncing(false)
        }
        
        performSyncSelectionWithActiveTab(activeTabId: activeTabId)
    }
    
    private func performSyncSelectionWithActiveTab(activeTabId: UUID?) {
        guard let manager = sidebarManager,
              let _ = manager.tabManager else { 
            return 
        }
        
        guard let activeTabId = activeTabId else {
            if manager.selectedItem != nil {
                manager.selectedItem = nil
            }
            return
        }
        
        // Add the active tab to history (this works for both organized and regular tabs)
        addToTabHistory(activeTabId)
        
        // First, try to find a mapped sidebar tab for the active browser tab
        if let sidebarTabId = manager.browserToSidebarTabMapping[activeTabId] {
            if manager.sidebarStructure.tabs[sidebarTabId] != nil {
                if manager.selectedItem != sidebarTabId {
                    manager.selectedItem = sidebarTabId
                    // Also add the sidebar tab ID to history for organized tabs
                    addToTabHistory(sidebarTabId)
                }
                return
            } else {
                logWarning(.sidebar, "Stale mapping found, cleaning up")
                manager.browserToSidebarTabMapping.removeValue(forKey: activeTabId)
                manager.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
            }
        }
        
        // No mapping found - this is a regular tab (not organized)
        // Set selection to the active regular tab ID for visual feedback
        if manager.selectedItem != activeTabId {
            manager.selectedItem = activeTabId
        }
    }
    
    func performInitialSelectionSync(activeTabId: UUID?) {
        guard let manager = sidebarManager,
              let _ = manager.tabManager else { return }
        
        // Simple initial sync without triggering @Published updates on observers
        guard let activeTabId = activeTabId else {
            manager.selectedItem = nil
            return
        }
        
        // Add the active tab to history
        addToTabHistory(activeTabId)
        
        // Check if there's a mapped sidebar tab for the active browser tab
        if let sidebarTabId = manager.browserToSidebarTabMapping[activeTabId],
           manager.sidebarStructure.tabs[sidebarTabId] != nil {
            manager.selectedItem = sidebarTabId
            addToTabHistory(sidebarTabId)
        } else {
            // Regular tab or no mapping
            manager.selectedItem = activeTabId
        }
    }
}
