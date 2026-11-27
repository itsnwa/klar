import SwiftUI

struct URLSuggestionRow: View {
    let suggestion: HistoryEntryData
    let isSelected: Bool
    let isTopHit: Bool
    @State private var isHovering: Bool = false
    @EnvironmentObject var tabManager: TabManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon based on type (clock for history, star for top hits)
            if isTopHit {
                Image(systemName: "star.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.yellow)
                    .frame(width: 22, height: 22, alignment: .center)
            } else {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.6))
                    .frame(width: 22, height: 22, alignment: .center)
            }
                
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 14, weight: isTopHit ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                
                Text(URLUtilities.cleanURL(suggestion.url))
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Delete button (visible on hover)
            if isHovering {
                Button(action: {
                    tabManager.deleteHistoryEntry(suggestion)
                    // Post notification to update suggestions
                    NotificationCenter.default.post(name: .commandPaletteUpdateSelection, object: tabManager)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
    }
} 
