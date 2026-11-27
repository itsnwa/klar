import SwiftUI

struct SearchSuggestionRow: View {
    let suggestion: String
    let isSelected: Bool
    /// The site shortcut's site it searches, else the default search engine.
    var siteName: String? = nil
    
    // Observe settings changes for reactive UI updates
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    
    // Get the search engine display name
    private var searchEngineDisplayName: String {
        return siteName ?? settingsManager.defaultSearchEngine.displayName
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Magnifying glass icon for search suggestions
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.6))
                .frame(width: 22, height: 22, alignment: .center)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                
                Text("Search \(searchEngineDisplayName)")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
}

// Keep the old name for backward compatibility but redirect to new component
typealias GoogleSuggestionRow = SearchSuggestionRow 
