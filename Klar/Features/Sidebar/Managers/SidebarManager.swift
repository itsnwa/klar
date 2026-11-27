import Foundation
import SwiftUI
import Combine

/// One window's sidebar: what it shows selected, scrolled to or being
/// renamed, its expanded folders, the tabs it went through, and the page
/// each saved tab has in this window, kept in step with the window's
/// `TabManager`. The saved tabs, folders, pinned sites and spaces
/// themselves, and which saved tab a page belongs to, are every window's
/// (`SidebarStore`): `sidebarStructure` and `browserToSidebarTabMapping`
/// read and change those.
class SidebarManager: ObservableObject {
    @Published var expandedFolders: Set<UUID> = []
    @Published var isRenaming: UUID?
    @Published var selectedItem: UUID? {
        didSet {
            // Another tab shown: the ones ⌘-clicked along with it are let go
            if selectedItem != oldValue, !extraSelectedItems.isEmpty {
                extraSelectedItems.removeAll()
            }
        }
    }
    /// Tabs ⌘-clicked in the sidebar, selected along with the active one
    /// (`selectedItem`): saved tabs' IDs and regular tabs'. A menu on one of
    /// them is for all of them.
    @Published var extraSelectedItems: Set<UUID> = []
    @Published var scrollToItem: UUID?

    let store = SidebarStore.shared

    /// Every window's saved tabs, folders, pinned sites and spaces
    var sidebarStructure: SidebarStructure {
        get { store.structure }
        set { store.structure = newValue }
    }

    /// Published before `sidebarStructure` changes, with the new value
    var sidebarStructurePublisher: Published<SidebarStructure>.Publisher {
        store.$structure
    }

    /// Each saved tab's page in this window: a saved tab can be open in
    /// several windows, a page of its own in each
    internal var sidebarToBrowserTabMapping: [UUID: UUID] = [:]
    /// The saved tab each browser tab, in any window, is a page of
    internal var browserToSidebarTabMapping: [UUID: UUID] {
        get { store.browserToSidebarTabMapping }
        set { store.browserToSidebarTabMapping = newValue }
    }

    /// A saved tab's page retitled itself (its ID). The title changes in
    /// `sidebarStructure` without `lastUpdated`, so the sidebar doesn't
    /// reload: only that tab's row updates (`SidebarTabRowView`).
    var savedTabTitleDidChange: PassthroughSubject<UUID, Never> {
        store.savedTabTitleDidChange
    }
    
    // Core dependencies
    internal weak var tabManager: TabManager?

    /// The space the window shows
    var spaceSelection: SpaceSelection? {
        tabManager?.spaceSelection
    }
    
    // Specialized managers
    internal lazy var sidebarTabManager: SidebarTabManager = SidebarTabManager(sidebarManager: self)
    internal lazy var folderManager: SidebarFolderManager = SidebarFolderManager(sidebarManager: self)
    internal lazy var selectionManager: SidebarSelectionManager = SidebarSelectionManager(sidebarManager: self)
    internal lazy var dragDropManager: SidebarDragDropManager = SidebarDragDropManager(sidebarManager: self)
    internal lazy var syncManager: SidebarSyncManager = SidebarSyncManager(sidebarManager: self)
    
    // State management flags
    internal var isManuallySelecting: Bool = false
    internal var isSyncing: Bool = false
    internal var isInitializing = true
    internal var lastSyncedActiveTabId: UUID?
    
    // Combine cancellables for reactive subscriptions
    private var cancellables = Set<AnyCancellable>()
    /// Keeps the pinned sites loaded (SidebarManager+PinnedSites).
    internal var pinnedSitesCancellables = Set<AnyCancellable>()
    internal var isPinnedSitesLoadScheduled = false
    /// What follows New Group from the space bar: the palette once it's
    /// named, then closing its tab if nothing was opened in it
    /// (SidebarManager+Groups)
    internal var newGroupFollowUp: AnyCancellable?

    // NotificationCenter block-observer tokens (must be removed individually in deinit)
    private var notificationObservers: [NSObjectProtocol] = []
    
    // MARK: - Helper Methods
    
    internal func findItemLocation(itemID: UUID, in structure: SidebarStructure) -> (parentID: UUID?, index: Int?)? {
        // Check root level
        if let index = structure.rootItems.firstIndex(of: itemID) {
            return (nil, index)
        }
        
        // Check in folders
        for (folderID, folder) in structure.folders {
            if let index = folder.childrenIds.firstIndex(of: itemID) {
                return (folderID, index)
            }
        }
        
        return nil
    }
    
    init() {
        // The views that observe this sidebar see the shared structure change
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        setupNotificationListeners()
        
        // Initialization will be cleared when setTabManager is called and completes
        // Safety mechanism: clear initialization after 5 seconds if setTabManager is never called
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.isInitializing == true {
                logWarning(.sidebar, "SidebarManager initialization timeout - forcing completion")
                self?.isInitializing = false
            }
        }
    }
    
    isolated deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        NotificationCenter.default.removeObserver(self)

        // Clean up initialization state
        if isInitializing {
            isInitializing = false
        }
    }
    
    func setTabManager(_ tabManager: TabManager) {
        // Set initialization flag to prevent observer interference
        isSyncing = true
        self.tabManager = tabManager
        
        // Important: Allow TabManager to restore its mappings first, then perform sync
        // This ensures that tab mappings are available before we try to sync state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // DEFENSIVE FIX: Perform integrity check after tab mappings are restored
            self.performIntegrityCheck(with: tabManager)
            
            // Perform all initial sync operations without triggering observers
            // This now runs after tab mappings have been restored by TabManager
            self.syncManager.syncWithTabManagerQuietly()
            
            // Defer observer setup and initial selection sync to prevent cycles
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Do initial selection sync quietly (without observers active)
                self.selectionManager.performInitialSelectionSync(activeTabId: tabManager.activeTabId)
                
                // Set up observer after initial sync is complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.syncManager.setupTabManagerObserver()
                    
                    // Clear all initialization flags after everything is set up
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.isSyncing = false
                        self?.isInitializing = false
                        logInfo(.sidebar, "SidebarManager initialization complete")
                        // Once the last session's tabs and mappings are sorted out
                        self?.keepPinnedSitesLoaded()
                    }
                }
            }
        }
    }
    
    // MARK: - Integrity Checks
    
    /// Every window's browser tabs: a saved tab's page may be open in
    /// another window than this one.
    var allBrowserTabIDs: Set<UUID> {
        Set(BrowserWindowSession.allTabs.map(\.id))
    }

    /// A saved tab's browser tab from the last session, in any window,
    /// restored with the window's tab mappings (`TabManager.isSidebarMappedTab`)
    func isSidebarMappedTabInAnyWindow(_ browserTabID: UUID) -> Bool {
        tabManager?.isSidebarMappedTab(browserTabID) == true
            || BrowserWindowSession.all.contains { $0.tabManager.isSidebarMappedTab(browserTabID) }
    }

    /// Perform integrity checks to ensure saved tabs and browser tabs are in consistent state
    private func performIntegrityCheck(with tabManager: TabManager) {
        let activeSavedTabs = sidebarStructure.tabs.values.filter { !$0.isUnloaded }
        let activeSavedTabsCount = activeSavedTabs.count
        let allBrowserTabIDs = allBrowserTabIDs
        let browserTabsCount = allBrowserTabIDs.count
        let mappingsCount = browserToSidebarTabMapping.count
        
        // Check for impossible state: active saved tabs but no browser tabs and no mappings
        if activeSavedTabsCount > 0 && browserTabsCount == 0 && mappingsCount == 0 {
            logWarning(.sidebar, "🔧 INTEGRITY ISSUE detected in SidebarManager")
            logWarning(.sidebar, "🔧 Found \(activeSavedTabsCount) saved tabs marked as active but no browser tabs exist")
            logWarning(.sidebar, "🔧 This will be handled by TabManager startup cleanup")
            return
        }
        
        // Check for mapping inconsistencies
        var hasInconsistentMappings = false
        
        // Check that all browser tab mappings point to valid saved tabs
        for (browserTabId, sidebarTabId) in browserToSidebarTabMapping {
            if sidebarStructure.tabs[sidebarTabId] == nil {
                logWarning(.sidebar, "🔧 Invalid mapping: browser tab \(browserTabId.uuidString.prefix(8)) maps to non-existent sidebar tab \(sidebarTabId.uuidString.prefix(8))")
                hasInconsistentMappings = true
            } else if !allBrowserTabIDs.contains(browserTabId) && !isSidebarMappedTabInAnyWindow(browserTabId) {
                logWarning(.sidebar, "🔧 Stale mapping: sidebar tab \(sidebarTabId.uuidString.prefix(8)) maps to non-existent browser tab \(browserTabId.uuidString.prefix(8))")
                hasInconsistentMappings = true
            }
        }
        
        // Clean up inconsistent mappings
        if hasInconsistentMappings {
            logInfo(.sidebar, "🔧 Cleaning up inconsistent mappings")
            cleanupInconsistentMappings(with: tabManager)
        }
    }
    
    /// Clean up mappings that don't correspond to actual tabs
    private func cleanupInconsistentMappings(with tabManager: TabManager) {
        let browserTabIds = allBrowserTabIDs
        let sidebarTabIds = Set(sidebarStructure.tabs.keys)
        
        var cleanedBrowserToSidebar: [UUID: UUID] = [:]
        
        // Every window's pages
        for (browserTabId, sidebarTabId) in browserToSidebarTabMapping {
            // Only keep mapping if both tabs actually exist (including sidebar-mapped tabs)
            let browserTabExists = browserTabIds.contains(browserTabId) || isSidebarMappedTabInAnyWindow(browserTabId)
            if browserTabExists && sidebarTabIds.contains(sidebarTabId) {
                cleanedBrowserToSidebar[browserTabId] = sidebarTabId
            } else {
                logDebug(.sidebar, "🔧 Removed stale mapping: browser \(browserTabId.uuidString.prefix(8)) <-> sidebar \(sidebarTabId.uuidString.prefix(8))")
            }
        }
        // This window's, of those
        let cleanedSidebarToBrowser = sidebarToBrowserTabMapping.filter { cleanedBrowserToSidebar[$0.value] == $0.key }
        
        let removedMappings = browserToSidebarTabMapping.count - cleanedBrowserToSidebar.count
            + sidebarToBrowserTabMapping.count - cleanedSidebarToBrowser.count
        if removedMappings > 0 {
            browserToSidebarTabMapping = cleanedBrowserToSidebar
            sidebarToBrowserTabMapping = cleanedSidebarToBrowser
            logInfo(.sidebar, "🔧 Cleaned up \(removedMappings) inconsistent mappings")
        }
    }
    
    // MARK: - Data Management
    
    internal func saveSidebarStructure() {
        store.save()
    }
    
    /// Writes out a pending debounced change and waits until every queued
    /// save is on disk. Call when the app is about to exit.
    func flushPendingSaves() {
        store.flushPendingSaves()
    }

    // MARK: - Notification Listeners
    
    private func setupNotificationListeners() {
        // From this window's sidebar
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("UpdateSavedTabToCurrentState"),
            object: self
        ) { [weak self] notification in
            self?.handleUpdateSavedTabToCurrentStateNotification(notification)
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("SaveTabToSidebar"),
            object: nil
        ) { [weak self] notification in
            self?.handleSaveTabToSidebarNotification(notification)
        })
    }
    
    // MARK: - Notification Handlers

    private func handleUpdateSavedTabToCurrentStateNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIDString = userInfo["tabID"] as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            logError(.sidebar, "Failed to parse update saved tab notification")
            return
        }
        
        logDebug(.sidebar, "Received request to update saved tab to current state: \(tabID)")
        updateSavedTabToCurrentState(for: tabID)
    }
    
    private func handleSaveTabToSidebarNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIDString = userInfo["tabID"] as? String,
              let tabID = UUID(uuidString: tabIDString),
              let tabManager = tabManager,
              let browserTab = tabManager.tabs.first(where: { $0.id == tabID }) else {
            logError(.sidebar, "Failed to parse SaveTabToSidebar notification")
            return
        }
        
        // Parse parent and collection IDs
        let parentID: UUID?
        if let parentIDString = userInfo["parentID"] as? String {
            parentID = UUID(uuidString: parentIDString)
        } else {
            parentID = nil
        }
        
        let collectionID: UUID?
        if let collectionIDString = userInfo["collectionID"] as? String {
            collectionID = UUID(uuidString: collectionIDString)
        } else {
            collectionID = nil
        }
        
        logDebug(.sidebar, "Saving browser tab to sidebar: \(browserTab.title) to folder: \(parentID?.uuidString ?? "root")")
        
        // Check if this tab was selected before saving
        let wasSelected = selectedItem == tabID
        
        // Add the tab to the sidebar
        let sidebarTabID = sidebarTabManager.addTab(browserTab, to: parentID)
        
        // Set collection if specified
        if let collectionID = collectionID {
            if var sidebarTab = sidebarStructure.tabs[sidebarTabID] {
                sidebarTab.collectionID = collectionID
                sidebarStructure.tabs[sidebarTabID] = sidebarTab
                saveSidebarStructure()
            }
        }
        
        // Preserve selection state: update selectedItem to the new sidebar tab ID
        if wasSelected {
            logDebug(.sidebar, "Updating selection from browser tab \(tabID) to sidebar tab \(sidebarTabID)")
            selectedItem = sidebarTabID
            selectionManager.addToTabHistory(sidebarTabID)
        }
    }
    
    // MARK: - Tab Management (Delegated to SidebarTabManager)
    
    @discardableResult
    func addTab(_ browserTab: BrowserTab, to parentID: UUID? = nil) -> UUID {
        return sidebarTabManager.addTab(browserTab, to: parentID)
    }
    
    @discardableResult
    func addTabAtPosition(_ browserTab: BrowserTab, to parentID: UUID?, at index: Int) -> UUID {
        return sidebarTabManager.addTabAtPosition(browserTab, to: parentID, at: index)
    }
    
    func removeTab(withID id: UUID) {
        sidebarTabManager.removeTab(withID: id)
    }

    func removeTabs(withIDs ids: [UUID], closingTheirTabs: Bool = false,
                    alongWith change: ((inout SidebarStructure) -> Void)? = nil) {
        sidebarTabManager.removeTabs(withIDs: ids, closingTheirTabs: closingTheirTabs, alongWith: change)
    }
    
    func unloadTab(withID id: UUID) {
        sidebarTabManager.unloadTab(withID: id)
    }
    
    func loadTab(withID id: UUID) {
        sidebarTabManager.loadTab(withID: id)
    }
    
    func updateTabState(for tabID: UUID, title: String? = nil, url: String? = nil, 
                       isLoading: Bool? = nil, progress: Double? = nil, isActiveTab: Bool = true) {
        sidebarTabManager.updateTabState(for: tabID, title: title, url: url, isLoading: isLoading,
                                         progress: progress, isActiveTab: isActiveTab)
    }
    
    func markTabAsActive(_ tabID: UUID) {
        sidebarTabManager.markTabAsActive(tabID)
    }
    
    func updateSavedTabToCurrentState(for sidebarTabID: UUID) {
        sidebarTabManager.updateSavedTabToCurrentState(for: sidebarTabID)
    }

    func updateTabURL(for sidebarTabID: UUID, newURL: String) {
        sidebarTabManager.updateTabURL(for: sidebarTabID, newURL: newURL)
    }

    func returnToSavedPage(for itemID: UUID) -> Bool {
        return sidebarTabManager.returnToSavedPage(for: itemID)
    }
    
    func shouldShowReturnToSavedPage(for itemID: UUID) -> Bool {
        return sidebarTabManager.shouldShowReturnToSavedPage(for: itemID)
    }

    /// The address a saved tab's page is at now: where its browser tab has
    /// gone since it was saved, else the saved one.
    func currentURL(ofSavedTab itemID: UUID) -> String? {
        guard let tab = sidebarStructure.tabs[itemID] else { return nil }
        if let browserTabID = sidebarToBrowserTabMapping[itemID],
           let browserTab = browserTab(withID: browserTabID),
           !browserTab.isEmpty {
            return browserTab.url
        }
        return tab.url
    }
    
    // MARK: - Folder Management
    
    func createFolder(title: String = OpenTabGroup.defaultTitle, in parentID: UUID? = nil) -> UUID {
        return folderManager.createFolder(title: title, in: parentID)
    }
    
    func deleteFolder(_ folderID: UUID, includingContents: Bool) {
        folderManager.deleteFolder(folderID, includingContents: includingContents)
    }

    func toggleFolderExpansion(_ folderID: UUID) {
        folderManager.toggleFolderExpansion(folderID)
    }
    
    /// Asks the sidebar to scroll the row of `itemID` — a folder, saved tab
    /// or regular tab — into view.
    func scrollToItem(_ itemID: UUID) {
        scrollToItem = itemID
        // Clear the scroll trigger after a brief delay to allow for potential subsequent scrolls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.scrollToItem = nil
        }
    }

    /// Brings a browser tab's row into view: a saved tab's enclosing folders
    /// are expanded first, so its own row shows rather than a folder's peek.
    func revealTab(withBrowserTabID browserTabID: UUID) {
        guard let sidebarTabID = browserToSidebarTabMapping[browserTabID],
              let savedTab = sidebarStructure.tabs[sidebarTabID] else {
            // A regular tab: always listed below the saved ones, in its
            // group, opened
            if let page = tabManager?.tabs.first(where: { $0.id == browserTabID }),
               let group = OpenTabStore.shared.group(ofPage: page), !expandedFolders.contains(group.id) {
                expandedFolders.insert(group.id)
            }
            scrollToItem(browserTabID)
            return
        }

        var ancestors: [UUID] = []
        var parentID = savedTab.parentID
        while let folderID = parentID, let folder = sidebarStructure.folders[folderID],
              !ancestors.contains(folderID) {
            ancestors.append(folderID)
            parentID = folder.parentID
        }
        if !expandedFolders.isSuperset(of: ancestors) {
            expandedFolders.formUnion(ancestors)
        }
        scrollToItem(sidebarTabID)
    }
    
    // MARK: - Drag and Drop
    
    func moveItem(withID itemID: UUID, to folderID: UUID?) {
        dragDropManager.moveItem(withID: itemID, to: folderID)
    }
    
    func getCurrentItemsInOrder(parentID: UUID?) -> [UUID] {
        if let parentID = parentID {
            return sidebarStructure.folders[parentID]?.childrenIds ?? []
        } else {
            return sidebarStructure.rootItems
        }
    }

    // MARK: - Naming and Customization
    
    func startRenaming(_ itemID: UUID) {
        isRenaming = itemID
    }
    
    func updateCustomTitle(for itemID: UUID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Whether anything actually changed — used to gate the
        // `lastUpdated` bump so we only wake the structure-publisher
        // dedupe filter (and trigger a sidebar reload) when the value
        // really moved.
        var didChange = false

        if var tab = sidebarStructure.tabs[itemID] {
            let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            if tab.customTitle != newTitle {
                tab.customTitle = newTitle
                sidebarStructure.tabs[itemID] = tab
                didChange = true
            }
        } else if var folder = sidebarStructure.folders[itemID] {
            let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            if folder.customTitle != newTitle {
                folder.customTitle = newTitle
                sidebarStructure.folders[itemID] = folder
                didChange = true
            }
        } else if var collection = sidebarStructure.collections[itemID] {
            let newTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            if collection.customTitle != newTitle {
                collection.customTitle = newTitle
                sidebarStructure.collections[itemID] = collection
                didChange = true
            }
        } else if OpenTabStore.shared.group(withID: itemID) != nil {
            // A group of regular tabs: its tabs have its name
            renameRegularGroup(itemID, to: trimmedTitle)
        }

        if didChange {
            // Bump `lastUpdated` so the controller's `removeDuplicates(by:)`
            // dedupe filter on `sidebarStructurePublisher` lets the publish through
            // and the cell re-configures with the new displayTitle.
            sidebarStructure.lastUpdated = Date()
            saveSidebarStructure()
        }
    }
    
    // MARK: - Collection Management
    
    func getDefaultCollectionID() -> UUID {
        var structure = sidebarStructure
        let defaultID = structure.ensureDefaultCollection()
        
        // Save if a new collection was created
        if sidebarStructure.collections.count != structure.collections.count {
            sidebarStructure = structure
            saveSidebarStructure()
        }
        
        return defaultID
    }
    
    func getAllCollections() -> [SidebarCollection] {
        return sidebarStructure.orderedCollections
    }

    /// The space a new saved tab or folder goes in: its folder's, else the active one.
    func collectionIDForNewItem(in parentID: UUID?) -> UUID {
        if let collectionID = spaceSelection?.collectionIDForNewItem(in: parentID),
           sidebarStructure.collections[collectionID] != nil {
            return collectionID
        }
        return getDefaultCollectionID()
    }
    
    // MARK: - Selection and Navigation
    
    func selectItem(_ itemID: UUID) {
        selectionManager.selectItem(itemID)
    }

    /// This window's tabs as its sidebar shows them, top to bottom, for
    /// ⌘⌥↓ and ⌘⌥↑: the pinned sites, the active space's saved tabs as their
    /// rows are laid out, then its regular tabs. A collapsed folder's tabs
    /// open in this window are at its place, in its order, the active one
    /// (its peek row) among them, so one left can be gone back to; the rest
    /// of what's in it is left out. Saved tabs by their own ID, loaded or
    /// not, as `selectItem` takes them.
    func tabsInSidebarOrder() -> [UUID] {
        let structure = sidebarStructure
        var order = structure.pinnedItems.filter { structure.tabs[$0] != nil }
        let mappedBrowserIDs = Set(browserToSidebarTabMapping.keys)
        let regularTabs = tabManager?.tabs.filter { tab in
            !mappedBrowserIDs.contains(tab.id)
                && tabManager?.isEmptyPane(tab) == false
                && spaceSelection?.isInActiveSpace(tab) != false
        } ?? []
        let groups = OpenTabStore.shared.groups(ofPages: regularTabs).mapValues(\.id)
        let rows = SidebarLayoutEngine.layout(SidebarLayoutEngine.Input(
            structure: structure,
            expandedFolders: expandedFolders,
            activeTabID: selectedItem,
            regularTabs: regularTabs,
            regularTabGroups: groups,
            collectionExpanded: true,
            spaceID: spaceSelection?.currentSpaceID,
            width: 0
        )).rows
        for row in rows {
            switch row.key {
            case .tab(let id), .regularTab(let id):
                order.append(id)
            case .folder(let id) where !expandedFolders.contains(id) && structure.folders[id] == nil:
                // A closed group of regular tabs: they're all open here
                order.append(contentsOf: regularTabs.lazy.filter { groups[$0.id] == id }.map(\.id))
            case .folder(let id) where !expandedFolders.contains(id):
                appendTabsOpenHere(inFolder: id, structure: structure, to: &order)
            default:
                // A peek row's tab is among its collapsed folder's
                break
            }
        }
        return order
    }

    /// The tabs open in this window in a folder and the folders in it, in
    /// their order.
    private func appendTabsOpenHere(inFolder folderID: UUID, structure: SidebarStructure, to order: inout [UUID]) {
        guard let folder = structure.folders[folderID] else { return }
        for childID in folder.childrenIds {
            if structure.tabs[childID] != nil {
                if isOpenHere(childID) {
                    order.append(childID)
                }
            } else if structure.folders[childID] != nil {
                appendTabsOpenHere(inFolder: childID, structure: structure, to: &order)
            }
        }
    }

    public func setManuallySelecting(_ value: Bool) {
        isManuallySelecting = value
    }
    
    public func setIsSyncing(_ value: Bool) {
        isSyncing = value
    }
    
    // Expose internal save methods for specialized managers
    internal func exposeSaveSidebarStructureDebounced() {
        store.saveDebounced()
    }
    
    // MARK: - Utility Methods
    
    internal func getNextOrderValue(in parentID: UUID?) -> Int {
        let siblings = getCurrentItemsInOrder(parentID: parentID)
        return siblings.count
    }
    
    // Fix order properties to match current array positions
    // Returns true if changes were made, false if no changes needed
    @discardableResult
    internal func resyncOrderProperties() -> Bool {
        store.resyncOrderProperties()
    }
    
    // Helper method to update parent relationships for both tabs and folders (used by specialized managers)
    internal func updateItemParentRelationship(itemID: UUID, newParentID: UUID?) {
        if var tab = sidebarStructure.tabs[itemID] {
            tab.parentID = newParentID
            sidebarStructure.tabs[itemID] = tab
        } else if var folder = sidebarStructure.folders[itemID] {
            folder.parentID = newParentID
            sidebarStructure.folders[itemID] = folder
        }
    }
    
    // MARK: - New Universal Move Method (Delegated to DragDropManager)
    
    /// `collectionID` is the space it goes to; by default its new folder's,
    /// else the active space.
    func moveItemToPosition(_ itemID: UUID, containerID: UUID?, index: Int, collectionID: UUID? = nil) {
        dragDropManager.moveItemToPosition(itemID, containerID: containerID, index: index, collectionID: collectionID)
    }
    
    // MARK: - Other windows

    /// Whether a saved tab has a page in this window (it may have one in
    /// others too)
    func isOpenHere(_ savedTabID: UUID) -> Bool {
        sidebarToBrowserTabMapping[savedTabID] != nil
    }

    /// A saved tab's page in this window is gone: it's unloaded unless
    /// another window has one
    func isUnloadedAfterClosingHere(_ savedTabID: UUID) -> Bool {
        !store.isOpenInAnyWindow(savedTabID)
    }

    /// A browser tab in this window or another
    func browserTab(withID id: UUID) -> BrowserTab? {
        tabManager?.tabs.first { $0.id == id } ?? BrowserWindowSession.allTabs.first { $0.id == id }
    }

    /// One of this window's browser tabs, or another window's regular tab
    /// dropped here: an open tab's page in this window, which every window
    /// has (`OpenTabStore`), or a tab of that window's own (a private tab,
    /// a page a script opened), which comes over, its page as it is. Not
    /// another window's page of a saved tab: that window keeps it.
    func browserTabBroughtHere(_ id: UUID) -> BrowserTab? {
        guard let tabManager else { return nil }
        if let tab = tabManager.tabs.first(where: { $0.id == id }) {
            return tab
        }
        guard browserToSidebarTabMapping[id] == nil,
              let owner = BrowserWindowSession.owner(ofTab: id),
              let tab = owner.tabManager.tabs.first(where: { $0.id == id }) else { return nil }
        if let openTabID = tab.openTabID {
            return tabManager.tabs.first { $0.openTabID == openTabID }
        }
        BrowserWindowSession.moveTab(tab, to: tabManager, activate: false)
        return tab
    }

    // MARK: - Changes from elsewhere

    /// A folder removed on another Mac
    func folderWasRemoved(_ id: UUID) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        }
        if selectedItem == id {
            selectedItem = nil
        }
    }

    /// A saved tab removed on another Mac. Its page, if it was open, stays
    /// as a regular tab: selected in its place.
    func savedTabWasRemoved(_ id: UUID, leaving browserTabID: UUID?) {
        selectionManager.removeFromTabHistory(id)
        if selectedItem == id {
            let isOpenHere = browserTabID.map { id in tabManager?.tabs.contains { $0.id == id } == true } ?? false
            selectedItem = isOpenHere ? browserTabID : nil
        }
    }

    /// iCloud's first sync matched a saved tab or folder here to one with another ID.
    func itemWasRekeyed(from oldID: UUID, to newID: UUID) {
        if let page = sidebarToBrowserTabMapping.removeValue(forKey: oldID) {
            sidebarToBrowserTabMapping[newID] = page
            browserToSidebarTabMapping[page] = newID
        }
        if expandedFolders.contains(oldID) {
            expandedFolders.remove(oldID)
            expandedFolders.insert(newID)
        }
        if selectedItem == oldID {
            selectedItem = newID
        }
        selectionManager.replaceInTabHistory(oldID, with: newID)
    }

    // MARK: - Public Methods for UI
    
    func getOrganizedBrowserTabIDs() -> Set<UUID> {
        return Set(browserToSidebarTabMapping.keys)
    }
    
} 
