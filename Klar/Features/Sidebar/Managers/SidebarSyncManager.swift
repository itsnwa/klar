import Foundation
import SwiftUI
import Combine

/// Manages synchronization between sidebar and TabManager
class SidebarSyncManager {
    private weak var sidebarManager: SidebarManager?
    private var cancellables = Set<AnyCancellable>()
    
    // Debounced refresh to prevent AttributeGraph cycles
    private var refreshWorkItem: DispatchWorkItem?
    private let refreshDebounceInterval: TimeInterval = 0.05
    
    init(sidebarManager: SidebarManager) {
        self.sidebarManager = sidebarManager
    }
    
    // MARK: - Debounced Refresh
    
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = DispatchWorkItem { [weak self] in
            self?.sidebarManager?.objectWillChange.send()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounceInterval, execute: refreshWorkItem!)
    }
    
    // MARK: - TabManager Observer Setup
    
    func setupTabManagerObserver() {
        guard let manager = sidebarManager,
              let tabManager = manager.tabManager else { return }
        
        // Set up the activeTabId observer with optimized performance
        tabManager.$activeTabId
            .debounce(for: .milliseconds(25), scheduler: DispatchQueue.main)  // Reduced debounce for snappier feel
            .removeDuplicates()
            .sink { [weak self] activeTabId in
                // Skip sync during initialization or manual selection
                guard let self = self,
                      let manager = self.sidebarManager,
                      !manager.isInitializing,
                      !manager.isManuallySelecting,
                      manager.lastSyncedActiveTabId != activeTabId else { 
                    return 
                }
                
                // Update tracking and sync efficiently
                manager.lastSyncedActiveTabId = activeTabId
                manager.selectionManager.syncSelectionWithActiveTab(activeTabId: activeTabId)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Sync
    
    func syncWithTabManagerQuietly() {
        guard let manager = sidebarManager,
              let tabManager = manager.tabManager else { return }
        
        var hasChanges = false
        var newStructure = manager.sidebarStructure
        
        // Establish mappings for existing tabs and sync organized tabs. The
        // window's own; a saved tab may be open in another window, which
        // keeps it loaded too.
        let browserTabIDs = manager.allBrowserTabIDs
        for browserTab in tabManager.tabs {
            // Check if we already have a mapping for this browser tab
            if let sidebarTabId = manager.browserToSidebarTabMapping[browserTab.id],
               var sidebarTab = newStructure.tabs[sidebarTabId] {
                // The saved tab's page in this window
                if manager.sidebarToBrowserTabMapping[sidebarTabId] == nil {
                    manager.sidebarToBrowserTabMapping[sidebarTabId] = browserTab.id
                }
                
                // Check for cross-domain navigation
                if !URLUtilities.isSameSite(browserTab.url, sidebarTab.url) {
                    logInfo(.sidebar, "Cross-domain navigation detected (quiet): \(URLUtilities.baseDomain(of: sidebarTab.url) ?? "unknown") → \(URLUtilities.baseDomain(of: browserTab.url) ?? "unknown")")
                    
                    // Break the mapping to let the browser tab become a regular tab
                    manager.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
                    manager.browserToSidebarTabMapping.removeValue(forKey: browserTab.id)
                    
                    // Mark the saved tab as unloaded (unless another window
                    // has it open) to preserve its original state
                    sidebarTab.isUnloaded = manager.isUnloadedAfterClosingHere(sidebarTabId)
                    sidebarTab.lastActiveAt = Date()
                    newStructure.tabs[sidebarTabId] = sidebarTab
                    hasChanges = true
                    
                    // Immediately update selection to show browser tab as regular tab
                    if manager.selectedItem == sidebarTabId {
                        // Update selection immediately, then force UI refresh after structure changes
                        DispatchQueue.main.async { [weak manager, weak self] in
                            manager?.selectedItem = browserTab.id
                            // Schedule debounced UI refresh after selection change
                            self?.scheduleRefresh()
                        }
                    }
                    
                    logInfo(.sidebar, "Saved tab '\(sidebarTab.displayTitle)' preserved, browser tab now regular")
                    continue
                }

                // NOTE: Same-domain URL differences (e.g., trailing slashes, query params, redirects)
                // are intentionally NOT treated as navigation. The saved tab keeps its mapping
                // to the browser tab even if URLs differ slightly within the same domain.
                // This prevents aggressive unloading when pages redirect or add query params.

                // Update existing organized tab only if values actually changed
                // NOTE: We preserve the original URL, title, and favicon of saved tabs
                // to maintain their bookmark-like behavior for same-domain navigation
                var tabChanged = false
                
                // Only update loading state and progress, NOT title or URL
                if sidebarTab.isLoading != browserTab.isLoading {
                    sidebarTab.isLoading = browserTab.isLoading
                    tabChanged = true
                }
                
                if sidebarTab.estimatedProgress != browserTab.estimatedProgress {
                    sidebarTab.estimatedProgress = browserTab.estimatedProgress
                    tabChanged = true
                }
                
                if sidebarTab.isUnloaded {
                    sidebarTab.isUnloaded = false
                    tabChanged = true
                }
                
                if tabChanged {
                    sidebarTab.lastActiveAt = Date()
                    newStructure.tabs[sidebarTabId] = sidebarTab
                    hasChanges = true
                }
            } else if !browserTab.isPrivate, browserTab.openTabID == nil {
                // No mapping exists: a saved tab shown as loaded with this
                // exact address, and no page of its own, takes it (for
                // backward compatibility), in the browser tab's space:
                // another's may have another profile. Only an exact match,
                // whatever order the saved tabs come in: a same-site entry
                // met first used to end the search. Not an open tab's page,
                // which every window has.
                let browserTabSpaceID = browserTab.spaceID ?? SpaceManager.shared.defaultSpaceID
                // Not one open in another window: that one's page is its own.
                let match = newStructure.tabs.first { sidebarTabId, sidebarTab in
                    guard !sidebarTab.isUnloaded, sidebarTab.url == browserTab.url,
                          !manager.store.isOpenInAnyWindow(sidebarTabId) else { return false }
                    if let mappedID = manager.sidebarToBrowserTabMapping[sidebarTabId],
                       browserTabIDs.contains(mappedID) { return false }
                    if let collectionID = sidebarTab.collectionID, let browserTabSpaceID {
                        return collectionID == browserTabSpaceID
                    }
                    return true
                }
                if let sidebarTabId = match?.key {
                    if let staleID = manager.sidebarToBrowserTabMapping[sidebarTabId] {
                        manager.browserToSidebarTabMapping.removeValue(forKey: staleID)
                    }
                    manager.sidebarToBrowserTabMapping[sidebarTabId] = browserTab.id
                    manager.browserToSidebarTabMapping[browserTab.id] = sidebarTabId
                }
            }
        }
        
        // Check for organized tabs that no longer have corresponding browser tabs
        let mappedBrowserTabIDs = Set(manager.browserToSidebarTabMapping.keys)
        
        // Find browser tabs that are no longer active but still have mappings
        // Exclude sidebar-mapped tabs from being considered "stale" since they're legitimate
        let staleBrowserTabIDs = mappedBrowserTabIDs.subtracting(browserTabIDs).filter { !manager.isSidebarMappedTabInAnyWindow($0) }
        
        if !staleBrowserTabIDs.isEmpty {
            logInfo(.sidebar, "Found \(staleBrowserTabIDs.count) stale browser tab mappings - cleaning up")
        }
        
        for staleBrowserTabID in staleBrowserTabIDs {
            guard let sidebarTabId = manager.browserToSidebarTabMapping[staleBrowserTabID] else { continue }
            // Clean up mapping since browser tab no longer exists: in
            // whichever window it was the saved tab's page
            manager.browserToSidebarTabMapping.removeValue(forKey: staleBrowserTabID)
            for other in manager.store.sidebarManagers where other.sidebarToBrowserTabMapping[sidebarTabId] == staleBrowserTabID {
                other.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
            }
            if manager.sidebarToBrowserTabMapping[sidebarTabId] == staleBrowserTabID {
                manager.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
            }

            // Unloaded, unless it's open in a window still
            if var sidebarTab = newStructure.tabs[sidebarTabId], !sidebarTab.isUnloaded,
               manager.isUnloadedAfterClosingHere(sidebarTabId) {
                logDebug(.sidebar, "Marking saved tab '\(sidebarTab.displayTitle)' as unloaded (browser tab \(staleBrowserTabID.uuidString.prefix(8)) no longer exists)")
                sidebarTab.isUnloaded = true
                sidebarTab.lastActiveAt = Date()
                newStructure.tabs[sidebarTabId] = sidebarTab
                hasChanges = true
                logDebug(.sidebar, "Unloaded stale sidebar tab: \(sidebarTabId.uuidString.prefix(8))")
            }
        }
        
        // DEFENSIVE CHECK: Look for saved tabs marked as active but with no actual browser tab.
        // Verify the mapped browser tab still exists in tabManager.tabs — a stale mapping can
        // outlive the browser tab when a sidebar-mapped tab from a previous session never gets
        // restored, leaving the saved tab stuck "loaded" and invisible to the command palette.
        for (sidebarTabId, sidebarTab) in newStructure.tabs {
            guard !sidebarTab.isUnloaded else { continue }

            // A page in any window
            let mappedBrowserTabId = manager.sidebarToBrowserTabMapping[sidebarTabId]
            let hasActualBrowserTab = manager.store.sidebarManagers.contains { other in
                other.sidebarToBrowserTabMapping[sidebarTabId].map { browserTabIDs.contains($0) } ?? false
            }
            // A browser tab with its address, but not its own (a regular
            // tab, or another saved tab's), doesn't keep it loaded: one it
            // could take was mapped to it above.
            if !hasActualBrowserTab {
                logWarning(.sidebar, "Found active saved tab '\(sidebarTab.displayTitle)' with no corresponding browser tab - marking as unloaded")

                var updatedTab = sidebarTab
                updatedTab.isUnloaded = true
                updatedTab.lastActiveAt = Date()
                newStructure.tabs[sidebarTabId] = updatedTab
                hasChanges = true

                if let bid = mappedBrowserTabId {
                    manager.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
                    manager.browserToSidebarTabMapping.removeValue(forKey: bid)
                }
            }
        }
        
        // Only update and save if there were actual changes
        if hasChanges {
            manager.sidebarStructure = newStructure
            manager.saveSidebarStructure()
            
            // Schedule debounced UI refresh after quiet sync changes
            scheduleRefresh()
        }
    }
    
    // MARK: - Utility Methods
    
} 
