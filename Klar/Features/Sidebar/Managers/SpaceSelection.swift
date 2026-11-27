import Combine
import Foundation

/// The space a window shows, and the tab it last showed in each: its own,
/// as every window can be in another space. The spaces themselves are
/// every window's (`SpaceManager`).
///
/// The active space follows the active tab: activating a tab of another
/// space — from the command palette, say — switches the window to that
/// space.
final class SpaceSelection: ObservableObject {
    @Published private(set) var activeSpaceID: UUID?

    private weak var sidebarManager: SidebarManager?
    private weak var tabManager: TabManager?
    private let defaults: WindowDefaults
    private var cancellables = Set<AnyCancellable>()

    /// The browser tab last shown in each space, to show again on switching back.
    private var lastActiveTabBySpace: [UUID: UUID] = [:]

    private var spaces: SpaceManager { .shared }

    init(defaults: WindowDefaults, sidebarManager: SidebarManager, tabManager: TabManager) {
        self.defaults = defaults
        self.sidebarManager = sidebarManager
        self.tabManager = tabManager
        let userDefaults = UserDefaults.standard
        activeSpaceID = userDefaults.string(forKey: defaults.key("ActiveSpaceID")).flatMap(UUID.init(uuidString:))
        if let stored = userDefaults.dictionary(forKey: defaults.key("LastActiveTabBySpace")) as? [String: String] {
            for (space, tab) in stored {
                if let spaceID = UUID(uuidString: space), let tabID = UUID(uuidString: tab) {
                    lastActiveTabBySpace[spaceID] = tabID
                }
            }
        }
        refreshActiveSpace()

        SidebarStore.shared.$structure
            .removeDuplicates(by: { $0.lastUpdated == $1.lastUpdated })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshActiveSpace()
                self?.syncMappedTabSpaces()
            }
            .store(in: &cancellables)

        tabManager.$tabs
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncMappedTabSpaces()
            }
            .store(in: &cancellables)

        tabManager.$activeTabId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeTabId in
                self?.activeTabDidChange(activeTabId)
            }
            .store(in: &cancellables)
    }

    private var structure: SidebarStructure {
        SidebarStore.shared.structure
    }

    /// A space that's gone: the first one instead
    private func refreshActiveSpace() {
        if activeSpaceID.flatMap({ structure.collections[$0] }) == nil {
            setActiveSpace(structure.orderedCollections.first?.id)
        }
    }

    // MARK: - Lookup

    /// The active space, or the first one.
    var currentSpaceID: UUID? {
        activeSpaceID ?? spaces.defaultSpaceID
    }

    var activeSpace: Space? {
        spaces.space(withID: currentSpaceID)
    }

    /// The active space's history: the History list and the command palette's suggestions.
    @MainActor
    var activeHistory: HistoryManager {
        spaces.history(forSpace: currentSpaceID)
    }

    /// True when not set up yet, so code that runs while tabs are restored
    /// at launch sees every tab.
    func isInActiveSpace(_ tab: BrowserTab) -> Bool {
        guard let sidebarManager, let current = currentSpaceID else { return true }
        if sidebarManager.isPinnedSite(browserTabID: tab.id) {
            return true
        }
        return spaces.spaceID(of: tab) == current
    }

    /// Whether a saved tab or folder is in the active space.
    func isItemInActiveSpace(_ itemID: UUID) -> Bool {
        guard let current = currentSpaceID else { return true }
        guard let collectionID = structure.collectionID(ofItem: itemID) else { return true }
        return collectionID == current
    }

    /// Where a new saved tab or folder goes: its folder's space, else the active one.
    func collectionIDForNewItem(in parentID: UUID?) -> UUID? {
        if let parentID, let collectionID = structure.folders[parentID]?.collectionID {
            return collectionID
        }
        return currentSpaceID
    }

    /// The space a new tab opens in: its opener's, else the active one.
    func spaceIDForNewTab(parentTabId: UUID?) -> UUID? {
        if let parentTabId, let parent = tabManager?.tabs.first(where: { $0.id == parentTabId }),
           let parentSpace = spaces.spaceID(of: parent) {
            return parentSpace
        }
        return currentSpaceID
    }

    /// The window's browser tabs in a space, in the order TabManager keeps them.
    func tabs(inSpace spaceID: UUID) -> [BrowserTab] {
        tabManager?.tabs.filter { spaces.spaceID(of: $0) == spaceID } ?? []
    }

    /// Saved tabs plus the window's open tabs that aren't saved ones: what
    /// the overview's card of the space counts.
    func tabCount(inSpace spaceID: UUID) -> Int {
        guard let sidebarManager else { return 0 }
        let saved = structure.tabs.values.filter { $0.collectionID == spaceID }.count
        let regular = tabs(inSpace: spaceID).filter {
            sidebarManager.browserToSidebarTabMapping[$0.id] == nil && tabManager?.isEmptyPane($0) != true
        }.count
        return saved + regular
    }

    /// Saved tabs' browser tabs carry their saved tab's space, so a tab that
    /// stops being a saved tab (navigated to another site, dragged out of
    /// the saved tabs) stays in its space. A pinned site's carries the
    /// active space of the window it's in: the one it's shown in.
    private func syncMappedTabSpaces() {
        guard let tabManager else { return }
        let structure = structure
        let mapping = SidebarStore.shared.browserToSidebarTabMapping
        for tab in tabManager.tabs {
            guard let sidebarTabID = mapping[tab.id] else { continue }
            let spaceID = structure.pinnedItems.contains(sidebarTabID)
                ? currentSpaceID
                : structure.tabs[sidebarTabID]?.collectionID
            guard let spaceID, tab.spaceID != spaceID else { continue }
            tab.spaceID = spaceID
        }
    }

    // MARK: - Switching

    private func setActiveSpace(_ id: UUID?) {
        guard activeSpaceID != id else { return }
        activeSpaceID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: defaults.key("ActiveSpaceID"))
        } else {
            UserDefaults.standard.removeObject(forKey: defaults.key("ActiveSpaceID"))
        }
        syncMappedTabSpaces()
    }

    /// The active tab moved: to a tab of another space, that space comes
    /// along; either way it's what to show when coming back to its space.
    private func activeTabDidChange(_ activeTabId: UUID?) {
        guard let activeTabId, let tab = tabManager?.tabs.first(where: { $0.id == activeTabId }),
              let spaceID = spaces.spaceID(of: tab) else { return }
        rememberActiveTab(activeTabId, in: spaceID)
        if spaceID != activeSpaceID {
            setActiveSpace(spaceID)
        }
    }

    /// An open tab the window shows moved to another space, in another
    /// window or on another Mac: the window goes along, as it would here
    func openTabDidMove(_ tab: BrowserTab) {
        guard tabManager?.activeTabId == tab.id else { return }
        activeTabDidChange(tab.id)
    }

    private func rememberActiveTab(_ tabID: UUID, in spaceID: UUID) {
        guard lastActiveTabBySpace[spaceID] != tabID else { return }
        lastActiveTabBySpace[spaceID] = tabID
        saveLastActiveTabs()
    }

    private func saveLastActiveTabs() {
        let stored = Dictionary(uniqueKeysWithValues: lastActiveTabBySpace.map { ($0.key.uuidString, $0.value.uuidString) })
        UserDefaults.standard.set(stored, forKey: defaults.key("LastActiveTabBySpace"))
    }

    /// Shows a space: its last tab, else its most recently used one, else
    /// nothing (the empty state) until a tab is opened in it.
    func switchTo(_ spaceID: UUID) {
        guard let sidebarManager, let tabManager, structure.collections[spaceID] != nil else { return }
        setActiveSpace(spaceID)

        if let active = tabManager.activeTab, spaces.spaceID(of: active) == spaceID {
            return
        }

        if let itemID = itemShown(onSwitchingTo: spaceID) {
            sidebarManager.selectItem(itemID)
        } else {
            sidebarManager.selectedItem = nil
            tabManager.activeTabId = nil
        }
    }

    /// Switches to the space before or after the active one.
    func switchToAdjacentSpace(by offset: Int) {
        let spaces = spaces.spaces
        guard !spaces.isEmpty else { return }
        let index = spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let newIndex = (index + offset + spaces.count) % spaces.count
        switchTo(spaces[newIndex].id)
    }

    /// Switches to the space at `index` (⌃1 is index 0).
    func switchToSpace(at index: Int) {
        let spaces = spaces.spaces
        guard spaces.indices.contains(index) else { return }
        switchTo(spaces[index].id)
    }

    /// The sidebar item `switchTo(_:)` selects in a space, for a preview
    /// of it: a saved tab's ID, or a regular tab's.
    func itemShown(onSwitchingTo spaceID: UUID) -> UUID? {
        guard let tab = tabToShow(in: spaceID) else { return nil }
        return sidebarManager?.browserToSidebarTabMapping[tab.id] ?? tab.id
    }

    private func tabToShow(in spaceID: UUID) -> BrowserTab? {
        let candidates = tabs(inSpace: spaceID).filter { !$0.isEmpty }
        if let lastID = lastActiveTabBySpace[spaceID], let last = candidates.first(where: { $0.id == lastID }) {
            return last
        }
        return candidates.max { lastActive($0) < lastActive($1) }
    }

    private func lastActive(_ tab: BrowserTab) -> Date {
        let effectiveID = sidebarManager?.browserToSidebarTabMapping[tab.id] ?? tab.id
        return TabActivityManager.shared.getLastActiveTime(for: effectiveID) ?? tab.lastActiveAt
    }

    // MARK: - Spaces changing

    /// iCloud's first sync matched a space here to one with another ID.
    func spaceWasRekeyed(from oldID: UUID, to newID: UUID) {
        for tab in tabManager?.tabs ?? [] where tab.spaceID == oldID {
            tab.spaceID = newID
        }
        if let lastTab = lastActiveTabBySpace.removeValue(forKey: oldID) {
            rememberActiveTab(lastTab, in: newID)
        }
        if activeSpaceID == oldID {
            setActiveSpace(newID)
        }
    }

    func spaceWasDeleted(_ id: UUID) {
        if lastActiveTabBySpace.removeValue(forKey: id) != nil {
            saveLastActiveTabs()
        }
    }

    // MARK: - Moving tabs between spaces

    /// Moves a saved tab or folder (with everything in it), one of the
    /// window's regular tabs or a group of them, to the end of another
    /// space. A tab whose page is open there with another profile is
    /// reopened in that profile; the active tab brings the space along, in
    /// whichever window it's in. A regular tab moved on its own leaves its
    /// group, unless `keepingGroup`.
    func move(itemID: UUID, toSpace spaceID: UUID, keepingGroup: Bool = false) {
        guard let sidebarManager, let tabManager, structure.collections[spaceID] != nil else { return }
        let structure = structure

        if structure.tabs[itemID] == nil, structure.folders[itemID] == nil,
           OpenTabStore.shared.group(withID: itemID) != nil {
            // A group of regular tabs: its tabs, still in it
            for page in sidebarManager.pages(inRegularGroup: itemID) {
                move(itemID: page.id, toSpace: spaceID, keepingGroup: true)
            }
            return
        }

        if structure.tabs[itemID] != nil || structure.folders[itemID] != nil {
            let oldSpaceID = structure.collectionID(ofItem: itemID)
            guard oldSpaceID != spaceID else { return }
            let openTabs = spaces.browserTabs(inSavedItem: itemID)
            let windowsShowingIt = openTabs.filter { $0.session.tabManager.activeTabId == $0.browserTab.id }.map(\.session)
            // Their split views stay behind
            for open in openTabs {
                open.session.tabManager.splitViews.remove(open.browserTab.id)
            }

            sidebarManager.moveItemToPosition(itemID, containerID: nil, index: structure.rootItems.count, collectionID: spaceID)
            for session in windowsShowingIt {
                session.spaceSelection.switchTo(spaceID)
            }
            spaces.reopenSavedItemIfProfileChanged(itemID, from: oldSpaceID)
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == itemID }),
              spaces.spaceID(of: tab) != spaceID else { return }
        let wasActive = tabManager.activeTabId == tab.id
        let group = OpenTabStore.shared.group(ofPage: tab)
        if group != nil, !keepingGroup {
            OpenTabStore.shared.setGroup(nil, forPages: [tab])
        }
        tabManager.splitViews.remove(tab.id)
        if spaces.profileID(ofSpace: spaces.spaceID(of: tab)) != spaces.profileID(ofSpace: spaceID), !tab.isEmpty, !tab.isPrivate {
            let url = tab.url
            if wasActive {
                setActiveSpace(spaceID)
            }
            let newTabID = tabManager.createNewTab(url: url, activate: wasActive, inSpace: spaceID)
            if keepingGroup, let group, tabManager.tabs.contains(where: { $0.id == newTabID }) {
                // In its place in the group
                OpenTabStore.shared.movePages([newTabID], before: tab.id, into: group, in: tabManager)
            }
            tabManager.closeTab(tab)
            if wasActive {
                rememberActiveTab(newTabID, in: spaceID)
            }
        } else {
            tabManager.objectWillChange.send()
            tab.spaceID = spaceID
            NotificationCenter.default.post(name: .spaceTabsDidChange, object: tabManager)
            // An open tab moves in every window
            OpenTabStore.shared.pageDidChangeSpace(tab)
            if wasActive {
                rememberActiveTab(tab.id, in: spaceID)
                setActiveSpace(spaceID)
            }
        }
    }
}
