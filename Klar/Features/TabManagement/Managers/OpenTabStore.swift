import AppKit
import Combine
import Foundation

/// A regular tab — open, not saved — as every window lists it and iCloud
/// syncs it (`OpenTabStore`).
struct OpenTab: Codable, Equatable {
    var id: UUID
    /// Where its last navigation went, in whichever window or on whichever
    /// Mac. Without tracking parameters, as a tab's is saved.
    var url: String
    var title: String
    /// Nil: the first space, as with a browser tab
    var spaceID: UUID?
    var createdAt: Date
    var lastActiveAt: Date
    /// The group it's in among the regular tabs: each of the group's tabs
    /// has it, its name and icon too, so it syncs with them.
    var group: OpenTabGroup?
}

/// A group of regular tabs (`OpenTab.group`), below the divider: there
/// while it has tabs, one level deep, its tabs together in the open tabs'
/// order. Moved among the saved tabs it's a saved group (`SidebarFolder`)
/// with the same ID, name and icon, and back.
struct OpenTabGroup: Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    /// An `Icomoji`'s stored string; empty for its tabs' favicons
    var icon: String

    static let defaultTitle = "New Group"
}

extension Notification.Name {
    /// A regular tab joined or left a group, or a group was renamed or
    /// given an icon (`OpenTabStore`)
    static let openTabGroupsDidChange = Notification.Name("klar.openTabGroupsDidChange")
}

/// The regular tabs every window shows, and every Mac while Settings ›
/// iCloud is on: one list for the app, in the sidebar's order. A window
/// has a page of its own of each, a `BrowserTab` linked by `openTabID`,
/// without a web view until it's shown, so selecting one in a window never
/// takes it from another, as with a saved tab. An open tab is where its
/// last navigation went: a page that isn't on screen goes there when it's
/// shown next; one on screen stays as it is until it navigates itself.
/// Closing one in a window closes it in every window, and on every Mac.
/// Private tabs, pages a script opened (sign-in windows, with an opener)
/// and empty panes aren't open tabs: they're their window's own.
final class OpenTabStore {
    static let shared = OpenTabStore()

    /// In the sidebar's order
    private(set) var tabs: [OpenTab] = []
    /// Closed here, and when: iCloud deletes them even when this Mac didn't
    /// tell it of them this session (closed before its first sync), and an
    /// earlier copy coming back from iCloud doesn't open them again. For a
    /// month.
    private var closedTabs: [UUID: Date] = [:]
    /// Once every window's tabs are restored at launch: until then, they
    /// come and go as they're restored.
    private(set) var isStarted = false
    /// The store is changing windows' pages: what they do meanwhile isn't
    /// theirs to report.
    private var isApplying = false
    /// Pages being closed, out of their window's list a turn later
    private var closingPageIDs: Set<UUID> = []
    /// Pages of removed saved tabs left open as regular tabs, by page ID:
    /// each becomes the open tab with its saved tab's ID, the same in every
    /// window and on every Mac, so its pages everywhere are one open tab
    /// (removed here, and on another Mac as iCloud removes it there)
    private var formerSavedTabs: [UUID: UUID] = [:]
    /// The group each page that isn't an open tab yet joins as it becomes
    /// one: a link's new tab from a tab in a group, a saved tab's page left
    /// open in one
    private var pendingGroups: [UUID: OpenTabGroup] = [:]
    /// Where each page last went, by its own navigation or following its
    /// open tab: an address it rewrote since (replaceState) leaves it there.
    /// A page not at its open tab's address follows it.
    private var navigatedAddresses: [UUID: String] = [:]
    private var pageObservations: [UUID: PageObservation] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var terminationObserver: (any NSObjectProtocol)?
    private var isReconcileScheduled = false
    private var saveWorkItem: DispatchWorkItem?

    private struct PageObservation {
        weak var page: BrowserTab?
        let cancellable: AnyCancellable
    }

    private struct Stored: Codable {
        var tabs: [OpenTab]
        var closedTabs: [UUID: Date]
    }

    private static let defaultsKey = "OpenTabs"
    private static let closedTabLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let saveDelay: TimeInterval = 0.5

    private init() {}

    func openTab(withID id: UUID) -> OpenTab? {
        tabs.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    /// Every window's tabs, and those of the one waiting for the next window
    private var windows: [TabManager] {
        BrowserWindowSession.all.map(\.tabManager).filter { !$0.isWindowClosed }
    }

    // MARK: - Starting

    /// Once every window's tabs are restored at launch
    /// (`BrowserWindowSession.restoreAll`).
    func start() {
        guard !isStarted else { return }
        let hasStored = load()
        isStarted = true
        if !hasStored {
            // The first launch with them: the windows' regular tabs become
            // the open tabs, the window in front's first
            for window in windows {
                window.tabs.forEach { $0.openTabID = nil }
            }
        }
        reconcile()
        // Restored pages have no web view yet: they take their open tab's
        // address and title
        applying {
            for window in windows {
                for page in window.tabs where page.isSuspended {
                    if let tab = page.openTabID.flatMap(openTab(withID:)) {
                        apply(tab, to: page, in: window)
                    }
                }
            }
        }

        // A page that becomes a saved tab's (saved, pinned), or a saved
        // tab's page that becomes a regular tab again
        SidebarStore.shared.$structure
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        terminationObserver = NotificationCenter.default.addMainObserver(
            forName: NSApplication.willTerminateNotification
        ) { [weak self] _ in
            self?.appWillTerminate()
        }
        if !hasStored {
            save()
        }
        logInfo(.tabManagement, "\(tabs.count) open tabs in \(windows.count) windows")
    }

    // MARK: - Windows' changes

    /// A window's tabs changed: a new regular tab among them, or one that's
    /// saved now
    func windowTabsDidChange() {
        scheduleReconcile()
    }

    /// A new window, before it shows: a page of every open tab
    func windowDidJoin() {
        guard isStarted else { return }
        reconcile()
    }

    /// A window's active tab changed: the open tab it shows now was used
    /// just now, and the page it showed goes where its open tab went
    /// meanwhile in another window or on another Mac.
    func activeTabDidChange(in window: TabManager, from previousID: UUID?) {
        guard isStarted else { return }
        if let previousID, let page = window.tabs.first(where: { $0.id == previousID }),
           let tab = page.openTabID.flatMap(openTab(withID:)), navigatedAddresses[page.id] != tab.url {
            applying { apply(tab, to: page, in: window) }
        }
        guard let page = window.activeTab, let id = page.openTabID, let index = index(of: id),
              page.lastActiveAt > tabs[index].lastActiveAt else { return }
        tabs[index].lastActiveAt = page.lastActiveAt
        for other in windows.flatMap(\.tabs) where other.openTabID == id {
            other.lastActiveAt = max(other.lastActiveAt, page.lastActiveAt)
        }
        save()
    }

    /// A window closes its page of an open tab (⌘W, its close button, the
    /// rules that close tabs): the open tab closes, in every window and on
    /// every Mac.
    func pageWillClose(_ page: BrowserTab) {
        guard isStarted, !isApplying, let id = page.openTabID, let index = index(of: id) else { return }
        closingPageIDs.insert(page.id)
        tabs.remove(at: index)
        closedTabs[id] = Date()
        applying { closePages(of: id, except: page) }
        save()
    }

    /// The open tabs reordered in a window's sidebar: in that order in
    /// every window
    func pagesWereReordered(in window: TabManager) {
        guard isStarted, takeOrder(of: window) else { return }
        // A group's tabs stay together: put back together, the window
        // that moved them follows too
        let regathered = gatherGroups()
        for other in windows where other !== window || regathered {
            conform(other)
        }
        save()
    }

    /// The open tabs in the order a window has its pages of them; whether
    /// that changed it
    @discardableResult
    private func takeOrder(of window: TabManager) -> Bool {
        var seen: Set<UUID> = []
        let order = window.tabs.compactMap(\.openTabID).filter { seen.insert($0).inserted }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = order.compactMap { byID[$0] } + tabs.filter { !seen.contains($0.id) }
        guard reordered.map(\.id) != tabs.map(\.id) else { return false }
        tabs = reordered
        return true
    }

    /// A window moved its page of an open tab to another space: the open
    /// tab goes there, in every window
    func pageDidChangeSpace(_ page: BrowserTab) {
        guard isStarted, let id = page.openTabID, let index = index(of: id),
              tabs[index].spaceID != page.spaceID else { return }
        tabs[index].spaceID = page.spaceID
        apply(tabs[index], exceptTo: page)
        save()
    }

    /// A removed saved tab's pages stay as regular tabs: one open tab, not
    /// one each, with the saved tab's ID. Another Mac that had it open
    /// leaves its page as that tab too, not another one.
    func pagesWillBecomeOpenTab(_ pageIDs: [UUID], ofSavedTab savedTabID: UUID) {
        for pageID in pageIDs {
            formerSavedTabs[pageID] = savedTabID
        }
    }

    // MARK: - Groups

    /// A window's page's group among the regular tabs: its open tab's, or
    /// the one it joins as it becomes one
    func group(ofPage page: BrowserTab) -> OpenTabGroup? {
        if let id = page.openTabID {
            return openTab(withID: id)?.group
        }
        return pendingGroups[page.id]
    }

    /// The groups of a window's pages, by page ID: those in one
    func groups(ofPages pages: [BrowserTab]) -> [UUID: OpenTabGroup] {
        var byOpenTab: [UUID: OpenTabGroup] = [:]
        for tab in tabs {
            if let group = tab.group { byOpenTab[tab.id] = group }
        }
        var result: [UUID: OpenTabGroup] = [:]
        for page in pages {
            if let id = page.openTabID {
                result[page.id] = byOpenTab[id]
            } else if let group = pendingGroups[page.id] {
                result[page.id] = group
            }
        }
        return result
    }

    /// The group with this ID, as its tabs have it, while it has any
    func group(withID id: UUID) -> OpenTabGroup? {
        tabs.lazy.compactMap(\.group).first { $0.id == id }
            ?? pendingGroups.values.first { $0.id == id }
    }

    /// Whether a window's page can be in a group: an open tab, or a page
    /// that becomes one. Not a private tab, a page a script opened, an
    /// empty pane or a saved tab's page.
    func canGroup(_ page: BrowserTab, in window: TabManager) -> Bool {
        if page.openTabID != nil {
            return SidebarStore.shared.browserToSidebarTabMapping[page.id] == nil
        }
        return isOpenTabPage(page, in: window)
    }

    /// Moves a window's pages of regular tabs to just before
    /// `beforePageID` (the end with none), in this order, into `group` or,
    /// nil, out of any: their open tabs, in every window, or the ones they
    /// become. In one change, so a group never takes the place of a tab
    /// joining it.
    func movePages(_ pageIDs: [UUID], before beforePageID: UUID?, into group: OpenTabGroup?, in window: TabManager) {
        let pages = pageIDs.compactMap { id in window.tabs.first { $0.id == id } }
        for page in pages {
            assign(group, to: page)
        }
        window.reorderTabs(moving: pageIDs, before: beforePageID)
        guard isStarted else { return }
        takeOrder(of: window)
        groupsDidChange()
    }

    /// Puts pages in `group`, or with nil takes them out of theirs, where
    /// they are
    func setGroup(_ group: OpenTabGroup?, forPages pages: [BrowserTab]) {
        for page in pages {
            assign(group, to: page)
        }
        guard isStarted else { return }
        groupsDidChange()
    }

    /// Renames a group, or gives it an icon (empty for its favicons)
    func updateGroup(_ id: UUID, title: String? = nil, icon: String? = nil) {
        var changed = false
        func update(_ group: inout OpenTabGroup) {
            if let title, group.title != title { group.title = title; changed = true }
            if let icon, group.icon != icon { group.icon = icon; changed = true }
        }
        for index in tabs.indices where tabs[index].group?.id == id {
            update(&tabs[index].group!)
        }
        for (pageID, var group) in pendingGroups where group.id == id {
            update(&group)
            pendingGroups[pageID] = group
        }
        guard changed else { return }
        NotificationCenter.default.post(name: .openTabGroupsDidChange, object: nil)
        save()
    }

    /// Its tabs stay where they are, in no group
    func ungroup(_ id: UUID) {
        var changed = false
        for index in tabs.indices where tabs[index].group?.id == id {
            tabs[index].group = nil
            changed = true
        }
        let pending = pendingGroups.filter { $0.value.id == id }.map(\.key)
        for pageID in pending {
            pendingGroups[pageID] = nil
            changed = true
        }
        guard changed else { return }
        NotificationCenter.default.post(name: .openTabGroupsDidChange, object: nil)
        save()
    }

    /// Only an open tab, or a page that can become one, joins a group
    private func assign(_ group: OpenTabGroup?, to page: BrowserTab) {
        if let id = page.openTabID, let index = index(of: id) {
            tabs[index].group = group
        } else if let group, !page.isPrivate, !page.hasOpener {
            pendingGroups[page.id] = group
        } else {
            pendingGroups[page.id] = nil
        }
    }

    /// A group's tabs changed: together again, every window in step
    private func groupsDidChange() {
        gatherGroups()
        for window in windows {
            conform(window)
        }
        NotificationCenter.default.post(name: .openTabGroupsDidChange, object: nil)
        save()
    }

    /// Each group's tabs together, in their order, where its first one is.
    /// Whether that changed the order.
    @discardableResult
    private func gatherGroups() -> Bool {
        var members: [UUID: [OpenTab]] = [:]
        for tab in tabs {
            if let id = tab.group?.id { members[id, default: []].append(tab) }
        }
        guard !members.isEmpty else { return false }
        var placed: Set<UUID> = []
        var gathered: [OpenTab] = []
        gathered.reserveCapacity(tabs.count)
        for tab in tabs {
            guard let id = tab.group?.id else {
                gathered.append(tab)
                continue
            }
            if placed.insert(id).inserted {
                gathered.append(contentsOf: members[id] ?? [])
            }
        }
        guard gathered.map(\.id) != tabs.map(\.id) else { return false }
        tabs = gathered
        return true
    }

    // MARK: - Keeping the windows in step

    private func scheduleReconcile() {
        guard isStarted, !isReconcileScheduled else { return }
        isReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reconcile()
        }
    }

    /// Brings the windows and the open tabs in step: a window's new regular
    /// tab becomes an open tab, one that's saved now isn't one any more,
    /// and every window has a page of each open tab, in their order.
    private func reconcile() {
        isReconcileScheduled = false
        guard isStarted else { return }
        let windows = windows
        var hasChanged = false
        var hasJoinedGroups = false

        for window in windows {
            var hasLinkedPages = false
            for page in window.tabs where !closingPageIDs.contains(page.id) {
                if let id = page.openTabID {
                    if let savedTabID = SidebarStore.shared.browserToSidebarTabMapping[page.id] {
                        page.openTabID = nil
                        hasLinkedPages = true
                        if index(of: id) != nil {
                            remove(id, savedAs: savedTabID, keeping: page)
                            hasChanged = true
                        }
                    } else if index(of: id) == nil {
                        // Closed in another window or on another Mac
                        applying { close(page, in: window) }
                    }
                } else if isOpenTabPage(page, in: window) {
                    if add(page, in: window) {
                        hasJoinedGroups = true
                    }
                    hasLinkedPages = true
                    hasChanged = true
                }
            }
            if hasLinkedPages {
                window.openTabIDsDidChange()
            }
        }
        // Pages closed before they became open tabs, or that are ones now
        let pageIDs = Set(windows.flatMap { $0.tabs.map(\.id) })
        pendingGroups = pendingGroups.filter { pageIDs.contains($0.key) }
        let pagesWithoutOpenTab = Set(windows.flatMap { $0.tabs.filter { $0.openTabID == nil }.map(\.id) })
        formerSavedTabs = formerSavedTabs.filter { pagesWithoutOpenTab.contains($0.key) }
        if hasJoinedGroups {
            gatherGroups()
        }

        for window in windows {
            conform(window)
        }
        if hasJoinedGroups {
            NotificationCenter.default.post(name: .openTabGroupsDidChange, object: nil)
        }
        observePages(in: windows)
        closingPageIDs.formIntersection(windows.flatMap { $0.tabs.map(\.id) })
        if hasChanged {
            save()
        }
    }

    /// Whether a window's tab is a page of an open tab: a regular tab with
    /// a page, not a private one, a script's, an empty pane or one of Klar's
    /// own pages (`hasPage`)
    private func isOpenTabPage(_ page: BrowserTab, in window: TabManager) -> Bool {
        !page.isPrivate && !page.hasOpener && !window.isEmptyPane(page)
            && SidebarStore.shared.browserToSidebarTabMapping[page.id] == nil
            && Self.hasPage(page.url)
    }

    /// Klar's own pages (What's New) aren't anywhere else: another Mac's Klar
    /// may not know them.
    private static func hasPage(_ url: String) -> Bool {
        !url.isEmpty && url != "about:blank" && !KlarSchemeHandler.isPage(url)
    }

    private static func address(of page: BrowserTab) -> String {
        URLUtilities.removeTrackingParameters(from: page.url).cleanURL
    }

    /// A window's new regular tab, as an open tab: after the open tab of the
    /// page before it in the window. A removed saved tab's page is the open
    /// tab with the saved tab's ID (`formerSavedTabs`), joining it if
    /// another of its pages, or another Mac, made it already; a page that
    /// lost its open tab finds it again. Whether it joined a group
    /// meanwhile meant for it (`pendingGroups`).
    private func add(_ page: BrowserTab, in window: TabManager) -> Bool {
        let group = pendingGroups.removeValue(forKey: page.id)
        var newID = index(of: page.id) == nil ? page.id : UUID()
        if let savedTabID = formerSavedTabs[page.id] {
            let existingID: UUID? = index(of: savedTabID) != nil ? savedTabID
                : windows.lazy.flatMap(\.tabs)
                    .first(where: { $0 !== page && self.formerSavedTabs[$0.id] == savedTabID && $0.openTabID != nil })?.openTabID
            if let existingID, let index = index(of: existingID) {
                join(page, toOpenTabAt: index, group: group, in: window)
                return group != nil
            }
            // Closed once already (a saved tab back from Undo): not that one
            if closedTabs[savedTabID] == nil {
                newID = savedTabID
            }
        } else if let tab = lostOpenTab(of: page, in: window), let index = index(of: tab.id) {
            join(page, toOpenTabAt: index, group: group, in: window)
            return group != nil
        }
        let tab = OpenTab(id: newID, url: Self.address(of: page), title: page.title, spaceID: page.spaceID,
                          createdAt: page.createdAt, lastActiveAt: page.lastActiveAt, group: group)
        tabs.insert(tab, at: insertionIndex(for: page, in: window))
        page.openTabID = newID
        navigatedAddresses[page.id] = tab.url
        return group != nil
    }

    /// A page becomes the window's page of an open tab it already has: in
    /// another window, from another Mac. A page of it the window got
    /// meanwhile (`conform`, before the saved tab was removed here) goes:
    /// this is the one that was open.
    private func join(_ page: BrowserTab, toOpenTabAt index: Int, group: OpenTabGroup?, in window: TabManager) {
        let id = tabs[index].id
        page.openTabID = id
        if let group {
            tabs[index].group = group
        }
        if let other = window.tabs.first(where: { $0 !== page && $0.openTabID == id }) {
            applying { close(other, in: window) }
        }
    }

    /// The open tab a page without one was a page of, if the window has no
    /// other page of it: the one with its ID, or with its address, space
    /// and time it was opened. A Klar from before open tabs saves pages
    /// without theirs; each became an open tab of its own, the one it was
    /// a page of getting a new page beside it.
    private func lostOpenTab(of page: BrowserTab, in window: TabManager) -> OpenTab? {
        let linkedIDs = Set(window.tabs.compactMap(\.openTabID))
        let address = Self.address(of: page)
        return tabs.first { tab in
            guard !linkedIDs.contains(tab.id) else { return false }
            return tab.id == page.id
                || tab.url == address && tab.spaceID == page.spaceID
                    // Synced, it's to the second
                    && abs(tab.createdAt.timeIntervalSince(page.createdAt)) < 1
        }
    }

    /// Where a window's new open tab goes among them: after the open tab of
    /// the page before it in the window, else before the next one's
    private func insertionIndex(for page: BrowserTab, in window: TabManager) -> Int {
        guard let position = window.tabs.firstIndex(where: { $0 === page }) else { return tabs.endIndex }
        for earlier in window.tabs[..<position].reversed() {
            if let id = earlier.openTabID, let index = index(of: id) {
                return index + 1
            }
        }
        for later in window.tabs[(position + 1)...] {
            if let id = later.openTabID, let index = index(of: id) {
                return index
            }
        }
        return tabs.endIndex
    }

    /// A window with a page of every open tab, in their order. Its other
    /// tabs (saved tabs' pages, private tabs) keep their places.
    private func conform(_ window: TabManager) {
        var pages = window.tabs
        let present = Set(pages.compactMap(\.openTabID))
        var takenIDs = Set(windows.flatMap { $0.tabs.map(\.id) })
        var added: [BrowserTab] = []
        for (index, tab) in tabs.enumerated() where !present.contains(tab.id) {
            let page = makePage(of: tab, takenIDs: &takenIDs)
            pages.insert(page, at: pageIndex(forOpenTabAt: index, in: pages))
            added.append(page)
        }

        let order = Dictionary(tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = pages.indices.filter { pages[$0].openTabID.flatMap { order[$0] } != nil }
        let ordered = slots.map { pages[$0] }.sorted { a, b in
            (a.openTabID.flatMap { order[$0] } ?? 0) < (b.openTabID.flatMap { order[$0] } ?? 0)
        }
        for (slot, page) in zip(slots, ordered) {
            pages[slot] = page
        }
        guard !added.isEmpty || !pages.elementsEqual(window.tabs, by: ===) else { return }
        window.setOpenTabPages(pages, adding: added)
    }

    /// Where a new page goes among a window's tabs: after the page of the
    /// open tab before it, else before the next one's
    private func pageIndex(forOpenTabAt index: Int, in pages: [BrowserTab]) -> Int {
        for earlier in tabs[..<index].reversed() {
            if let position = pages.lastIndex(where: { $0.openTabID == earlier.id }) {
                return position + 1
            }
        }
        for later in tabs[(index + 1)...] {
            if let position = pages.firstIndex(where: { $0.openTabID == later.id }) {
                return position
            }
        }
        return pages.endIndex
    }

    /// A window's page of an open tab, without a web view until it's shown.
    /// The open tab's ID unless a page in a window has it (browser tab IDs
    /// are unique across windows) or a saved tab does: one that was a saved
    /// tab's page has its ID, and its row would select the saved tab.
    private func makePage(of tab: OpenTab, takenIDs: inout Set<UUID>) -> BrowserTab {
        let id = takenIDs.contains(tab.id) || SidebarStore.shared.structure.tabs[tab.id] != nil ? UUID() : tab.id
        takenIDs.insert(id)
        let page = BrowserTab(id: id, createdAt: tab.createdAt, url: tab.url, title: tab.title, lastActiveAt: tab.lastActiveAt)
        page.spaceID = tab.spaceID
        page.openTabID = tab.id
        page.markSuspended()
        return page
    }

    /// An open tab's page became a saved tab's (saved, pinned): the open
    /// tab goes, and with it its pages in other windows, but for one on
    /// screen there, which becomes that window's page of the saved tab.
    private func remove(_ id: UUID, savedAs savedTabID: UUID, keeping kept: BrowserTab) {
        guard let index = index(of: id) else { return }
        tabs.remove(at: index)
        closedTabs[id] = Date()
        applying {
            for window in windows {
                for page in window.tabs where page.openTabID == id && page !== kept {
                    if window.splitViews.isVisible(page.id), let sidebarManager = window.sidebarManager,
                       sidebarManager.sidebarToBrowserTabMapping[savedTabID] == nil {
                        page.openTabID = nil
                        sidebarManager.sidebarToBrowserTabMapping[savedTabID] = page.id
                        sidebarManager.browserToSidebarTabMapping[page.id] = savedTabID
                        if sidebarManager.selectedItem == page.id {
                            sidebarManager.selectedItem = savedTabID
                        }
                        window.openTabIDsDidChange()
                    } else {
                        close(page, in: window)
                    }
                }
            }
        }
    }

    private func closePages(of id: UUID, except kept: BrowserTab?) {
        for window in windows {
            for page in window.tabs where page.openTabID == id && page !== kept {
                close(page, in: window)
            }
        }
    }

    private func close(_ page: BrowserTab, in window: TabManager) {
        guard closingPageIDs.insert(page.id).inserted else { return }
        window.closeTab(page)
    }

    /// Runs `body` as the store's change, which windows' pages don't report
    private func applying(_ body: () -> Void) {
        let wasApplying = isApplying
        isApplying = true
        body()
        isApplying = wasApplying
    }

    // MARK: - Pages

    /// Follows every regular tab: an open tab's page navigating takes the
    /// open tab along, its title changing retitles it, and a new tab becomes
    /// one once it has a page.
    private func observePages(in windows: [TabManager]) {
        var pageIDs: Set<UUID> = []
        for window in windows {
            for page in window.tabs where !page.isPrivate {
                pageIDs.insert(page.id)
                guard pageObservations[page.id]?.page !== page else { continue }
                navigatedAddresses[page.id] = Self.address(of: page)
                let navigations = page.$ownNavigationCount.dropFirst()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak page] _ in
                        guard let self, let page else { return }
                        self.pageDidNavigate(page)
                    }
                let changes = page.$url.dropFirst().map { _ in () }
                    .merge(with: page.$title.dropFirst().map { _ in () })
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak page] in
                        guard let self, let page else { return }
                        self.pageDidChange(page)
                    }
                pageObservations[page.id] = PageObservation(page: page, cancellable: AnyCancellable {
                    navigations.cancel()
                    changes.cancel()
                })
            }
        }
        for id in pageObservations.keys where !pageIDs.contains(id) {
            pageObservations[id] = nil
            navigatedAddresses[id] = nil
        }
    }

    /// One of an open tab's pages went somewhere itself
    /// (`BrowserTab.ownNavigationCount`): the open tab goes there, and its
    /// other pages with it. Not a redirect or an address the page rewrote,
    /// nor a page following its open tab: two windows showing one never
    /// send each other back and forth.
    private func pageDidNavigate(_ page: BrowserTab) {
        guard isStarted, !isApplying else { return }
        let address = Self.address(of: page)
        navigatedAddresses[page.id] = address
        guard let id = page.openTabID, let index = index(of: id),
              !closingPageIDs.contains(page.id), Self.hasPage(page.url),
              SidebarStore.shared.browserToSidebarTabMapping[page.id] == nil,
              address != tabs[index].url else { return }
        tabs[index].url = address
        tabs[index].title = page.title
        apply(tabs[index], exceptTo: page)
        save()
    }

    /// A page's address or title changed (a turn later, both set by then):
    /// a new tab with a page is an open tab now, and the title of a live
    /// page where its open tab is is the open tab's
    private func pageDidChange(_ page: BrowserTab) {
        guard isStarted, !isApplying else { return }
        guard let id = page.openTabID else {
            if Self.hasPage(page.url) {
                scheduleReconcile()
            }
            return
        }
        guard let index = index(of: id), !closingPageIDs.contains(page.id), !page.isSuspended,
              navigatedAddresses[page.id] == tabs[index].url, page.title != tabs[index].title,
              SidebarStore.shared.browserToSidebarTabMapping[page.id] == nil else { return }
        tabs[index].title = page.title
        apply(tabs[index], exceptTo: page)
        save()
    }

    /// An open tab changed: each other page of it takes the change
    private func apply(_ tab: OpenTab, exceptTo source: BrowserTab?) {
        applying {
            for window in windows {
                for page in window.tabs where page.openTabID == tab.id && page !== source {
                    apply(tab, to: page, in: window)
                }
            }
        }
    }

    /// A page takes its open tab's space, when it was last used and where it
    /// is: on screen, it goes there now, its last page kept in its history;
    /// otherwise when it's shown next, its web view, if it has one, let go
    /// meanwhile.
    private func apply(_ tab: OpenTab, to page: BrowserTab, in window: TabManager) {
        page.lastActiveAt = max(page.lastActiveAt, tab.lastActiveAt)
        if page.spaceID != tab.spaceID {
            window.objectWillChange.send()
            page.spaceID = tab.spaceID
            NotificationCenter.default.post(name: .spaceTabsDidChange, object: window)
            window.spaceSelection?.openTabDidMove(page)
        }
        if navigatedAddresses[page.id] != tab.url {
            let isOnScreen = window.splitViews.isVisible(page.id)
            if !isOnScreen {
                window.suspendTab(page)
            }
            page.follow(url: tab.url, title: tab.title)
            navigatedAddresses[page.id] = tab.url
            window.updateFavicon(for: page, url: tab.url)
            if isOnScreen {
                TabWebViewCoordinator.coordinator(for: page.id)?.loadPendingNavigation()
            }
        } else if page.isSuspended, page.title != tab.title {
            page.title = tab.title
        }
    }

    // MARK: - Saving

    /// Whether anything was stored
    private func load() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        tabs = stored.tabs
        let cutoff = Date().addingTimeInterval(-Self.closedTabLifetime)
        closedTabs = stored.closedTabs.filter { $0.value > cutoff }
        return true
    }

    private func save() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: item)
        CloudSyncManager.localDataChanged(.openTabs)
    }

    private func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let data = try? JSONEncoder().encode(Stored(tabs: tabs, closedTabs: closedTabs)) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Settings › Tabs closes regular tabs as Klar quits: they close
    /// everywhere, as when they're closed by hand
    private func appWillTerminate() {
        if TOMLSettingsManager.shared.tabCloseAction == .whenClosingApp {
            for tab in tabs {
                closedTabs[tab.id] = Date()
            }
            tabs.removeAll()
        }
        saveNow()
    }
}

// MARK: - iCloud

private let openTabRecordType = "OpenTab"
private let openTabRecordPrefix = "opentab-"

/// A record per open tab (`opentab-<uuid>`): its address, title, space
/// and place in the list, when it was opened and, to the half hour, last
/// used, which the rules that close tabs go by on every Mac, and its group
/// (`groupID`, `groupTitle`, `groupIcon`; empty for none).
extension OpenTabStore: CloudSyncSource {
    var syncRecordTypes: Set<String> { [openTabRecordType] }

    var isReadyForSync: Bool { isStarted }

    var syncDeletedRecordNames: Set<String> {
        Set(closedTabs.keys.map(Self.recordName))
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        var records: [String: CloudSyncRecord] = [:]
        for (position, tab) in tabs.enumerated() {
            records[Self.recordName(tab.id)] = CloudSyncRecord(type: openTabRecordType, fields: [
                "url": .string(tab.url),
                "title": .string(tab.title),
                "spaceID": .string(tab.spaceID?.uuidString ?? ""),
                "position": .int(position),
                "createdAt": .seconds(tab.createdAt),
                // Using a tab isn't a change worth sending each time
                "lastActiveAt": .seconds(Self.toHalfHour(tab.lastActiveAt)),
                // Empty for none
                "groupID": .string(tab.group?.id.uuidString ?? ""),
                "groupTitle": .string(tab.group?.title ?? ""),
                "groupIcon": .string(tab.group?.icon ?? ""),
            ])
        }
        return records
    }

    /// Open tabs opened, changed and closed on other Macs. On this Mac's
    /// first sync, a tab open here and there (the same address, in the
    /// same space) is one tab.
    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        var closedIDs: [UUID] = []
        for name in deleted {
            guard let id = Self.tabID(fromRecordName: name), let index = index(of: id) else { continue }
            tabs.remove(at: index)
            closedIDs.append(id)
        }

        let savedIDs = Set(saved.keys.compactMap(Self.tabID(fromRecordName:)))
        var positions: [UUID: Int] = [:]
        var changedIDs: [UUID] = []
        var rekeyed: [(from: UUID, to: UUID)] = []
        for (name, record) in saved.sorted(by: { $0.key < $1.key }) {
            guard let id = Self.tabID(fromRecordName: name), closedTabs[id] == nil,
                  let url = record["url"]?.stringValue, Self.hasPage(url) else { continue }
            let spaceID = record["spaceID"]?.stringValue.flatMap(UUID.init(uuidString:))
            let group = record["groupID"]?.stringValue.flatMap(UUID.init(uuidString:)).map { groupID in
                OpenTabGroup(id: groupID, title: record["groupTitle"]?.stringValue ?? OpenTabGroup.defaultTitle,
                             icon: record["groupIcon"]?.stringValue ?? "")
            }
            var tab = OpenTab(
                id: id, url: url, title: record["title"]?.stringValue ?? url, spaceID: spaceID,
                createdAt: record["createdAt"]?.dateValue ?? Date(),
                lastActiveAt: record["lastActiveAt"]?.dateValue ?? .distantPast,
                group: group
            )
            positions[id] = record["position"]?.intValue
            if let index = index(of: id) {
                tab.lastActiveAt = max(tab.lastActiveAt, tabs[index].lastActiveAt)
                guard tab != tabs[index] else { continue }
                tabs[index] = tab
            } else if isInitialMerge,
                      let index = tabs.firstIndex(where: { !savedIDs.contains($0.id) && $0.url == url && $0.spaceID == spaceID }) {
                rekeyed.append((from: tabs[index].id, to: id))
                tab.lastActiveAt = max(tab.lastActiveAt, tabs[index].lastActiveAt)
                tabs[index] = tab
            } else {
                tabs.append(tab)
            }
            changedIDs.append(id)
        }
        if !positions.isEmpty {
            tabs = tabs.enumerated()
                .sorted { a, b in
                    (positions[a.element.id] ?? a.offset, a.offset) < (positions[b.element.id] ?? b.offset, b.offset)
                }
                .map(\.element)
        }
        // Another Mac's tabs in a group, with this one's: together
        gatherGroups()

        applying {
            for id in closedIDs {
                closePages(of: id, except: nil)
            }
            for (from, to) in rekeyed {
                for window in windows {
                    for page in window.tabs where page.openTabID == from {
                        page.openTabID = to
                        window.openTabIDsDidChange()
                    }
                }
            }
        }
        for id in changedIDs {
            if let tab = openTab(withID: id) {
                apply(tab, exceptTo: nil)
            }
        }
        reconcile()
        save()
        NotificationCenter.default.post(name: .openTabGroupsDidChange, object: nil)
        logInfo(.sync, "Applied \(changedIDs.count) open tabs and \(closedIDs.count) closed ones from iCloud")
    }

    private static func recordName(_ id: UUID) -> String {
        openTabRecordPrefix + id.uuidString
    }

    private static func tabID(fromRecordName name: String) -> UUID? {
        guard name.hasPrefix(openTabRecordPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(openTabRecordPrefix.count)))
    }

    private static func toHalfHour(_ date: Date) -> Date {
        let interval: TimeInterval = 30 * 60
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / interval).rounded(.down) * interval)
    }
}
