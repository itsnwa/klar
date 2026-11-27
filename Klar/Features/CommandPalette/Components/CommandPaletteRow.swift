import SwiftUI

/// Shared wrapper component for all command palette row items
/// Provides consistent selection and hover styling
struct CommandPaletteRow<Content: View>: View {
    let isSelected: Bool
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    
    @State private var isHovering: Bool = false
    
    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectionBackgroundColor)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if isHovering != hovering {
                    isHovering = hovering
                }
            }
            .onTapGesture {
                onTap()
            }
    }
    
    private var selectionBackgroundColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovering {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
        }
    }
} 