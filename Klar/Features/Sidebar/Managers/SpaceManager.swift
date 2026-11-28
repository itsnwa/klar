import Foundation
import AppKit
import Combine
import WebKit

/// Spaces: separate sets of saved tabs, folders and open tabs, shown one at
/// a time in a window's sidebar and switched from its space bar.
///
/// A space is a `SidebarCollection`: saved tabs and folders belong to it by
/// `collectionID`, regular tabs by `BrowserTab.spaceID`, and a saved tab's
/// browser tab by its saved tab (whose space this mirrors into `spaceID`, so
/// the tab stays put when it becomes a regular tab again).
///
/// The spaces are every window's, and so is this manager: the list, making,
/// changing and removing spaces, their profiles, and which space a tab is
/// in. Which space a window shows, and the tab it last showed in each, is
/// that window's own (`SpaceSelection`).
///
/// A space with a separate profile has its own website data
/// (`WKWebsiteDataStore(forIdentifier:)`) and history (a `HistoryManager`
/// of its own), both named by its `profileID`.
final class SpaceManager: ObservableObject {
    static let shared = SpaceManager()

    /// In the order of their buttons.
    @Published private(set) var spaces: [Space] = []

    private var cancellables = Set<AnyCancellable>()

    /// By profile ID. WebKit hands out a new object for each call.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// Private tabs' website data, in memory only: one store for every open
    /// private tab, in any window, so a sign-in popup shares its opener's
    /// cookies. Made for the first private tab and let go once the last one
    /// closes, so the next private tab starts out signed out of everything.
    private var privateDataStore: WKWebsiteDataStore?

    private static let pendingProfileRemovalsKey = "PendingProfileRemovals"

    private init() {
        // Profiles whose removal failed last time (a web view still used
        // them) go now, before any web view is made.
        removePendingProfiles()
        refreshSpaces()

        SidebarStore.shared.$structure
            .removeDuplicates(by: { $0.lastUpdated == $1.lastUpdated })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSpaces()
            }
            .store(in: &cancellables)
    }

    private var structure: SidebarStructure {
        SidebarStore.shared.structure
    }

    /// The window in front's sidebar: for Settings, which has no window of
    /// its own (Arc import).
    var sidebarManager: SidebarManager {
        BrowserWindowSession.current.sidebarManager
    }

    /// Every window's choice of space
    private var selections: [SpaceSelection] {
        BrowserWindowSession.all.map(\.spaceSelection)
    }

    private func refreshSpaces() {
        let newSpaces = structure.orderedCollections.map(Space.init)
        if newSpaces != spaces {
            spaces = newSpaces
        }
    }

    // MARK: - Lookup

    /// The first space: where tabs from before spaces, and tabs of a space
    /// that's gone, belong.
    var defaultSpaceID: UUID? {
        spaces.first?.id ?? structure.orderedCollections.first?.id
    }

    func space(withID id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    /// The space a browser tab is in. None for a pinned site's: it's in
    /// every space, with the shared profile.
    func spaceID(of tab: BrowserTab) -> UUID? {
        let structure = structure
        if let sidebarTabID = SidebarStore.shared.browserToSidebarTabMapping[tab.id] {
            if structure.pinnedItems.contains(sidebarTabID) {
                return nil
            }
            if let collectionID = structure.tabs[sidebarTabID]?.collectionID,
               structure.collections[collectionID] != nil {
                return collectionID
            }
        }
        if let spaceID = tab.spaceID, structure.collections[spaceID] != nil {
            return spaceID
        }
        return defaultSpaceID
    }

    // MARK: - Creating, changing, removing

    /// A new space after the others, switched to in the window `selection`
    /// is for (the window in front by default).
    @discardableResult
    func createSpace(switchingIn selection: SpaceSelection? = nil) -> UUID? {
        let store = SidebarStore.shared
        var structure = store.structure
        let existing = structure.orderedCollections
        let usedColors = Set(existing.map(\.color))
        let color = SpaceColor.allCases.first { !usedColors.contains($0) }
            ?? SpaceColor.allCases[existing.count % SpaceColor.allCases.count]
        let name = "Space \(existing.count + 1)"
        let space = SidebarCollection(
            title: name,
            order: (existing.map(\.order).max() ?? -1) + 1,
            icon: .letter,
            color: color
        )
        structure.collections[space.id] = space
        structure.lastUpdated = Date()
        store.structure = structure
        store.save()
        refreshSpaces()
        (selection ?? BrowserWindowSession.current.spaceSelection).switchTo(space.id)
        return space.id
    }

    /// Changes a space's name, icon or color. The profile has its own
    /// methods, since turning it on or off reopens the space's tabs.
    func updateSpace(_ id: UUID, _ change: (inout SidebarCollection) -> Void) {
        let store = SidebarStore.shared
        guard var space = store.structure.collections[id] else { return }
        change(&space)
        var structure = store.structure
        structure.collections[id] = space
        structure.lastUpdated = Date()
        store.structure = structure
        store.save()
        refreshSpaces()
    }

    func renameSpace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSpace(id) { space in
            space.title = trimmed
            space.customTitle = nil
        }
    }

    /// Moves a space's button `offset` places along the bar.
    func moveSpace(_ id: UUID, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + offset
        guard spaces.indices.contains(newIndex) else { return }
        var ordered = spaces.map(\.id)
        ordered.swapAt(index, newIndex)
        reorderSpaces(ordered)
    }

    func reorderSpaces(_ orderedIDs: [UUID]) {
        let store = SidebarStore.shared
        var structure = store.structure
        for (index, id) in orderedIDs.enumerated() {
            structure.collections[id]?.order = index
        }
        structure.lastUpdated = Date()
        store.structure = structure
        store.save()
        refreshSpaces()
    }

    func canDeleteSpace(_ id: UUID) -> Bool {
        spaces.count > 1 && spaces.contains { $0.id == id }
    }

    /// Removes a space with its saved tabs and folders; its open tabs close
    /// in every window, and its profile's website data and history are
    /// deleted. Windows showing it switch to another.
    func deleteSpace(_ id: UUID) {
        let sidebarManager = sidebarManager
        guard canDeleteSpace(id), let space = sidebarManager.sidebarStructure.collections[id] else { return }

        if let other = spaces.first(where: { $0.id != id }) {
            for selection in selections where selection.currentSpaceID == id {
                selection.switchTo(other.id)
            }
        }

        // Its saved tabs, folders and the space in one change, before its
        // browser tabs close: closing a saved tab's unloads it.
        let savedTabIDs = sidebarManager.sidebarStructure.tabs.values.filter { $0.collectionID == id }.map(\.id)
        let folderIDs = sidebarManager.sidebarStructure.folders.values.filter { $0.collectionID == id }.map(\.id)
        sidebarManager.removeTabs(withIDs: savedTabIDs) { structure in
            let removed = Set(folderIDs)
            for folderID in folderIDs {
                structure.folders[folderID] = nil
            }
            structure.rootItems.removeAll { removed.contains($0) }
            for (folderID, folder) in structure.folders {
                let remaining = folder.childrenIds.filter {
                    structure.tabs[$0] != nil || structure.folders[$0] != nil
                }
                structure.folders[folderID]?.childrenIds = remaining
            }
            structure.collections[id] = nil
        }
        for session in BrowserWindowSession.all {
            session.sidebarManager.expandedFolders.subtract(folderIDs)
            for tab in session.spaceSelection.tabs(inSpace: id) {
                session.tabManager.closeTab(tab)
            }
            session.spaceSelection.spaceWasDeleted(id)
        }

        if space.usesSeparateProfile, let profileID = space.profileID {
            removeProfile(profileID)
        }
        refreshSpaces()
    }

    /// iCloud's first sync matched a space here to one with another ID.
    func spaceWasRekeyed(from oldID: UUID, to newID: UUID) {
        for selection in selections {
            selection.spaceWasRekeyed(from: oldID, to: newID)
        }
    }

    // MARK: - Moving tabs between spaces

    /// After a saved tab or folder moved from `oldSpaceID`: pages open in it,
    /// in any window, were loaded with the old space's profile, so they
    /// reopen with the new one.
    func reopenSavedItemIfProfileChanged(_ itemID: UUID, from oldSpaceID: UUID?) {
        let newSpaceID = structure.collectionID(ofItem: itemID)
        guard profileID(ofSpace: oldSpaceID) != profileID(ofSpace: newSpaceID) else { return }
        for open in browserTabs(inSavedItem: itemID) {
            let sidebarManager = open.session.sidebarManager
            let wasActive = open.session.tabManager.activeTabId == open.browserTab.id
            sidebarManager.unloadTab(withID: open.savedTabID)
            if wasActive {
                DispatchQueue.main.async {
                    sidebarManager.selectItem(open.savedTabID)
                }
            }
        }
    }

    /// The open browser tabs of a saved tab, or of the saved tabs in a
    /// folder, with the window each is in: a page of each in every window
    /// that has one open.
    func browserTabs(inSavedItem itemID: UUID) -> [(savedTabID: UUID, browserTab: BrowserTab, session: BrowserWindowSession)] {
        let structure = structure
        var result: [(savedTabID: UUID, browserTab: BrowserTab, session: BrowserWindowSession)] = []
        var pending = [itemID]
        var seen: Set<UUID> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            if structure.tabs[id] != nil {
                for session in BrowserWindowSession.all {
                    if let browserTabID = session.sidebarManager.sidebarToBrowserTabMapping[id],
                       let tab = session.tabManager.tabs.first(where: { $0.id == browserTabID }) {
                        result.append((savedTabID: id, browserTab: tab, session: session))
                    }
                }
            } else if let folder = structure.folders[id] {
                pending.append(contentsOf: folder.childrenIds)
            }
        }
        return result
    }

    // MARK: - Profiles

    /// The profile ID of a space with a separate profile, nil for the shared one.
    func profileID(ofSpace spaceID: UUID?) -> UUID? {
        guard let spaceID, let space = structure.collections[spaceID], space.usesSeparateProfile else { return nil }
        return space.profileID
    }

    func profileID(of tab: BrowserTab) -> UUID? {
        profileID(ofSpace: spaceID(of: tab))
    }

    /// The website data store a tab's web view uses. A private tab's is
    /// the private session's, whichever space it's in.
    func websiteDataStore(for tab: BrowserTab) -> WKWebsiteDataStore {
        guard tab.isPrivate else { return websiteDataStore(forProfile: profileID(of: tab)) }
        if let privateDataStore {
            return privateDataStore
        }
        let store = WKWebsiteDataStore.nonPersistent()
        privateDataStore = store
        return store
    }

    /// The last private tab, in any window, has closed: its cookies, storage and cache go
    /// with the store once its web views do, and the answers its pages got
    /// to permission prompts are forgotten, as are the sites whose trackers
    /// were allowed from one, and a lock on them ends.
    @MainActor
    func endPrivateSession() {
        guard privateDataStore != nil, !BrowserWindowSession.allTabs.contains(where: \.isPrivate) else { return }
        privateDataStore = nil
        SitePermissionsManager.shared.forgetPrivateDecisions()
        TrackerBlocker.shared.forgetPrivateAllowances()
        PrivateTabLock.shared.privateSessionEnded()
        logInfo(.general, "Ended the private browsing session")
    }

    func websiteDataStore(forProfile profileID: UUID?) -> WKWebsiteDataStore {
        guard let profileID else { return .default() }
        if let store = dataStores[profileID] {
            return store
        }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    /// Every store in use: the shared one and each separate profile's made
    /// this session. A profile not opened since launch has nothing in
    /// memory to purge, so no store is made for it.
    var allWebsiteDataStores: [WKWebsiteDataStore] {
        [WKWebsiteDataStore.default()] + dataStores.values
    }

    /// The history a tab's visits go to.
    @MainActor
    func history(for tab: BrowserTab) -> HistoryManager {
        HistoryManager.forProfile(profileID(of: tab))
    }

    /// A space's history
    @MainActor
    func history(forSpace spaceID: UUID?) -> HistoryManager {
        HistoryManager.forProfile(profileID(ofSpace: spaceID))
    }

    /// Turns a space's separate profile on (empty) or off (its data is
    /// deleted). Its open tabs reopen with the new profile.
    func setSeparateProfile(_ isOn: Bool, forSpace spaceID: UUID) {
        guard let space = structure.collections[spaceID], space.usesSeparateProfile != isOn else { return }
        let oldProfileID = space.usesSeparateProfile ? space.profileID : nil
        updateSpace(spaceID) { space in
            space.usesSeparateProfile = isOn
            space.profileID = isOn ? UUID() : nil
        }
        reopenTabs(inSpace: spaceID)
        if let oldProfileID {
            removeProfile(oldProfileID)
        }
    }

    /// Deletes a separate profile's website data and history, keeping the profile.
    @MainActor
    func clearProfileData(forSpace spaceID: UUID) {
        guard let profileID = profileID(ofSpace: spaceID) else { return }
        websiteDataStore(forProfile: profileID).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            logInfo(.general, "Cleared the website data of profile \(profileID.uuidString.prefix(8))")
        }
        HistoryManager.forProfile(profileID).clearHistory()
    }

    /// The open tabs of a space, in every window, get new web views — with
    /// the profile it has now.
    private func reopenTabs(inSpace spaceID: UUID) {
        for session in BrowserWindowSession.all {
            let sidebarManager = session.sidebarManager
            let tabManager = session.tabManager
            let activeTabID = tabManager.activeTabId
            var reselect: UUID?
            // A private tab doesn't use the profile
            for tab in session.spaceSelection.tabs(inSpace: spaceID) where !tab.isEmpty && !tab.isPrivate {
                if let savedTabID = sidebarManager.browserToSidebarTabMapping[tab.id] {
                    if tab.id == activeTabID {
                        reselect = savedTabID
                    }
                    sidebarManager.unloadTab(withID: savedTabID)
                } else {
                    let isActive = tab.id == activeTabID
                    _ = tabManager.createNewTab(url: tab.url, activate: isActive, inSpace: spaceID)
                    tabManager.closeTab(tab)
                }
            }
            if let reselect {
                DispatchQueue.main.async {
                    sidebarManager.selectItem(reselect)
                }
            }
        }
    }

    /// Deletes a profile's website data store and history. A store still in
    /// use by a web view can't be removed; that's tried again at next launch.
    func removeProfile(_ profileID: UUID) {
        dataStores[profileID] = nil
        var pending = Set(pendingProfileRemovals)
        pending.insert(profileID)
        pendingProfileRemovals = Array(pending)
        Task { @MainActor in
            HistoryManager.deleteProfile(profileID)
            // Closed tabs' web views go away on the next turns.
            try? await Task.sleep(for: .seconds(2))
            await self.removeDataStore(profileID)
        }
    }

    @MainActor
    private func removeDataStore(_ profileID: UUID) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: profileID)
            pendingProfileRemovals.removeAll { $0 == profileID }
            logInfo(.general, "Removed the website data of profile \(profileID.uuidString.prefix(8))")
        } catch {
            logWarning(.general, "Couldn't remove profile \(profileID.uuidString.prefix(8)) yet: \(error.localizedDescription)")
        }
    }

    private var pendingProfileRemovals: [UUID] {
        get {
            (UserDefaults.standard.stringArray(forKey: Self.pendingProfileRemovalsKey) ?? []).compactMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.pendingProfileRemovalsKey)
        }
    }

    private func removePendingProfiles() {
        let pending = pendingProfileRemovals
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for profileID in pending {
                HistoryManager.deleteProfile(profileID)
                await self.removeDataStore(profileID)
            }
        }
    }
}

extension Notification.Name {
    /// A regular tab moved to another space; the sidebar lists it again.
    static let spaceTabsDidChange = Notification.Name("klar.spaceTabsDidChange")
}
