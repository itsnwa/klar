import Foundation

/// Validation utilities for sidebar operations
struct SidebarValidation {
    
    // MARK: - Structure Validation
    
    static func validateStructureIntegrity(_ structure: SidebarStructure) -> SidebarResult<Void> {
        // Check for orphaned items
        let orphanedItems = findOrphanedItems(in: structure)
        if !orphanedItems.isEmpty {
            return .failure(.invalidConfiguration("Found \(orphanedItems.count) orphaned items"))
        }
        
        // Check for circular references in folders
        if let circularFolder = findCircularReference(in: structure) {
            return .failure(.invalidConfiguration("Circular reference detected for folder: \(circularFolder)"))
        }
        
        // Check nesting depth
        for folder in structure.folders.values {
            let depth = calculateFolderDepth(folder.id, in: structure)
            if depth > SidebarConfiguration.maxNestingLevel {
                return .failure(.nestingLevelExceeded(depth))
            }
        }
        
        return .success(())
    }
    
    private static func findOrphanedItems(in structure: SidebarStructure) -> [UUID] {
        var orphanedItems: [UUID] = []
        
        // Check tabs
        for tab in structure.tabs.values {
            if let parentID = tab.parentID {
                if structure.folders[parentID] == nil {
                    orphanedItems.append(tab.id)
                }
            }
        }
        
        // Check folders
        for folder in structure.folders.values {
            if let parentID = folder.parentID {
                if structure.folders[parentID] == nil {
                    orphanedItems.append(folder.id)
                }
            }
        }
        
        return orphanedItems
    }
    
    private static func findCircularReference(in structure: SidebarStructure) -> UUID? {
        for folder in structure.folders.values {
            if hasCircularReference(folderID: folder.id, in: structure) {
                return folder.id
            }
        }
        return nil
    }
    
    private static func hasCircularReference(folderID: UUID, in structure: SidebarStructure, visited: Set<UUID> = []) -> Bool {
        if visited.contains(folderID) {
            return true
        }
        
        guard let folder = structure.folders[folderID],
              let parentID = folder.parentID else {
            return false
        }
        
        var newVisited = visited
        newVisited.insert(folderID)
        
        return hasCircularReference(folderID: parentID, in: structure, visited: newVisited)
    }
    
    private static func calculateFolderDepth(_ folderID: UUID, in structure: SidebarStructure) -> Int {
        var depth = 0
        var currentFolderID: UUID? = folderID
        
        while let currentID = currentFolderID {
            if let folder = structure.folders[currentID] {
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
    
    // MARK: - Operation Validation
    
    static func validateFolderOperation(_ operation: FolderOperation, in structure: SidebarStructure) -> SidebarResult<Void> {
        switch operation {
        case .create(let parentID):
            if let parentID = parentID {
                guard structure.folders[parentID] != nil else {
                    return .failure(.folderNotFound(parentID))
                }
                
                let depth = calculateFolderDepth(parentID, in: structure)
                if depth >= SidebarConfiguration.maxNestingLevel - 1 {
                    return .failure(.nestingLevelExceeded(depth + 1))
                }
            }
            return .success(())
        }
    }
}

// MARK: - Operation Types

enum FolderOperation {
    case create(parentID: UUID?)
}

// MARK: - Auto-repair Utilities

struct SidebarAutoRepair {
    
    static func repairStructure(_ structure: inout SidebarStructure) -> [String] {
        var repairActions: [String] = []
        
        // Remove orphaned items
        let orphanedTabs = findOrphanedTabs(in: structure)
        for tabID in orphanedTabs {
            if var tab = structure.tabs[tabID] {
                tab.parentID = nil
                structure.tabs[tabID] = tab
                if !structure.rootItems.contains(tabID) {
                    structure.rootItems.append(tabID)
                }
                repairActions.append("Moved orphaned tab \(tabID) to root")
            }
        }
        
        let orphanedFolders = findOrphanedFolders(in: structure)
        for folderID in orphanedFolders {
            if var folder = structure.folders[folderID] {
                folder.parentID = nil
                structure.folders[folderID] = folder
                if !structure.rootItems.contains(folderID) {
                    structure.rootItems.append(folderID)
                }
                repairActions.append("Moved orphaned folder \(folderID) to root")
            }
        }
        
        // Fix order inconsistencies
        repairOrderProperties(&structure)
        repairActions.append("Fixed order property inconsistencies")
        
        return repairActions
    }
    
    private static func findOrphanedTabs(in structure: SidebarStructure) -> [UUID] {
        return structure.tabs.values.compactMap { tab in
            if let parentID = tab.parentID,
               structure.folders[parentID] == nil {
                return tab.id
            }
            return nil
        }
    }
    
    private static func findOrphanedFolders(in structure: SidebarStructure) -> [UUID] {
        return structure.folders.values.compactMap { folder in
            if let parentID = folder.parentID,
               structure.folders[parentID] == nil {
                return folder.id
            }
            return nil
        }
    }
    
    private static func repairOrderProperties(_ structure: inout SidebarStructure) {
        // Fix root items
        for (index, itemID) in structure.rootItems.enumerated() {
            if var tab = structure.tabs[itemID] {
                tab.order = index
                structure.tabs[itemID] = tab
            } else if var folder = structure.folders[itemID] {
                folder.order = index
                structure.folders[itemID] = folder
            }
        }
        
        // Fix folder children
        for folder in structure.folders.values {
            for (index, childID) in folder.childrenIds.enumerated() {
                if var tab = structure.tabs[childID] {
                    tab.order = index
                    structure.tabs[childID] = tab
                } else if var childFolder = structure.folders[childID] {
                    childFolder.order = index
                    structure.folders[childID] = childFolder
                }
            }
        }
    }
} 