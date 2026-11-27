import Foundation
import AppKit

class SidebarPersistenceManager {
    static let shared = SidebarPersistenceManager()
    
    private var sidebarStructureURL: URL {
        // Get the proper Application Support directory using system APIs
        let fileManager = FileManager.default
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, 
                                                          in: .userDomainMask).first else {
            fatalError("Could not find Application Support directory")
        }
        
        // Create app-specific subdirectory
        let appSupportURL = applicationSupportURL.appendingPathComponent(SidebarConfiguration.appSupportDirectoryName)
        
        // Ensure directory exists
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        
        return appSupportURL.appendingPathComponent(SidebarConfiguration.sidebarFileName)
    }
    
    private init() {}

    /// Saves are encoded and written here, in order. Encoding a few hundred
    /// saved tabs takes tens of milliseconds — too long for the main thread,
    /// where every rename, move and unload used to pay for it.
    private let saveQueue = DispatchQueue(label: "Klar.SidebarPersistence.save", qos: .utility)
    
    // MARK: - Save/Load Methods
    
    /// Writes `structure` in the background. It's a value, so the snapshot
    /// taken here is what lands on disk, whatever happens on main meanwhile.
    func saveSidebarStructure(_ structure: SidebarStructure) {
        let url = sidebarStructureURL
        saveQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

                let data = try encoder.encode(structure)
                try data.write(to: url, options: .atomic)

                logInfo(.persistence, "Saved sidebar structure")
            } catch {
                logError(.persistence, "Failed to save sidebar structure: \(error)")
            }
        }
    }

    /// Blocks until every queued save is on disk. Call before the app exits.
    func flushPendingSaves() {
        saveQueue.sync {}
    }
    
    func loadSidebarStructure() -> SidebarStructure? {
        guard FileManager.default.fileExists(atPath: sidebarStructureURL.path) else {
            logInfo(.persistence, "No existing sidebar structure found, starting fresh")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: sidebarStructureURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let structure = try decoder.decode(SidebarStructure.self, from: data)
            return structure
        } catch {
            logError(.persistence, "Failed to load sidebar structure: \(error)")
            // Try to backup the corrupted file
            backupCorruptedFile()
            return nil
        }
    }
    
    // MARK: - Corrupt File Backup
    
    private func backupCorruptedFile() {
        let backupURL = sidebarStructureURL.appendingPathExtension("corrupted.\(Date().timeIntervalSince1970)")
        try? FileManager.default.copyItem(at: sidebarStructureURL, to: backupURL)
        logInfo(.persistence, "Backed up corrupted file to: \(backupURL.path)")
    }
}
