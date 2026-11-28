import SwiftUI
import Combine
import AppKit

// MARK: - Section Configuration
enum CommandPaletteSectionType: String, CaseIterable {
    case update = "update"  // Restart to Update, once an update is ready
    case tabs = "tabs"
    case urlSuggestions = "urlSuggestions"
    case searchResults = "searchResults"  // Combined tabs + history when searching
    case directURL = "directURL"
    case searchEngines = "searchEngines"
    case googleSuggestions = "googleSuggestions"
    case tabActions = "tabActions"
    case subview = "subview"
}

// MARK: - Section Content Info
struct SectionInfo {
    let type: CommandPaletteSectionType
    let startIndex: Int
    let count: Int
}

// MARK: - Palette Tabs

/// A tab as the palette lists it — an open tab or an unloaded saved tab —
/// as a plain value holding what its row shows.
nonisolated struct PaletteTab: Identifiable, Equatable {
    /// The browser tab's ID, or the saved tab's for an unloaded saved tab.
    let id: UUID
    let url: String
    /// A saved tab's display title (its custom title, if it has one).
    let title: String
    /// The URL without scheme and "www.".
    let displayURL: String
    /// A saved tab's folder path, e.g. "News / Tech".
    let breadcrumb: String?
    let isSaved: Bool
}

/// A palette tab plus what searching and ordering it needs.
struct IndexedPaletteTab {
    let tab: PaletteTab
    let searchKey: FuzzySearch.Candidate
    /// The "/"-separated folder path searches match.
    let folderPath: String?
    /// An open tab, as opposed to an unloaded saved tab.
    let isOpen: Bool
    let createdAt: Date
    /// When an unloaded saved tab was last active; open tabs' is read live.
    let savedLastActiveAt: Date?
}

/// A Reading List item prepared for searching.
nonisolated struct IndexedReadingListItem {
    let item: ReadingListItem
    let cleanedURL: String
    let searchKey: FuzzySearch.Candidate
}

// MARK: - Combined Search Results
nonisolated enum SearchResult: Identifiable, Equatable {
    case tab(PaletteTab, score: Double)
    case history(HistoryEntryData, score: Double)
    case readingList(ReadingListItem, score: Double)
    /// A popular site not in history yet, by host (see `PopularSites`).
    case site(String)

    var id: String {
        switch self {
        case .tab(let tab, _):
            return "tab-\(tab.id.uuidString)"
        case .history(let entry, _):
            return "history-\(entry.id.uuidString)"
        case .readingList(let item, _):
            return "readinglist-\(item.id.uuidString)"
        case .site(let host):
            return "site-\(host)"
        }
    }

    var score: Double {
        switch self {
        case .tab(_, let score), .history(_, let score), .readingList(_, let score):
            return score
        case .site:
            // Placed by `rank`, not by score.
            return 0
        }
    }

    var url: String {
        switch self {
        case .tab(let tab, _):
            return tab.url
        case .history(let entry, _):
            return entry.url
        case .readingList(let item, _):
            return item.url
        case .site(let host):
            return "https://\(host)"
        }
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Ranking

/// Ranks a query's matches among tabs, history and Reading List items.
/// Pure, so it runs off the main thread.
nonisolated enum CommandPaletteSearch {
    /// Calculate combined score based on search relevance and visit frequency
    static func combinedScore(fuzzyScore: Double, visitCount: Int) -> Double {
        // Normalize visit count using logarithmic scale to prevent dominance
        // Most sites have visit counts from 1-100, some popular ones go to 1000+
        let normalizedVisitCount = visitCount > 0 ? log(Double(visitCount) + 1) / log(1001) : 0

        // Weighted combination: 70% search relevance, 30% visit frequency
        return 0.7 * fuzzyScore + 0.3 * normalizedVisitCount
    }

    /// The top `limit` results, best first; nil if the task was cancelled.
    /// `tabs` come in recency order, which ties keep. A popular `site` the
    /// typed text is the start of leads them, as a visited site would (see
    /// `placeSite`).
    static func rank(
        query: FuzzySearch.Query,
        tabs: [IndexedPaletteTab],
        history: [HistoryEntryData],
        readingList: [IndexedReadingListItem],
        site: (host: String, prefix: String)?,
        limit: Int
    ) -> [SearchResult]? {
        var scoredResults: [SearchResult] = []
        var seenURLs: Set<String> = []

        // Process tabs first (they take priority over history for same URLs)
        for (index, entry) in tabs.enumerated() {
            if index % 64 == 0 && Task.isCancelled { return nil }
            guard let fuzzyScore = FuzzySearch.score(query, entry.searchKey) else { continue }
            // For tabs, we don't have visit count, so use a baseline score
            scoredResults.append(.tab(entry.tab, score: combinedScore(fuzzyScore: fuzzyScore, visitCount: 1)))
            // Normalize URL for deduplication to prevent duplicates like finn.no and https://finn.no
            seenURLs.insert(entry.tab.displayURL)
        }

        // History items come already filtered by the store; they get a high
        // base relevance and are ranked by visit count (skip duplicates).
        for historyItem in history {
            let normalizedURL = URLUtilities.cleanURL(historyItem.url)
            guard !seenURLs.contains(normalizedURL) else { continue }
            scoredResults.append(.history(historyItem, score: combinedScore(fuzzyScore: 0.8, visitCount: historyItem.visitCount)))
            seenURLs.insert(normalizedURL)
        }

        // Process Safari Reading List items (skip duplicates).
        // Apply a small score penalty so they consistently rank below open/saved
        // tabs of similar fuzzy relevance — tabs are usually what the user wants.
        for (index, entry) in readingList.enumerated() {
            if index % 64 == 0 && Task.isCancelled { return nil }
            guard !seenURLs.contains(entry.cleanedURL),
                  let fuzzyScore = FuzzySearch.score(query, entry.searchKey) else { continue }
            let baseScore = combinedScore(fuzzyScore: fuzzyScore, visitCount: 1)
            scoredResults.append(.readingList(entry.item, score: baseScore * 0.7))
            seenURLs.insert(entry.cleanedURL)
        }

        // Sort by combined score (highest first), ties in the order above, and limit results
        let order = scoredResults.indices.sorted { lhs, rhs in
            let lhsScore = scoredResults[lhs].score
            let rhsScore = scoredResults[rhs].score
            return lhsScore != rhsScore ? lhsScore > rhsScore : lhs < rhs
        }
        var results = order.prefix(limit).map { scoredResults[$0] }
        if let site = site {
            placeSite(site, in: &results, seenURLs: seenURLs)
            results = Array(results.prefix(limit))
        }
        return results
    }

    /// Puts the site first, unless it's already there as the user's own tab
    /// or history entry for its front page, or is all that's typed (the
    /// Navigate row opens it). The top result goes before it if it's the
    /// user's own for a host that starts with the typed text too.
    private static func placeSite(_ site: (host: String, prefix: String), in results: inout [SearchResult], seenURLs: Set<String>) {
        guard site.host != site.prefix, !seenURLs.contains(site.host) else { return }
        let index = results.first.map { host(of: $0.url).hasPrefix(site.prefix) ? 1 : 0 } ?? 0
        results.insert(.site(site.host), at: index)
    }

    /// The URL's host, without scheme and "www.".
    private static func host(of url: String) -> String {
        let cleaned = URLUtilities.cleanURL(url).lowercased()
        return String(cleaned.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" })
    }
}

/// Manages the state and business logic for the command palette.
///
/// One instance lives as long as the window (ContentView holds it), so the
/// index of tabs it searches survives between opens and is only brought up
/// to date when the palette opens. Searches run off the main thread and
/// publish their rows once per query.
@MainActor
class CommandPaletteState: ObservableObject {
    // MARK: - Published Properties
    @Published var userTypedText: String = "" // Track what the user actually typed
    @Published var selectedTabIndex = 0
    @Published var filteredTabs: [PaletteTab] = []
    @Published var urlSuggestions: [HistoryEntryData] = []
    @Published var searchEngineSuggestions: [SiteShortcut] = []
    @Published var googleSuggestions: [String] = []
    
    /// The query the rows are for. Trails `userTypedText` while a search is
    /// in flight, so the rows change over in one go when its results land.
    @Published private(set) var displayedQuery: String = ""
    
    // New suggestion types
    @Published var directURLSuggestion: String? = nil
    /// The Navigate row's URL is a popular site's (see `PopularSites`), so
    /// it shows the site's icon.
    @Published var directURLIsPopularSite = false
    
    // Combined search results (tabs + history with unified scoring)
    @Published var combinedSearchResults: [SearchResult] = []
    
    /// The update ready to install as the palette opened (`AppUpdater`),
    /// for the Restart to Update row. Taken then, so the rows don't change
    /// under the selection.
    @Published private(set) var readyUpdate: AppUpdater.Update?

    // MARK: - Prefix Mode State
    @Published var isInPrefixMode: Bool = false
    /// The site shortcut whose keyword was typed: what's typed now searches its site.
    @Published var activeShortcut: SiteShortcut? = nil

    // MARK: - Mode (tab actions, drill-down subviews)
    @Published var mode: CommandPaletteMode = .normal {
        didSet {
            guard mode != oldValue else { return }
            selectedTabIndex = 0
            switch mode {
            case .normal:
                tabActions = []
                subviewRows = []
            case .tabActions:
                rebuildTabActions()
                subviewRows = []
            case .subview:
                tabActions = []
                rebuildSubviewRows()
            }
        }
    }
    @Published var tabActions: [TabAction] = []
    @Published var subviewRows: [PaletteSubviewRow] = []
    
    // MARK: - URL Pre-fill State
    @Published var hasPrefilledURL: Bool = false
    @Published var prefilledURL: String = ""
    
    // MARK: - User Input State
    @Published var isUserTyping: Bool = false // Track if user is actively typing vs navigating
    
    // MARK: - Lazy Loading State
    /// How much of the tab list is shown; it grows as the selection nears its end.
    private var visibleItemLimit: Int = 10
    /// The tab list grows once the selection is this close to its last row,
    /// by `loadMoreCount`: early enough that a held arrow key never reaches it.
    private let loadMoreDistance: Int = 20
    private let loadMoreCount: Int = 50

    // MARK: - Visibility State
    private var isVisible = false
    /// Numbers each open, so a late close() from an earlier palette view
    /// can't clear a newer one.
    private var session: UInt = 0

    // MARK: - Index

    /// Every tab the palette lists, in the order it lists them with nothing
    /// typed: the active tab first, then the most recently used.
    private var indexedTabs: [IndexedPaletteTab] = []
    /// Unloaded saved tabs are only re-read after the sidebar changed.
    private var unloadedTabsAreStale = true
    private var readingListIndex: [IndexedReadingListItem] = []
    private var readingListIndexIsStale = true

    // MARK: - Search State

    private var searchTask: Task<Void, Never>?
    /// The query being searched, until its results land.
    private var pendingQuery: String?
    /// A Return pressed before the rows for its text were in: carried out
    /// once they land, even if that text has to be searched again meanwhile.
    private var pendingSubmit: (query: String, commandPressed: Bool)?
    /// Coalesces keystrokes that come faster than this.
    private static let searchDebounceNanoseconds: UInt64 = 30_000_000
    
    // MARK: - Computed Properties
    
    /// The text to display in the text field - shows user input when typing, selected item when navigating
    var displayText: String {
        // Tab actions and subview modes treat the field as a filter input only.
        if !mode.isNormal {
            return userTypedText
        }

        if isInPrefixMode {
            return userTypedText // In prefix mode, always show what user typed
        } else {
            // If user is actively typing, show their input
            if isUserTyping {
                return userTypedText
            }

            // In new tab mode, always show userTypedText (should be empty) regardless of selection
            if let tabManager = tabManager, tabManager.isNewTabMode {
                return userTypedText
            }

            // If we have a valid selection and user is not typing, show the text from the selected item
            if selectedTabIndex >= 0 && selectedTabIndex < getTotalSuggestionCount() {
                return getDisplayTextForSelectedItem()
            } else {
                // No valid selection, show what user typed
                return userTypedText
            }
        }
    }
    
    /// The placeholder text for the search field
    var placeholderText: String {
        switch mode {
        case .tabActions:
            return "Tab actions..."
        case .subview(let sv):
            switch sv.id {
            case .folderPicker(let intent):
                return intent == .save ? "Save to..." : "Move to..."
            case .explore:
                return "Explore with AI..."
            }
        case .normal:
            if isInPrefixMode, let shortcut = activeShortcut {
                return "Search \(shortcut.name)..."
            } else if let tabManager, tabManager.isPickingSplitPane {
                return "Search or enter a site to open in this pane..."
            } else if let tabManager, tabManager.isNewTabMode, tabManager.isNewTabPrivate {
                return "Search or enter a site in a private tab..."
            } else {
                return "Search tabs, history, or web..."
            }
        }
    }
    
    // MARK: - Private Properties
    private weak var tabManager: TabManager?
    private weak var observedSidebarManager: SidebarManager?
    private var sidebarSubscription: AnyCancellable?
    private var readingListSubscription: AnyCancellable?

    // MARK: - Initialization
    init(tabManager: TabManager) {
        self.tabManager = tabManager

        readingListSubscription = SafariReadingListManager.shared.$items
            .sink { [weak self] _ in
                self?.readingListIndexIsStale = true

                // Keep the Save/Remove from Reading List action title accurate while the palette is open.
                Task { @MainActor in
                    guard let self = self, self.mode == .tabActions else { return }
                    self.rebuildTabActions()
                }
            }
    }

    // MARK: - Opening and Closing

    /// Called when the palette appears: brings the tab index up to date and
    /// starts over in the requested mode. Returns the session to close.
    @discardableResult
    func open() -> UInt {
        session &+= 1
        isVisible = true
        readyUpdate = AppUpdater.shared.readyUpdate
        refreshTabIndex()

        // The mode asked for (⌘K's tab actions)
        mode = tabManager?.requestedPaletteMode ?? .normal

        reset()
        return session
    }

    /// Called when the palette disappears. This state outlives the palette
    /// view, so it's cleared here for the next open; the index is kept.
    func close(session closedSession: UInt) {
        guard closedSession == session else { return }
        isVisible = false
        cancelSearch()
        pendingSubmit = nil

        // Cancel any pending Google suggestions requests
        SearchSuggestionsService.shared.cancelAllRequests()

        userTypedText = ""
        hasPrefilledURL = false
        prefilledURL = ""
        isUserTyping = false
        isInPrefixMode = false
        activeShortcut = nil
        mode = .normal
        clearRows()
        readyUpdate = nil
        selectedTabIndex = 0
        visibleItemLimit = 10
    }

    /// Tabs were closed, unloaded or removed, or a history entry deleted,
    /// while the palette is open: refresh the rows for the current text.
    func refreshAfterTabsChanged() {
        guard isVisible else { return }
        refreshTabIndex()

        switch mode {
        case .normal:
            let query = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            runQuery(query, debounce: false)
            if !isInPrefixMode && query.isEmpty {
                selectActiveTab()
            }
        case .tabActions:
            rebuildTabActions()
        case .subview:
            break
        }

        // Ensure selectedTabIndex is within bounds after tab changes
        let itemCount = getTotalSuggestionCount()
        if selectedTabIndex >= itemCount {
            selectedTabIndex = max(0, itemCount - 1)
        }
    }

    private func reset() {
        userTypedText = ""
        selectedTabIndex = 0
        isUserTyping = false

        // Reset lazy loading state
        visibleItemLimit = 10

        // Clear pre-filled URL state
        hasPrefilledURL = false
        prefilledURL = ""

        // Exit prefix mode
        isInPrefixMode = false
        activeShortcut = nil

        cancelSearch()
        clearRows()

        guard let tabManager = tabManager else { return }

        // Tab actions / subview modes own their row arrays; skip the navigation-mode setup.
        if !mode.isNormal {
            switch mode {
            case .tabActions:
                rebuildTabActions()
            case .subview:
                rebuildSubviewRows()
            case .normal:
                break
            }
            selectedTabIndex = getTotalSuggestionCount() > 0 ? 0 : -1
            return
        }

        if !tabManager.isNewTabMode, let activeTab = tabManager.activeTab, !activeTab.isEmpty {
            // For navigation mode, pre-fill the current tab URL
            setPrefilledURL(activeTab.url)
        } else {
            showTabList()
            if tabManager.isNewTabMode {
                // Ensure selection is set to first item if there are any suggestions
                selectedTabIndex = getTotalSuggestionCount() > 0 ? 0 : -1
            } else {
                selectActiveTab()
            }
        }
    }
    
    // MARK: - Tab Index

    /// Brings the tab index up to date and orders it. Open tabs are re-read
    /// every time (titles and URLs change without notice); unloaded saved
    /// tabs only after the sidebar changed. Entries whose text is unchanged
    /// keep their prepared search keys.
    private func refreshTabIndex() {
        guard let tabManager = tabManager else {
            indexedTabs = []
            return
        }
        let sidebarManager = tabManager.sidebarManager
        observeSidebar(sidebarManager)

        // Entries to reuse: all of them after a sidebar change, otherwise just
        // the open tabs (unloaded ones are carried over as they are).
        var previousEntries: [UUID: IndexedPaletteTab] = [:]
        for indexed in indexedTabs where unloadedTabsAreStale || indexed.isOpen {
            previousEntries[indexed.tab.id] = indexed
        }

        let structure = sidebarManager?.sidebarStructure
        let browserToSidebar = sidebarManager?.browserToSidebarTabMapping ?? [:]

        // Folder paths like "News/Tech", built once per folder.
        var folderPaths: [UUID: String] = [:]
        func folderPath(of folderID: UUID?) -> String? {
            guard let folderID = folderID, let structure = structure else { return nil }
            if let cached = folderPaths[folderID] {
                return cached.isEmpty ? nil : cached
            }
            var pathComponents: [String] = []
            var currentFolderID: UUID? = folderID
            var seen: Set<UUID> = []
            // Cycle protection: a corrupt structure can have a parent loop.
            while let currentID = currentFolderID,
                  seen.insert(currentID).inserted,
                  let folder = structure.folders[currentID] {
                pathComponents.insert(folder.displayTitle, at: 0) // Insert at beginning to build path from root
                currentFolderID = folder.parentID
            }
            let path = pathComponents.joined(separator: "/")
            folderPaths[folderID] = path
            return path.isEmpty ? nil : path
        }

        func makeEntry(id: UUID, url: String, title: String, folderPath: String?, isSaved: Bool, isOpen: Bool, createdAt: Date, savedLastActiveAt: Date?) -> IndexedPaletteTab {
            if let previous = previousEntries[id],
               previous.tab.url == url,
               previous.tab.title == title,
               previous.folderPath == folderPath,
               previous.tab.isSaved == isSaved {
                return IndexedPaletteTab(
                    tab: previous.tab,
                    searchKey: previous.searchKey,
                    folderPath: folderPath,
                    isOpen: isOpen,
                    createdAt: createdAt,
                    savedLastActiveAt: savedLastActiveAt
                )
            }
            let breadcrumb = folderPath.map { $0.split(separator: "/").joined(separator: " / ") }
            let tab = PaletteTab(
                id: id,
                url: url,
                title: title,
                displayURL: URLUtilities.cleanURL(url),
                breadcrumb: breadcrumb?.isEmpty == false ? breadcrumb : nil,
                isSaved: isSaved
            )
            return IndexedPaletteTab(
                tab: tab,
                searchKey: FuzzySearch.Candidate(displayTitle: title, url: url, breadcrumb: folderPath),
                folderPath: folderPath,
                isOpen: isOpen,
                createdAt: createdAt,
                savedLastActiveAt: savedLastActiveAt
            )
        }

        var entries: [IndexedPaletteTab] = []
        entries.reserveCapacity(indexedTabs.count)
        var listedIDs: Set<UUID> = []

        // Open tabs, saved or not: a saved tab's page maps to it. Not a
        // locked private tab: nothing of it shows (PrivateTabLock)
        for browserTab in tabManager.tabs where !browserTab.isEmpty && !browserTab.isLocked {
            let sidebarTab = browserToSidebar[browserTab.id].flatMap { structure?.tabs[$0] }
            entries.append(makeEntry(
                id: browserTab.id,
                url: browserTab.url,
                title: sidebarTab?.displayTitle ?? browserTab.title, // Custom title if it exists
                folderPath: folderPath(of: sidebarTab?.parentID),
                isSaved: sidebarTab != nil,
                isOpen: true,
                createdAt: browserTab.createdAt,
                savedLastActiveAt: nil
            ))
            listedIDs.insert(browserTab.id)
        }

        // Saved tabs with no page in this window (unloaded, or open in
        // other windows only): picked, they open here.
        if let sidebarManager = sidebarManager, let structure = structure, !sidebarManager.isInitializing {
            if unloadedTabsAreStale {
                for (sidebarTabID, sidebarTab) in structure.tabs
                where !sidebarManager.isOpenHere(sidebarTabID) && !sidebarTab.isEmpty && !listedIDs.contains(sidebarTabID) {
                    entries.append(makeEntry(
                        id: sidebarTabID,
                        url: sidebarTab.url,
                        title: sidebarTab.displayTitle,
                        folderPath: folderPath(of: sidebarTab.parentID),
                        isSaved: true,
                        isOpen: false,
                        createdAt: sidebarTab.createdAt,
                        savedLastActiveAt: sidebarTab.lastActiveAt
                    ))
                }
                unloadedTabsAreStale = false
            } else {
                entries.append(contentsOf: indexedTabs.filter {
                    !$0.isOpen && !listedIDs.contains($0.tab.id) && !sidebarManager.isOpenHere($0.tab.id)
                })
            }
        }

        indexedTabs = rankTabs(entries, tabManager: tabManager)
    }

    /// Marks the unloaded saved tabs stale whenever the sidebar changes.
    private func observeSidebar(_ sidebarManager: SidebarManager?) {
        guard let sidebarManager = sidebarManager, sidebarManager !== observedSidebarManager else { return }
        observedSidebarManager = sidebarManager
        unloadedTabsAreStale = true
        sidebarSubscription = sidebarManager.sidebarStructurePublisher.sink { [weak self] _ in
            self?.unloadedTabsAreStale = true
        }
    }
    
    /// Orders tabs the way the palette lists them with nothing typed: the
    /// active tab first, then by when each was last active, then by position
    /// in the sidebar's tab history, then newest first. The keys are looked
    /// up once per tab rather than in every comparison.
    private func rankTabs(_ entries: [IndexedPaletteTab], tabManager: TabManager) -> [IndexedPaletteTab] {
        struct RankedTab {
            let entry: IndexedPaletteTab
            let lastActive: Date
            let historyPosition: Int?
        }

        let sidebarManager = tabManager.sidebarManager
        let browserToSidebar = sidebarManager?.browserToSidebarTabMapping ?? [:]
        let activeTabId = tabManager.activeTabId
        let activeSidebarTabId = activeTabId.flatMap { browserToSidebar[$0] }
        var openTabsLastActive: [UUID: Date] = [:]
        for tab in tabManager.tabs {
            openTabsLastActive[tab.id] = tab.lastActiveAt
        }
        let activity = TabActivityManager.shared

        var activeEntry: IndexedPaletteTab?
        var rankedTabs: [RankedTab] = []
        rankedTabs.reserveCapacity(entries.count)
        for entry in entries {
            let id = entry.tab.id
            // The active tab, or the saved tab it was loaded from
            if activeEntry == nil, let activeTabId = activeTabId, id == activeTabId || id == activeSidebarTabId {
                activeEntry = entry
                continue
            }

            // Activity is tracked under the sidebar tab's ID for open saved tabs
            let trackedID = browserToSidebar[id] ?? id
            let fallback: Date
            if entry.isOpen {
                fallback = openTabsLastActive[id] ?? .distantPast
            } else {
                let ownActivity = trackedID == id ? nil : activity.getLastActiveTime(for: id)
                fallback = ownActivity ?? entry.savedLastActiveAt ?? .distantPast
            }
            rankedTabs.append(RankedTab(
                entry: entry,
                lastActive: activity.getLastActiveTime(for: trackedID) ?? fallback,
                historyPosition: sidebarManager?.selectionManager.getTabHistoryPosition(trackedID)
            ))
        }

        let usesTabHistory = sidebarManager != nil
        rankedTabs.sort { tab1, tab2 in
            if tab1.lastActive != tab2.lastActive {
                return tab1.lastActive > tab2.lastActive
            }

            // If activity times are the same, fall back to in-memory history
            if usesTabHistory {
                switch (tab1.historyPosition, tab2.historyPosition) {
                case let (index1?, index2?):
                    return index1 < index2  // More recent tabs (lower index) come first
                case (.some, nil):
                    return true  // tab1 is in history, tab2 is not
                case (nil, .some):
                    return false  // tab2 is in history, tab1 is not
                case (nil, nil):
                    break
                }
            }

            // Final fallback to creation date
            return tab1.entry.createdAt > tab2.entry.createdAt
        }

        var result: [IndexedPaletteTab] = []
        result.reserveCapacity(entries.count)
        if let activeEntry = activeEntry {
            result.append(activeEntry)
        }
        result.append(contentsOf: rankedTabs.map { $0.entry })
        return result
    }

    private func refreshReadingListIndexIfNeeded() {
        guard readingListIndexIsStale else { return }
        readingListIndexIsStale = false
        readingListIndex = SafariReadingListManager.shared.items.map { item in
            IndexedReadingListItem(
                item: item,
                cleanedURL: URLUtilities.cleanURL(item.url),
                searchKey: FuzzySearch.Candidate(displayTitle: item.title, url: item.url, breadcrumb: nil)
            )
        }
    }

    // MARK: - Rows

    /// The rows with nothing typed: tabs, most recently used first.
    private func showTabList() {
        displayedQuery = ""
        // In prefix mode, don't show any tabs
        filteredTabs = isInPrefixMode ? [] : indexedTabs.prefix(visibleItemLimit).map { $0.tab }
        combinedSearchResults = []
        urlSuggestions = []
        directURLSuggestion = nil
        searchEngineSuggestions = []
        googleSuggestions = []
    }

    private func clearRows() {
        displayedQuery = ""
        filteredTabs = []
        combinedSearchResults = []
        urlSuggestions = []
        directURLSuggestion = nil
        searchEngineSuggestions = []
        googleSuggestions = []
    }

    private func selectActiveTab() {
        guard let tabManager = tabManager,
              let activeTabId = tabManager.activeTabId else { return }

        // The active tab's row, or that of the saved tab it was loaded from
        let activeSidebarTabId = tabManager.sidebarManager?.browserToSidebarTabMapping[activeTabId]
        guard let row = filteredTabs.firstIndex(where: { $0.id == activeTabId || $0.id == activeSidebarTabId }) else {
            selectedTabIndex = 0
            return
        }
        // Below Restart to Update, if it's there
        let tabsStart = calculateSectionInfos().first { $0.type == .tabs }?.startIndex ?? 0
        selectedTabIndex = tabsStart + row
    }

    /// Keeps the selection on a row: the first while typing (as when results
    /// came with every keystroke), otherwise where it was if still in range.
    private func updateSelectionForNewRows() {
        let totalSuggestions = getTotalSuggestionCount()
        if isUserTyping {
            // A shortcut with nothing typed after it opens its site on Return
            let opensSite = isInPrefixMode && displayedQuery.isEmpty
            selectedTabIndex = totalSuggestions > 0 && !opensSite ? 0 : -1
        } else if totalSuggestions == 0 {
            selectedTabIndex = -1
        } else if selectedTabIndex < 0 {
            selectedTabIndex = 0
        } else if selectedTabIndex >= totalSuggestions {
            selectedTabIndex = totalSuggestions - 1
        }
    }

    // MARK: - Search

    /// Shows the rows for `query`: tabs right away when it's empty, otherwise
    /// once it's been searched. With `thenSubmit`, Return is handled after
    /// the rows land.
    private func runQuery(_ query: String, debounce: Bool, thenSubmit commandPressed: Bool? = nil) {
        cancelSearch()

        // A refresh of the same text (a tab closed meanwhile, say) keeps a
        // waiting Return; other text drops it.
        if let commandPressed = commandPressed {
            pendingSubmit = (query, commandPressed)
        } else if pendingSubmit?.query != query {
            pendingSubmit = nil
        }

        if !isInPrefixMode && query.isEmpty {
            showTabList()
            if isUserTyping {
                selectedTabIndex = getTotalSuggestionCount() > 0 ? 0 : -1
            }
            submitPendingReturn()
            return
        }

        pendingQuery = query
        let inPrefixMode = isInPrefixMode
        // When actively searching, show more results
        let limit = isUserTyping ? (inPrefixMode ? 20 : 50) : visibleItemLimit
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: CommandPaletteState.searchDebounceNanoseconds)
            }
            guard !Task.isCancelled, let self = self else { return }

            let landed: Bool
            if inPrefixMode {
                landed = await self.loadPrefixSuggestions(for: query, limit: limit)
            } else {
                landed = await self.search(for: query, limit: limit)
            }
            if landed {
                self.submitPendingReturn()
            }
        }
    }

    private func submitPendingReturn() {
        guard let submit = pendingSubmit else { return }
        pendingSubmit = nil
        submitSelection(commandPressed: submit.commandPressed)
    }
    
    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        pendingQuery = nil
    }

    /// Searches tabs, history and the Reading List for `query` and shows the
    /// results with the Navigate and search-engine rows. Returns false if
    /// cancelled by a newer query.
    private func search(for query: String, limit: Int) async -> Bool {
        let directURL = makeDirectURLSuggestion(for: query)
        // If we have a direct URL (including deep links), don't show search suggestions
        if directURL == nil {
            fetchGoogleSuggestions(for: query)
        }

        let history = await historySuggestions { await $0.getURLSuggestions(for: query) }
        guard !Task.isCancelled, let fuzzyQuery = FuzzySearch.Query(query) else { return false }

        refreshReadingListIndexIfNeeded()
        let tabs = indexedTabs
        let readingList = readingListIndex
        let ranking = Task.detached(priority: .userInitiated) { () -> (results: [SearchResult], siteIsTyped: Bool)? in
            let site = PopularSites.site(matching: query)
            guard let results = CommandPaletteSearch.rank(query: fuzzyQuery, tabs: tabs, history: history, readingList: readingList, site: site, limit: limit) else { return nil }
            return (results, site.map { $0.host == $0.prefix } ?? false)
        }
        let ranked = await withTaskCancellationHandler {
            await ranking.value
        } onCancel: {
            ranking.cancel()
        }
        guard let ranked = ranked, !Task.isCancelled else { return false }

        pendingQuery = nil
        displayedQuery = query
        combinedSearchResults = ranked.results
        directURLSuggestion = directURL
        directURLIsPopularSite = directURL != nil && ranked.siteIsTyped
        searchEngineSuggestions = directURL == nil
            ? SiteShortcuts.search(in: query).map { [$0.shortcut] } ?? []
            : []
        clearGoogleSuggestionsIfNeeded(for: query, hasDirectURL: directURL != nil)
        filteredTabs = []
        urlSuggestions = []
        updateSelectionForNewRows()
        return true
    }

    /// Prefix mode lists the shortcut's earlier searches for the query
    /// instead of tabs. Returns false if cancelled by a newer query.
    private func loadPrefixSuggestions(for query: String, limit: Int) async -> Bool {
        // Suggestions for the words, searched on the shortcut's site
        fetchGoogleSuggestions(for: query)

        let history = await shortcutSearches(matching: query, limit: limit)
        guard !Task.isCancelled else { return false }

        pendingQuery = nil
        displayedQuery = query
        // For prefix mode, deduplicate suggestions by URL and limit results
        urlSuggestions = Array(deduplicateURLSuggestions(history).prefix(limit))
        filteredTabs = []
        combinedSearchResults = []
        directURLSuggestion = nil
        searchEngineSuggestions = []
        clearGoogleSuggestionsIfNeeded(for: query, hasDirectURL: false)
        updateSelectionForNewRows()
        return true
    }

    /// Earlier searches on the active shortcut's site whose words contain
    /// `query`, newest words once each, titled with the words.
    private func shortcutSearches(matching query: String, limit: Int) async -> [HistoryEntryData] {
        guard let shortcut = activeShortcut else { return [] }
        // The site's search pages with these words in them, then those
        // whose words read back from the address contain the query
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let entries = await historySuggestions {
            await $0.getSiteSearchSuggestions(prefix: shortcut.searchPrefix, words: words, limit: 200)
        }
        var seen = Set<String>()
        let searches = entries.compactMap { entry -> HistoryEntryData? in
            guard let words = shortcut.query(in: entry.url),
                  query.isEmpty || words.localizedCaseInsensitiveContains(query),
                  seen.insert(words.lowercased()).inserted else { return nil }
            return HistoryEntryData(id: entry.id, url: entry.url, title: words, visitedAt: entry.visitedAt, visitCount: entry.visitCount)
        }
        return Array(searches.prefix(limit))
    }

    /// What `fetch` finds: typed-in history in new-tab mode, browsing
    /// history otherwise. Browsing history is read on the queue its writes
    /// and maintenance use; if that's busy (the one-time cleanup after an
    /// update, say), the results go ahead without it rather than wait.
    private func historySuggestions(_ fetch: @escaping @MainActor (TabManager) async -> [HistoryEntryData]) async -> [HistoryEntryData] {
        guard let tabManager = tabManager else { return [] }
        let maxWait = Self.historyWaitNanoseconds
        // Unstructured tasks, so a late fetch is left to finish on its own
        // instead of being waited for (a task group waits for every child).
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            Task {
                let entries = await fetch(tabManager)
                answer.resume(returning: entries)
            }
            Task {
                try? await Task.sleep(nanoseconds: maxWait)
                answer.resume(returning: [])
            }
        }
    }

    private static let historyWaitNanoseconds: UInt64 = 150_000_000

    /// Switches the rows to `query` with what's known before searching: the
    /// Navigate and search-engine rows. The results follow.
    private func showSearchPlaceholder(for query: String) {
        let directURL = makeDirectURLSuggestion(for: query)
        displayedQuery = query
        directURLSuggestion = directURL
        directURLIsPopularSite = false
        searchEngineSuggestions = directURL == nil
            ? SiteShortcuts.search(in: query).map { [$0.shortcut] } ?? []
            : []
        filteredTabs = []
        combinedSearchResults = []
        urlSuggestions = []
        googleSuggestions = []
    }

    /// Fetches web search suggestions; they're shown when they arrive if the
    /// query is still what's typed.
    private func fetchGoogleSuggestions(for query: String) {
        guard query.count >= 2 else { return }

        // Note: The exact search text row is rendered directly from displayedQuery in the UI
        // googleSuggestions only contains API suggestions (not the exact text)
        SearchSuggestionsService.shared.fetchSuggestions(for: query) { [weak self] suggestions in
            DispatchQueue.main.async {
                // Ensure self still exists, command palette is still visible, and the search text hasn't changed
                guard let self = self,
                      let tabManager = self.tabManager,
                      tabManager.showCommandPalette,
                      self.userTypedText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }

                // Filter out the exact search text from suggestions to avoid duplicates
                let filteredSuggestions = suggestions.filter { $0.lowercased() != query.lowercased() }

                // Store only API suggestions (exact text is rendered directly from displayedQuery)
                self.googleSuggestions = Array(filteredSuggestions.prefix(5))
            }
        }
    }

    /// Drops web suggestions that can't apply to `query`.
    private func clearGoogleSuggestionsIfNeeded(for query: String, hasDirectURL: Bool) {
        if hasDirectURL {
            googleSuggestions = []
        } else if query.count < 2 {
            googleSuggestions = []
            // Reset exhausted prefix tracking when search is cleared
            SearchSuggestionsService.shared.resetExhaustedPrefix()
        }
    }
    
    // MARK: - Text Change Handling
    
    /// Handle text input and manage prefix mode transitions
    func handleTextInput(_ newText: String) {
        // In tab-actions / subview modes the search field is a filter, not a navigation input.
        if !mode.isNormal {
            isUserTyping = true
            userTypedText = newText
            switch mode {
            case .tabActions:
                rebuildTabActions()
                selectedTabIndex = tabActions.isEmpty ? -1 : 0
            case .subview:
                rebuildSubviewRows()
                selectedTabIndex = subviewRows.isEmpty ? -1 : 0
            case .normal:
                break
            }
            return
        }

        // Only mark as typing if user is actually changing text, not if it's just setting pre-filled URL
        if !hasPrefilledURL || newText != prefilledURL {
            isUserTyping = true

            // Clear pre-filled URL state if user is typing something different
            if hasPrefilledURL && newText != prefilledURL {
                hasPrefilledURL = false
                prefilledURL = ""
            }
        }

        if isInPrefixMode {
            if newText.isEmpty {
                // Don't exit here - let the backspace handler in CustomTextField handle it
                userTypedText = newText
            } else {
                // User typed something - update text
                userTypedText = newText
            }
        } else {
            // Check for prefix activation only if:
            // 1. The new text ends with a space
            // 2. The previous text didn't end with a space (meaning a space was just added)
            // 3. The text before the space is exactly a valid prefix
            if newText.hasSuffix(" ") && !userTypedText.hasSuffix(" ") {
                let textBeforeSpace = String(newText.dropLast())

                // Only activate prefix mode if the text before space is EXACTLY a keyword
                // This prevents activation when typing spaces in the middle of longer text
                if let shortcut = SiteShortcuts.shortcut(forKeyword: textBeforeSpace) {
                    enterPrefixMode(with: shortcut)
                    return
                }
            }

            // No prefix detected or not checking for prefix, just update search text normally
            userTypedText = newText
        }
    }
    
    /// Enter prefix search mode
    private func enterPrefixMode(with shortcut: SiteShortcut) {
        logDebug(.commandPalette, "Entering prefix mode with shortcut: \(shortcut.keyword)")
        isInPrefixMode = true
        activeShortcut = shortcut
        userTypedText = "" // Clear the text, ready for query input

        // The engine's history replaces the rows (filled in once it's read)
        clearRows()
        runQuery("", debounce: false)
    }
    
    /// Exit prefix search mode: the keyword goes back to being typed text,
    /// so a search that only started with one goes on as typed.
    func exitPrefixMode() {
        logDebug(.commandPalette, "Exiting prefix mode")
        let keyword = activeShortcut?.keyword ?? ""
        isInPrefixMode = false
        activeShortcut = nil
        userTypedText = keyword
        isUserTyping = !keyword.isEmpty
        
        // Restore normal command palette contents
        runQuery(keyword, debounce: false)
        
        // Reset selection to first item if we have content
        if getTotalSuggestionCount() > 0 {
            selectedTabIndex = 0
        } else {
            selectedTabIndex = -1
        }
    }
    
    func handleSearchTextChange(_ newValue: String) {
        // Tab actions / subview modes filter their own rows as the text changes.
        guard mode.isNormal else { return }

        let trimmedSearchText = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already shown or being searched (e.g. a pre-filled URL).
        guard trimmedSearchText != (pendingQuery ?? displayedQuery) else { return }

        // Only reset selection if user is actively typing (not when navigating);
        // it's reset again when the results land.
        if isUserTyping {
            selectedTabIndex = getTotalSuggestionCount() > 0 ? 0 : -1

            // When user starts typing, allow showing more results
            if !trimmedSearchText.isEmpty && visibleItemLimit < 20 {
                visibleItemLimit = 20 // Increase limit for search results
            }
        }
        
        runQuery(trimmedSearchText, debounce: true)
    }
    
    // MARK: - Helper Methods
    func getTotalSuggestionCount() -> Int {
        switch mode {
        case .tabActions:
            return tabActions.count
        case .subview:
            return subviewRows.count
        case .normal:
            // Only the sections shown count, so the selection can't move past the last row.
            return getSectionsForCurrentState().reduce(0) { $0 + getSectionCount(for: $1) }
        }
    }

    enum SuggestionType: Equatable {
        case update(AppUpdater.Update)
        case tab(PaletteTab)
        case urlSuggestion(HistoryEntryData)
        case searchResult(SearchResult)
        case searchEngine(SiteShortcut)
        case googleSuggestion(String)
        case directURL(String)
        case tabAction(TabAction)
        case subviewRow(PaletteSubviewRow)
        case none

        static func == (lhs: SuggestionType, rhs: SuggestionType) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case (.update(let update1), .update(let update2)):
                return update1 == update2
            case (.tab(let tab1), .tab(let tab2)):
                return tab1.id == tab2.id
            case (.urlSuggestion(let entry1), .urlSuggestion(let entry2)):
                return entry1.url == entry2.url && entry1.title == entry2.title
            case (.searchResult(let result1), .searchResult(let result2)):
                return result1 == result2
            case (.searchEngine(let engine1), .searchEngine(let engine2)):
                return engine1 == engine2
            case (.googleSuggestion(let suggestion1), .googleSuggestion(let suggestion2)):
                return suggestion1 == suggestion2
            case (.directURL(let url1), .directURL(let url2)):
                return url1 == url2
            case (.tabAction(let a1), .tabAction(let a2)):
                return a1 == a2
            case (.subviewRow(let r1), .subviewRow(let r2)):
                return r1 == r2
            default:
                return false
            }
        }
    }
    
    // MARK: - Section Calculation
    func calculateSectionInfos() -> [SectionInfo] {
        // Tab-actions and subview modes own the entire list as a single section.
        switch mode {
        case .tabActions:
            return tabActions.isEmpty
                ? []
                : [SectionInfo(type: .tabActions, startIndex: 0, count: tabActions.count)]
        case .subview:
            return subviewRows.isEmpty
                ? []
                : [SectionInfo(type: .subview, startIndex: 0, count: subviewRows.count)]
        case .normal:
            break
        }

        var sectionInfos: [SectionInfo] = []
        var currentIndex = 0

        // Determine which sections to show based on search state
        let sectionsToShow = getSectionsForCurrentState()

        for sectionType in sectionsToShow {
            let count = getSectionCount(for: sectionType)
            if count > 0 {
                sectionInfos.append(SectionInfo(
                    type: sectionType,
                    startIndex: currentIndex,
                    count: count
                ))
                currentIndex += count
            }
        }

        return sectionInfos
    }
    
    /// Get the appropriate sections to show based on current search state
    private func getSectionsForCurrentState() -> [CommandPaletteSectionType] {
        let isSearching = !displayedQuery.isEmpty && !isInPrefixMode
        
        if isInPrefixMode {
            // The words on the shortcut's site first, then its earlier searches
            return [
                .googleSuggestions,
                .urlSuggestions
            ]
        } else if isSearching {
            // When searching, combine tabs and history into searchResults.
            // Text starting with a shortcut's keyword ("yt cats", pasted)
            // searches its site first.
            if !searchEngineSuggestions.isEmpty {
                return [
                    .update,
                    .directURL,
                    .searchEngines,
                    .searchResults,
                    .googleSuggestions
                ]
            }
            return [
                .update,
                .directURL,
                .searchResults,  // Combined tabs + history
                .searchEngines,
                .googleSuggestions
            ]
        } else {
            // Normal mode: show separate sections
            return [
                .update,
                .directURL,
                .urlSuggestions,
                .tabs,
                .searchEngines,
                .googleSuggestions
            ]
        }
    }
    
    private func getSectionCount(for sectionType: CommandPaletteSectionType) -> Int {
        switch sectionType {
        case .update:
            return showsUpdateRow ? 1 : 0
        case .tabs:
            return filteredTabs.count
        case .urlSuggestions:
            return urlSuggestions.count
        case .searchResults:
            return combinedSearchResults.count
        case .directURL:
            return directURLSuggestion != nil ? 1 : 0
        case .searchEngines:
            return searchEngineSuggestions.count
        case .googleSuggestions:
            // Count includes exact text row (rendered directly from displayedQuery) + API suggestions
            return (hasExactTextRow ? 1 : 0) + googleSuggestions.count
        case .tabActions:
            return tabActions.count
        case .subview:
            return subviewRows.count
        }
    }
    
    /// Restart to Update leads the rows once an update is ready: with nothing
    /// typed, where it's selected, so ⌘T and Return restart into it, and for
    /// "upd…" or "resta…"; a silent update only for those. Not for a split
    /// view's empty pane, which waits for a page.
    private var showsUpdateRow: Bool {
        guard let readyUpdate, mode.isNormal, !isInPrefixMode,
              tabManager?.isPickingSplitPane != true else { return false }
        let query = displayedQuery.lowercased()
        return query.isEmpty && !readyUpdate.isSilent
            || query.count >= 3 && "update".hasPrefix(query)
            || query.count >= 5 && "restart to update".hasPrefix(query)
    }

    /// The suggestions start with a row for the query itself: from two
    /// characters, or any after a site shortcut, where it's what Return does.
    var hasExactTextRow: Bool {
        isInPrefixMode ? !displayedQuery.isEmpty : displayedQuery.count >= 2
    }

    func getSelectedSuggestion(at index: Int) -> SuggestionType {
        let sectionInfos = calculateSectionInfos()

        // Find which section contains this index
        for sectionInfo in sectionInfos {
            let sectionEndIndex = sectionInfo.startIndex + sectionInfo.count

            if index >= sectionInfo.startIndex && index < sectionEndIndex {
                let indexInSection = index - sectionInfo.startIndex

                switch sectionInfo.type {
                case .update:
                    if indexInSection == 0, let readyUpdate {
                        return .update(readyUpdate)
                    }
                case .tabs:
                    if indexInSection < filteredTabs.count {
                        return .tab(filteredTabs[indexInSection])
                    }
                case .urlSuggestions:
                    if indexInSection < urlSuggestions.count {
                        return .urlSuggestion(urlSuggestions[indexInSection])
                    }
                case .searchResults:
                    if indexInSection < combinedSearchResults.count {
                        return .searchResult(combinedSearchResults[indexInSection])
                    }
                case .directURL:
                    if indexInSection == 0, let directURL = directURLSuggestion {
                        return .directURL(directURL)
                    }
                case .searchEngines:
                    if indexInSection < searchEngineSuggestions.count {
                        return .searchEngine(searchEngineSuggestions[indexInSection])
                    }
                case .googleSuggestions:
                    // First row is the exact query (see hasExactTextRow)

                    if hasExactTextRow && indexInSection == 0 {
                        // Exact text row - return the query
                        return .googleSuggestion(displayedQuery)
                    }

                    // API suggestions (offset by 1 if we have exact text row)
                    let apiIndex = hasExactTextRow ? indexInSection - 1 : indexInSection
                    if apiIndex >= 0 && apiIndex < googleSuggestions.count {
                        return .googleSuggestion(googleSuggestions[apiIndex])
                    }
                case .tabActions:
                    if indexInSection < tabActions.count {
                        return .tabAction(tabActions[indexInSection])
                    }
                case .subview:
                    if indexInSection < subviewRows.count {
                        return .subviewRow(subviewRows[indexInSection])
                    }
                }
                break
            }
        }

        return .none
    }
    
    // MARK: - Submit Handling
    func handleSubmit(commandPressed: Bool = false) {
        guard tabManager != nil else { return }

        switch mode {
        case .tabActions:
            handleTabActionsSubmit()
            return
        case .subview:
            handleSubviewSubmit()
            return
        case .normal:
            break
        }

        // Return right after typing, before the rows for the latest text are
        // in (they're searched off the main thread): submit once they are,
        // so it acts on the top row for what was typed.
        let trimmedSearchText = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUserTyping && trimmedSearchText != displayedQuery {
            runQuery(trimmedSearchText, debounce: false, thenSubmit: commandPressed)
            return
        }

        submitSelection(commandPressed: commandPressed)
    }

    /// A click on a row: what Return does with it selected.
    func activateRow(at index: Int, commandPressed: Bool) {
        guard let tabManager = tabManager else { return }

        // A click acts on the row it hit, never on a search still in flight.
        isUserTyping = false
        selectedTabIndex = index
        perform(getSelectedSuggestion(at: index), commandPressed: commandPressed)

        DispatchQueue.main.async {
            tabManager.showCommandPalette = false
        }
    }

    private func submitSelection(commandPressed: Bool) {
        guard let tabManager = tabManager else { return }

        // A site shortcut with no row to act on: its search, or the site
        // itself with nothing typed after the keyword
        if isInPrefixMode, let shortcut = activeShortcut,
           case .none = getSelectedSuggestion(at: selectedTabIndex) {
            let query = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            tabManager.navigateToURL(query.isEmpty ? shortcut.homeURL : shortcut.searchURL(for: query))
            DispatchQueue.main.async {
                tabManager.showCommandPalette = false
            }
            return
        }

        if tabManager.isNewTabMode {
            handleNewTabSubmit(commandPressed: commandPressed)
        } else {
            handleNavigationSubmit(commandPressed: commandPressed)
        }

        // Close command palette after handling the action
        DispatchQueue.main.async {
            tabManager.showCommandPalette = false
        }
    }
    
    private func handleNewTabSubmit(commandPressed: Bool = false) {
        guard let tabManager = tabManager else { return }
        
        // Handle selection from consolidated suggestions
        if selectedTabIndex >= 0 && perform(getSelectedSuggestion(at: selectedTabIndex), commandPressed: commandPressed) {
            return
        }

        // Use typed text if no selection
        let textToNavigate = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !textToNavigate.isEmpty {
            let formattedURL = formatURLForNavigation(textToNavigate)
            tabManager.navigateToURL(formattedURL)
        }
    }

    private func handleNavigationSubmit(commandPressed: Bool = false) {
        guard let tabManager = tabManager else { return }
        
        // Handle selection from consolidated suggestions
        if selectedTabIndex >= 0 && perform(getSelectedSuggestion(at: selectedTabIndex), commandPressed: commandPressed) {
            return
        }

        // Use typed text if no selection
        if !userTypedText.isEmpty {
            tabManager.navigateToURL(userTypedText)
        }
    }

    /// Carries out a row's action. Returns false when there's no row to act on.
    @discardableResult
    private func perform(_ suggestion: SuggestionType, commandPressed: Bool) -> Bool {
        guard let tabManager = tabManager else { return false }

        switch suggestion {
        case .update:
            // Klar quits, installs it and opens again
            AppUpdater.shared.installUpdate()
        case .tab(let tab):
            activateTab(tab, commandPressed: commandPressed)
        case .urlSuggestion(let entry):
            // Navigate to the URL in the current tab
            tabManager.navigateToURL(entry.url)
        case .searchResult(let result):
            switch result {
            case .tab(let tab, _):
                activateTab(tab, commandPressed: commandPressed)
            case .history(let entry, _):
                tabManager.navigateToURL(entry.url)
            case .site:
                tabManager.navigateToURL(result.url)
            case .readingList(let item, _):
                tabManager.navigateToURL(item.url)
                if item.isUnread {
                    Task {
                        try? await SafariReadingListManager.shared.markAs(read: true, url: item.url)
                    }
                }
            }
        case .searchEngine(let shortcut):
            // The words the row shows, which a click can't run ahead of
            let query = SiteShortcuts.search(in: displayedQuery)?.query ?? displayedQuery
            tabManager.navigateToURL(shortcut.searchURL(for: query))
        case .googleSuggestion(let suggestion):
            // After a site shortcut, on its site
            if isInPrefixMode, let shortcut = activeShortcut {
                tabManager.navigateToURL(shortcut.searchURL(for: suggestion))
            } else {
                tabManager.navigateToURL(getSearchURL(for: suggestion))
            }
        case .directURL(let url):
            handleDirectURLNavigation(url, with: tabManager)
        case .tabAction, .subviewRow, .none:
            // Tab actions and subview rows are handled by mode-specific submit paths.
            return false
        }
        return true
    }

    /// Switches to a tab row's tab: an open tab directly, a saved one through
    /// the sidebar (which loads it if unloaded). With ⌘, a saved tab's URL
    /// opens in a new regular tab instead.
    private func activateTab(_ tab: PaletteTab, commandPressed: Bool) {
        guard let tabManager = tabManager else { return }
        let sidebarManager = tabManager.sidebarManager

        // Unloaded saved tabs (and tabs loaded from them) carry the sidebar
        // tab's ID; other open saved tabs map to it.
        var sidebarTabID: UUID?
        if let sidebarManager = sidebarManager {
            if sidebarManager.sidebarStructure.tabs[tab.id] != nil {
                sidebarTabID = tab.id
            } else if let mappedID = sidebarManager.browserToSidebarTabMapping[tab.id],
                      sidebarManager.sidebarStructure.tabs[mappedID] != nil {
                sidebarTabID = mappedID
            }
        }

        // Check if this is a saved tab and if command key is pressed
        if commandPressed && sidebarTabID != nil {
            // Open the saved tab URL in a new regular tab
            _ = tabManager.createNewTab(url: tab.url)
            return
        }

        var loadsItself = false
        if let sidebarManager = sidebarManager,
           let sidebarTabID = sidebarTabID,
           sidebarManager.sidebarStructure.tabs[sidebarTabID] != nil {
            if !sidebarManager.isOpenHere(sidebarTabID) {
                // No page in this window: load one (loadTab method handles focus)
                loadsItself = true
                sidebarManager.loadTab(withID: sidebarTabID)
            } else {
                // It's an active saved tab, select it through sidebar manager
                sidebarManager.selectItem(sidebarTabID)
            }
        } else if let browserTab = tabManager.tabs.first(where: { $0.id == tab.id }) {
            // It's a regular tab, switch to it normally
            tabManager.switchToTab(browserTab)
        }

        // Send focus notification only for tabs open here already
        // (loaded ones handle focus in the loadTab method)
        guard !loadsItself else { return }
        let tabID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Check coordinator still exists before sending notification
            guard TabWebViewCoordinator.coordinator(for: tabID) != nil else {
                logWarning(.commandPalette, "Coordinator deallocated for tab \(tabID.uuidString.prefix(8)), skipping focus notification")
                return
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("FocusWebView"),
                object: nil,
                userInfo: ["tabId": tabID.uuidString]
            )
        }
    }
    
    private func formatURLForNavigation(_ text: String) -> String {
        URLUtilities.formatURLForNavigation(text)
    }
    
    /// Handle direct URL navigation with deep link support
    private func handleDirectURLNavigation(_ url: String, with tabManager: TabManager) {
        // Check if this is a deep link that should be handled specially
        if DeepLinkHandler.shared.shouldHandleAsDeepLink(url) {
            // Create a mock WebView for the deep link handler
            // We'll use the active tab's WebView if available
            if let activeTab = tabManager.activeTab,
               let coordinator = TabWebViewCoordinator.coordinator(for: activeTab.id) {
                DeepLinkHandler.shared.handleDeepLink(url, from: coordinator.webView)
            } else {
                // Fallback: try to open with NSWorkspace directly
                if let urlObj = URL(string: url) {
                    NSWorkspace.shared.open(urlObj)
                }
            }
        } else {
            // Handle regular URLs through normal navigation
            tabManager.navigateToURL(url)
        }
    }
    
    // MARK: - Lazy Loading
    
    /// Shows more of the tab list once the selection nears its end, at once:
    /// the list builds only the rows in view, so there's nothing to wait for.
    /// Search results keep their limit until the next query.
    func loadMoreItemsIfNeeded() {
        // While typing, the search decides the rows
        guard isVisible, !isUserTyping, showsTabList, indexedTabs.count > filteredTabs.count else { return }
        guard selectedTabIndex >= getTotalSuggestionCount() - loadMoreDistance else { return }

        visibleItemLimit = filteredTabs.count + loadMoreCount
        filteredTabs = indexedTabs.prefix(visibleItemLimit).map { $0.tab }
        logDebug(.commandPalette, "Loaded more items, new limit: \(visibleItemLimit)")
    }

    /// The tab list is shown: nothing typed, no search running
    private var showsTabList: Bool {
        mode.isNormal && !isInPrefixMode && displayedQuery.isEmpty && pendingQuery == nil
    }
    
    // MARK: - Navigation
    /// Moves through the rows shown, a pre-filled URL's too (its Navigate
    /// row, then what the search found for it); the field shows the
    /// selected row's text.
    func moveSelectionUp() {
        // Mark that user is navigating (not typing)
        isUserTyping = false

        if selectedTabIndex > 0 {
            selectedTabIndex -= 1
        }
    }

    func moveSelectionDown() {
        // Mark that user is navigating (not typing)
        isUserTyping = false

        let itemCount = getTotalSuggestionCount()
        if selectedTabIndex < itemCount - 1 {
            selectedTabIndex += 1
        }
    }
    
    // MARK: - URL Pre-fill Management
    func setPrefilledURL(_ url: String) {
        guard mode.isNormal, !isInPrefixMode else { return }

        let query = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShowingURL = hasPrefilledURL && prefilledURL == url && (pendingQuery ?? displayedQuery) == query

        hasPrefilledURL = true
        prefilledURL = url
        userTypedText = url
        
        // Explicitly keep isUserTyping as false for pre-filled URLs
        isUserTyping = false
        
        if !isShowingURL {
            // Switch to the URL's rows now rather than when its search lands,
            // so the palette doesn't open on the tab list first.
            showSearchPlaceholder(for: query)
            runQuery(query, debounce: false)
        }

        // Select the first row, which is where selecting the active tab in
        // the tab list filtered by its URL always ended up
        selectedTabIndex = 0
        
        // Trigger text selection for pre-filled URL in navigation mode
        // Wait a bit to ensure focus is established first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            NotificationCenter.default.post(name: NSNotification.Name("ForceTextSelection"), object: self.tabManager)
        }
    }
    
    /// The Navigate row for text that looks like a URL (deep links included).
    private func makeDirectURLSuggestion(for searchText: String) -> String? {
        // Check if the text looks like a URL
        guard isValidURL(searchText) else { return nil }

        // For deep links, use the text as-is without formatting
        if isDeepLink(searchText) {
            return searchText
        }
        // For regular URLs, use the formatting function
        return formatURLForNavigation(searchText)
    }

    /// Whether typed text is another app's address (`mailto:…`,
    /// `zoommtg://…`): an address (`URLUtilities.addressScheme(of:)`, so
    /// not `localhost:3000` or `site:reddit.com klar`, which got an Open
    /// row for an app that doesn't exist) whose scheme isn't the web's.
    private func isDeepLink(_ text: String) -> Bool {
        URLUtilities.addressScheme(of: text) != nil && DeepLinkHandler.shared.shouldHandleAsDeepLink(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Check if a string is a valid URL (including deep links)
    private func isValidURL(_ string: String) -> Bool {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for deep links first
        if isDeepLink(trimmedString) {
            return true
        }
        
        // An address with its scheme (`https:`, `file:`, an extension's
        // page, `data:`): one ⌘L showed, with a fragment, went to the
        // search engine's suggestions whole
        if URLUtilities.addressScheme(of: trimmedString) != nil {
            return true
        }
        
        // Handle file paths that look like local paths
        if trimmedString.hasPrefix("/") || (trimmedString.contains("/") && 
           (trimmedString.hasSuffix(".html") || trimmedString.hasSuffix(".htm") || 
            trimmedString.hasSuffix(".txt") || trimmedString.hasSuffix(".pdf") || 
            trimmedString.hasSuffix(".md") || trimmedString.hasSuffix(".js") || 
            trimmedString.hasSuffix(".css") || trimmedString.hasSuffix(".json"))) {
            return true
        }
        
        // Check for domain-like patterns (no spaces allowed)
        guard !trimmedString.contains(" ") else { return false }
        
        // Special case: localhost (with or without port/path)
        if isValidLocalhostPattern(trimmedString) {
            return true
        }
        
        // Special case: IP addresses (with or without port/path)
        if isValidIPAddressWithPortAndPath(trimmedString) {
            return true
        }
        
        // Check for valid domain format (with or without path)
        if isValidDomainWithPath(trimmedString) {
            // Try to construct a URL with https prefix to validate further
            let urlWithProtocol = "https://" + trimmedString
            if let url = URL(string: urlWithProtocol), url.host != nil {
                return true
            }
        }
        
        return false
    }
    
    /// Check if a string is a valid localhost pattern (with optional port and/or path)
    private func isValidLocalhostPattern(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        
        // Handle localhost by itself
        if lowercased == "localhost" {
            return true
        }
        
        // Handle localhost with path (localhost/path)
        if lowercased.hasPrefix("localhost/") {
            return true
        }
        
        // Handle localhost with port (localhost:3000, localhost:8080, etc.)
        if lowercased.hasPrefix("localhost:") {
            let portAndPath = String(lowercased.dropFirst("localhost:".count))
            
            // Extract port number (everything before / or end of string)
            let portPart = portAndPath.components(separatedBy: "/").first ?? portAndPath
            
            // Validate port number (1-65535)
            if let port = Int(portPart), port >= 1 && port <= 65535 {
                return true
            }
        }
        
        return false
    }
    
    /// Check if a string is a valid IP address with optional port and/or path (IPv4)
    private func isValidIPAddressWithPortAndPath(_ string: String) -> Bool {
        // First separate by "/" to handle paths
        let pathComponents = string.components(separatedBy: "/")
        let hostPart = pathComponents.first ?? ""
        
        // Now separate host part by ":" to handle ports
        let hostComponents = hostPart.components(separatedBy: ":")
        let ipPart = hostComponents.first ?? ""
        
        // Validate the IP address part
        guard isValidIPAddress(ipPart) else { return false }
        
        // If there's a port, validate it
        if hostComponents.count == 2 {
            let portPart = hostComponents[1]
            if let port = Int(portPart), port >= 1 && port <= 65535 {
                return true
            } else {
                return false // Invalid port
            }
        } else if hostComponents.count == 1 {
            // No port, just IP - that's valid
            return true
        } else {
            // Multiple colons - invalid
            return false
        }
    }
    
    /// Check if a string is a valid IP address (IPv4)
    private func isValidIPAddress(_ string: String) -> Bool {
        let components = string.components(separatedBy: ".")
        
        // IPv4 should have exactly 4 components
        guard components.count == 4 else { return false }
        
        // Each component should be a valid number between 0-255
        for component in components {
            // Check if it's a valid integer
            guard let number = Int(component),
                  number >= 0,
                  number <= 255,
                  // Ensure no leading zeros (except for "0" itself)
                  (component == "0" || !component.hasPrefix("0")) else {
                return false
            }
        }
        
        return true
    }
    
    /// Check if a string is a valid domain name with optional path
    private func isValidDomainWithPath(_ string: String) -> Bool {
        // Separate domain from path
        let components = string.components(separatedBy: "/")
        let domainPart = components.first ?? ""
        
        // Validate the domain part
        return isValidDomain(domainPart)
    }
    
    /// Check if a string is a valid domain name
    private func isValidDomain(_ string: String) -> Bool {
        // Must contain at least one dot
        guard string.contains(".") else { return false }
        
        // Split by dots to check each part
        let components = string.components(separatedBy: ".")
        
        // Must have at least 2 components (domain.tld)
        guard components.count >= 2 else { return false }
        
        // Check each component
        for (index, component) in components.enumerated() {
            // Components cannot be empty
            guard !component.isEmpty else { return false }
            
            // The last component (TLD) should be at least 2 characters
            if index == components.count - 1 {
                guard component.count >= 2 else { return false }
            }
            
            // Each component should contain only valid domain characters
            let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            guard component.rangeOfCharacter(from: allowedCharacters.inverted) == nil else {
                return false
            }
            
            // Cannot start or end with hyphen
            guard !component.hasPrefix("-") && !component.hasSuffix("-") else {
                return false
            }
        }
        
        // The last component (TLD) should not be all numeric
        let tld = components.last!
        guard !tld.allSatisfy({ $0.isNumber }) else { return false }
        
        return true
    }
    
    // MARK: - Helper Methods
    
    /// Deduplicate URL suggestions by URL, keeping the entry with highest visit count
    private func deduplicateURLSuggestions(_ suggestions: [HistoryEntryData]) -> [HistoryEntryData] {
        var seenURLs: Set<String> = []
        var uniqueEntries: [HistoryEntryData] = []
        
        for entry in suggestions {
            if !seenURLs.contains(entry.url) {
                seenURLs.insert(entry.url)
                uniqueEntries.append(entry)
            }
        }
        
        return uniqueEntries
    }

    // MARK: - Helper Methods for Display Text
    
    /// Get the display text for the currently selected item
    private func getDisplayTextForSelectedItem() -> String {
        let selectedSuggestion = getSelectedSuggestion(at: selectedTabIndex)

        switch selectedSuggestion {
        case .tab(let tab):
            return tab.url
        case .urlSuggestion(let entry):
            return entry.url
        case .searchResult(let result):
            return result.url
        case .searchEngine:
            if userTypedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ""
            } else {
                return userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .googleSuggestion(let suggestion):
            return suggestion
        case .directURL(let url):
            return url
        case .update, .tabAction, .subviewRow:
            return userTypedText
        case .none:
            return userTypedText
        }
    }
    
    /// Generate search URL using the default search engine from settings
    private func getSearchURL(for query: String) -> String {
        TOMLSettingsManager.shared.defaultSearchEngine.searchURL(for: query)
    }

    // MARK: - Mode helpers (tab actions / subview)

    func enterTabActions() {
        userTypedText = ""
        isUserTyping = false
        mode = .tabActions
    }

    func enterSubview(_ id: PaletteSubviewID, rootFrame: PaletteSubviewFrame) {
        userTypedText = ""
        isUserTyping = false
        mode = .subview(PaletteSubview(id: id, rootFrame: rootFrame))
    }

    func pushSubviewFrame(_ frame: PaletteSubviewFrame) {
        guard case .subview(var sv) = mode else { return }
        sv.frames.append(frame)
        userTypedText = ""
        isUserTyping = false
        mode = .subview(sv)
    }

    func popSubviewFrame() {
        guard case .subview(var sv) = mode else { return }
        guard sv.frames.count > 1 else { return }
        sv.frames.removeLast()
        userTypedText = ""
        isUserTyping = false
        mode = .subview(sv)
    }

    func rebuildTabActions() {
        guard let tabManager = tabManager else {
            tabActions = []
            return
        }
        let all = TabActionsBuilder.actions(
            for: tabManager.activeTab,
            sidebarManager: tabManager.sidebarManager
        )
        let filter = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if filter.isEmpty {
            tabActions = all
        } else {
            tabActions = all.filter { action in
                if action.title.lowercased().contains(filter) { return true }
                if let subtitle = action.subtitle, subtitle.lowercased().contains(filter) { return true }
                return false
            }
        }
    }

    func rebuildSubviewRows() {
        guard case .subview(let sv) = mode,
              let sidebar = tabManager?.sidebarManager else {
            subviewRows = []
            return
        }
        switch sv.id {
        case .folderPicker(let intent):
            guard case .folder(let parentID) = sv.current.context else {
                subviewRows = []
                return
            }
            subviewRows = FolderPickerSubview.rows(
                intent: intent,
                parentID: parentID,
                filter: userTypedText,
                sidebar: sidebar
            )
        case .explore:
            let filter = userTypedText.trimmingCharacters(in: .whitespacesAndNewlines)
            subviewRows = ExplorePage.Question.allCases
                .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
                .map { PaletteSubviewRow(id: $0.rawValue, title: $0.title, subtitle: $0.subtitle, systemIcon: $0.symbol, kind: .explore($0)) }
        }
    }

    private func handleTabActionsSubmit() {
        guard let tabManager = tabManager,
              selectedTabIndex >= 0,
              selectedTabIndex < tabActions.count else { return }
        let action = tabActions[selectedTabIndex]
        guard action.isEnabled else { return }
        performTabAction(action, tabManager: tabManager)
    }

    private func performTabAction(_ action: TabAction, tabManager: TabManager) {
        switch action {
        case .saveOrMove(let isAlreadySaved, _, _):
            let rootTitle = tabManager.sidebarManager.map(FolderPickerSubview.rootCollectionName) ?? "Saved"
            enterSubview(
                .folderPicker(intent: isAlreadySaved ? .move : .save),
                rootFrame: PaletteSubviewFrame(
                    id: UUID(),
                    title: rootTitle,
                    context: .folder(parentID: nil)
                )
            )
        case .saveToReadingList(let isAlreadySaved, _):
            performReadingListAction(isAlreadySaved: isAlreadySaved, tabManager: tabManager)
        case .copyLink:
            tabManager.copyCurrentTabURL()
            DispatchQueue.main.async {
                tabManager.showCommandPalette = false
            }
        case .privateBrowsing(let isPrivate, _, _):
            if let activeTab = tabManager.activeTab {
                tabManager.reopenTab(activeTab, isPrivate: !isPrivate)
            }
            DispatchQueue.main.async {
                tabManager.showCommandPalette = false
            }
        case .explore:
            enterSubview(.explore, rootFrame: PaletteSubviewFrame(id: UUID(), title: "Explore with AI", context: .explore))
        }
    }

    private func performReadingListAction(isAlreadySaved: Bool, tabManager: TabManager) {
        guard let activeTab = tabManager.activeTab else { return }
        let url = activeTab.url
        let readingList = SafariReadingListManager.shared
        if isAlreadySaved {
            readingList.removeFromReadingList(url: url, reportingTo: tabManager.toastManager)
        } else {
            readingList.addToReadingList(url: url, title: activeTab.title, reportingTo: tabManager.toastManager)
        }

        DispatchQueue.main.async {
            tabManager.showCommandPalette = false
        }
    }

    private func handleSubviewSubmit() {
        guard case .subview(let sv) = mode,
              selectedTabIndex >= 0,
              selectedTabIndex < subviewRows.count,
              let sidebar = tabManager?.sidebarManager else { return }
        let row = subviewRows[selectedTabIndex]

        switch sv.id {
        case .folderPicker(let intent):
            guard case .folder(let currentParentID) = sv.current.context else { return }
            let decision = FolderPickerSubview.resolve(
                row: row,
                currentParentID: currentParentID,
                sidebar: sidebar
            )
            switch decision {
            case .ignore:
                break
            case .push(let frame):
                pushSubviewFrame(frame)
            case .commit(let parentID):
                commitFolderPick(parentID: parentID, intent: intent)
            }
        case .explore:
            guard case .explore(let question) = row.kind, let tabManager,
                  let page = tabManager.activeTab, ExplorePage.canAsk(about: page) else { return }
            // A page of its own, next to this one, which shows it's searching. The site's name comes
            // from the page's head first: a moment's script in the page
            let title = page.title.isEmpty ? (URL(string: page.url)?.host() ?? page.url) : page.title
            let source = page.url
            let webView = TabWebViewCoordinator.coordinator(for: page.id)?.webView
            tabManager.showCommandPalette = false
            Task {
                let siteName = await ExplorePage.siteName(in: webView)
                tabManager.createNewTab(url: ExplorePage.url(for: question, source: source, title: title, siteName: siteName))
            }
        }
    }

    private func commitFolderPick(parentID: UUID?, intent: FolderPickerIntent) {
        guard let tabManager = tabManager,
              let sidebar = tabManager.sidebarManager,
              let activeTab = tabManager.activeTab else { return }

        let location: String = {
            if let parentID = parentID,
               let title = sidebar.sidebarStructure.folders[parentID]?.displayTitle {
                return title
            }
            return FolderPickerSubview.rootCollectionName(sidebar: sidebar)
        }()

        switch intent {
        case .save:
            let wasSelected = sidebar.selectedItem == activeTab.id
            let newSidebarTabID = sidebar.addTab(activeTab, to: parentID)
            if wasSelected {
                sidebar.selectedItem = newSidebarTabID
                sidebar.selectionManager.addToTabHistory(newSidebarTabID)
            }
            tabManager.toastManager.showToast(
                message: "Tab saved to \(location)",
                type: .info,
                icon: "folder.badge.plus.fill"
            )
        case .move:
            guard let sidebarTabID = sidebar.browserToSidebarTabMapping[activeTab.id],
                  let sidebarTab = sidebar.sidebarStructure.tabs[sidebarTabID] else { return }

            if sidebarTab.parentID == parentID {
                tabManager.toastManager.showToast(
                    message: "Already in this group",
                    type: .info,
                    icon: FolderIcons.groupSymbol
                )
            } else {
                sidebar.moveItem(withID: sidebarTabID, to: parentID)
                tabManager.toastManager.showToast(
                    message: "Tab moved to \(location)",
                    type: .info,
                    icon: FolderIcons.groupSymbol
                )
            }
        }

        DispatchQueue.main.async {
            tabManager.showCommandPalette = false
        }
    }
}

/// Resumes a continuation with whichever of several answers comes first;
/// later ones are dropped. Safe to call from any thread.
nonisolated private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
