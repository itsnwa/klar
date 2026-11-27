import Foundation

/// Another browser's spaces, pinned tabs, folders and favorites
/// (`ImportedSidebar`), brought into the sidebar (Settings › Import,
/// onboarding). Running it again adds only what's new: a space goes into the
/// Klar space of the same name, folders are matched by name, and a tab
/// already in the same place is left out.
extension SidebarManager {
    struct SidebarImportResult {
        var newSpaces = 0
        var tabs = 0
        var pinnedSites = 0

        var isEmpty: Bool { newSpaces == 0 && tabs == 0 && pinnedSites == 0 }
    }

    /// `spaceIDs`: the spaces to bring in. Favorites become pinned sites.
    @discardableResult
    func importSidebar(_ sidebar: ImportedSidebar, spaceIDs: Set<String>, includeFavorites: Bool) -> SidebarImportResult {
        var structure = sidebarStructure
        var result = SidebarImportResult()

        for importedSpace in sidebar.spaces where spaceIDs.contains(importedSpace.id) {
            let spaceID = Self.space(for: importedSpace, in: &structure, result: &result)
            result.tabs += Self.insert(importedSpace.items, into: nil, space: spaceID, structure: &structure)
        }

        if includeFavorites {
            var pinnedURLs = Set(structure.pinnedItems.compactMap { structure.tabs[$0].map { Self.comparableURL($0.url) } })
            for favorite in sidebar.favorites where pinnedURLs.insert(Self.comparableURL(favorite.url)).inserted {
                let tab = Self.savedTab(favorite, parentID: nil, collectionID: nil, order: structure.pinnedItems.count)
                structure.tabs[tab.id] = tab
                structure.pinnedItems.append(tab.id)
                result.pinnedSites += 1
            }
        }

        guard !result.isEmpty else { return result }
        structure.lastUpdated = Date()
        sidebarStructure = structure
        saveSidebarStructure()
        logInfo(.sidebar, "Imported from \(sidebar.source.name): \(result.newSpaces) new spaces, \(result.tabs) tabs, \(result.pinnedSites) pinned sites")
        return result
    }

    /// The Klar space of the same name, or a new one after the others.
    private static func space(for importedSpace: ImportedSpace, in structure: inout SidebarStructure, result: inout SidebarImportResult) -> UUID {
        let existing = structure.orderedCollections
        if let match = existing.first(where: { $0.displayTitle.localizedCaseInsensitiveCompare(importedSpace.title) == .orderedSame }) {
            return match.id
        }

        let usedColors = Set(existing.map(\.color))
        let color = importedSpace.color
            ?? SpaceColor.allCases.first { !usedColors.contains($0) }
            ?? SpaceColor.allCases[existing.count % SpaceColor.allCases.count]
        // Website data isn't copied from the other browser: the profile starts empty
        let space = SidebarCollection(
            title: importedSpace.title,
            order: (existing.map(\.order).max() ?? -1) + 1,
            icon: importedSpace.icon,
            color: color,
            usesSeparateProfile: importedSpace.usesSeparateProfile,
            profileID: importedSpace.usesSeparateProfile ? UUID() : nil
        )
        structure.collections[space.id] = space
        result.newSpaces += 1
        return space.id
    }

    /// Adds `items` at the end of a folder, or of a space's top level.
    /// Returns how many tabs were added.
    private static func insert(_ items: [ImportedItem], into parentID: UUID?, space spaceID: UUID, structure: inout SidebarStructure) -> Int {
        var existingURLs = Set(siblings(in: parentID, space: spaceID, structure).compactMap {
            structure.tabs[$0].map { comparableURL($0.url) }
        })
        var added = 0

        for item in items {
            switch item {
            case .tab(let importedTab):
                guard existingURLs.insert(comparableURL(importedTab.url)).inserted else { continue }
                let tab = savedTab(importedTab, parentID: parentID, collectionID: spaceID, order: 0)
                structure.tabs[tab.id] = tab
                append(tab.id, to: parentID, structure: &structure)
                added += 1

            case .folder(let title, let icon, let children):
                let folderID: UUID
                let match = siblings(in: parentID, space: spaceID, structure).first {
                    structure.folders[$0]?.displayTitle.localizedCaseInsensitiveCompare(title) == .orderedSame
                }
                if let match {
                    folderID = match
                } else {
                    var folder = SidebarFolder(title: title, parentID: parentID, collectionID: spaceID, isExpanded: false)
                    if let icon {
                        folder.icon = icon.stored
                    }
                    structure.folders[folder.id] = folder
                    append(folder.id, to: parentID, structure: &structure)
                    folderID = folder.id
                }
                added += insert(children, into: folderID, space: spaceID, structure: &structure)
            }
        }
        return added
    }

    /// What's in a folder, or at a space's top level.
    private static func siblings(in parentID: UUID?, space spaceID: UUID, _ structure: SidebarStructure) -> [UUID] {
        if let parentID {
            return structure.folders[parentID]?.childrenIds ?? []
        }
        return structure.rootItems.filter { structure.collectionID(ofItem: $0) == spaceID }
    }

    /// At the end of the folder or of `rootItems`, its order its position there.
    private static func append(_ itemID: UUID, to parentID: UUID?, structure: inout SidebarStructure) {
        let order: Int
        if let parentID {
            structure.folders[parentID]?.childrenIds.append(itemID)
            order = (structure.folders[parentID]?.childrenIds.count ?? 1) - 1
        } else {
            structure.rootItems.append(itemID)
            order = structure.rootItems.count - 1
        }
        structure.tabs[itemID]?.order = order
        structure.folders[itemID]?.order = order
    }

    private static func savedTab(_ importedTab: ImportedTab, parentID: UUID?, collectionID: UUID?, order: Int) -> SidebarTab {
        SidebarTab(
            title: importedTab.title,
            url: importedTab.url,
            parentID: parentID,
            collectionID: collectionID,
            customTitle: importedTab.customTitle,
            order: order,
            isUnloaded: true
        )
    }

    /// As saved tabs store it, so a tab saved earlier matches.
    private static func comparableURL(_ url: String) -> String {
        URLUtilities.removeTrackingParameters(from: url).cleanURL
    }
}
