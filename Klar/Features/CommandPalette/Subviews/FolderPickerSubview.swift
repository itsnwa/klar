import Foundation

enum FolderPickerSubview {
    static func rows(intent: FolderPickerIntent,
                     parentID: UUID?,
                     filter: String,
                     sidebar: SidebarManager) -> [PaletteSubviewRow] {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmedFilter.isEmpty {
            // No search: commit row at top + direct children of the current level.
            let commit = makeCommitRow(intent: intent, parentID: parentID, sidebar: sidebar)
            let direct = childFolders(at: parentID, sidebar: sidebar)
            return [commit] + direct.map { folderRow(for: $0, path: nil, sidebar: sidebar) }
        }

        // Searching: flatten everything from this level downwards.
        // Search results always commit on selection so the breadcrumb path stays in sync.
        let flattened = flattenedFolders(at: parentID, sidebar: sidebar, currentPath: [])
        let matches = flattened.filter { entry in
            entry.folder.displayTitle.lowercased().contains(trimmedFilter)
        }
        return matches.map { entry in
            folderRow(for: entry.folder, path: entry.path, sidebar: sidebar, treatAsLeaf: true)
        }
    }

    enum Decision: Equatable {
        case ignore
        case commit(parentID: UUID?)
        case push(PaletteSubviewFrame)
    }

    static func resolve(row: PaletteSubviewRow,
                        currentParentID: UUID?,
                        sidebar: SidebarManager) -> Decision {
        switch row.kind {
        case .commitHere:
            return .commit(parentID: currentParentID)
        case .folder(let folderID, let hasSubfolders):
            if hasSubfolders, let folder = sidebar.sidebarStructure.folders[folderID] {
                return .push(PaletteSubviewFrame(
                    id: folderID,
                    title: folder.displayTitle,
                    context: .folder(parentID: folderID)
                ))
            } else {
                return .commit(parentID: folderID)
            }
        case .explore:
            return .ignore
        }
    }

    // MARK: - Builders

    private static func makeCommitRow(intent: FolderPickerIntent,
                                      parentID: UUID?,
                                      sidebar: SidebarManager) -> PaletteSubviewRow {
        let actionWord = intent == .save ? "Save to" : "Move to"
        let folder = parentID.flatMap { sidebar.sidebarStructure.folders[$0] }
        let destinationName = folder?.displayTitle ?? rootCollectionName(sidebar: sidebar)
        let icon = folder.map { FolderIcons.symbol(for: $0.icon) } ?? defaultRootIcon(for: intent)
        return PaletteSubviewRow(
            id: "commit-here",
            title: "\(actionWord) \(destinationName)",
            subtitle: nil,
            systemIcon: icon,
            kind: .commitHere
        )
    }

    private static func defaultRootIcon(for intent: FolderPickerIntent) -> String {
        switch intent {
        case .save: return "folder.badge.plus.fill"
        case .move: return "folder.fill"
        }
    }

    /// The space a tab saved at the top level goes in: the active one.
    static func rootCollectionName(sidebar: SidebarManager) -> String {
        sidebar.sidebarStructure.collections[sidebar.collectionIDForNewItem(in: nil)]?.displayTitle ?? "Saved"
    }

    private static func folderRow(for folder: SidebarFolder,
                                  path: String?,
                                  sidebar: SidebarManager,
                                  treatAsLeaf: Bool = false) -> PaletteSubviewRow {
        let hasSubfolders = treatAsLeaf
            ? false
            : folder.childrenIds.contains { sidebar.sidebarStructure.folders[$0] != nil }
        return PaletteSubviewRow(
            id: "folder-\(folder.id.uuidString)",
            title: folder.displayTitle,
            subtitle: (path?.isEmpty ?? true) ? nil : path,
            systemIcon: FolderIcons.symbol(for: folder.icon),
            kind: .folder(folder.id, hasSubfolders: hasSubfolders)
        )
    }

    // MARK: - Folder traversal

    private static func childFolders(at parentID: UUID?, sidebar: SidebarManager) -> [SidebarFolder] {
        if let parentID = parentID {
            guard let parent = sidebar.sidebarStructure.folders[parentID] else { return [] }
            return parent.childrenIds.compactMap { sidebar.sidebarStructure.folders[$0] }
        } else {
            // The active space's folders
            let spaceID = sidebar.spaceSelection?.currentSpaceID
            return sidebar.sidebarStructure.rootItems.compactMap {
                sidebar.sidebarStructure.folders[$0]
            }.filter { spaceID == nil || $0.collectionID == spaceID }
        }
    }

    private static func flattenedFolders(at parentID: UUID?,
                                         sidebar: SidebarManager,
                                         currentPath: [String]) -> [(folder: SidebarFolder, path: String)] {
        var results: [(SidebarFolder, String)] = []
        let direct = childFolders(at: parentID, sidebar: sidebar)
        for folder in direct {
            let path = currentPath.isEmpty ? "" : currentPath.joined(separator: " > ")
            results.append((folder, path))
            let nested = flattenedFolders(
                at: folder.id,
                sidebar: sidebar,
                currentPath: currentPath + [folder.displayTitle]
            )
            results.append(contentsOf: nested)
        }
        return results
    }
}
