import Foundation
import SwiftUI

// MARK: - Enhanced Sidebar Data Models

// Base protocol for sidebar items (tabs and folders)
nonisolated protocol SidebarItem: Codable, Identifiable {
    var id: UUID { get }
    var title: String { get set }
    var createdAt: Date { get }
    var parentID: UUID? { get set }
    var customTitle: String? { get set }
    var order: Int { get set }
}

// A space: its saved tabs and folders (by `collectionID`), the regular tabs
// opened in it (`BrowserTab.spaceID`), and how its button looks.
nonisolated struct SidebarCollection: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var customTitle: String?
    var order: Int
    var isExpanded: Bool

    var icon: SpaceIcon
    var color: SpaceColor
    /// Website data and history of its own, in the data store and history
    /// store named by `profileID`.
    var usesSeparateProfile: Bool
    /// A new one each time the profile is turned on, so turning it off and on
    /// again starts empty while the old store is still being removed.
    var profileID: UUID?

    var displayTitle: String {
        return customTitle ?? title
    }

    init(id: UUID = UUID(), title: String, customTitle: String? = nil, order: Int = 0, isExpanded: Bool = true,
         icon: SpaceIcon = .letter, color: SpaceColor = .blue,
         usesSeparateProfile: Bool = false, profileID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.customTitle = customTitle
        self.order = order
        self.isExpanded = isExpanded
        self.icon = icon
        self.color = color
        self.usesSeparateProfile = usesSeparateProfile
        self.profileID = profileID
    }

    static func == (lhs: SidebarCollection, rhs: SidebarCollection) -> Bool {
        return lhs.id == rhs.id
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, customTitle, order, isExpanded
        case icon, color, usesSeparateProfile, profileID
    }

    // Collections saved before spaces have no icon, color or profile.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        icon = (try? container.decodeIfPresent(SpaceIcon.self, forKey: .icon)) ?? .letter
        color = (try? container.decodeIfPresent(SpaceColor.self, forKey: .color)) ?? .blue
        usesSeparateProfile = try container.decodeIfPresent(Bool.self, forKey: .usesSeparateProfile) ?? false
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(order, forKey: .order)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(icon, forKey: .icon)
        try container.encode(color, forKey: .color)
        try container.encode(usesSeparateProfile, forKey: .usesSeparateProfile)
        try container.encodeIfPresent(profileID, forKey: .profileID)
    }
}

// Enhanced tab model for sidebar persistence
nonisolated struct SidebarTab: SidebarItem, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var parentID: UUID?
    var customTitle: String?
    var originalTitle: String? // The title when tab was first saved, used for restoration when unloaded
    var order: Int
    
    // Tab-specific properties
    var url: String
    var isUnloaded: Bool // No page in any window, only its row (SidebarStore.isOpenInAnyWindow)
    var lastActiveAt: Date
    var estimatedProgress: Double
    var isLoading: Bool
    
    // Collection assignment
    var collectionID: UUID?
    
    // Computed properties
    var displayTitle: String {
        // Priority: customTitle > originalTitle (when unloaded) > title
        if let customTitle = customTitle {
            return customTitle
        } else if isUnloaded, let originalTitle = originalTitle {
            return originalTitle
        } else {
            return title
        }
    }
    
    var isEmpty: Bool {
        return url.isEmpty || url == "about:blank"
    }
    
    // Initialize from BrowserTab
    @MainActor init(from browserTab: BrowserTab, parentID: UUID? = nil, collectionID: UUID? = nil, order: Int = 0) {
        self.id = UUID() // Generate new UUID for each sidebar tab instance
        self.title = browserTab.title
        self.createdAt = browserTab.createdAt
        self.parentID = parentID
        self.customTitle = nil
        self.originalTitle = browserTab.title // Store original title for restoration when unloaded
        self.order = order
        self.url = browserTab.url
        self.isUnloaded = false
        self.lastActiveAt = Date()
        self.estimatedProgress = browserTab.estimatedProgress
        self.isLoading = browserTab.isLoading
        self.collectionID = collectionID
    }
    
    // Manual initializer
    init(id: UUID = UUID(), title: String, url: String, createdAt: Date = Date(), 
         parentID: UUID? = nil, collectionID: UUID? = nil, customTitle: String? = nil, 
         originalTitle: String? = nil, order: Int = 0, isUnloaded: Bool = false, 
         lastActiveAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.parentID = parentID
        self.customTitle = customTitle
        self.originalTitle = originalTitle ?? title // Default to title if not provided
        self.order = order
        self.url = url
        self.isUnloaded = isUnloaded
        self.lastActiveAt = lastActiveAt
        self.estimatedProgress = 0.0
        self.isLoading = false
        self.collectionID = collectionID
    }
    
    /// Its page as a browser tab, with an ID of its own: one sharing the
    /// saved tab's, left open as a regular tab once it's no longer the saved
    /// tab's page, would select the saved tab when its row is clicked.
    @MainActor func toBrowserTab() -> BrowserTab {
        let browserTab = BrowserTab(id: UUID(), createdAt: createdAt, url: url, title: title)
        browserTab.estimatedProgress = estimatedProgress
        browserTab.isLoading = isLoading
        
        // Favicon will be loaded asynchronously via FaviconCacheManager
        // This avoids blocking the main thread during tab restoration
        
        return browserTab
    }
    
    static func == (lhs: SidebarTab, rhs: SidebarTab) -> Bool {
        return lhs.id == rhs.id
    }
    
    // MARK: - Codable Implementation

    // Same keys as the property names, so the synthesized decoder reads
    // what this writes. `isUnloaded` keeps the name it was saved under,
    // `isOffloaded`. (A stored `faviconCacheKey` that nothing read is gone;
    // older files that still have it decode fine.)
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, parentID, customTitle, originalTitle, order
        case url, lastActiveAt, estimatedProgress, isLoading, collectionID
        case isUnloaded = "isOffloaded"
    }

    // Written out by hand: reflecting over every property with Mirror cost
    // several times more for each of the hundreds of saved tabs on every
    // sidebar save.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(originalTitle, forKey: .originalTitle)
        try container.encode(order, forKey: .order)
        // Save clean URL without tracking parameters
        try container.encode(URLUtilities.removeTrackingParameters(from: url).cleanURL, forKey: .url)
        try container.encode(isUnloaded, forKey: .isUnloaded)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(estimatedProgress, forKey: .estimatedProgress)
        try container.encode(isLoading, forKey: .isLoading)
        try container.encodeIfPresent(collectionID, forKey: .collectionID)
    }
}

// Folder model for organizing tabs
nonisolated struct SidebarFolder: SidebarItem, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var parentID: UUID?
    var customTitle: String?
    var order: Int
    
    // Folder-specific properties
    var isExpanded: Bool
    var icon: String // Changed from color to icon
    var childrenIds: [UUID] // IDs of tabs and subfolders
    
    // Collection assignment
    var collectionID: UUID?
    
    var displayTitle: String {
        return customTitle ?? title
    }
    
    init(id: UUID = UUID(), title: String, parentID: UUID? = nil, collectionID: UUID? = nil,
         customTitle: String? = nil, order: Int = 0,
         isExpanded: Bool = true, icon: String = "folder.fill") {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.parentID = parentID
        self.customTitle = customTitle
        self.order = order
        self.isExpanded = isExpanded
        self.icon = icon
        self.childrenIds = []
        self.collectionID = collectionID
    }
    
    static func == (lhs: SidebarFolder, rhs: SidebarFolder) -> Bool {
        return lhs.id == rhs.id
    }
}

// SF Symbols dynamic discovery and management
nonisolated struct FolderIcons {
    /// Stored for a group without an icon of its own (from when groups were
    /// folders): it shows its tabs' favicons (`SidebarGroupIcon`)
    static let defaultIcon = "folder.fill"
    /// What stands for such a group where its favicons don't show
    static let groupSymbol = "square.stack.fill"

    /// A group's icon as a symbol, emoji or brand icon to show: its own, else
    /// `groupSymbol` (also for a brand icon Klar no longer has)
    static func symbol(for icon: String) -> String {
        if icon.isEmpty || icon == defaultIcon || CuratedFolderIcons.isRetiredBrandIcon(icon) {
            return groupSymbol
        }
        return CuratedFolderIcons.renamedBrandIcons[icon] ?? icon
    }
    
    /// Check if a symbol name is valid (exists in the system)
    static func isValidIcon(_ icon: String) -> Bool {
        return CuratedFolderIcons.isValidIcon(icon)
    }
    
    /// Filter symbols based on search text
    static func filterIcons(_ searchText: String) -> [String] {
        return CuratedFolderIcons.filterIcons(searchText)
    }
}

// Container for the entire sidebar structure
nonisolated struct SidebarStructure: Codable {
    var version: Int = 4 // 3: collections, 4: collections are spaces (migrateToSpaces)
    var collections: [UUID: SidebarCollection] = [:]
    var tabs: [UUID: SidebarTab] = [:]
    var folders: [UUID: SidebarFolder] = [:]
    var rootItems: [UUID] = [] // Top-level items in display order
    /// Pinned sites, in the order of the grid: saved tabs of no space or folder.
    var pinnedItems: [UUID] = []
    var lastUpdated: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case version, collections, tabs, folders, rootItems, pinnedItems, lastUpdated
    }

    // Ensure there's always a default collection: the first space
    mutating func ensureDefaultCollection() -> UUID {
        if collections.isEmpty {
            let defaultCollection = SidebarCollection.makeDefaultSpace()
            collections[defaultCollection.id] = defaultCollection
            return defaultCollection.id
        }

        return orderedCollections.first?.id ?? UUID()
    }
    
    // MARK: - Performance-Optimized Collection Methods
    
    /// A space's top level: its part of `rootItems`, in that order (the
    /// order drops index into; `order` isn't kept up to date at the root).
    func getCollectionItems(for collectionID: UUID) -> [any SidebarItem] {
        rootItems.compactMap { id -> (any SidebarItem)? in
            if let tab = tabs[id] {
                return tab.collectionID == collectionID ? tab : nil
            }
            if let folder = folders[id] {
                return folder.collectionID == collectionID ? folder : nil
            }
            return nil
        }
    }
    
    // Add item to structure
    mutating func addItem(_ item: any SidebarItem, to parentID: UUID? = nil, collectionID: UUID? = nil) {
        let targetCollectionID = collectionID ?? ensureDefaultCollection()
        
        if var tab = item as? SidebarTab {
            tab.collectionID = targetCollectionID
            tabs[tab.id] = tab
        } else if var folder = item as? SidebarFolder {
            folder.collectionID = targetCollectionID
            folders[folder.id] = folder
        }
        
        if let parentID = parentID {
            // Add to folder
            if var folder = folders[parentID] {
                if !folder.childrenIds.contains(item.id) {
                    folder.childrenIds.append(item.id)
                    folders[parentID] = folder
                }
            }
        } else {
            // Add to root
            if !rootItems.contains(item.id) {
                rootItems.append(item.id)
            }
        }
        
        lastUpdated = Date()
    }
    
    // Remove item from structure
    mutating func removeItem(withID id: UUID) {
        // Remove from parent if it has one
        if let tab = tabs[id] {
            removeFromParent(itemID: id, parentID: tab.parentID)
            tabs.removeValue(forKey: id)
        } else if let folder = folders[id] {
            // Its children take its place in its parent
            let parentID = folder.parentID.flatMap { folders[$0] != nil ? $0 : nil }
            let children = folder.childrenIds.filter { tabs[$0] != nil || folders[$0] != nil }
            for childID in children {
                tabs[childID]?.parentID = parentID
                folders[childID]?.parentID = parentID
            }

            var siblings = parentID.flatMap { folders[$0]?.childrenIds } ?? rootItems
            siblings.removeAll { children.contains($0) }
            if let index = siblings.firstIndex(of: id) {
                siblings.replaceSubrange(index...index, with: children)
            } else {
                siblings.append(contentsOf: children)
            }
            folders.removeValue(forKey: id)
            reorderItems(siblings, in: parentID)
        }
        
        lastUpdated = Date()
    }
    
    /// Every saved tab and folder inside a folder, its subfolders' included.
    func contents(ofFolder folderID: UUID) -> (tabIDs: [UUID], folderIDs: [UUID]) {
        var tabIDs: [UUID] = []
        var folderIDs: [UUID] = []
        var pending = folders[folderID]?.childrenIds ?? []
        var seen: Set<UUID> = [folderID]
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            if tabs[id] != nil {
                tabIDs.append(id)
            } else if let folder = folders[id] {
                folderIDs.append(id)
                pending.append(contentsOf: folder.childrenIds)
            }
        }
        return (tabIDs, folderIDs)
    }

    // Helper to remove item from its parent
    private mutating func removeFromParent(itemID: UUID, parentID: UUID?) {
        if let parentID = parentID {
            if var folder = folders[parentID] {
                folder.childrenIds.removeAll { $0 == itemID }
                folders[parentID] = folder
            }
        } else {
            rootItems.removeAll { $0 == itemID }
            pinnedItems.removeAll { $0 == itemID }
        }
    }
    
    // Reorder items within a parent
    mutating func reorderItems(_ orderedIDs: [UUID], in parentID: UUID?) {
        if let parentID = parentID {
            if var folder = folders[parentID] {
                folder.childrenIds = orderedIDs
                folders[parentID] = folder
            }
        } else {
            rootItems = orderedIDs
        }
        
        // Update order values
        for (index, id) in orderedIDs.enumerated() {
            if var tab = tabs[id] {
                tab.order = index
                tabs[id] = tab
            } else if var folder = folders[id] {
                folder.order = index
                folders[id] = folder
            }
        }
        
        lastUpdated = Date()
    }
} 

/// The favicons a group without an icon shows, stacked: its first tabs'
/// sites, one of each.
nonisolated enum SidebarGroupFavicons {
    static let maxCount = 3

    /// The first `maxCount` addresses of different sites (host and port),
    /// in order
    static func urls(from addresses: some Sequence<String>) -> [String] {
        var sites: Set<String> = []
        var result: [String] = []
        for address in addresses where !address.isEmpty && address != "about:blank" {
            let url = URL(string: address)
            let site = url?.host().map { "\($0.lowercased()):\(url?.port ?? 0)" } ?? address
            guard sites.insert(site).inserted else { continue }
            result.append(address)
            if result.count == maxCount { break }
        }
        return result
    }
}

nonisolated extension SidebarStructure {
    /// The addresses whose favicons a saved group shows: its tabs', in the
    /// order its rows show them, those in groups in it too
    func faviconURLs(inFolder folderID: UUID) -> [String] {
        var addresses: [String] = []
        var seen: Set<UUID> = []
        func visit(_ id: UUID) {
            guard addresses.count < 32, seen.insert(id).inserted else { return }
            if let tab = tabs[id] {
                addresses.append(tab.url)
            } else if let folder = folders[id] {
                folder.childrenIds.forEach(visit)
            }
        }
        folders[folderID]?.childrenIds.forEach(visit)
        return SidebarGroupFavicons.urls(from: addresses)
    }
}

// In an extension, so the structure keeps its memberwise and empty initializers.
nonisolated extension SidebarStructure {
    // Structures from before pinned sites have no `pinnedItems`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        collections = try container.decode([UUID: SidebarCollection].self, forKey: .collections)
        tabs = try container.decode([UUID: SidebarTab].self, forKey: .tabs)
        folders = try container.decode([UUID: SidebarFolder].self, forKey: .folders)
        rootItems = try container.decode([UUID].self, forKey: .rootItems)
        pinnedItems = try container.decodeIfPresent([UUID].self, forKey: .pinnedItems) ?? []
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
    }
}
