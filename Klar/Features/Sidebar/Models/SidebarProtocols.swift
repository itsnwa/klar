import Foundation
import SwiftUI
import Combine

// MARK: - Configuration Management

struct SidebarConfiguration {
    // Nesting and organization
    static let maxNestingLevel: Int = 4
    static let defaultFolderIcon: String = "folder.fill"
    
    static let tabHistorySize: Int = 25
    
    // Debounce timers
    static let saveDebounceInterval: TimeInterval = 0.5
    
    // File paths and persistence
    static let sidebarFileName: String = "SidebarStructure.json"
    static let appSupportDirectoryName: String = "Klar"
}

// MARK: - Error Types

enum SidebarError: LocalizedError {
    case persistenceFailure(String)
    case invalidConfiguration(String)
    case mappingNotFound(UUID)
    case nestingLevelExceeded(Int)
    case tabNotFound(UUID)
    case folderNotFound(UUID)
    
    var errorDescription: String? {
        switch self {
        case .persistenceFailure(let message):
            return "Persistence error: \(message)"
        case .invalidConfiguration(let message):
            return "Configuration error: \(message)"
        case .mappingNotFound(let id):
            return "Mapping not found for ID: \(id)"
        case .nestingLevelExceeded(let level):
            return "Nesting level \(level) exceeds maximum allowed"
        case .tabNotFound(let id):
            return "Tab not found: \(id)"
        case .folderNotFound(let id):
            return "Folder not found: \(id)"
        }
    }
}

// MARK: - Result Types

typealias SidebarResult<T> = Result<T, SidebarError>
