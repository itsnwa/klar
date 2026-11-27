import Foundation

private let tabRecordType = "SidebarTab"
private let folderRecordType = "SidebarFolder"
private let spaceRecordType = "SidebarSpace"
private let tabRecordPrefix = "tab-"
private let folderRecordPrefix = "folder-"
private let spaceRecordPrefix = "space-"
/// A pinned site's `spaceID`: it's in no space. An earlier Klar reads it as
/// no space and keeps the tab where it has it.
private let pinnedSpaceID = "pinned"

/// The sidebar's spaces, saved tabs and folders in iCloud (CloudSyncManager).
/// Every window's: what changes here for a window (its selection, its
/// expanded folders, an open pinned site) is told to each.
///
/// A tab syncs its URL (without tracking parameters), saved title, custom
/// title, space, folder and position; a folder its title, custom title,
/// icon, space, parent and position; a space its name, icon, color,
/// whether it has a separate profile, and position. A position is the
/// index within the parent, so the order on screen is what syncs. Whether a
/// tab is loaded, its live page title, recency, which folders are expanded,
/// and a profile's website data and history stay on each Mac. A tab or
/// folder without a space (from an earlier Klar) keeps the one it has here,
/// or goes to the first space. A pinned site is a tab whose space is
/// `pinned`, positioned in the pinned sites.
@MainActor
extension SidebarStore: CloudSyncSource {
    var syncRecordTypes: Set<String> {
        [tabRecordType, folderRecordType, spaceRecordType]
    }

    /// Not before every window's tabs and mappings are restored at launch.
    var isReadyForSync: Bool {
        let sidebarManagers = sidebarManagers
        return !sidebarManagers.isEmpty && !sidebarManagers.contains(where: \.isInitializing)
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        let structure = structure
        let positions = Self.positions(in: structure)
        var records: [String: CloudSyncRecord] = [:]
        records.reserveCapacity(structure.tabs.count + structure.folders.count + structure.collections.count)

        for (index, space) in structure.orderedCollections.enumerated() {
            records[spaceRecordPrefix + space.id.uuidString] = CloudSyncRecord(type: spaceRecordType, fields: [
                "name": .string(space.displayTitle),
                "icon": .string(space.icon.storageString),
                "color": .string(space.color.rawValue),
                "separateProfile": .bool(space.usesSeparateProfile),
                "position": .int(index),
                "createdAt": .seconds(space.createdAt)
            ])
        }
        let pinned = Set(structure.pinnedItems)
        for tab in structure.tabs.values {
            let spaceID = pinned.contains(tab.id) ? pinnedSpaceID : tab.collectionID?.uuidString ?? ""
            records[tabRecordPrefix + tab.id.uuidString] = CloudSyncRecord(type: tabRecordType, fields: [
                "url": .string(Self.syncedURL(tab.url)),
                "title": .string(tab.originalTitle ?? tab.title),
                "customTitle": .string(tab.customTitle ?? ""),
                "spaceID": .string(spaceID),
                "parentID": .string(tab.parentID?.uuidString ?? ""),
                "position": .int(positions[tab.id] ?? tab.order),
                "createdAt": .seconds(tab.createdAt)
            ])
        }
        for folder in structure.folders.values {
            records[folderRecordPrefix + folder.id.uuidString] = CloudSyncRecord(type: folderRecordType, fields: [
                "title": .string(folder.title),
                "customTitle": .string(folder.customTitle ?? ""),
                "icon": .string(folder.icon),
                "spaceID": .string(folder.collectionID?.uuidString ?? ""),
                "parentID": .string(folder.parentID?.uuidString ?? ""),
                "position": .int(positions[folder.id] ?? folder.order),
                "createdAt": .seconds(folder.createdAt)
            ])
        }
        return records
    }

    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        // The first Mac's merge brings nothing.
        guard !saved.isEmpty || !deleted.isEmpty else { return }
        var structure = structure
        // What each item sorts by in its parent: its synced position if that
        // changed, else where it is now.
        var positions = Self.positions(in: structure)
        var pinned = Set(structure.pinnedItems)

        var remoteTabs: [UUID: CloudSyncRecord] = [:]
        var remoteFolders: [UUID: CloudSyncRecord] = [:]
        var remoteSpaces: [UUID: CloudSyncRecord] = [:]
        for (name, record) in saved {
            if record.type == tabRecordType, let id = Self.itemID(fromRecordName: name, prefix: tabRecordPrefix) {
                remoteTabs[id] = record
            } else if record.type == folderRecordType, let id = Self.itemID(fromRecordName: name, prefix: folderRecordPrefix) {
                remoteFolders[id] = record
            } else if record.type == spaceRecordType, let id = Self.itemID(fromRecordName: name, prefix: spaceRecordPrefix) {
                remoteSpaces[id] = record
            }
        }

        if isInitialMerge {
            matchLocalSpaces(remoteSpaces, in: &structure)
            matchLocalItems(folders: remoteFolders, tabs: remoteTabs, in: &structure, positions: &positions)
        }

        // Spaces first, so the tabs and folders find theirs. Turning a
        // profile on or off reopens the space's tabs, which SpaceManager
        // does once the structure is in.
        var profileChanges: [(spaceID: UUID, isOn: Bool)] = []
        for (id, record) in remoteSpaces {
            let name = record["name"]?.stringValue ?? "Space"
            let existing = structure.collections[id]
            var space = existing ?? SidebarCollection(id: id, title: name)
            space.title = name
            space.customTitle = nil
            if let icon = record["icon"]?.stringValue.flatMap(SpaceIcon.init(storageString:)) {
                space.icon = icon
            }
            if let color = record["color"]?.stringValue.flatMap(SpaceColor.init(rawValue:)) {
                space.color = color
            }
            if let position = record["position"]?.intValue {
                space.order = position
            }
            if let createdAt = record["createdAt"]?.dateValue {
                space.createdAt = createdAt
            }
            let wantsProfile = record["separateProfile"]?.boolValue ?? space.usesSeparateProfile
            if existing == nil {
                // New here: its profile starts empty on this Mac.
                space.usesSeparateProfile = wantsProfile
                space.profileID = wantsProfile ? UUID() : nil
            } else if wantsProfile != space.usesSeparateProfile {
                profileChanges.append((id, wantsProfile))
            }
            structure.collections[id] = space
        }
        var removedProfileIDs: [UUID] = []
        for name in deleted {
            guard let id = Self.itemID(fromRecordName: name, prefix: spaceRecordPrefix),
                  let space = structure.collections[id], structure.collections.count > 1 else { continue }
            structure.collections[id] = nil
            if space.usesSeparateProfile, let profileID = space.profileID {
                removedProfileIDs.append(profileID)
            }
        }
        let collectionID = structure.ensureDefaultCollection()

        for (id, record) in remoteFolders {
            let title = record["title"]?.stringValue ?? "Group"
            var folder = structure.folders[id]
                ?? SidebarFolder(id: id, title: title, collectionID: collectionID, isExpanded: false)
            folder.title = title
            folder.customTitle = Self.nonEmpty(record["customTitle"])
            folder.icon = Self.nonEmpty(record["icon"]) ?? FolderIcons.defaultIcon
            if let spaceID = Self.spaceID(of: record), structure.collections[spaceID] != nil {
                folder.collectionID = spaceID
            }
            folder.parentID = Self.parentID(of: record)
            if let createdAt = record["createdAt"]?.dateValue {
                folder.createdAt = createdAt
            }
            structure.folders[id] = folder
            positions[id] = record["position"]?.intValue ?? positions[id]
        }

        for (id, record) in remoteTabs {
            let title = record["title"]?.stringValue ?? ""
            let url = record["url"]?.stringValue ?? ""
            var tab = structure.tabs[id]
                ?? SidebarTab(id: id, title: title, url: url, collectionID: collectionID, isUnloaded: true)
            tab.url = url
            tab.originalTitle = title
            tab.customTitle = Self.nonEmpty(record["customTitle"])
            if Self.isPinned(record) {
                tab.collectionID = nil
                pinned.insert(id)
            } else {
                pinned.remove(id)
                if let spaceID = Self.spaceID(of: record), structure.collections[spaceID] != nil {
                    tab.collectionID = spaceID
                }
            }
            // An open tab keeps showing its page's own title.
            if !isOpenInAnyWindow(id) {
                tab.title = title
            }
            tab.parentID = Self.isPinned(record) ? nil : Self.parentID(of: record)
            if let createdAt = record["createdAt"]?.dateValue {
                tab.createdAt = createdAt
                if structure.tabs[id] == nil {
                    tab.lastActiveAt = createdAt
                }
            }
            structure.tabs[id] = tab
            positions[id] = record["position"]?.intValue ?? positions[id]
        }

        // Pinned sites' tabs, loaded in the background, that are let go
        var closingTabIDs: [UUID] = []
        for name in deleted {
            if let id = Self.itemID(fromRecordName: name, prefix: tabRecordPrefix), structure.tabs[id] != nil {
                structure.tabs[id] = nil
                closingTabIDs.append(contentsOf: forgetSavedTab(id, wasPinned: structure.pinnedItems.contains(id)))
            } else if let id = Self.itemID(fromRecordName: name, prefix: folderRecordPrefix), structure.folders[id] != nil {
                structure.folders[id] = nil
                for sidebarManager in sidebarManagers {
                    sidebarManager.folderWasRemoved(id)
                }
            }
        }

        // Whatever was in a space that's gone goes to the first one.
        for (id, tab) in structure.tabs where !pinned.contains(id) && tab.collectionID.flatMap({ structure.collections[$0] }) == nil {
            structure.tabs[id]?.collectionID = collectionID
        }
        for (id, folder) in structure.folders where folder.collectionID.flatMap({ structure.collections[$0] }) == nil {
            structure.folders[id]?.collectionID = collectionID
        }

        Self.rebuildContainers(of: &structure, positions: positions, pinned: pinned)
        structure.lastUpdated = Date()
        self.structure = structure
        save()
        for browserTabID in closingTabIDs {
            BrowserWindowSession.owner(ofTab: browserTabID)?.tabManager.closeTab(withId: browserTabID)
        }

        let spaces = SpaceManager.shared
        for change in profileChanges {
            spaces.setSeparateProfile(change.isOn, forSpace: change.spaceID)
        }
        for profileID in removedProfileIDs {
            spaces.removeProfile(profileID)
        }
        logInfo(.sync, "Applied \(remoteSpaces.count) spaces, \(remoteTabs.count + remoteFolders.count) saved items and \(deleted.count) removals from iCloud")
    }

    // MARK: - Applying

    /// A saved tab removed on another Mac. If it's open here, the page stays
    /// open as a regular tab, except a pinned site's out of sight: always
    /// loaded in the background, it wasn't opened, so its tab is returned
    /// to be closed.
    private func forgetSavedTab(_ id: UUID, wasPinned: Bool) -> [UUID] {
        var closing: [UUID] = []
        var staying: [UUID] = []
        // Its page in each window that has one
        for sidebarManager in sidebarManagers {
            let page = sidebarManager.sidebarToBrowserTabMapping.removeValue(forKey: id)
            if let page {
                browserToSidebarTabMapping.removeValue(forKey: page)
            }
            sidebarManager.savedTabWasRemoved(id, leaving: page)
            if let page, wasPinned, let tabManager = sidebarManager.tabManager,
               tabManager.activeTabId != page, !tabManager.splitViews.isVisible(page) {
                closing.append(page)
            } else if let page {
                staying.append(page)
            }
        }
        // One regular tab, which every window has, with the saved tab's ID:
        // the one the Mac that removed it made of its page, if it had one
        OpenTabStore.shared.pagesWillBecomeOpenTab(staying, ofSavedTab: id)
        return closing
    }

    /// Puts every tab and folder in its parent's list, and the `pinned` tabs
    /// in the pinned sites, sorted by `positions`, and renumbers `order` to
    /// match. An item whose parent is gone, or that would make a folder its
    /// own ancestor, goes to the end of the root.
    private static func rebuildContainers(of structure: inout SidebarStructure, positions: [UUID: Int], pinned: Set<UUID>) {
        var detached: Set<UUID> = []

        // Sorted, so every Mac breaks a cycle at the same folder.
        for folderID in structure.folders.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var seen: Set<UUID> = [folderID]
            var ancestorID = structure.folders[folderID]?.parentID
            while let currentID = ancestorID {
                guard let ancestor = structure.folders[currentID], !seen.contains(currentID) else {
                    structure.folders[folderID]?.parentID = nil
                    detached.insert(folderID)
                    break
                }
                seen.insert(currentID)
                ancestorID = ancestor.parentID
            }
        }
        for (tabID, tab) in structure.tabs {
            if let parentID = tab.parentID, structure.folders[parentID] == nil {
                structure.tabs[tabID]?.parentID = nil
                detached.insert(tabID)
            }
        }

        var children: [UUID?: [UUID]] = [:]
        var pinnedTabs: [UUID] = []
        for tab in structure.tabs.values {
            if pinned.contains(tab.id) {
                pinnedTabs.append(tab.id)
            } else {
                children[tab.parentID, default: []].append(tab.id)
            }
        }
        for folder in structure.folders.values {
            children[folder.parentID, default: []].append(folder.id)
        }
        func sortKey(_ id: UUID) -> (Int, Int, String) {
            (detached.contains(id) ? 1 : 0, positions[id] ?? Int.max, id.uuidString)
        }
        func ordered(_ ids: [UUID]) -> [UUID] {
            ids.sorted { sortKey($0) < sortKey($1) }
        }

        structure.rootItems = ordered(children[nil] ?? [])
        structure.pinnedItems = ordered(pinnedTabs)
        for folderID in Array(structure.folders.keys) {
            structure.folders[folderID]?.childrenIds = ordered(children[folderID] ?? [])
        }

        func renumber(_ ids: [UUID]) {
            for (index, id) in ids.enumerated() {
                if structure.tabs[id] != nil {
                    structure.tabs[id]?.order = index
                } else {
                    structure.folders[id]?.order = index
                }
            }
        }
        renumber(structure.rootItems)
        renumber(structure.pinnedItems)
        for folder in Array(structure.folders.values) {
            renumber(folder.childrenIds)
        }
    }

    // MARK: - First sync

    /// This Mac's first sync: a space with the same name as one in iCloud
    /// takes its ID, and so does this Mac's first space with iCloud's first,
    /// so both Macs' first spaces become one.
    private func matchLocalSpaces(_ remoteSpaces: [UUID: CloudSyncRecord], in structure: inout SidebarStructure) {
        guard !remoteSpaces.isEmpty else { return }
        for remoteID in remoteSpaces.keys.sorted(by: { $0.uuidString < $1.uuidString }) where structure.collections[remoteID] == nil {
            let name = Self.matchText(remoteSpaces[remoteID]?["name"]?.stringValue ?? "")
            guard let local = structure.collections.values.first(where: {
                remoteSpaces[$0.id] == nil && Self.matchText($0.displayTitle) == name
            }) else { continue }
            rekeySpace(local.id, to: remoteID, in: &structure)
        }

        let remoteFirst = remoteSpaces.min {
            ($0.value["position"]?.intValue ?? Int.max, $0.key.uuidString) < ($1.value["position"]?.intValue ?? Int.max, $1.key.uuidString)
        }?.key
        if let remoteFirst, structure.collections[remoteFirst] == nil,
           let localFirst = structure.orderedCollections.first, remoteSpaces[localFirst.id] == nil {
            rekeySpace(localFirst.id, to: remoteFirst, in: &structure)
        }
    }

    private func rekeySpace(_ oldID: UUID, to newID: UUID, in structure: inout SidebarStructure) {
        guard let space = structure.collections.removeValue(forKey: oldID) else { return }
        var rekeyed = SidebarCollection(
            id: newID, title: space.title, customTitle: space.customTitle, order: space.order,
            isExpanded: space.isExpanded, icon: space.icon, color: space.color,
            usesSeparateProfile: space.usesSeparateProfile, profileID: space.profileID
        )
        rekeyed.createdAt = space.createdAt
        structure.collections[newID] = rekeyed
        for (id, tab) in structure.tabs where tab.collectionID == oldID {
            structure.tabs[id]?.collectionID = newID
        }
        for (id, folder) in structure.folders where folder.collectionID == oldID {
            structure.folders[id]?.collectionID = newID
        }
        SpaceManager.shared.spaceWasRekeyed(from: oldID, to: newID)
    }

    /// This Mac's first sync: a folder here with the same name in the same
    /// place as one in iCloud, or a tab with the same URL in the same
    /// folder, takes the iCloud item's ID, so it's matched rather than added
    /// a second time.
    private func matchLocalItems(
        folders remoteFolders: [UUID: CloudSyncRecord],
        tabs remoteTabs: [UUID: CloudSyncRecord],
        in structure: inout SidebarStructure,
        positions: inout [UUID: Int]
    ) {
        struct MatchKey: Hashable {
            let parentID: UUID?
            let text: String
            var isPinned = false
        }

        // Parents before their subfolders, so those are looked for inside
        // the matched parent.
        func depth(_ id: UUID) -> Int {
            var depth = 0
            var seen: Set<UUID> = [id]
            var parentID = remoteFolders[id].flatMap { Self.parentID(of: $0) }
            while let currentID = parentID, let parent = remoteFolders[currentID], !seen.contains(currentID) {
                depth += 1
                seen.insert(currentID)
                parentID = Self.parentID(of: parent)
            }
            return depth
        }
        let depths = Dictionary(uniqueKeysWithValues: remoteFolders.keys.map { ($0, depth($0)) })
        let orderedFolderIDs = remoteFolders.keys.sorted {
            (depths[$0] ?? 0, $0.uuidString) < (depths[$1] ?? 0, $1.uuidString)
        }

        var matchedFolders = 0
        for remoteID in orderedFolderIDs where structure.folders[remoteID] == nil {
            guard let record = remoteFolders[remoteID] else { continue }
            let key = MatchKey(
                parentID: Self.parentID(of: record),
                text: Self.matchText(Self.nonEmpty(record["customTitle"]) ?? record["title"]?.stringValue ?? "")
            )
            // Looked up afresh each time: matching a parent moves its
            // subfolders under the new ID.
            guard let local = structure.folders.values.first(where: { folder in
                remoteFolders[folder.id] == nil
                    && MatchKey(parentID: folder.parentID, text: Self.matchText(folder.displayTitle)) == key
            }) else { continue }
            rekeyFolder(local.id, to: remoteID, in: &structure, positions: &positions)
            matchedFolders += 1
        }

        var localTabs: [MatchKey: [UUID]] = [:]
        let pinned = Set(structure.pinnedItems)
        for tab in structure.tabs.values where remoteTabs[tab.id] == nil {
            let key = MatchKey(parentID: tab.parentID, text: Self.matchURL(tab.url), isPinned: pinned.contains(tab.id))
            localTabs[key, default: []].append(tab.id)
        }
        var matchedTabs = 0
        for remoteID in remoteTabs.keys.sorted(by: { $0.uuidString < $1.uuidString }) where structure.tabs[remoteID] == nil {
            guard let record = remoteTabs[remoteID] else { continue }
            let key = MatchKey(
                parentID: Self.isPinned(record) ? nil : Self.parentID(of: record),
                text: Self.matchURL(record["url"]?.stringValue ?? ""),
                isPinned: Self.isPinned(record)
            )
            guard var candidates = localTabs[key], !candidates.isEmpty else { continue }
            let localID = candidates.removeFirst()
            localTabs[key] = candidates
            rekeyTab(localID, to: remoteID, in: &structure, positions: &positions)
            matchedTabs += 1
        }

        if matchedFolders + matchedTabs > 0 {
            logInfo(.sync, "Matched \(matchedFolders) folders and \(matchedTabs) saved tabs to iCloud's")
        }
    }

    private func rekeyTab(_ oldID: UUID, to newID: UUID, in structure: inout SidebarStructure, positions: inout [UUID: Int]) {
        guard let tab = structure.tabs.removeValue(forKey: oldID) else { return }
        var rekeyed = SidebarTab(
            id: newID, title: tab.title, url: tab.url, createdAt: tab.createdAt,
            parentID: tab.parentID, collectionID: tab.collectionID, customTitle: tab.customTitle,
            originalTitle: tab.originalTitle, order: tab.order, isUnloaded: tab.isUnloaded,
            lastActiveAt: tab.lastActiveAt
        )
        rekeyed.estimatedProgress = tab.estimatedProgress
        rekeyed.isLoading = tab.isLoading
        structure.tabs[newID] = rekeyed
        positions[newID] = positions.removeValue(forKey: oldID)

        // Its pages, in each window, follow (itemWasRekeyed)
        for sidebarManager in sidebarManagers {
            sidebarManager.itemWasRekeyed(from: oldID, to: newID)
        }
    }

    private func rekeyFolder(_ oldID: UUID, to newID: UUID, in structure: inout SidebarStructure, positions: inout [UUID: Int]) {
        guard let folder = structure.folders.removeValue(forKey: oldID) else { return }
        var rekeyed = SidebarFolder(
            id: newID, title: folder.title, parentID: folder.parentID, collectionID: folder.collectionID,
            customTitle: folder.customTitle, order: folder.order, isExpanded: folder.isExpanded, icon: folder.icon
        )
        rekeyed.createdAt = folder.createdAt
        rekeyed.childrenIds = folder.childrenIds
        structure.folders[newID] = rekeyed
        positions[newID] = positions.removeValue(forKey: oldID)

        for (id, tab) in structure.tabs where tab.parentID == oldID {
            structure.tabs[id]?.parentID = newID
        }
        for (id, child) in structure.folders where child.parentID == oldID {
            structure.folders[id]?.parentID = newID
        }
        for sidebarManager in sidebarManagers {
            sidebarManager.itemWasRekeyed(from: oldID, to: newID)
        }
    }

    // MARK: - Helpers

    /// Each item's index within its parent's list, or the pinned sites.
    private static func positions(in structure: SidebarStructure) -> [UUID: Int] {
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(structure.tabs.count + structure.folders.count)
        for (index, id) in structure.rootItems.enumerated() {
            positions[id] = index
        }
        for (index, id) in structure.pinnedItems.enumerated() {
            positions[id] = index
        }
        for folder in structure.folders.values {
            for (index, id) in folder.childrenIds.enumerated() {
                positions[id] = index
            }
        }
        return positions
    }

    /// The URL as saved to disk: without tracking parameters.
    /// Addresses with their tracking parameters taken out, as worked out
    /// earlier: every sidebar save builds every tab's record again, and
    /// taking them out parses the address.
    private static var syncedURLs: [String: String] = [:]

    private static func syncedURL(_ url: String) -> String {
        guard url.contains("?") else { return url }
        if let synced = syncedURLs[url] {
            return synced
        }
        let synced = URLUtilities.removeTrackingParameters(from: url).cleanURL
        // Addresses edited or deleted since stay until there are many
        if syncedURLs.count >= 4096 {
            syncedURLs.removeAll(keepingCapacity: true)
        }
        syncedURLs[url] = synced
        return synced
    }

    private static func itemID(fromRecordName name: String, prefix: String) -> UUID? {
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    private static func parentID(of record: CloudSyncRecord) -> UUID? {
        record["parentID"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Nil when the record has no space: from a Klar before spaces.
    private static func spaceID(of record: CloudSyncRecord) -> UUID? {
        record["spaceID"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    private static func isPinned(_ record: CloudSyncRecord) -> Bool {
        record["spaceID"]?.stringValue == pinnedSpaceID
    }

    private static func nonEmpty(_ value: CloudSyncValue?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    private static func matchText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchURL(_ url: String) -> String {
        var url = matchText(syncedURL(url))
        if url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }
}
