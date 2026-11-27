import Foundation

/// Saved tabs worth removing (Clean Up Saved Tabs…): the same page saved
/// more than once, and tabs not opened in months. Worked out on this Mac,
/// from the saved addresses alone.
nonisolated enum SavedTabCleanup {
    /// Saved tabs of one page, the one to keep first.
    struct DuplicateGroup: Identifiable {
        let key: String
        let tabIDs: [UUID]
        var id: String { key }
    }

    /// The same page whatever way the address is written: http or https,
    /// with or without `www.`, a trailing slash, a fragment (not a `#/…`
    /// route, which is a page of its own), tracking parameters, or its
    /// parameters in another order.
    static func comparableKey(for address: String) -> String? {
        let cleaned = URLUtilities.removeTrackingParameters(from: address).cleanURL
        guard let components = URLComponents(string: cleaned),
              let scheme = components.scheme?.lowercased(),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let sameScheme = (scheme == "http" || scheme == "https") ? "web" : scheme
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        var key = "\(sameScheme)://\(host)"
        if let port = components.port, !(port == 80 || port == 443) {
            key += ":\(port)"
        }
        key += path
        if let query = components.percentEncodedQuery, !query.isEmpty {
            key += "?" + query.split(separator: "&").sorted().joined(separator: "&")
        }
        if let fragment = components.percentEncodedFragment, fragment.hasPrefix("/") || fragment.hasPrefix("!") {
            key += "#" + fragment
        }
        return key
    }

    /// Pages saved more than once, in sidebar order. In each, the one to
    /// keep comes first: a pinned site, else one with a title of its own,
    /// else the one opened last.
    static func duplicates(in structure: SidebarStructure) -> [DuplicateGroup] {
        let order = sidebarOrder(of: structure)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let pinned = Set(structure.pinnedItems)

        var byKey: [String: [UUID]] = [:]
        for id in order {
            guard let tab = structure.tabs[id], !tab.isEmpty, let key = comparableKey(for: tab.url) else { continue }
            byKey[key, default: []].append(id)
        }

        return byKey.compactMap { key, ids -> DuplicateGroup? in
            guard ids.count > 1 else { return nil }
            let ranked = ids.sorted { a, b in
                let tabA = structure.tabs[a]!, tabB = structure.tabs[b]!
                if pinned.contains(a) != pinned.contains(b) { return pinned.contains(a) }
                if (tabA.customTitle != nil) != (tabB.customTitle != nil) { return tabA.customTitle != nil }
                if tabA.lastActiveAt != tabB.lastActiveAt { return tabA.lastActiveAt > tabB.lastActiveAt }
                return position[a, default: 0] < position[b, default: 0]
            }
            return DuplicateGroup(key: key, tabIDs: ranked)
        }
        .sorted { position[$0.tabIDs[0], default: 0] < position[$1.tabIDs[0], default: 0] }
    }

    /// Saved tabs (not pinned sites, which stay loaded) last opened before
    /// `cutoff`, longest unopened first.
    static func notOpened(since cutoff: Date, in structure: SidebarStructure) -> [UUID] {
        let pinned = Set(structure.pinnedItems)
        return sidebarOrder(of: structure)
            .filter { id in
                guard !pinned.contains(id), let tab = structure.tabs[id] else { return false }
                return tab.lastActiveAt < cutoff
            }
            .sorted { structure.tabs[$0]!.lastActiveAt < structure.tabs[$1]!.lastActiveAt }
    }

    /// Where a saved tab is: "Pinned", or its space and folders, "Work › Design".
    static func location(of tabID: UUID, in structure: SidebarStructure) -> String {
        if structure.pinnedItems.contains(tabID) {
            return "Pinned"
        }
        var parts: [String] = []
        var parentID = structure.tabs[tabID]?.parentID
        var seen: Set<UUID> = []
        while let id = parentID, seen.insert(id).inserted, let folder = structure.folders[id] {
            parts.insert(folder.displayTitle, at: 0)
            parentID = folder.parentID
        }
        if let spaceID = structure.tabs[tabID]?.collectionID, let space = structure.collections[spaceID] {
            parts.insert(space.displayTitle, at: 0)
        }
        return parts.joined(separator: " › ")
    }

    /// Every saved tab, as the sidebar shows them: pinned sites, then each
    /// space's in turn, folders' contents in place.
    static func sidebarOrder(of structure: SidebarStructure) -> [UUID] {
        var order = structure.pinnedItems.filter { structure.tabs[$0] != nil }
        var seen = Set(order)
        func visit(_ id: UUID) {
            guard seen.insert(id).inserted else { return }
            if structure.tabs[id] != nil {
                order.append(id)
            } else if let folder = structure.folders[id] {
                folder.childrenIds.forEach(visit)
            }
        }
        for space in structure.orderedCollections {
            for id in structure.rootItems where structure.collectionID(ofItem: id) == space.id {
                visit(id)
            }
        }
        return order
    }
}
