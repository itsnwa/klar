import SwiftUI

struct TabRow: View {
    let tab: PaletteTab
    let isSelected: Bool
    let isActive: Bool
    @EnvironmentObject var tabManager: TabManager
    @State private var isHovering: Bool = false
    @State private var isCommandKeyPressed: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Favicon
            FaviconView.commandPalette(url: tab.url)
            
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .center) {
                  Text(tab.title)
                      .font(.system(size: 14, weight: .medium))
                      .foregroundColor(isSelected ? .white : .primary)
                      .lineLimit(1)
              }
              
              Text(tab.displayURL)
                  .font(.system(size: 12))
                  .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                  .lineLimit(1)
            }
            
            Spacer()
          
            // Tab type indicator text with slot machine animation
            if let breadcrumb = tab.breadcrumb {
                let showsNewTabHint = isCommandKeyPressed && isSelected && tab.isSaved
                ZStack(alignment: .trailing) {
                    // Folder path
                    Text(breadcrumb)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                        .opacity(showsNewTabHint ? 0 : 1)
                        .offset(y: showsNewTabHint ? -20 : 0)
                        .animation(.easeInOut(duration: 0.15), value: showsNewTabHint)
                    
                    // "open in new tab" text
                    Text("Open in New Tab")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                        .opacity(showsNewTabHint ? 1 : 0)
                        .offset(y: showsNewTabHint ? 0 : 20)
                        .animation(.easeInOut(duration: 0.15), value: showsNewTabHint)
                }
            }
            
            if isActive {
                Circle()
                    .fill(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 6, height: 6)
            }
            
            // Action button - only visible on hover
            if isHovering {
                actionButton
            }
        }
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommandKeyStateChanged"))) { notification in
            if let isPressed = notification.object as? Bool, isCommandKeyPressed != isPressed {
                isCommandKeyPressed = isPressed
            }
        }
    }
    
    // MARK: - Computed Properties
    
    @ViewBuilder
    private var actionButton: some View {
        if let sidebarManager = tabManager.sidebarManager {
            // Looked up when shown: the saved tab may have been loaded or unloaded since
            if let sidebarTab = savedTab(in: sidebarManager) {
                if !sidebarManager.isOpenHere(sidebarTab.id) {
                    // X button for tabs unloaded in this window (removes from sidebar)
                    CompactButton(action: {
                        sidebarManager.removeTab(withID: sidebarTab.id)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .help("Remove from sidebar")
                } else {
                    // Minus button for loaded saved tabs (unloads the tab)
                    CompactButton(action: {
                        sidebarManager.unloadTab(withID: sidebarTab.id)
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .help("Unload tab")
                }
            } else {
                // X button for regular tabs (closes the tab)
                CompactButton(action: {
                    if let browserTab = tabManager.tabs.first(where: { $0.id == tab.id }) {
                        tabManager.closeTabUndoably(browserTab)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .help("Close tab")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func savedTab(in sidebarManager: SidebarManager) -> SidebarTab? {
        // First check if this is an unloaded tab (uses sidebar tab ID)
        if let unloadedTab = sidebarManager.sidebarStructure.tabs[tab.id] {
            return unloadedTab
        } else if let sidebarTabId = sidebarManager.browserToSidebarTabMapping[tab.id],
                  let mappedTab = sidebarManager.sidebarStructure.tabs[sidebarTabId] {
            // This is a loaded saved tab (uses browser tab ID with mapping)
            return mappedTab
        }
        return nil
    }
}
