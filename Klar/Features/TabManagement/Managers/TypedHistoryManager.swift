import SwiftUI
import Foundation

// Typed History Entry - specifically for manually typed queries
struct TypedHistoryEntry: Codable, Identifiable {
    let id: UUID
    let originalInput: String // What the user actually typed
    let finalURL: String // The formatted URL that was navigated to
    let timestamp: Date
    var visitCount: Int = 1
    
    // Computed title based on the input type
    var displayTitle: String {
        // A search on the default engine's site or a shortcut's: its words
        if let search = SiteShortcuts.searchQuery(in: finalURL) {
            return "\(search.query) at \(search.siteName)"
        }
        
        if originalInput.contains(".") && !originalInput.contains(" ") {
            // Looks like a domain - use the cleaned domain as title
            if let url = URL(string: finalURL), let host = url.host {
                return host.replacingOccurrences(of: "www.", with: "")
            }
            return originalInput
        } else {
            // Search query - show as "Search for [query]"
            return originalInput
        }
    }
    
    // Custom initializer for creating new entries
    init(originalInput: String, finalURL: String, timestamp: Date, visitCount: Int = 1) {
        self.id = UUID()
        self.originalInput = originalInput
        self.finalURL = finalURL
        self.timestamp = timestamp
        self.visitCount = visitCount
    }
}

// Manager for typed history (only manual entries from new tab mode)
/// What was typed into new tabs, in every window
class TypedHistoryManager: ObservableObject {
    static let shared = TypedHistoryManager()

    @Published private var entries: [TypedHistoryEntry] = []
    private let maxEntries = 100
    private let userDefaults = UserDefaults.standard
    private let storageKey = "TypedHistory"
    
    private init() {
        loadHistory()
    }
    
    func addTypedEntry(originalInput: String, finalURL: String) {
        let trimmedInput = originalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }
        
        // Check if we already have this input
        if let existingIndex = entries.firstIndex(where: { $0.originalInput.lowercased() == trimmedInput.lowercased() }) {
            // Update existing entry
            entries[existingIndex].visitCount += 1
            entries[existingIndex] = TypedHistoryEntry(
                originalInput: trimmedInput,
                finalURL: finalURL,
                timestamp: Date(),
                visitCount: entries[existingIndex].visitCount
            )
            // Move to front
            let updatedEntry = entries.remove(at: existingIndex)
            entries.insert(updatedEntry, at: 0)
        } else {
            // Add new entry
            let newEntry = TypedHistoryEntry(
                originalInput: trimmedInput,
                finalURL: finalURL,
                timestamp: Date()
            )
            entries.insert(newEntry, at: 0)
        }
        
        // Keep only recent entries
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        
        saveHistory()
    }
    
    func getTypedSuggestions(for searchText: String, limit: Int = 8) -> [HistoryEntryData] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard !trimmedSearchText.isEmpty else {
            // Return recent entries when no search text
                    return entries.prefix(limit).map { entry in
            HistoryEntryData(
                id: HistoryEntryData.stableID(for: entry.finalURL),
                url: entry.finalURL,
                title: entry.displayTitle,
                visitedAt: entry.timestamp,
                visitCount: entry.visitCount
            )
        }
        }
        
        let suggestions = entries.filter { entry in
            let inputMatches = entry.originalInput.localizedCaseInsensitiveContains(trimmedSearchText)
            let urlMatches = entry.finalURL.localizedCaseInsensitiveContains(trimmedSearchText)
            return inputMatches || urlMatches
        }
        
        // Sort by relevance and frequency
        let sortedSuggestions = suggestions.sorted { entry1, entry2 in
            let entry1ExactMatch = entry1.originalInput.lowercased().hasPrefix(trimmedSearchText)
            let entry2ExactMatch = entry2.originalInput.lowercased().hasPrefix(trimmedSearchText)
            
            if entry1ExactMatch && !entry2ExactMatch {
                return true
            } else if !entry1ExactMatch && entry2ExactMatch {
                return false
            }
            
            // Sort by visit count, then by recency
            if entry1.visitCount != entry2.visitCount {
                return entry1.visitCount > entry2.visitCount
            }
            
            return entry1.timestamp > entry2.timestamp
        }
        
        return sortedSuggestions.prefix(limit).map { entry in
            HistoryEntryData(
                id: HistoryEntryData.stableID(for: entry.finalURL),
                url: entry.finalURL,
                title: entry.displayTitle,
                visitedAt: entry.timestamp,
                visitCount: entry.visitCount
            )
        }
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(entries)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            // Silently fail - data will be lost but app continues
        }
    }
    
    private func loadHistory() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        
        do {
            entries = try JSONDecoder().decode([TypedHistoryEntry].self, from: data)
        } catch {
            // Silently fail - start with empty history
        }
    }
    
    func clearHistory() {
        entries.removeAll()
        userDefaults.removeObject(forKey: storageKey)
    }
    
    func removeEntry(_ entry: HistoryEntryData) {
        // Every entry that leads there: two things typed can, and with only
        // one removed the row came back.
        let count = entries.count
        entries.removeAll { $0.finalURL == entry.url }
        if entries.count != count {
            saveHistory()
        }
    }

} 