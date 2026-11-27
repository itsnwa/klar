import Foundation
import SwiftUI

/// Manages all folder-specific operations for the sidebar
class SidebarFolderManager {
    private weak var sidebarManager: SidebarManager?
    
    init(sidebarManager: SidebarManager) {
        self.sidebarManager = sidebarManager
    }
    
    // MARK: - Folder Management
    
    func createFolder(title: String = OpenTabGroup.defaultTitle, in parentID: UUID? = nil) -> UUID {
        guard let manager = sidebarManager else { return UUID() }
        
        // Validate operation before proceeding
        let operation = FolderOperation.create(parentID: parentID)
        switch SidebarValidation.validateFolderOperation(operation, in: manager.sidebarStructure) {
        case .success():
            break
        case .failure(let error):
            logError(.sidebar, "Failed to create folder: \(error.localizedDescription)")
            return UUID()
        }
        
        // The parent folder's space, else the active one
        let defaultCollectionID = manager.collectionIDForNewItem(in: parentID)
        
        let folder = SidebarFolder(
            title: title, 
            parentID: parentID,
            collectionID: defaultCollectionID,
            order: manager.getNextOrderValue(in: parentID),
            icon: SidebarConfiguration.defaultFolderIcon
        )
        
        var newStructure = manager.sidebarStructure
        newStructure.addItem(folder, to: parentID, collectionID: defaultCollectionID)
        manager.sidebarStructure = newStructure
        
        manager.expandedFolders.insert(folder.id)
        manager.saveSidebarStructure()
        
        // Scroll to the newly created folder if it's outside the visible area
        // Add a small delay to ensure the folder is rendered in the UI first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            manager.scrollToItem(folder.id)
        }
        
        return folder.id
    }
    
    /// Deletes a folder. Its saved tabs and folders take its place, or with
    /// `includingContents` are deleted too, and their open tabs close.
    func deleteFolder(_ folderID: UUID, includingContents: Bool) {
        guard let manager = sidebarManager, manager.sidebarStructure.folders[folderID] != nil else { return }
        let contents = includingContents
            ? manager.sidebarStructure.contents(ofFolder: folderID)
            : (tabIDs: [], folderIDs: [])
        let deletedFolderIDs = Set(contents.folderIDs).union([folderID])

        // In one change with its saved tabs, removed before their browser
        // tabs close: closing them would unload them.
        manager.removeTabs(withIDs: contents.tabIDs, closingTheirTabs: true) { structure in
            for subfolderID in contents.folderIDs {
                structure.folders[subfolderID] = nil
            }
            structure.removeItem(withID: folderID)
        }
        manager.expandedFolders.subtract(deletedFolderIDs)
        if let selected = manager.selectedItem, deletedFolderIDs.contains(selected) {
            manager.selectedItem = nil
        }
        logInfo(.sidebar, "Deleted folder \(folderID)\(includingContents ? " and its contents" : "")")
    }

    func toggleFolderExpansion(_ folderID: UUID) {
        guard let manager = sidebarManager else { return }
        
        // IMMEDIATE UI UPDATE: Toggle state instantly without any checks or delays
        if manager.expandedFolders.contains(folderID) {
            manager.expandedFolders.remove(folderID)
        } else {
            manager.expandedFolders.insert(folderID)
        }
        
        // No save operations, no debouncing, no background work
        // The @Published property change triggers immediate UI update
    }
    
    // MARK: - Folder Validation
    
    /// Calculate the nesting depth of a folder (0 = root level, 1 = first level, etc.)
    func calculateNestingDepth(for folderID: UUID) -> Int {
        guard let manager = sidebarManager else { return 0 }

        var depth = 0
        var currentFolderID: UUID? = folderID
        var seen: Set<UUID> = []

        while let currentID = currentFolderID {
            if seen.contains(currentID) {
                logWarning(.sidebar, "calculateNestingDepth: cycle detected at \(currentID); aborting traversal")
                break
            }
            seen.insert(currentID)

            if let folder = manager.sidebarStructure.folders[currentID] {
                currentFolderID = folder.parentID
                if currentFolderID != nil {
                    depth += 1
                }
            } else {
                break
            }
        }

        return depth
    }
    
    /// Check if a folder can be dropped into another folder
    func canDropFolder(_ draggedFolderID: UUID, into targetFolderID: UUID, maxNestingLevel: Int = SidebarConfiguration.maxNestingLevel) -> Bool {
        guard sidebarManager != nil else { return false }

        // Prevent dropping a folder into itself or any of its descendants —
        // either would make the dragged folder its own ancestor (cycle).
        // The check is: "is target one of dragged's descendants?", which is
        // `isFolderDescendant(target, of: dragged)`. The args were
        // historically swapped, which is how the News-and-Blogs/Gaming
        // cycle slipped through and corrupted the persisted structure.
        if draggedFolderID == targetFolderID || isFolderDescendant(targetFolderID, of: draggedFolderID) {
            return false
        }

        // Check if target folder has room for another nesting level
        let targetDepth = calculateNestingDepth(for: targetFolderID)
        return targetDepth < maxNestingLevel - 1
    }

    /// Check if a folder is a descendant of another folder.
    ///
    /// Walks the parent chain from `folderID` upward, returning true if
    /// `ancestorID` appears anywhere along the way. A `seen` set guards
    /// against pre-existing cycles in the data — without it, a corrupt
    /// `parentID` chain (e.g. A.parent = B, B.parent = A) would loop
    /// forever and hang the app.
    private func isFolderDescendant(_ folderID: UUID, of ancestorID: UUID) -> Bool {
        guard let manager = sidebarManager else { return false }

        var currentFolderID: UUID? = folderID
        var seen: Set<UUID> = []

        while let currentID = currentFolderID {
            if seen.contains(currentID) {
                logWarning(.sidebar, "isFolderDescendant: cycle detected at \(currentID); aborting traversal")
                return false
            }
            seen.insert(currentID)

            if let folder = manager.sidebarStructure.folders[currentID] {
                if folder.parentID == ancestorID {
                    return true
                }
                currentFolderID = folder.parentID
            } else {
                break
            }
        }

        return false
    }
} 