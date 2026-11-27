import Foundation
import SwiftUI

/// Manages all drag and drop operations for the sidebar
class SidebarDragDropManager {
    private weak var sidebarManager: SidebarManager?
    
    init(sidebarManager: SidebarManager) {
        self.sidebarManager = sidebarManager
    }
    
    // MARK: - Drag and Drop Operations
    
    func moveItem(withID itemID: UUID, to folderID: UUID?) {
        guard let manager = sidebarManager else { return }
        
        // Validate folder drops for nesting levels
        if manager.sidebarStructure.folders[itemID] != nil,
           let folderID = folderID {
            if !manager.folderManager.canDropFolder(itemID, into: folderID) {
                logWarning(.sidebar, "Cannot move folder \(itemID) to folder \(folderID) - would exceed max nesting level or create circular reference")
                return
            }
        }
        
        var newStructure = manager.sidebarStructure
        
        // Find and remove the item from its current location
        if let (currentParent, currentIndex) = manager.findItemLocation(itemID: itemID, in: newStructure),
           let currentIndex = currentIndex {
            if let currentParent = currentParent {
                newStructure.folders[currentParent]?.childrenIds.remove(at: currentIndex)
            } else {
                newStructure.rootItems.remove(at: currentIndex)
            }
        }
        newStructure.pinnedItems.removeAll { $0 == itemID }
        
        // Update the item's parent relationship
        if var tab = newStructure.tabs[itemID] {
            tab.parentID = folderID
            newStructure.tabs[itemID] = tab
        } else if var folder = newStructure.folders[itemID] {
            folder.parentID = folderID
            newStructure.folders[itemID] = folder
        }
        
        // Add to new location
        if let folderID = folderID {
            if newStructure.folders[folderID] != nil {
                newStructure.folders[folderID]!.childrenIds.append(itemID)
            }
        } else {
            newStructure.rootItems.append(itemID)
        }

        assignSpace(to: itemID, containerID: folderID, collectionID: nil, in: &newStructure)
        newStructure.lastUpdated = Date()
        
        // Reassign to trigger @Published updates
        manager.sidebarStructure = newStructure
        
        // Save immediately
        manager.saveSidebarStructure()
    }
    
    func moveItemToPosition(_ itemID: UUID, containerID: UUID?, index: Int, collectionID: UUID? = nil) {
        guard let manager = sidebarManager else { return }
        
        logDebug(.dragDrop, "moveItemToPosition: item=\(itemID), container=\(containerID?.uuidString ?? "root"), index=\(index)")
        
        // Get the current location of the item
        let currentLocation = manager.findItemLocation(itemID: itemID, in: manager.sidebarStructure)
        let currentParentID = currentLocation?.0
        let currentIndex = currentLocation?.1
        
        logDebug(.dragDrop, "Current: parent=\(currentParentID?.uuidString ?? "root"), index=\(currentIndex ?? -1)")
        
        // Check if we're moving within the same container
        let isSameContainer = currentParentID == containerID
        logDebug(.dragDrop, "Same container: \(isSameContainer)")
        
        // Validate folder drops for nesting levels ONLY when moving to different containers
        if !isSameContainer && manager.sidebarStructure.folders[itemID] != nil {
            if let containerID = containerID {
                if !manager.folderManager.canDropFolder(itemID, into: containerID) {
                    logWarning(.dragDrop, "Cannot move folder \(itemID) to container \(containerID) - would exceed max nesting level or create circular reference")
                    return
                }
            }
        } else if isSameContainer {
            logDebug(.dragDrop, "Same container reordering - skipping nesting validation")
        }
        
        // Calculate the actual target index
        var actualTargetIndex = index
        if isSameContainer, let currentIdx = currentIndex, currentIdx < index {
            // If moving within same container and current position is before target,
            // we need to adjust target index down by 1 because removal will shift indices
            actualTargetIndex = index - 1
        }
        
        logDebug(.dragDrop, "Actual target index: \(actualTargetIndex)")
        
        // First, update the parent relationship
        updateItemParentRelationship(itemID: itemID, newParentID: containerID)
        
        // Remove item from its current location
        var newStructure = manager.sidebarStructure
        
        if let (currentParent, currentIndex) = manager.findItemLocation(itemID: itemID, in: newStructure),
           let currentIndex = currentIndex {
            if let currentParent = currentParent {
                newStructure.folders[currentParent]?.childrenIds.remove(at: currentIndex)
            } else {
                newStructure.rootItems.remove(at: currentIndex)
            }
        }
        // A pinned site moved into the space's tabs is no longer pinned
        newStructure.pinnedItems.removeAll { $0 == itemID }
        
        // Get target container items (after removal)
        var targetItems: [UUID]
        if let containerID = containerID {
            targetItems = newStructure.folders[containerID]?.childrenIds ?? []
        } else {
            targetItems = newStructure.rootItems
        }
        
        logDebug(.dragDrop, "Target items before insert: \(targetItems)")
        
        // Insert at adjusted target position
        let insertIndex = min(max(0, actualTargetIndex), targetItems.count)
        targetItems.insert(itemID, at: insertIndex)
        
        logDebug(.dragDrop, "Target items after insert: \(targetItems)")
        
        // Update the container
        if let containerID = containerID {
            newStructure.folders[containerID]?.childrenIds = targetItems
        } else {
            newStructure.rootItems = targetItems
        }
        
        // Update order properties
        newStructure.reorderItems(targetItems, in: containerID)
        assignSpace(to: itemID, containerID: containerID, collectionID: collectionID, in: &newStructure)
        newStructure.lastUpdated = Date()
        
        // Apply changes
        manager.sidebarStructure = newStructure
        manager.saveSidebarStructure()
        
        logDebug(.dragDrop, "moveItemToPosition completed")
    }
    
    // MARK: - Helper Methods

    /// An item moved into a folder takes the folder's space; one moved to
    /// the top level, the space it was dropped in (the active one, unless
    /// `collectionID` says otherwise). Everything in a folder goes with it.
    private func assignSpace(to itemID: UUID, containerID: UUID?, collectionID: UUID?, in structure: inout SidebarStructure) {
        let target = collectionID
            ?? containerID.flatMap { structure.folders[$0]?.collectionID }
            ?? sidebarManager?.spaceSelection?.currentSpaceID
        guard let target, structure.collections[target] != nil,
              structure.collectionID(ofItem: itemID) != target else { return }
        structure.assignCollection(target, toItemAndDescendants: itemID)
    }
    
    private func updateItemParentRelationship(itemID: UUID, newParentID: UUID?) {
        guard let manager = sidebarManager else { return }
        
        if var tab = manager.sidebarStructure.tabs[itemID] {
            tab.parentID = newParentID
            manager.sidebarStructure.tabs[itemID] = tab
        } else if var folder = manager.sidebarStructure.folders[itemID] {
            folder.parentID = newParentID
            manager.sidebarStructure.folders[itemID] = folder
        }
    }
} 