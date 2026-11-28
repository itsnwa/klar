import SwiftUI
import Foundation
import AppKit
import WebKit

// Simplified TabManager for clean browser functionality

// MARK: - Supporting Types

enum SidebarNotificationEvent {
    case tabUpdated
    case tabActivated
    case tabRemoved
}

/// One window's tabs: its regular tabs, and the saved tabs and pinned sites
/// open in it, with the one on screen, the command palette, split views and
/// toasts. Each browser window has its own (`BrowserWindowSession`).
class TabManager: ObservableObject {
    // MARK: - Properties
    @Published var tabs: [BrowserTab] = [] {
        didSet {
            // However the last private tab went, the private session ends
            // with it. A plain call, not another @Published write.
            if oldValue.contains(where: \.isPrivate), !tabs.contains(where: \.isPrivate) {
                SpaceManager.shared.endPrivateSession()
            }
            // A closed or unloaded tab's pane goes from its split view
            if !splitViews.splits.isEmpty {
                splitViews.removeTabs(notIn: Set(tabs.map(\.id)))
            }
            // A new regular tab is every window's
            OpenTabStore.shared.windowTabsDidChange()
        }
    }
    @Published var activeTabId: UUID? {
        didSet {
            // A plain call, not another @Published write (see
            // shouldDisableWebViewInteraction below).
            if activeTabId != oldValue {
                suspensionManager.activeTabDidChange(from: oldValue, to: activeTabId)
                fillPaneFromPalette()
                splitViews.activeTabID = activeTabId
                // They'd stay over whatever shows now.
                AutofillCoordinator.shared.dismissSuggestions()
                // However it came to be the active tab: a click in the
                // sidebar sets this directly, and "close tabs after 24
                // hours" goes by when a tab was last used.
                activeTab?.markAsActive()
                OpenTabStore.shared.activeTabDidChange(in: self, from: oldValue)
            }
        }
    }
    @Published var showCommandPalette: Bool = false {
        didSet {
            if !showCommandPalette {
                // Closed without picking anything: the pane stays empty
                paneToFill = nil
            } else if paneToFill == nil, let activeTab, activeTab.isEmpty, splitViews.contains(activeTab.id) {
                paneToFill = activeTab.id
            }
        }
    }
    @Published var isNewTabMode: Bool = false
    /// The palette's new tab is a private one. Only read in new-tab mode.
    @Published private(set) var isNewTabPrivate: Bool = false
    /// The mode the latest request opens the palette in (⌘K's tab actions);
    /// nil for the normal one. Set by every request.
    @Published private(set) var requestedPaletteMode: CommandPaletteMode? = nil
    /// Counts the requests to open the palette. ContentView recreates the
    /// palette on each, so ⌘K, ⌘T or ⌘L pressed while it's open opens it
    /// again in that mode.
    @Published private(set) var commandPaletteRequest = 0

    // Derived state. Reads underlying @Published values directly so we don't
    // need a stored mirror that has to be kept in sync via didSet — that
    // pattern (write @Published A → didSet writes @Published B) is the
    // classic AttributeGraph cycle source when both publishers feed the
    // same view tree.
    var shouldDisableWebViewInteraction: Bool {
        (sidebarStateManager?.isFloating == true) || showCommandPalette
    }
    
    // Track if command palette has been auto-shown on empty state
    private var hasAutoShownCommandPalette: Bool = false
    
    // Track if we're in startup loading phase to prevent unnecessary sidebar saves
    private var isStartupLoading: Bool = false
    
    // Temporarily store filtered sidebar tabs during startup for mapping restoration
    // This fixes the issue where saved tabs with sidebar mappings were being marked as unloaded
    // because their mappings couldn't be restored (the browser tabs were filtered out during initial load)
    private var filteredSidebarTabs: [BrowserTab] = []
    
    // Persistent tracking of sidebar-mapped tab IDs (persists after filteredSidebarTabs is cleared)
    // This allows SidebarManager to know which tabs are legitimately sidebar-only
    private var sidebarMappedTabIds: Set<UUID> = []
    
    // Delegate to specialized managers
    private let typedHistoryManager = TypedHistoryManager.shared
    private lazy var suspensionManager = TabSuspensionManager(tabManager: self)

    // Toast manager for notifications
    let toastManager = ToastManager()

    /// The window's split views: tabs side by side or one above the other
    let splitViews = SplitViewManager()

    /// The empty pane the command palette is open for (after ⌘D, ⇧⌘D, or
    /// opened from the pane): the tab picked in it takes the pane's place.
    private var paneToFill: UUID?
    /// The tabs of empty panes (⌘D, ⇧⌘D). They're only there for their
    /// pane: not in the sidebar or the saved session, and closed once
    /// they're out of their split view.
    private var emptyPaneTabIDs: Set<UUID> = []
    
    // Sidebar integration
    weak var sidebarManager: SidebarManager?
    
    // Sidebar state manager integration
    weak var sidebarStateManager: SidebarStateManager?
    
    // Find manager integration
    weak var findManager: FindManager?

    /// The space the window shows
    weak var spaceSelection: SpaceSelection?
    
    /// Its window closed, and it wasn't the last: none of its tabs are kept
    private(set) var isWindowClosed = false

    /// A new window's: it opens the command palette for a new tab, as one
    /// without tabs would, though it has a page of every open tab
    var opensWithNewTab = false

    // Timer management for tab closing
    private var endOfDayTimer: Timer?
    private var inactivityTimer: Timer?

    // NotificationCenter block-observer tokens (must be removed individually in deinit)
    private var notificationObservers: [NSObjectProtocol] = []

    // Debounced tab persistence. saveTabs() is called from many high-frequency
    // call sites (tab switch, page-load completion, every navigation). The
    // JSON encode + UserDefaults write is non-trivial CPU work; running it on
    // every call stalls the main thread. We collapse rapid bursts into a
    // single save with this work item.
    private var saveTabsWorkItem: DispatchWorkItem?
    private static let saveTabsDebounceInterval: TimeInterval = 0.5

    // MARK: - Pointer Events Control

    /// Controls pointer events for the active tab's web content
    func setActiveTabPointerEventsEnabled(_ enabled: Bool) {
        guard let activeTab = activeTab else {
            return
        }

        if let coordinator = TabWebViewCoordinator.coordinator(for: activeTab.id) {
            coordinator.setPointerEventsEnabled(enabled)
        } else {
            logWarning(.tabManagement, "Cannot set pointer events - no coordinator for tab \(activeTab.id.uuidString.prefix(8))")
        }
    }
    
    private let userDefaults = UserDefaults.standard
    private let tabsKey: String
    private let activeTabKey: String
    private let tabMappingsKey: String
    
    var activeTab: BrowserTab? {
        guard let activeTabId = activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }
    

    
    init(defaults: WindowDefaults) {
        tabsKey = defaults.key("SavedTabs")
        activeTabKey = defaults.key("ActiveTabId")
        tabMappingsKey = defaults.key("TabMappings")
        givePagesTheirOwnIDs(defaults: defaults)
        loadSavedTabs()
        setupNotificationObservers()
        setupTabClosingTimers()

        // An empty pane out of its split view closes, once the change is done
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: .splitViewsDidChange, object: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.closeEmptyPanesOutOfSplitViews() }
        })
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: .faviconAppearanceChanged
        ) { [weak self] note in
            self?.updateFaviconAppearance(for: note.object as? String, privateOnly: note.userInfo?["private"] as? Bool == true)
        })

        // Let the WebView pool decide whether pre-warming is worthwhile
        // based on whether the user actually has any tabs, in any window.
        WebViewPool.shared.tabCountProvider = {
            BrowserWindowSession.allTabs.count
        }
    }

    isolated deinit {
        endOfDayTimer?.invalidate()
        inactivityTimer?.invalidate()
        saveTabsWorkItem?.cancel()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Core Tab Management
    
    func ensureActiveTabHasContent() {
        // With no active tab, or an empty one, show the most recently used
        // tab that has content (per the sidebar's tab history), else the
        // first one that does.
        // Only the active space's tabs: another space's would switch spaces.
        let spaceTabs = tabs.filter { spaceSelection?.isInActiveSpace($0) != false }
        if (activeTabId == nil && !spaceTabs.isEmpty) || activeTab?.isEmpty == true {
            let mostRecentTabId = sidebarManager?.selectionManager.getMostRecentActiveTab()
            if let tab = spaceTabs.first(where: { $0.id == mostRecentTabId && !$0.isEmpty })
                ?? spaceTabs.first(where: { !$0.isEmpty }) {
                activeTabId = tab.id
                focusWebView(for: tab.id)
                return
            }
        }

        // IMPROVED: Handle the case where we have no browser tabs but saved tabs exist
        // This can happen after integrity fixes where saved tabs were marked as unloaded
        if tabs.isEmpty, let sidebarManager = sidebarManager {
            let unloadedSavedTabs = sidebarManager.sidebarStructure.tabs.values.filter {
                $0.isUnloaded && !$0.isEmpty && spaceSelection?.isItemInActiveSpace($0.id) != false
            }
            
            if !unloadedSavedTabs.isEmpty {
                logDebug(.tabManagement, "🔄 No browser tabs but \(unloadedSavedTabs.count) saved tabs available")
                
                // Find the most recently active saved tab
                let mostRecentSavedTab = unloadedSavedTabs.max { $0.lastActiveAt < $1.lastActiveAt }
                
                if let tabToLoad = mostRecentSavedTab {
                    logInfo(.tabManagement, "🔄 Auto-loading most recent saved tab: '\(tabToLoad.displayTitle)'")
                    
                    // Reset auto-show flag since we're loading content
                    hasAutoShownCommandPalette = false
                    
                    // Find the saved tab ID
                    if let sidebarTabId = sidebarManager.sidebarStructure.tabs.first(where: { $0.value.id == tabToLoad.id })?.key {
                        sidebarManager.sidebarTabManager.loadTab(withID: sidebarTabId)
                    }
                }
            } else {
                logDebug(.tabManagement, "🔄 No browser tabs and no saved tabs available")
            }
        }
    }
    
    /// `activate: false` opens it in the background (an extension's
    /// tabs.create with `active: false`). It opens in `inSpace`, else its
    /// opener's space, else the active one. It's private if `isPrivate`
    /// says so, else if its opener is: a link or popup from a private tab
    /// stays private.
    @discardableResult
    func createNewTab(url: String = "", isExternalURL: Bool = false, parentTabId: UUID? = nil, predeterminedId: UUID? = nil, activate: Bool = true, inSpace spaceID: UUID? = nil, isPrivate: Bool? = nil) -> UUID {
        // Prevent automatic creation of tracking/advertising tabs. Not a
        // link clicked in another app or dropped on the sidebar, which is
        // often an ad's click-through (googleadservices, doubleclick) the
        // person chose to open: it opened nothing.
        if !isExternalURL && !url.isEmpty && isTrackingOrAdvertisingURL(url) {
            logWarning(.tabManagement, "🚫 BLOCKED automatic creation of tracking/advertising tab: \(url)")
            return UUID() // Return placeholder ID for blocked tabs
        }

        // predeterminedId is used for window.open() handoff: CustomWKUIDelegate
        // pre-builds a WKWebView with the parent's configuration (preserving
        // window.opener) and stashes it under this ID so the new tab's coordinator
        // can adopt it instead of building a fresh WebView from the pool.
        let isPrivate = isPrivate ?? parentTabId.map { id in tabs.contains { $0.id == id && $0.isPrivate } } ?? false
        let newTab = BrowserTab(id: predeterminedId ?? UUID(), url: url, parentTabId: parentTabId, isPrivate: isPrivate)
        newTab.spaceID = spaceID ?? spaceSelection?.spaceIDForNewTab(parentTabId: parentTabId) ?? SpaceManager.shared.defaultSpaceID
        newTab.hasOpener = predeterminedId != nil
        // Skip the navigateToURL trigger when this tab adopts a pre-existing
        // WebView: WebKit is already driving the load on that WebView from the
        // createWebViewWith call, so flipping pendingUserNavigation here would
        // cause loadPendingNavigation to cancel-and-restart the same request.
        if !url.isEmpty && predeterminedId == nil {
            newTab.navigateToURL(url)
        }
        tabs.append(newTab)
        // A link from a tab in a group opens in that group (Settings ›
        // General), before it's shown: not a page a script opened
        if predeterminedId == nil, let parentTabId, !newTab.isPrivate,
           let group = sidebarManager?.groupForLink(openedFrom: parentTabId) {
            sidebarManager?.addLinkTab(newTab, to: group)
        }
        if activate {
            activeTabId = newTab.id
        }
        
        // Reset auto-show flag since we now have content
        if !url.isEmpty {
            hasAutoShownCommandPalette = false
        }
        
        if activate {
            notifySidebar(event: .tabActivated, tabId: newTab.id)
            // Give space selection and any sidebar drop a turn to put the
            // new tab in its space and its final position before revealing it.
            DispatchQueue.main.async { [weak self, tabID = newTab.id] in
                guard let self, let tab = self.activeTab, tab.id == tabID,
                      !self.isEmptyPane(tab), let sidebarManager = self.sidebarManager,
                      sidebarManager.browserToSidebarTabMapping[tabID] == nil else { return }
                sidebarManager.scrollToItem(tabID)
            }
        }
        
        // Focus the new tab's webview once it exists (an empty tab gets none)
        if activate && !url.isEmpty {
            focusWebView(for: newTab.id)
        }

        if !url.isEmpty {
            updateFavicon(for: newTab, url: url)
        }
        
        saveTabs()
        
        return newTab.id
    }
    
    /// Opens a tab's page again in a private tab, or out of one: in a new
    /// tab, since a web view's data store can't change. An open tab is
    /// replaced, in its place; a saved tab or pinned site stays, and its
    /// page opens in a new tab.
    func reopenTab(_ tab: BrowserTab, isPrivate: Bool) {
        guard tab.isPrivate != isPrivate, !tab.isEmpty else { return }
        let isSaved = sidebarManager?.browserToSidebarTabMapping[tab.id] != nil
        let newTabID = createNewTab(
            url: tab.url,
            activate: isSaved || tab.id == activeTabId,
            inSpace: SpaceManager.shared.spaceID(of: tab),
            isPrivate: isPrivate
        )
        guard !isSaved else { return }
        if let index = tabs.firstIndex(where: { $0 === tab }),
           let newIndex = tabs.firstIndex(where: { $0.id == newTabID }) {
            tabs.insert(tabs.remove(at: newIndex), at: index)
        }
        splitViews.replace(tab.id, with: newTabID)
        closeTab(tab)
    }

    /// Check if a URL is a tracking or advertising URL that should be blocked from creating tabs
    private func isTrackingOrAdvertisingURL(_ url: String) -> Bool {
        let lowercaseURL = url.lowercased()
        
        // Extract domain from URL for more precise matching
        let domain = extractDomain(from: lowercaseURL)
        
        // List of known tracking/advertising domains
        let trackingDomains = [
            "sync.criteo.com",
            "ssp-sync.criteo.com", 
            "sync.smartadserver.com",
            "csync.smilewanted.com",
            "csync-global.smartadserver.com",
            "sync.teads.tv",
            "sync.1dmp.io",
            "sync.richaudience.com",
            "match.adsystem.com",
            "cm.everesttech.net",
            "pixel.facebook.com",
            "googletagmanager.com",
            "google-analytics.com",
            "googleadservices.com",
            "doubleclick.net",
            "googlesyndication.com",
            "amazon-adsystem.com",
            "i.liadm.com",
            "liadm.com"
        ]
        
        // Check if domain exactly matches known tracking domains
        for trackingDomain in trackingDomains {
            if domain == trackingDomain || domain.hasSuffix("." + trackingDomain) {
                return true
            }
        }
        
        // More specific pattern checks that are less likely to catch legitimate sites
        // Only block if it's specifically a sync endpoint with tracking indicators
        if domain.contains("sync") && domain.contains("ads") {
            return true
        }
        
        // Block specific tracking pixel endpoints (but not domains that just contain "pixel")
        if domain == "pixel.facebook.com" || lowercaseURL.contains("/pixel.") || lowercaseURL.contains("/beacon.") {
            return true
        }
        
        // Block sync-container specific patterns
        if lowercaseURL.contains("sync-container") {
            return true
        }
        
        return false
    }
    
    /// Extract domain from URL for more precise matching
    private func extractDomain(from url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return ""
        }
        return host.lowercased()
    }
    
    /// The window closed, and it wasn't the last one: its tabs go with it.
    /// Its pages of saved tabs and pinned sites close too:
    /// another window that has one open keeps its own, and a saved tab open
    /// in no window any more is unloaded.
    func closeAllTabsForWindowClose() {
        isWindowClosed = true
        saveTabsWorkItem?.cancel()
        endOfDayTimer?.invalidate()
        inactivityTimer?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        let store = SidebarStore.shared
        var closedSavedTabIDs: [UUID] = []
        for tab in tabs {
            guard let savedTabID = store.browserToSidebarTabMapping.removeValue(forKey: tab.id) else { continue }
            closedSavedTabIDs.append(savedTabID)
        }
        sidebarManager?.sidebarToBrowserTabMapping.removeAll()

        var structure = store.structure
        var hasUnloaded = false
        for savedTabID in closedSavedTabIDs where !store.isOpenInAnyWindow(savedTabID) {
            if var savedTab = structure.tabs[savedTabID], !savedTab.isUnloaded {
                savedTab.isUnloaded = true
                savedTab.isLoading = false
                savedTab.estimatedProgress = 0
                savedTab.lastActiveAt = Date()
                structure.tabs[savedTabID] = savedTab
                hasUnloaded = true
            }
        }
        if hasUnloaded {
            structure.lastUpdated = Date()
            store.structure = structure
            store.saveDebounced()
        }

        emptyPaneTabIDs.removeAll()
        paneToFill = nil
        activeTabId = nil
        tabs.removeAll()
    }

    /// A tab going to another window (`BrowserWindowSession.moveTab`), its
    /// page and all: out of this one's list, without closing. The window
    /// shows the tab it showed before, or nothing.
    func detach(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        findManager?.clearFindStateForTab(tab.id)
        emptyPaneTabIDs.remove(tab.id)
        leaveSplitView(tab.id)

        let savedTabID = sidebarManager?.browserToSidebarTabMapping[tab.id]
        let excludedIDs = Set([tab.id] + (savedTabID.map { [$0] } ?? []))
        if let selectionManager = sidebarManager?.selectionManager {
            excludedIDs.forEach(selectionManager.removeFromTabHistory)
        }
        if activeTabId == tab.id {
            sidebarManager?.selectionManager.moveSelectionToNextActiveTab(excluding: excludedIDs)
            if activeTabId == tab.id {
                activeTabId = nil
            }
        }
        if let sidebarManager, let selected = sidebarManager.selectedItem, excludedIDs.contains(selected) {
            sidebarManager.selectedItem = nil
        }
        tabs.removeAll { $0 === tab }
        saveTabs()
    }

    /// A tab from another window (`BrowserWindowSession.moveTab`), its page
    /// and all
    func adopt(_ tab: BrowserTab, activate: Bool) {
        guard !tabs.contains(where: { $0 === tab }) else { return }
        tabs.append(tab)
        if activate {
            activeTabId = tab.id
            focusWebView(for: tab.id)
        }
        saveTabs()
    }

    /// A tab whose page isn't loaded until it's shown, at the end, as a
    /// restored one: a saved tab open in no window that's a regular tab now
    @discardableResult
    func addUnloadedTab(url: String, title: String, inSpace spaceID: UUID?) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), createdAt: Date(), url: url, title: title)
        tab.spaceID = spaceID ?? spaceSelection?.currentSpaceID ?? SpaceManager.shared.defaultSpaceID
        tab.markSuspended()
        tabs.append(tab)
        updateFavicon(for: tab, url: url)
        saveTabs()
        return tab
    }

    /// Moves a tab to just before `beforeTabID` among the window's tabs, or
    /// to the end with none: the regular tabs' order in the sidebar.
    func moveTab(_ tabID: UUID, before beforeTabID: UUID?) {
        guard reorderTabs(moving: [tabID], before: beforeTabID) else { return }
        OpenTabStore.shared.pagesWereReordered(in: self)
    }

    /// Moves tabs, in this order, to just before `beforeTabID` (or the end),
    /// without telling the open tabs (`OpenTabStore.movePages` does).
    /// Whether the order changed.
    @discardableResult
    func reorderTabs(moving tabIDs: [UUID], before beforeTabID: UUID?) -> Bool {
        let moving = Set(tabIDs)
        let moved = tabIDs.compactMap { id in tabs.first { $0.id == id } }
        guard !moved.isEmpty else { return false }
        var reordered = tabs.filter { !moving.contains($0.id) }
        // Before the one after it, when it's among them itself
        var anchor = beforeTabID
        if let id = anchor, moving.contains(id), let index = tabs.firstIndex(where: { $0.id == id }) {
            anchor = tabs[(index + 1)...].first { !moving.contains($0.id) }?.id
        }
        let destination = anchor.flatMap { id in reordered.firstIndex { $0.id == id } } ?? reordered.endIndex
        reordered.insert(contentsOf: moved, at: destination)
        guard !reordered.elementsEqual(tabs, by: ===) else { return false }
        tabs = reordered
        saveTabs()
        return true
    }

    /// Its pages of the open tabs, which every window has
    /// (`OpenTabStore`): new ones, and the tabs in their order
    func setOpenTabPages(_ newTabs: [BrowserTab], adding added: [BrowserTab]) {
        tabs = newTabs
        for tab in added {
            updateFavicon(for: tab, url: tab.url)
        }
        saveTabs()
    }

    /// Which open tab a page of the window's is changed (`OpenTabStore`):
    /// saved with the tabs, or it'd be a new one at the next launch
    func openTabIDsDidChange() {
        saveTabs()
    }

    func closeTab(withId tabId: UUID) {
        // Find the tab by ID with defensive check
        guard let tab = tabs.first(where: { $0.id == tabId }) else {
            logWarning(.tabManagement, "Attempted to close non-existent tab: \(tabId.uuidString.prefix(8))")
            return
        }
        closeTab(tab)
    }
    
    func closeTab(_ tab: BrowserTab) {
        // Clean up Find state for this tab
        findManager?.clearFindStateForTab(tab.id)

        // Out of its split view, the pane beside it taking over
        emptyPaneTabIDs.remove(tab.id)
        leaveSplitView(tab.id)
        
        // Check if this is a saved tab that should be unloaded instead of closed
        if let sidebarManager = sidebarManager {
            if let sidebarTabId = sidebarManager.browserToSidebarTabMapping[tab.id] {
                // A pinned site stays loaded
                if sidebarManager.isPinnedSite(browserTabID: tab.id) {
                    sidebarManager.leavePinnedSite(sidebarTabId)
                    return
                }
                // This is a saved tab - unload it instead of closing it completely
                sidebarManager.unloadTab(withID: sidebarTabId)
                return
            }
        } else {
            logDebug(.tabManagement, "No sidebarManager available")
        }

        // A regular tab closes in every window
        OpenTabStore.shared.pageWillClose(tab)

        // Use main queue to ensure thread safety for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Re-verify tab exists and get current index (defensive against rapid operations)
            guard let index = self.tabs.firstIndex(where: { $0.id == tab.id }) else {
                logWarning(.tabManagement, "Tab \(tab.id.uuidString.prefix(8)) already removed or not found")
                return
            }
            
            // Additional bounds check
            guard index < self.tabs.count else {
                logWarning(.tabManagement, "Index \(index) out of bounds for tabs array (count: \(self.tabs.count))")
                return
            }
            
            // Clean up sidebar history FIRST to prevent accessing removed tab
            if let sidebarManager = self.sidebarManager {
                sidebarManager.selectionManager.removeFromTabHistory(tab.id)
            }
            
            // Force immediate coordinator cleanup to bypass SwiftUI's caching
            NotificationCenter.default.post(
                name: NSNotification.Name("ForceCoordinatorCleanup"),
                object: nil,
                userInfo: ["tabId": tab.id.uuidString]
            )
            
            // Remove tab from array with final bounds check
            if index < self.tabs.count {
                self.tabs.remove(at: index)
            } else {
                logWarning(.tabManagement, "Tab index changed during removal, filtering instead")
                self.tabs.removeAll { $0.id == tab.id }
            }
            
            // Clean up media control state
            MediaControlManager.shared.cleanupTab(tab.id)
            
            // Clean up activity tracking for regular tabs
            // Note: For saved tabs, we keep the activity history even when they're unloaded
            if self.sidebarManager?.sidebarStructure.tabs[tab.id] == nil {
                TabActivityManager.shared.removeTabActivity(for: tab.id)
            }
            
            // Clean up Find state for permanently removed tabs
            self.findManager?.clearFindStateForTab(tab.id)
            
            self.notifySidebar(event: .tabRemoved, tabId: tab.id)
            
            if self.showCommandPalette {
                NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: self)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .commandPaletteRefocus, object: self)
                }
            }
            
            if self.activeTabId == tab.id {
                if self.tabs.isEmpty {
                    self.activeTabId = nil
                } else {
                    // Use sidebar's tab history system for intelligent tab switching
                    if let sidebarManager = self.sidebarManager {
                        // Let the sidebar manager choose the next tab based on history
                        sidebarManager.selectionManager.moveSelectionToNextActiveTab(excluding: tab.id)

                        // Defensive fallback: ensure activeTabId is set if the space has tabs
                        // moveSelectionToNextActiveTab can fail silently if sidebar tab mappings are missing
                        if self.activeTabId == nil || self.activeTabId == tab.id {
                            // Not a pinned site: they're always loaded
                            if let firstTab = self.tabs.first(where: {
                                self.spaceSelection?.isInActiveSpace($0) != false && !sidebarManager.isPinnedSite(browserTabID: $0.id)
                            }) {
                                logWarning(.tabManagement, "Fallback: moveSelectionToNextActiveTab failed to set active tab, selecting first available")
                                self.activeTabId = firstTab.id
                                self.notifySidebar(event: .tabActivated, tabId: firstTab.id)
                                self.ensureActiveTabHasContent()
                            } else {
                                // The space's last tab: it stays, empty.
                                self.activeTabId = nil
                            }
                        }
                    } else {
                        // Fallback to index-based selection if no sidebar manager
                        let newIndex = min(index, self.tabs.count - 1)
                        if newIndex >= 0 && newIndex < self.tabs.count {
                            self.activeTabId = self.tabs[newIndex].id
                            
                            if let newActiveTabId = self.activeTabId {
                                self.notifySidebar(event: .tabActivated, tabId: newActiveTabId)
                            }
                            
                            self.ensureActiveTabHasContent()

                            if let newActiveTabId = self.activeTabId {
                                self.focusWebView(for: newActiveTabId)
                            }
                        }
                    }
                }
            }
            
            self.saveTabs()
        }
    }
    
    // MARK: - Undo Close Tab

    /// What a tab closed by hand left, for Undo Close Tab to open again
    private struct ClosedTab {
        let url: String
        let title: String
        let isPrivate: Bool
        let spaceID: UUID?
        let index: Int
        let interactionState: Any?
        let pageZoom: CGFloat?
        /// The group of regular tabs it was in, which it joins again
        let group: OpenTabGroup?
    }

    /// Closes a tab the person closed (⌘W, Close Tab, its row's close
    /// button), which ⌘Z — Edit › Undo Close Tab, on the window's undo
    /// manager — brings back: a regular or private tab in its
    /// place with its back/forward list, a saved tab or pinned site selected
    /// again. Not an empty tab or pane, which leave nothing to bring back.
    func closeTabUndoably(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let undoManager = windowUndoManager
        if let sidebarManager, let savedTabID = sidebarManager.browserToSidebarTabMapping[tab.id] {
            let wasShown = activeTabId == tab.id
            closeTab(tab)
            guard wasShown else { return }
            undoManager?.registerUndo(withTarget: self) { tabManager in
                tabManager.sidebarManager?.selectItem(savedTabID)
            }
            undoManager?.setActionName("Close Tab")
            return
        }

        guard let closed = closedTab(for: tab) else {
            closeTab(tab)
            return
        }
        closeTab(tab)
        undoManager?.registerUndo(withTarget: self) { tabManager in
            tabManager.reopen([closed], selecting: 0)
        }
        undoManager?.setActionName("Close Tab")
    }

    /// Closes tabs the person closed together (the sidebar divider's Close
    /// All), each as ⌘W does, the active one last so the selection doesn't
    /// go through the others on the way. One ⌘Z (Undo Close Tabs) opens the
    /// regular and private ones again where they were, in their groups.
    func closeTabsUndoably(_ tabsToClose: [BrowserTab]) {
        let closing = tabsToClose.filter { tab in tabs.contains { $0 === tab } }
        guard closing.count > 1 else {
            if let tab = closing.first { closeTabUndoably(tab) }
            return
        }
        let shownID = activeTabId
        // Every index is from the list as it is now: each tab leaves it a
        // turn later. Opened again from the first, each goes back among
        // those before it.
        let closedTabs = closing.compactMap { tab in closedTab(for: tab).map { (id: tab.id, closed: $0) } }
            .sorted { $0.closed.index < $1.closed.index }
        for tab in closing.filter({ $0.id != shownID }) + closing.filter({ $0.id == shownID }) {
            closeTab(tab)
        }
        guard !closedTabs.isEmpty else { return }
        let undoManager = windowUndoManager
        let shownIndex = closedTabs.firstIndex { $0.id == shownID }
        undoManager?.registerUndo(withTarget: self) { tabManager in
            tabManager.reopen(closedTabs.map(\.closed), selecting: shownIndex)
        }
        undoManager?.setActionName("Close Tabs")
    }

    /// What closing `tab` leaves for Undo Close Tab: nil for an empty tab
    /// or pane, which leave nothing to bring back, or a saved tab's page.
    private func closedTab(for tab: BrowserTab) -> ClosedTab? {
        guard sidebarManager?.browserToSidebarTabMapping[tab.id] == nil,
              !tab.isEmpty, !isEmptyPane(tab), let index = tabs.firstIndex(where: { $0 === tab }) else { return nil }
        // Its web view's state as it is now, else what it kept while suspended
        let coordinator = TabWebViewCoordinator.coordinator(for: tab.id)
        let interactionState: Any? = if let coordinator { coordinator.restorableInteractionState() } else { tab.suspendedInteractionState }
        let pageZoom: CGFloat? = if let coordinator { coordinator.webView.pageZoom } else { tab.suspendedPageZoom }
        return ClosedTab(
            url: tab.url,
            title: tab.title,
            isPrivate: tab.isPrivate,
            spaceID: tab.spaceID,
            index: index,
            interactionState: interactionState,
            pageZoom: pageZoom,
            group: OpenTabStore.shared.group(ofPage: tab)
        )
    }

    /// Opens closed tabs again in new tabs, where they were, in the order
    /// of their indices, and selects the one at `selectedIndex`, if any.
    /// Their web views pick up where the closed ones left off, as a
    /// suspended tab's does. Closing them again is the redo.
    private func reopen(_ closedTabs: [ClosedTab], selecting selectedIndex: Int?) {
        var reopened: [BrowserTab] = []
        for closed in closedTabs {
            let tab = BrowserTab(url: closed.url, title: closed.title, isPrivate: closed.isPrivate)
            tab.spaceID = SpaceManager.shared.space(withID: closed.spaceID) != nil ? closed.spaceID : SpaceManager.shared.defaultSpaceID
            tab.markSuspended(interactionState: closed.interactionState, pageZoom: closed.pageZoom)
            tabs.insert(tab, at: min(closed.index, tabs.count))
            if let group = closed.group {
                OpenTabStore.shared.setGroup(group, forPages: [tab])
            }
            updateFavicon(for: tab, url: tab.url)
            reopened.append(tab)
        }
        if let selectedIndex, reopened.indices.contains(selectedIndex) {
            let tab = reopened[selectedIndex]
            activeTabId = tab.id
            notifySidebar(event: .tabActivated, tabId: tab.id)
            focusWebView(for: tab.id)
            sidebarManager?.scrollToItem(tab.id)
        }
        saveTabs()

        windowUndoManager?.registerUndo(withTarget: self) { tabManager in
            if reopened.count == 1 {
                tabManager.closeTabUndoably(reopened[0])
            } else {
                tabManager.closeTabsUndoably(reopened)
            }
        }
        windowUndoManager?.setActionName(reopened.count == 1 ? "Close Tab" : "Close Tabs")
    }

    /// The undo manager of the window showing these tabs: the Edit menu's,
    /// shared with the page's and the command palette's text
    private var windowUndoManager: UndoManager? {
        BrowserWindowSession.all.first { $0.tabManager === self }?.window?.undoManager
    }

    // Close a tab and return to its parent tab (for back navigation in new tabs)
    private func closeTabAndReturnToParent(tabId: UUID, parentTabId: UUID) {
        logDebug(.tabManagement, "🔙 Closing tab and returning to parent")
        
        // Find the tab to close
        guard let tabToClose = tabs.first(where: { $0.id == tabId }) else {
            logWarning(.tabManagement, "Tab to close not found: \(tabId)")
            return
        }
        
        // Find the parent tab
        guard let parentTab = tabs.first(where: { $0.id == parentTabId }) else {
            logWarning(.tabManagement, "Parent tab not found: \(parentTabId), falling back to regular close")
            closeTab(tabToClose)
            return
        }
        
        // Switch to parent tab first, then close the child tab
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Activate the parent tab
            self.activeTabId = parentTab.id
            parentTab.markAsActive()
            
            // Notify sidebar about the tab activation
            self.notifySidebar(event: .tabActivated, tabId: parentTab.id)
            
            // Focus the parent tab's webview
            self.focusWebView(for: parentTab.id)

            // Close the child tab after a brief delay to ensure parent is active
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.closeTab(tabToClose)
            }
        }
    }

    
    func switchToTab(_ tab: BrowserTab) {
        activeTabId = tab.id
        tab.markAsActive()
        
        // Record tab activity for persistent history tracking
        TabActivityManager.shared.recordTabActivity(for: tab.id)
        
        notifySidebar(event: .tabActivated, tabId: tab.id)

        focusWebView(for: tab.id)

        let wasCommandPaletteOpen = showCommandPalette
        showCommandPalette = false

        if wasCommandPaletteOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: self)
            }
            // Ensure focus is given to the webview after command palette closes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.focusWebView(for: tab.id)
            }
        }
        
        saveTabs()
    }
    
    // MARK: - Navigation
    
    /// Navigates to a URL using smart saved tab logic.
    /// For saved tabs: same-domain navigation updates the tab, cross-domain creates a new tab.
    /// For regular tabs: navigates normally.
    func navigateToURL(_ url: String) {
        
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        
        let originalInput = trimmedURL
        let formattedURL = URLUtilities.formatURLForNavigation(trimmedURL)
        
        // An empty pane's page opens in a new tab too, which takes the
        // pane's place (the palette's new tab already has, if it was opened
        // from the pane)
        let emptyPane = activeTab.flatMap { isEmptyPane($0) ? $0.id : nil }
        if isNewTabMode || emptyPane != nil {
            let isPrivate = isNewTabMode && isNewTabPrivate
            if !isPrivate {
                typedHistoryManager.addTypedEntry(originalInput: originalInput, finalURL: formattedURL)
            }
            let newTabID = createNewTab(url: formattedURL, isPrivate: isPrivate)
            if let emptyPane, splitViews.contains(emptyPane) {
                fill(emptyPane: emptyPane, with: newTabID)
            }
        } else {
            guard let activeTab = activeTab else { return }
            
            // Check if current tab is a saved tab and apply domain-based navigation logic
            if let sidebarManager = sidebarManager,
               let savedTabId = sidebarManager.browserToSidebarTabMapping[activeTab.id],
               let _ = sidebarManager.sidebarStructure.tabs[savedTabId] {
                
                // Current tab is a saved tab - check domain compatibility
                if URLUtilities.isSameSite(activeTab.url, formattedURL) {
                    // Same domain - navigate within the saved tab
                    activeTab.navigateToURL(formattedURL)
                    // Don't update favicon for saved tabs - preserve the original favicon
                } else {
                    // Different domain - branch off to a new regular tab
                    _ = createNewTab(url: formattedURL)
                }
            } else {
                // Regular tab - navigate normally
                activeTab.navigateToURL(formattedURL)
                updateFavicon(for: activeTab, url: formattedURL)
            }
        }
        
        showCommandPalette = false
        isNewTabMode = false
    }

    /// ⌘⌥↓: the tab below the active one in the sidebar.
    func navigateToNextTab() {
        navigateInSidebarOrder(by: 1)
    }

    /// ⌘⌥↑: the tab above the active one in the sidebar.
    func navigateToPreviousTab() {
        navigateInSidebarOrder(by: -1)
    }

    /// Selects the tab `offset` rows from the active one, in the order the
    /// sidebar shows them (`SidebarManager.tabsInSidebarOrder`), going round
    /// from the last to the first and back. It's selected as a click on its
    /// row would (an unloaded saved tab loads), its row scrolled into view.
    private func navigateInSidebarOrder(by offset: Int) {
        guard let sidebarManager else { return }
        let order = sidebarManager.tabsInSidebarOrder()
        guard !order.isEmpty else { return }
        let current = activeTabId.map { sidebarManager.browserToSidebarTabMapping[$0] ?? $0 }
        let index: Int
        if let current, let currentIndex = order.firstIndex(of: current) {
            index = (currentIndex + offset % order.count + order.count) % order.count
        } else {
            index = offset > 0 ? 0 : order.count - 1
        }
        let itemID = order[index]
        guard itemID != current else { return }

        sidebarManager.selectItem(itemID)
        // A pinned site has no row to scroll to
        if !sidebarManager.sidebarStructure.pinnedItems.contains(itemID) {
            sidebarManager.scrollToItem(itemID)
        }
        // A tab to load is switched to on the next turn of the main queue
        DispatchQueue.main.async { [weak self] in
            self?.focusActiveWebView()
        }

        if showCommandPalette {
            NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: self)
        }
    }
    
    // MARK: - Command Palette
    
    private func requestCommandPalette(newTab: Bool, isPrivate: Bool = false, mode: CommandPaletteMode? = nil) {
        isNewTabMode = newTab
        isNewTabPrivate = isPrivate
        requestedPaletteMode = mode
        commandPaletteRequest &+= 1
        showCommandPalette = true
    }

    func openCommandPaletteForNewTab(isPrivate: Bool = false) {
        requestCommandPalette(newTab: true, isPrivate: isPrivate)
    }
    
    /// ⌘D, ⇧⌘D: splits the active tab's pane at once, side by side
    /// (horizontal) or one above the other (vertical). The new pane is a new
    /// tab, which shows the empty state, and the command palette opens to
    /// pick what goes in it (`paneToFill`).
    func splitActiveTab(_ axis: SplitAxis) {
        // A tab alone with no page shows the empty state over the whole window
        guard let activeTab, !activeTab.isEmpty || splitViews.contains(activeTab.id) else { return }
        let paneCount = splitViews.split(containing: activeTab.id)?.root.tabIDs.count ?? 1
        guard paneCount < SplitViewManager.maximumPanes else {
            NSSound.beep()
            return
        }
        // Active once it's in the split: the panes' layout can see the
        // window between the two, and would open the split from there, the
        // empty tab shown alone over the whole page
        let newTabID = createNewTab(activate: false)
        emptyPaneTabIDs.insert(newTabID)
        splitViews.add(newTabID, beside: activeTab.id, on: axis == .horizontal ? .right : .bottom)
        if let newTab = tabs.first(where: { $0.id == newTabID }) {
            activatePane(newTab, focusingPage: false)
        }
        openCommandPaletteForNewTab()
    }

    /// The tab of an empty pane, which only it shows
    func isEmptyPane(_ tab: BrowserTab) -> Bool {
        tab.isEmpty && emptyPaneTabIDs.contains(tab.id)
    }

    /// Whether the command palette is picking what goes in an empty pane
    var isPickingSplitPane: Bool {
        paneToFill != nil
    }

    func openCommandPaletteForNavigation() {
        requestCommandPalette(newTab: false)
    }

    func openCommandPaletteForTabActions() {
        requestCommandPalette(newTab: false, mode: .tabActions)
    }

    func openCommandPaletteWithCurrentURL() {
        requestCommandPalette(newTab: false)
        
        // Pre-fill with current tab's URL if available (a locked private tab's stays hidden)
        if let tab = activeTab, !tab.isLocked, !tab.url.isEmpty, tab.url != "about:blank" {
            let currentURL = tab.url
            // Post notification to set pre-filled URL after command palette setup
            // Use timing that coordinates with focus setup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SetPrefilledURL"), 
                    object: self, 
                    userInfo: ["url": currentURL]
                )
            }
        }
    }
    
    /// Check if app is in empty state and auto-show command palette if needed
    func checkAndAutoShowCommandPalette() {
        // Only auto-show if:
        // 1. Haven't already shown it this session
        // 2. No tabs have content (empty state)
        // 3. Command palette isn't already open
        let hasNonEmptyTabs = tabs.contains { !$0.isEmpty }
        let isNewWindow = opensWithNewTab && activeTabId == nil
        opensWithNewTab = false

        if !hasAutoShownCommandPalette && (!hasNonEmptyTabs || isNewWindow) && !showCommandPalette {
            logDebug(.general, "Auto-showing command palette for empty state")
            hasAutoShownCommandPalette = true
            openCommandPaletteForNewTab()
        }
    }
    
    // MARK: - History and Suggestions
    
    /// The command palette's suggestions: what was typed into new tabs in
    /// new-tab mode, browsing history (searched off the main thread) otherwise.
    @MainActor
    func getURLSuggestions(for searchText: String, limit: Int = 8) async -> [HistoryEntryData] {
        if isNewTabMode {
            return typedHistoryManager.getTypedSuggestions(for: searchText, limit: limit)
        } else {
            return await activeHistory.getURLSuggestions(for: searchText, limit: limit)
        }
    }
    
    /// A site shortcut's earlier searches: in what was typed into new tabs
    /// in new-tab mode (all of it, a hundred entries at most), browsing
    /// history otherwise, with the words in the query
    /// (`HistoryManager.siteSearches`).
    @MainActor
    func getSiteSearchSuggestions(prefix: String, words: [String], limit: Int) async -> [HistoryEntryData] {
        if isNewTabMode {
            return typedHistoryManager.getTypedSuggestions(for: prefix, limit: limit)
        } else {
            return await activeHistory.siteSearches(prefix: prefix, words: words, limit: limit)
        }
    }

    /// Removes the entry right away, so the palette's refresh that follows
    /// no longer finds it.
    @MainActor
    func deleteHistoryEntry(_ entry: HistoryEntryData) {
        if isNewTabMode {
            typedHistoryManager.removeEntry(entry)
        } else {
            activeHistory.removeEntry(entry)
        }
    }
    
    /// The history of the space the window shows
    @MainActor
    private var activeHistory: HistoryManager {
        spaceSelection?.activeHistory ?? SpaceManager.shared.history(forSpace: SpaceManager.shared.defaultSpaceID)
    }

    /// Records a visit in the history of `tabId`'s profile (the active tab's
    /// when there's none). A private tab's visits aren't kept.
    func trackPageVisit(url: String, title: String, tabId: UUID? = nil) {
        let visitedTabId = tabId ?? activeTabId
        let tab = tabs.first { $0.id == visitedTabId }
        if tab?.isPrivate != true {
            Task { @MainActor in
                let history = tab.map { SpaceManager.shared.history(for: $0) } ?? activeHistory
                history.addHistoryEntry(url: url, title: title)
            }
        }
        
        // The visited tab's saved tab, not the active one's: a page loading
        // in the background (a pinned site's) would retitle the tab in front
        if let visitedTabId {
            notifySidebar(event: .tabUpdated, tabId: visitedTabId, data: [
                "title": title,
                "url": url,
                "isActive": visitedTabId == activeTabId
            ])
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveTabs()
        }
    }
    
    // MARK: - Utilities
    
    func copyCurrentTabURL() {
        guard let activeTab = activeTab, !activeTab.isLocked else { return }
        
        let result = URLUtilities.removeTrackingParameters(from: activeTab.url)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.cleanURL, forType: .string)
        
        // Show appropriate toast notification
        let message = result.trackersDetected ? "Copied clean link without trackers" : "Copied link"
        toastManager.showToast(message: message, type: .info, icon: result.trackersDetected ? "checkmark.shield.fill" : "clipboard.fill")
    }
    
    func reloadCurrentTab() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("ReloadWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
        
    }
    
    func goBackInCurrentTab() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("GoBackWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    func goForwardInCurrentTab() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("GoForwardWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    func toggleWebInspector() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("ToggleWebInspector"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    // MARK: - Zoom Controls
    
    func zoomIn() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("ZoomInWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    func zoomOut() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("ZoomOutWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    func resetZoom() {
        guard let activeTab = activeTab else { return }
        
        NotificationCenter.default.post(
            name: NSNotification.Name("ResetZoomWebView"),
            object: nil,
            userInfo: ["tabId": activeTab.id.uuidString]
        )
    }
    
    func updateFavicon(for tab: BrowserTab, url: String) {
        Task { @MainActor [weak self] in
            let favicon = await FaviconCacheManager.shared.getFavicon(for: url, persist: !tab.isPrivate)
            
            // Update UI on main actor
            tab.favicon = favicon
            self?.objectWillChange.send()
        }
    }

    private func updateFaviconAppearance(for changedURL: String?, privateOnly: Bool) {
        let cache = FaviconCacheManager.shared
        let changedKey = changedURL.map { cache.generateCacheKey(for: $0) }
        for tab in tabs where !privateOnly || tab.isPrivate {
            let savedID = sidebarManager?.browserToSidebarTabMapping[tab.id]
            let savedURL = savedID.flatMap { sidebarManager?.sidebarStructure.tabs[$0]?.url }
            let url = savedURL ?? tab.url
            guard !url.isEmpty, changedKey == nil || changedKey == cache.generateCacheKey(for: url),
                  let image = cache.cachedFavicon(for: url, persist: !tab.isPrivate), image !== tab.favicon else { continue }
            tab.favicon = image
            if tab.id == activeTabId { objectWillChange.send() }
        }
    }
    
    func notifyTabDidUpdate(tabId: UUID? = nil) {
        // Only invalidate TabManager-observing views when the updated tab is the
        // active one. Inactive-tab title/URL/favicon changes are surfaced via the
        // sidebar structure's @Published state — calling objectWillChange here
        // for those would force every sidebar row to re-evaluate.
        if let tabId = tabId {
            if tabId == activeTabId {
                objectWillChange.send()
            }
        } else {
            // Caller didn't tell us which tab changed — preserve old behaviour.
            objectWillChange.send()
        }

        // Mirror the state of the tab that actually changed (not the active
        // one) so saved tabs loaded in the background keep live titles.
        guard let updatedTabId = tabId ?? activeTabId,
              let updatedTab = tabs.first(where: { $0.id == updatedTabId }) else { return }
        notifySidebar(event: .tabUpdated, tabId: updatedTabId, data: [
            "title": updatedTab.title,
            "url": updatedTab.url,
            "isLoading": updatedTab.isLoading,
            "progress": updatedTab.estimatedProgress,
            "isActive": updatedTabId == activeTabId
        ])
    }
    
    // MARK: - Tab Persistence
    
    /// Schedule a debounced tab save. Multiple rapid calls collapse into one.
    /// Use this from any normal-flow code path (tab switch, page-load, nav).
    private func saveTabs(onlyPersistent: Bool = false) {
        saveTabsWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveTabsImmediately(onlyPersistent: onlyPersistent)
        }
        saveTabsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveTabsDebounceInterval, execute: item)
    }

    /// Synchronously persist tabs. Call only from app termination / explicit
    /// flush paths where the work must complete before returning.
    private func saveTabsImmediately(onlyPersistent: Bool = false) {
        // If a debounced save is queued, cancel it — we're doing the work now.
        saveTabsWorkItem?.cancel()
        saveTabsWorkItem = nil
        // Its window closed with its tabs: nothing to restore
        guard !isWindowClosed else { return }

        do {
            // Private tabs aren't restored, nor empty panes, which split
            // views (not restored either) are all they're for
            var tabsToSave = tabs.filter { !$0.isPrivate && !emptyPaneTabIDs.contains($0.id) }

            // Filter out regular tabs on app termination
            if onlyPersistent, let sidebarManager = sidebarManager {
                tabsToSave = tabsToSave.filter { sidebarManager.browserToSidebarTabMapping[$0.id] != nil }
            }

            let data = try JSONEncoder().encode(tabsToSave)
            userDefaults.set(data, forKey: tabsKey)

            if let activeTabId = activeTabId,
               tabsToSave.contains(where: { $0.id == activeTabId }) {
                userDefaults.set(activeTabId.uuidString, forKey: activeTabKey)
            } else {
                userDefaults.removeObject(forKey: activeTabKey)
            }

            // The saved tabs open in this window, if sidebar manager is available
            if let sidebarManager = sidebarManager {
                let tabIDs = Set(tabsToSave.map(\.id))
                saveTabMappings(sidebarManager.browserToSidebarTabMapping.filter { tabIDs.contains($0.key) })
            }
        } catch {
            // Silently fail - tabs will not be persisted
        }
    }
    
    private func saveTabMappings(_ mappings: [UUID: UUID]) {
        do {
            // Convert mappings to string-keyed dictionary for JSON encoding
            let stringMappings = mappings.reduce(into: [String: String]()) { result, mapping in
                result[mapping.key.uuidString] = mapping.value.uuidString
            }
            let data = try JSONEncoder().encode(stringMappings)
            userDefaults.set(data, forKey: tabMappingsKey)
        } catch {
            // Silently fail - mappings will not be persisted
        }
    }
    
    private func loadTabMappings() -> [UUID: UUID] {
        guard let data = userDefaults.data(forKey: tabMappingsKey) else {
            return [:]
        }
        
        do {
            let stringMappings = try JSONDecoder().decode([String: String].self, from: data)
            // Convert back to UUID-keyed dictionary
            return stringMappings.compactMapValues { sidebarIdString in
                UUID(uuidString: sidebarIdString)
            }.reduce(into: [UUID: UUID]()) { result, mapping in
                if let browserTabId = UUID(uuidString: mapping.key) {
                    result[browserTabId] = mapping.value
                }
            }
        } catch {
            return [:]
        }
    }
    
    private func handleAppTermination() {
        let settings = TOMLSettingsManager.shared

        // Termination must complete before the process exits, so use the
        // immediate path rather than the debounced wrapper.
        switch settings.tabCloseAction {
        case .never:
            saveTabsImmediately(onlyPersistent: false)
        case .endOfDay, .after24Hours:
            saveTabsImmediately(onlyPersistent: false)
        case .whenClosingApp:
            saveTabsImmediately(onlyPersistent: true)
        }

        // Sidebar saves are written in the background; make sure the last
        // ones land before the process exits.
        sidebarManager?.flushPendingSaves()
    }
    
    private func handleAppInactive() {
        let settings = TOMLSettingsManager.shared

        switch settings.tabCloseAction {
        case .never, .endOfDay, .after24Hours:
            // Regular tabs should persist when app becomes inactive
            saveTabs(onlyPersistent: false)
        case .whenClosingApp:
            // Only close regular tabs on app termination, not when inactive
            saveTabs(onlyPersistent: false)
        }

        // Drop transient WebKit caches while the user is elsewhere — these
        // grow over a session (parsed CSS, fetched images, in-memory HTTP
        // responses) and otherwise sit resident until the next visit.
        // Cookies, IndexedDB, localStorage, and service workers are
        // preserved (they're persistent data types, not in this set). So is
        // the FetchCache: despite the name it's the on-disk Cache API store
        // of service workers, so purging it freed no memory and made sites
        // re-download their offline assets after every app switch.
        let memoryCacheTypes: Set<String> = [
            WKWebsiteDataTypeMemoryCache
        ]
        for store in SpaceManager.shared.allWebsiteDataStores {
            store.removeData(
                ofTypes: memoryCacheTypes,
                modifiedSince: .distantPast,
                completionHandler: {}
            )
        }
    }
    
    private func setupTabClosingTimers() {
        // Invalidate existing timers
        endOfDayTimer?.invalidate()
        inactivityTimer?.invalidate()
        
        let settings = TOMLSettingsManager.shared
        
        // Set up end of day timer
        if settings.shouldCloseTabsAtEndOfDay() {
            scheduleEndOfDayTimer()
        }
        
        // Set up 24-hour inactivity timer
        if settings.shouldCloseTabsAfter24Hours() {
            scheduleInactivityTimer()
        }
    }
    
    private func scheduleEndOfDayTimer() {
        // Calculate time until midnight
        let calendar = Calendar.current
        let now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let midnight = calendar.startOfDay(for: tomorrow)
        let interval = midnight.timeIntervalSinceNow

        // Block form with [weak self] avoids the target/selector retain cycle.
        // Re-arms itself for the next midnight after firing. Added to the run
        // loop in .common mode so it still fires during scrolling/tracking.
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeRegularTabsAtEndOfDay()
                self?.scheduleEndOfDayTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        endOfDayTimer = timer
    }
    
    private func scheduleInactivityTimer() {
        // Check every hour for inactive tabs.
        // Note: Timer.scheduledTimer already adds to the current run loop in
        // .default mode — re-adding to .common would cause the timer to fire
        // twice per interval.
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeInactiveRegularTabs()
            }
        }
    }
    
    @objc private func closeRegularTabsAtEndOfDay() {
        guard TOMLSettingsManager.shared.shouldCloseTabsAtEndOfDay() else { return }
        
        let regularTabs = getRegularTabs()
        logInfo(.tabManagement, "Closing \(regularTabs.count) regular tabs at end of day")
        
        for tab in regularTabs {
            closeTab(tab)
        }
    }
    
    private func closeInactiveRegularTabs() {
        guard TOMLSettingsManager.shared.shouldCloseTabsAfter24Hours() else { return }
        
        // Not the tabs on screen, however long they've been there
        let regularTabs = getRegularTabs()
        let inactiveIDs = Set(TOMLSettingsManager.shared.getInactiveTabsOlderThan24Hours(
            from: regularTabs.filter { !splitViews.isVisible($0.id) }
        ).map(\.id))
        // A group's tabs close together, once none of them has been used
        // for that long or is on screen: a group in use stays whole
        let groups = OpenTabStore.shared.groups(ofPages: regularTabs)
        let groupsInUse = Set(regularTabs.filter { !inactiveIDs.contains($0.id) }.compactMap { groups[$0.id]?.id })
        let inactiveTabs = regularTabs.filter { tab in
            inactiveIDs.contains(tab.id) && !(groups[tab.id].map { groupsInUse.contains($0.id) } ?? false)
        }

        logInfo(.tabManagement, "Closing \(inactiveTabs.count) inactive regular tabs (24h+ old)")
        
        for tab in inactiveTabs {
            closeTab(tab)
        }
    }
    
    private func getRegularTabs() -> [BrowserTab] {
        guard let sidebarManager = sidebarManager else { return tabs }
        
        // Regular tabs are those NOT in the browserToSidebarTabMapping
        return tabs.filter { sidebarManager.browserToSidebarTabMapping[$0.id] == nil }
    }
    
    /// Saved tabs' pages used to have their saved tab's ID. One left open as
    /// a regular tab, no longer the saved tab's page, selected the saved tab
    /// from its own row, and the palette took it for the saved tab. Each
    /// gets an ID of its own in what this window saved, before anything
    /// reads it: its tabs, which are saved tabs' pages, the active one and
    /// each space's last. (Only `id`: `openTabID` links it to its open tab.)
    private func givePagesTheirOwnIDs(defaults: WindowDefaults) {
        guard let data = userDefaults.data(forKey: tabsKey),
              var pages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let savedTabIDs = Set(SidebarStore.shared.structure.tabs.keys)
        var newIDs: [UUID: UUID] = [:]
        for index in pages.indices {
            guard let id = (pages[index]["id"] as? String).flatMap(UUID.init(uuidString:)),
                  savedTabIDs.contains(id) else { continue }
            let newID = UUID()
            pages[index]["id"] = newID.uuidString
            newIDs[id] = newID
        }
        guard !newIDs.isEmpty, let repaired = try? JSONSerialization.data(withJSONObject: pages) else { return }
        let renamed = { (id: String) in UUID(uuidString: id).flatMap { newIDs[$0] }?.uuidString ?? id }

        userDefaults.set(repaired, forKey: tabsKey)
        if let data = userDefaults.data(forKey: tabMappingsKey),
           let mappings = try? JSONDecoder().decode([String: String].self, from: data),
           let repairedMappings = try? JSONEncoder().encode(Dictionary(
               mappings.map { (renamed($0.key), $0.value) }, uniquingKeysWith: { first, _ in first }
           )) {
            userDefaults.set(repairedMappings, forKey: tabMappingsKey)
        }
        if let activeTabID = userDefaults.string(forKey: activeTabKey) {
            userDefaults.set(renamed(activeTabID), forKey: activeTabKey)
        }
        let lastTabsKey = defaults.key("LastActiveTabBySpace")
        if let lastTabs = userDefaults.dictionary(forKey: lastTabsKey) as? [String: String] {
            userDefaults.set(lastTabs.mapValues(renamed), forKey: lastTabsKey)
        }
        logInfo(.tabManagement, "Gave \(newIDs.count) saved tabs' pages IDs of their own")
    }

    private func loadSavedTabs() {
        // Set startup loading flag to prevent unnecessary sidebar saves during tab restoration
        isStartupLoading = true
        
        guard let data = userDefaults.data(forKey: tabsKey) else {
            isStartupLoading = false
            return
        }
        
        do {
            let savedTabs = try JSONDecoder().decode([BrowserTab].self, from: data)
            
            if !savedTabs.isEmpty {
                // Load saved tab mappings to determine which tabs should be regular vs sidebar tabs
                let savedMappings = loadTabMappings()
                let browserTabsWithMappings = Set(savedMappings.keys) // browser tab IDs that map to sidebar tabs
                
                // Split saved tabs into regular tabs and sidebar-mapped tabs
                // Regular tabs are loaded immediately, sidebar-mapped tabs are stored for mapping restoration
                var regularTabs: [BrowserTab] = []
                var sidebarMappedTabs: [BrowserTab] = []
                
                for tab in savedTabs {
                    let hasMapping = browserTabsWithMappings.contains(tab.id)
                    if hasMapping {
                        sidebarMappedTabs.append(tab)
                        sidebarMappedTabIds.insert(tab.id)
                    } else {
                        regularTabs.append(tab)
                    }
                }
                
                tabs = regularTabs
                filteredSidebarTabs = sidebarMappedTabs
                
                // Check if any restored tabs have content and reset auto-show flag
                let hasRestoredContent = regularTabs.contains { !$0.isEmpty }
                if hasRestoredContent {
                    hasAutoShownCommandPalette = false
                }
                
                // Restored tabs get their web view when first shown, not
                // all at launch — each would start a WebContent process and
                // load its page in the background. (Their pages don't
                // autoplay either; see TabWebViewCoordinator.createWebView.)
                // An empty tab has no page to restore.
                for tab in regularTabs where !tab.isEmpty {
                    tab.markSuspended()
                }
                
                // Set active tab, but only from regular tabs (not sidebar-mapped ones)
                var waitsForSavedActiveTab = false
                if let activeTabIdString = userDefaults.string(forKey: activeTabKey),
                   let savedActiveTabId = UUID(uuidString: activeTabIdString) {
                    
                    // If the saved active tab has a sidebar mapping, we'll let the sidebar manager handle activation
                    // (restoreTabMappings). None meanwhile: another tab, of another space, would take the window there.
                    if browserTabsWithMappings.contains(savedActiveTabId) {
                        activeTabId = nil
                        waitsForSavedActiveTab = true
                    } else if regularTabs.contains(where: { $0.id == savedActiveTabId }) {
                        activeTabId = savedActiveTabId
                    } else {
                        activeTabId = regularTabs.first?.id
                    }
                } else {
                    activeTabId = regularTabs.first?.id
                }
                
                for tab in regularTabs {
                    if !tab.isEmpty {
                        updateFavicon(for: tab, url: tab.url)
                    }
                }
                
                if !waitsForSavedActiveTab {
                    ensureActiveTabHasContent()
                }
            }
        } catch {
            // Silently fail - start with empty tabs
        }
        
        // Clear startup loading flag and perform final sidebar sync if needed
        DispatchQueue.main.async { [weak self] in
            self?.completeStartupLoading()
        }
    }
    
    private func completeStartupLoading() {
        isStartupLoading = false
        
        // Perform a single sidebar sync after all tabs are loaded if sidebar is available
        if let sidebarManager = sidebarManager {
            sidebarManager.saveSidebarStructure()
        }
    }
    
    // Public method to check if we're in startup loading phase
    var isInStartupLoadingPhase: Bool {
        return isStartupLoading
    }

    // MARK: - Sidebar Integration
    
    func setSidebarManager(_ manager: SidebarManager) {
        self.sidebarManager = manager
        
        // Restore saved tab mappings to maintain tab relationships
        restoreTabMappings(to: manager)
        
        // Validate the connection is properly established
        validateSidebarConnection()
        
        // Perform startup cleanup to remove orphaned empty tabs
        performStartupCleanup()
        
        // Schedule a secondary validation after initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.validateSidebarConnection()
        }
    }
    
    private func restoreTabMappings(to sidebarManager: SidebarManager) {
        let savedMappings = loadTabMappings()

        // The saved tabs open in this window at quit come back open, each
        // at the page it was on
        sidebarManager.sidebarTabManager.restoreTabs(filteredSidebarTabs.compactMap { browserTab in
            savedMappings[browserTab.id].map { (browserTab: browserTab, savedTabID: $0) }
        })

        if let savedActiveTabIdString = userDefaults.string(forKey: activeTabKey),
           let savedActiveTabId = UUID(uuidString: savedActiveTabIdString) {
            if tabs.contains(where: { $0.id == savedActiveTabId }),
               let sidebarTabId = sidebarManager.browserToSidebarTabMapping[savedActiveTabId] {
                activeTabId = savedActiveTabId
                sidebarManager.selectedItem = sidebarTabId
            } else if let sidebarTabId = savedMappings[savedActiveTabId],
                      sidebarManager.sidebarStructure.tabs[sidebarTabId] != nil {
                // Its page wasn't kept: the saved tab's own
                sidebarManager.sidebarTabManager.loadTab(withID: sidebarTabId)
            }
        }
        
        // Clear filtered tabs after mapping restoration is complete
        filteredSidebarTabs.removeAll()

        // The saved tab that was active couldn't be loaded: a tab of the
        // window's space instead
        if activeTabId == nil, let tab = tabs.first(where: { !$0.isEmpty && spaceSelection?.isInActiveSpace($0) != false }) {
            activeTabId = tab.id
        }
    }
    
    private func validateSidebarConnection() {
        guard let _ = sidebarManager else {
            logError(.sidebar, "SidebarManager connection validation failed - manager is nil")
            return
        }
        
        // Trigger command palette cache update to reflect proper tab state
        NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: self)
    }
    
    /// Check if a tab ID represents a sidebar-mapped tab that was filtered out during startup
    func isSidebarMappedTab(_ tabId: UUID) -> Bool {
        return sidebarMappedTabIds.contains(tabId)
    }
    
    /// Clean up orphaned empty browser tabs that should have been removed when tabs were unloaded
    private func performStartupCleanup() {
        guard let sidebarManager = sidebarManager else { return }

        let settings = TOMLSettingsManager.shared

        let originalTabCount = tabs.count
        let mappingCount = sidebarManager.browserToSidebarTabMapping.count

        // Detect saved tabs marked active that have no actual browser tab in `tabs`.
        // This catches the case where multiple sidebar-mapped tabs were loaded last session
        // but only the active one is restored as a browser tab — the others keep stale
        // mappings, stay marked active, and become invisible to the command palette.
        // In any window: a saved tab may be open in another. This one's
        // own too, which isn't among the windows' until it's set up.
        let allTabs = tabs + BrowserWindowSession.allTabs.filter { tab in !tabs.contains { $0 === tab } }
        let browserTabIds = Set(allTabs.map { $0.id })
        var orphanedActiveSavedTabIds: [UUID] = []

        for (sidebarTabId, sidebarTab) in sidebarManager.sidebarStructure.tabs {
            guard !sidebarTab.isUnloaded else { continue }

            // A page of it in this window or another
            let hasActualBrowserTab = sidebarManager.store.sidebarManagers.contains { other in
                other.sidebarToBrowserTabMapping[sidebarTabId].map { browserTabIds.contains($0) } ?? false
            }
            // One with its address that it could still take (not a private
            // tab, nor another saved tab's)
            let hasMatchingBrowserTab = allTabs.contains {
                $0.url == sidebarTab.url && !$0.isEmpty && !$0.isPrivate
                    && sidebarManager.browserToSidebarTabMapping[$0.id] == nil
            }

            if !hasActualBrowserTab && !hasMatchingBrowserTab {
                orphanedActiveSavedTabIds.append(sidebarTabId)
            }
        }

        if !orphanedActiveSavedTabIds.isEmpty {
            logWarning(.tabManagement, "Found \(orphanedActiveSavedTabIds.count) orphaned active saved tabs - marking as unloaded")
            var newStructure = sidebarManager.sidebarStructure
            for sidebarTabId in orphanedActiveSavedTabIds {
                if var tab = newStructure.tabs[sidebarTabId] {
                    tab.isUnloaded = true
                    tab.lastActiveAt = Date()
                    newStructure.tabs[sidebarTabId] = tab
                    logDebug(.tabManagement, "Marked saved tab '\(tab.displayTitle)' as unloaded")
                }
                if let bid = sidebarManager.sidebarToBrowserTabMapping[sidebarTabId] {
                    sidebarManager.sidebarToBrowserTabMapping.removeValue(forKey: sidebarTabId)
                    sidebarManager.browserToSidebarTabMapping.removeValue(forKey: bid)
                }
            }
            sidebarManager.sidebarStructure = newStructure
            sidebarManager.saveSidebarStructure()
        }

        // Only perform empty-tab cleanup if we have orphaned tabs (no mappings but tabs exist).
        // If we have mappings now (from restoration), tabs are properly connected.
        guard mappingCount == 0 && originalTabCount > 0 else {
            return
        }
        
        // If tab close action is "Never", we should preserve ALL non-empty tabs
        if settings.tabCloseAction == .never {
            return
        }
        
        // For other settings, get URLs and IDs of ALL saved tabs (both active and unloaded) to prevent
        // accidentally removing browser tabs that should be mapped to saved tabs
        let allSavedTabURLs = Set(sidebarManager.sidebarStructure.tabs.values.map { $0.url })
        let allSavedTabIds = Set(sidebarManager.sidebarStructure.tabs.keys)
        
        // Filter out empty tabs, tabs that match saved tab URLs, and tabs that match saved tab IDs
        let cleanedTabs = tabs.filter { tab in
            // Keep tab if it's NOT empty AND doesn't match any saved tab URL AND doesn't match any saved tab ID
            return !tab.isEmpty && !allSavedTabURLs.contains(tab.url) && !allSavedTabIds.contains(tab.id)
        }
        
        let removedCount = originalTabCount - cleanedTabs.count
        
        if removedCount > 0 {
            logDebug(.tabManagement, "Startup cleanup: Removing \(removedCount) orphaned browser tabs")
            
            // Update the tabs array
            tabs = cleanedTabs
            
            // If we removed the active tab, reset to first remaining tab or nil
            if let currentActiveTabId = activeTabId, !tabs.contains(where: { $0.id == currentActiveTabId }) {
                activeTabId = tabs.first?.id
                logDebug(.tabManagement, "Startup cleanup: Reset active tab to: \(activeTabId?.uuidString.prefix(8) ?? "none")")
            }
            
            // Save the cleaned tabs immediately
            saveTabs()
            
            logDebug(.tabManagement, "Startup cleanup complete - Tabs reduced from \(originalTabCount) to \(tabs.count)")
        }
    }
    
    private func notifySidebar(event: SidebarNotificationEvent, tabId: UUID, data: [String: Any] = [:]) {
        guard let sidebarManager = sidebarManager else { return }
        
        switch event {
        case .tabUpdated:
            // Convert browser tab ID to sidebar tab ID before updating
            if let sidebarTabId = sidebarManager.browserToSidebarTabMapping[tabId] {
                sidebarManager.updateTabState(
                    for: sidebarTabId,
                    title: data["title"] as? String,
                    url: data["url"] as? String,
                    isActiveTab: data["isActive"] as? Bool ?? true
                )
            }
        case .tabActivated:
            // Convert browser tab ID to sidebar tab ID before marking as active
            if let sidebarTabId = sidebarManager.browserToSidebarTabMapping[tabId] {
                sidebarManager.markTabAsActive(sidebarTabId)
            }
        case .tabRemoved:
            break
        }
    }
    
    // MARK: - Notification Setup

    /// Whether a notification about a tab is this window's to act on: the
    /// tab is one of its own, or, with none (or one no window has), this
    /// is the window in front.
    private func isForThisWindow(tabID: UUID?) -> Bool {
        if let tabID, let owner = BrowserWindowSession.owner(ofTab: tabID) {
            return owner.tabManager === self
        }
        return BrowserWindowSession.current.tabManager === self
    }
    
    private func setupNotificationObservers() {
        // Page visit tracking
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("TrackPageVisit"),
            object: nil
        ) { [weak self] notification in
            if let self, let userInfo = notification.userInfo,
               let url = userInfo["url"] as? String,
               let title = userInfo["title"] as? String {
                let tabId = (userInfo["tabId"] as? String).flatMap(UUID.init(uuidString:))
                // The tab's window's alone: in another, a private tab's
                // visit would go into history
                guard self.isForThisWindow(tabID: tabId) else { return }
                self.trackPageVisit(url: url, title: title, tabId: tabId)
            }
        })

        // App termination
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil
        ) { [weak self] _ in
            self?.handleAppTermination()
        })

        // App becomes inactive
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil
        ) { [weak self] _ in
            self?.handleAppInactive()
        })

        // App becomes active - warm up WebView pool, but only if the user
        // actually has tabs. Otherwise we'd allocate Web Content processes
        // (~30-60 MB each) on every wake-from-sleep with nothing to do.
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let self = self, !self.tabs.isEmpty else { return }
                WebViewPool.shared.warmUpPool()
            }
        })

        // Toast notifications from WebViews
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("ShowToast"),
            object: nil
        ) { [weak self] notification in
            if let self, let userInfo = notification.userInfo,
               let message = userInfo["message"] as? String {
                // In the page's window, or the window in front
                let tabId = (userInfo["tabId"] as? String).flatMap(UUID.init(uuidString:))
                guard self.isForThisWindow(tabID: tabId) else { return }
                let type = userInfo["type"] as? String ?? "info"
                let icon = userInfo["icon"] as? String

                let toastType: ToastType
                switch type {
                case "success": toastType = .success
                case "error": toastType = .error
                default: toastType = .info
                }

                self.toastManager.showToast(message: message, type: toastType, icon: icon)
            }
        })

        // New tab creation from WebViews
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("CreateNewTab"),
            object: nil
        ) { [weak self] notification in
            if let self, let userInfo = notification.userInfo,
               let url = userInfo["url"] as? String {
                let isExternalURL = userInfo["isExternalURL"] as? Bool ?? false
                let parentTabId = userInfo["parentTabId"] as? String
                let parentUUID = parentTabId != nil ? UUID(uuidString: parentTabId!) : nil
                // In the opener's window: once, and with its tab ID
                // (`predeterminedTabId`) in no other
                guard self.isForThisWindow(tabID: parentUUID) else { return }
                let predeterminedId = (userInfo["predeterminedTabId"] as? String).flatMap(UUID.init(uuidString:))
                let activate = userInfo["activate"] as? Bool ?? true
                _ = self.createNewTab(url: url, isExternalURL: isExternalURL, parentTabId: parentUUID, predeterminedId: predeterminedId, activate: activate)
            }
        })

        // Close tab from JavaScript window.close() (e.g. OAuth callback page
        // closing the adopted createWebViewWith tab after postMessage)
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("CloseTab"),
            object: nil
        ) { [weak self] notification in
            if let userInfo = notification.userInfo,
               let tabIdString = userInfo["tabId"] as? String,
               let tabId = UUID(uuidString: tabIdString) {
                self?.closeTab(withId: tabId)
            }
        })

        // Close tab and return to parent (for back navigation in new tabs)
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("CloseTabAndReturnToParent"),
            object: nil
        ) { [weak self] notification in
            if let userInfo = notification.userInfo,
               let tabIdString = userInfo["tabId"] as? String,
               let parentTabIdString = userInfo["parentTabId"] as? String,
               let tabId = UUID(uuidString: tabIdString),
               let parentTabId = UUID(uuidString: parentTabIdString) {
                self?.closeTabAndReturnToParent(tabId: tabId, parentTabId: parentTabId)
            }
        })

        // Close download tab (for auto-closing empty download tabs)
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("CloseDownloadTab"),
            object: nil
        ) { [weak self] notification in
            if let userInfo = notification.userInfo,
               let tabIdString = userInfo["tabId"] as? String,
               let tabId = UUID(uuidString: tabIdString) {
                // Find the tab
                if let tab = self?.tabs.first(where: { $0.id == tabId }) {
                    // Only close if tab is empty or shows minimal content
                    if tab.isEmpty || tab.title.isEmpty || tab.title == "New Tab" {
                        logDebug(.tabManagement, "🗂️ Auto-closing empty download tab: \(tabId.uuidString.prefix(8))")
                        self?.closeTab(withId: tabId)
                    }
                }
            }
        })

        // Settings changes
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: .tabCloseActionChanged,
            object: nil
        ) { [weak self] _ in
            self?.setupTabClosingTimers()
        })
    }
    

    
    // MARK: - Utility Methods
    
    
    // MARK: - Find Integration

    /// Get the WebView instance for a specific tab (used by FindManager).
    /// Nil while the tab has no web view (suspended, or not created yet).
    func getWebViewForTab(_ tabId: UUID) -> WKWebView? {
        guard let coordinator = TabWebViewCoordinator.coordinator(for: tabId) else {
            return nil
        }
        return coordinator.webView
    }

    // MARK: - Split View

    /// The tab picked in the command palette for an empty pane (a page
    /// opened in a new tab, or a tab switched to) takes the pane's place
    private func fillPaneFromPalette() {
        guard let pane = paneToFill, let activeTabId, activeTabId != pane else { return }
        paneToFill = nil
        guard splitViews.contains(pane), tabs.first(where: { $0.id == pane })?.isEmpty == true else { return }
        fill(emptyPane: pane, with: activeTabId)
    }

    /// A tab takes an empty pane's place, and the pane's own tab closes
    private func fill(emptyPane paneTabID: UUID, with tabID: UUID) {
        splitViews.replace(paneTabID, with: tabID)
        if let emptyTab = tabs.first(where: { $0.id == paneTabID }), emptyTab.isEmpty {
            closeTab(emptyTab)
        }
    }

    /// An empty pane left on its own (its split view separated, or its
    /// other panes gone) closes: its tab was only there for the pane
    private func closeEmptyPanesOutOfSplitViews() {
        for tabID in emptyPaneTabIDs where !splitViews.contains(tabID) {
            emptyPaneTabIDs.remove(tabID)
            if let tab = tabs.first(where: { $0.id == tabID }), tab.isEmpty {
                closeTab(tab)
            }
        }
    }

    /// A click in a pane of the split view on screen makes its tab the
    /// active one
    func focusPane(_ tabID: UUID) {
        guard tabID != activeTabId, splitViews.isVisible(tabID),
              let tab = tabs.first(where: { $0.id == tabID }) else { return }
        // The click gives its page the keyboard
        activatePane(tab, focusingPage: false)
    }

    /// ⌃⌘ and an arrow: the pane beside the active one that way becomes the
    /// active one, its page getting the keyboard
    func focusPane(toward edge: SplitEdge) {
        guard let activeTabId, let tabID = splitViews.pane(beside: activeTabId, toward: edge),
              let tab = tabs.first(where: { $0.id == tabID }) else { return }
        activatePane(tab, focusingPage: true)
    }

    /// Makes a pane's tab the active one, as switchToTab does, but leaving
    /// the command palette as it is
    private func activatePane(_ tab: BrowserTab, focusingPage: Bool) {
        activeTabId = tab.id
        tab.markAsActive()
        TabActivityManager.shared.recordTabActivity(for: tab.id)
        notifySidebar(event: .tabActivated, tabId: tab.id)
        if focusingPage, !showCommandPalette {
            focusWebView(for: tab.id)
        }
        saveTabs()
    }

    /// Tabs › Close Split View: the active tab's split view goes, and its
    /// tabs stay open, the active one shown alone
    func closeSplitView() {
        guard let activeTabId else { return }
        splitViews.separate(splitContaining: activeTabId)
    }

    /// Before a tab closes, or a saved tab is unloaded: out of its split
    /// view, and if it was the active tab, the pane beside it takes over
    func leaveSplitView(_ tabID: UUID) {
        guard splitViews.contains(tabID) else { return }
        let neighbor = tabID == activeTabId ? splitViews.neighbor(of: tabID) : nil
        // What its pane shows as it closes, if the tab is closing
        let closedLook: SplitViewManager.LeavingPane = tabs.first { $0.id == tabID }
            .map { $0.isEmpty ? .empty : .page($0.backgroundColor) } ?? .empty
        splitViews.remove(tabID, closedLook: closedLook)
        guard let neighbor, let tab = tabs.first(where: { $0.id == neighbor }) else { return }
        // The command palette stays open if the tab was closed from its list
        activatePane(tab, focusingPage: true)
        // The sidebar's own sync waits a moment, and closing a pinned site
        // would pick a tab of its own if it were still selected
        sidebarManager?.selectionManager.syncSelectionWithActiveTab(activeTabId: neighbor)
    }

    /// The open tab a sidebar item dragged onto a page would bring: a
    /// regular tab, or a saved tab's (none while it's unloaded)
    private func openTabID(forSidebarItem itemID: UUID) -> UUID? {
        if let mapped = sidebarManager?.sidebarToBrowserTabMapping[itemID],
           tabs.contains(where: { $0.id == mapped }) {
            return mapped
        }
        return tabs.contains { $0.id == itemID } ? itemID : nil
    }

    /// The open tab of a sidebar item, an unloaded saved tab loaded first
    /// (which selects it), another window's tab brought over
    private func openTab(forSidebarItem itemID: UUID) -> BrowserTab? {
        if openTabID(forSidebarItem: itemID) == nil {
            if sidebarManager?.sidebarStructure.tabs[itemID] != nil {
                sidebarManager?.loadTab(withID: itemID)
            } else {
                _ = sidebarManager?.browserTabBroughtHere(itemID)
            }
        }
        return openTabID(forSidebarItem: itemID).flatMap { id in tabs.first { $0.id == id } }
    }

    /// Whether a sidebar item can go beside a pane, or into it: a tab (not
    /// a folder), not the pane's own, and, beside it (`edge`), room left.
    /// No `edge`: into an empty pane, taking its place.
    private func canSplit(sidebarItem itemID: UUID, over paneTabID: UUID, on edge: SplitEdge?) -> Bool {
        let isTab = sidebarManager?.sidebarStructure.tabs[itemID] != nil || BrowserWindowSession.owner(ofTab: itemID) != nil
        guard isTab else { return false }
        let tabID = openTabID(forSidebarItem: itemID)
        guard edge != nil else { return tabID != paneTabID }
        // An unloaded saved tab gets a tab of its own
        return splitViews.canAdd(tabID ?? UUID(), beside: paneTabID)
    }

    /// What's dragged onto a pane: a sidebar item, or a pane of the split
    /// view on screen by its handle (its tab's ID)
    private enum SplitDragItem {
        case sidebarItem(UUID)
        case pane(UUID)
    }

    private func splitDragItem(_ info: NSDraggingInfo) -> SplitDragItem? {
        let pasteboard = info.draggingPasteboard
        if let raw = pasteboard.string(forType: SplitPaneControlsView.pasteboardType), let tabID = UUID(uuidString: raw) {
            return .pane(tabID)
        }
        return pasteboard.sidebarItemUUIDs().first.map { SplitDragItem.sidebarItem($0) }
    }

    private func canSplit(_ item: SplitDragItem, over paneTabID: UUID, on edge: SplitEdge?) -> Bool {
        switch item {
        case .sidebarItem(let itemID):
            return canSplit(sidebarItem: itemID, over: paneTabID, on: edge)
        case .pane(let tabID):
            // In the same split view, so moving it leaves the pane count as it is
            guard tabID != paneTabID, tabs.contains(where: { $0.id == tabID }) else { return false }
            return edge == nil || splitViews.canAdd(tabID, beside: paneTabID)
        }
    }

    /// A tab dragged from the sidebar, or a pane by its handle, over a page
    /// (beside it, on `edge`) or an empty pane (no `edge`): shows where it'd
    /// go, if it can
    func updateSplitDrop(_ info: NSDraggingInfo, over paneTabID: UUID, on edge: SplitEdge?) -> NSDragOperation {
        guard let item = splitDragItem(info), canSplit(item, over: paneTabID, on: edge) else {
            endSplitDrop(over: paneTabID)
            return []
        }
        splitViews.setDropTarget(SplitDropTarget(paneTabID: paneTabID, edge: edge))
        return .move
    }

    /// The drag left the pane, or ended
    func endSplitDrop(over paneTabID: UUID) {
        if splitViews.dropTarget?.paneTabID == paneTabID {
            splitViews.setDropTarget(nil)
        }
    }

    /// A tab dragged from the sidebar dropped on a page: it opens on `edge`
    /// of that page's pane, or in place of an empty pane, as the active tab.
    /// A pane dragged by its handle moves there.
    func performSplitDrop(_ info: NSDraggingInfo, over paneTabID: UUID, on edge: SplitEdge?) -> Bool {
        splitViews.setDropTarget(nil, animated: false)
        switch splitDragItem(info) {
        case .sidebarItem(let itemID)?:
            return split(sidebarItem: itemID, over: paneTabID, on: edge)
        case .pane(let tabID)?:
            guard canSplit(.pane(tabID), over: paneTabID, on: edge),
                  let tab = tabs.first(where: { $0.id == tabID }) else { return false }
            return split(tab, over: paneTabID, on: edge)
        case nil:
            return false
        }
    }

    /// A sidebar item's tab opens on `edge` of a pane, or in place of an
    /// empty pane (no `edge`), as the active tab
    @discardableResult
    private func split(sidebarItem itemID: UUID, over paneTabID: UUID, on edge: SplitEdge?) -> Bool {
        guard canSplit(sidebarItem: itemID, over: paneTabID, on: edge),
              let tab = openTab(forSidebarItem: itemID) else { return false }
        return split(tab, over: paneTabID, on: edge)
    }

    /// An open tab goes on `edge` of a pane (out of where it was, if it's
    /// in a split view), or in place of an empty pane (no `edge`), as the
    /// active tab
    @discardableResult
    private func split(_ tab: BrowserTab, over paneTabID: UUID, on edge: SplitEdge?) -> Bool {
        guard tab.id != paneTabID else { return false }
        let tabID = tab.id
        if let edge {
            guard splitViews.canAdd(tabID, beside: paneTabID) else { return false }
            splitViews.add(tabID, beside: paneTabID, on: edge)
        }
        if activeTabId == tabID {
            focusWebView(for: tabID)
        } else {
            switchToTab(tab)
        }
        sidebarManager?.selectionManager.syncSelectionWithActiveTab(activeTabId: tabID)
        if edge == nil {
            fill(emptyPane: paneTabID, with: tabID)
        }
        return true
    }

    // MARK: Split Tab, Remove from Split (a tab's menu in the sidebar)

    /// What Split Tab puts a tab beside: the active tab's page, on its
    /// right, or the active empty pane, in its place
    private var splitTabTarget: SplitDropTarget? {
        guard let activeTab else { return nil }
        if isEmptyPane(activeTab) {
            return SplitDropTarget(paneTabID: activeTab.id, edge: nil)
        }
        return activeTab.isEmpty ? nil : SplitDropTarget(paneTabID: activeTab.id, edge: .right)
    }

    /// Whether Split Tab has room for the sidebar item's tab where it'd go
    func canSplitTab(sidebarItem itemID: UUID) -> Bool {
        let tabID = openTabID(forSidebarItem: itemID)
        // A New Tab has no page to show in a pane
        if let tabID, tabs.first(where: { $0.id == tabID })?.isEmpty == true {
            return false
        }
        if let tabID, splitViews.isVisible(tabID) {
            let paneCount = splitViews.split(containing: tabID)?.root.tabIDs.count ?? 1
            return paneCount < SplitViewManager.maximumPanes
        }
        guard let target = splitTabTarget else { return true }
        return canSplit(sidebarItem: itemID, over: target.paneTabID, on: target.edge)
    }

    /// Split Tab: the tab opens beside the active one, on its right (or in
    /// place of the active empty pane). The tab on screen itself (or a pane
    /// beside it) gets a new empty pane on its right, as with ⌘D, and so
    /// does a tab with no page on screen to go beside.
    func splitTab(sidebarItem itemID: UUID) {
        if let tabID = openTabID(forSidebarItem: itemID), splitViews.isVisible(tabID),
           let tab = tabs.first(where: { $0.id == tabID }) {
            if tabID != activeTabId {
                activatePane(tab, focusingPage: true)
            }
            splitActiveTab(.horizontal)
        } else if let target = splitTabTarget {
            split(sidebarItem: itemID, over: target.paneTabID, on: target.edge)
        } else if let tab = openTab(forSidebarItem: itemID) {
            if tab.id != activeTabId {
                switchToTab(tab)
            }
            splitActiveTab(.horizontal)
        }
    }

    /// Whether the sidebar item's tab is in a split view
    func isInSplitView(sidebarItem itemID: UUID) -> Bool {
        openTabID(forSidebarItem: itemID).map(splitViews.contains) ?? false
    }

    /// Remove from Split: the tab leaves its split view and stays open. If
    /// it was the active tab, the pane beside it takes over, so what's on
    /// screen is the split view without it.
    func removeFromSplitView(sidebarItem itemID: UUID) {
        guard let tabID = openTabID(forSidebarItem: itemID) else { return }
        leaveSplitView(tabID)
    }

    // MARK: - Suspension

    /// Takes a background tab's web view down to free its memory. The tab
    /// keeps its place in the list and the sidebar; its web view records
    /// what it showed as it's torn down (TabWebViewCoordinator.tearDown) and
    /// the next one restores that when the tab is activated again.
    func suspendTab(_ tab: BrowserTab) {
        guard !tab.isSuspended, !splitViews.isVisible(tab.id),
              tabs.contains(where: { $0 === tab }) else { return }

        logDebug(.tabManagement, "Suspending background tab \(tab.id.uuidString.prefix(8))")
        objectWillChange.send()
        tab.markSuspended()

        // The page reloads when the tab comes back, so a saved match count
        // would be stale; the query, the open panel and any AI chat stay.
        // An unknown count shows the arrows, and the next step searches anew.
        if tab.findState?.findResult.hasResults == true {
            tab.findState?.findResult = FindResult(count: .unknown)
        }
        tab.findState?.isSearching = false
    }

    // MARK: - Focus Management

    /// Gives keyboard focus to the active tab's page: when the window opens,
    /// and back once the command palette or the find panel closes. A New Tab
    /// has no page to focus.
    func focusActiveWebView() {
        guard let tab = activeTab, !tab.isEmpty else { return }
        focusWebView(for: tab.id)
    }

    /// Moves keyboard focus into the tab's web view: right away if it
    /// exists, else once it does — a new or suspended tab gets its web view
    /// on the next render.
    private func focusWebView(for tabId: UUID) {
        if TabWebViewCoordinator.coordinator(for: tabId) != nil {
            NotificationCenter.default.post(
                name: NSNotification.Name("FocusWebView"),
                object: nil,
                userInfo: ["tabId": tabId.uuidString]
            )
        } else {
            attemptDelayedFocus(for: tabId, attempt: 1)
        }
    }

    /// Attempt to focus a WebView with retries if coordinator isn't ready
    private func attemptDelayedFocus(for tabId: UUID, attempt: Int) {
        let maxAttempts = 5
        let delays: [TimeInterval] = [0.05, 0.1, 0.15, 0.25, 0.4]
        
        guard attempt <= maxAttempts else {
            logWarning(.tabManagement, "Failed to focus WebView after \(maxAttempts) attempts for tab \(tabId.uuidString.prefix(8))")
            return
        }
        
        let delay = attempt <= delays.count ? delays[attempt - 1] : 0.4
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            
            // Verify tab is still active
            guard self.activeTabId == tabId else {
                logDebug(.tabManagement, "Tab \(tabId.uuidString.prefix(8)) no longer active, skipping focus")
                return
            }
            
            // Check if coordinator exists now
            if TabWebViewCoordinator.coordinator(for: tabId) != nil {
                logDebug(.tabManagement, "Focusing WebView for tab \(tabId.uuidString.prefix(8)) (delayed attempt \(attempt))")
                NotificationCenter.default.post(
                    name: NSNotification.Name("FocusWebView"),
                    object: nil,
                    userInfo: ["tabId": tabId.uuidString]
                )
            } else {
                // Coordinator still not ready, try again
                logDebug(.tabManagement, "Coordinator still not ready for tab \(tabId.uuidString.prefix(8)), retrying focus (attempt \(attempt))")
                self.attemptDelayedFocus(for: tabId, attempt: attempt + 1)
            }
        }
    }

} 
