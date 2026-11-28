import SwiftUI
import Foundation

struct CurrentURLView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @State private var isHovering = false
    
    private var currentTab: BrowserTab? {
        tabManager.activeTab
    }
    
    private var displayURL: String {
        guard let tab = currentTab, !tab.url.isEmpty else {
            return "No page loaded"
        }
        
        // Display clean URL without tracking parameters
        let result = URLUtilities.removeTrackingParameters(from: tab.url)
        
        // If trackers were detected, show the clean URL
        if result.trackersDetected {
            return result.cleanURL
        }
        
        return tab.url
    }
    
    /// A locked private tab: its address, connection and settings stay hidden, and a click unlocks
    private var isLocked: Bool {
        currentTab?.isLocked == true
    }

    private var securityStatus: SecurityStatus {
        guard let tab = currentTab, !tab.url.isEmpty, !tab.isLocked else {
            return .none
        }
        
        if tab.url.hasPrefix("https://") {
            return .secure
        } else if tab.url.hasPrefix("http://") {
            return .insecure
        } else if tab.url.hasPrefix("file://") {
            return .local
        }
        
        return .none
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Only show security indicator if not secure
            SecurityIndicatorView(status: securityStatus)
            
            // URL display
            if isLocked {
              Label("Locked", systemImage: "lock.fill")
                  .font(.system(size: 13))
                  .foregroundColor(.secondary)
                  .lineLimit(1)
            } else if let tab = currentTab, !tab.url.isEmpty && tab.url != "about:blank" {
              Text(displayURL)
                  .font(.system(size: 13))
                  .foregroundColor(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
            } else if currentTab == nil {
              Text("Search tabs, history or web...")
                  .font(.system(size: 13))
                  .foregroundColor(.secondary.opacity(0.5))
                  .lineLimit(1)
            } else {
                Text("about:blank")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()

            if currentTab?.isPrivate == true {
                PrivateTabBadge()
            }

            // Pinned extensions and the puzzle menu (only while any run)
            ExtensionActionsView(activeTabID: tabManager.activeTabId)

            // Settings button (always visible when there's a tab, but a locked one)
            if currentTab != nil && !isLocked {
                WebsiteSettingsView()
                    .opacity(isHovering ? 1.0 : 0.3)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
        )
        .background(
            // Invisible NSView pinned to the URL bar's frame; serves as the
            // anchor for AutofillCoordinator's Passwords pairing popover.
            URLBarAnchorRegistration(sidebarState: sidebarStateManager)
        )
        .onHover { hovering in
            if isHovering != hovering {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
        .onTapGesture {
            if isLocked {
                PrivateTabLock.shared.unlock()
            } else {
                // Open command palette with current URL pre-filled
                tabManager.openCommandPaletteWithCurrentURL()
            }
        }
        .help(isLocked ? "Unlock private tabs" : "Click to edit URL (⌘L)")
    }
}

/// In the URL bar while the tab is a private one.
struct PrivateTabBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sunglasses.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Private")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .fixedSize()
        .help("Private tab: its pages aren’t kept in history, and their cookies and website data are forgotten once your private tabs are closed")
    }
}

enum SecurityStatus {
    case secure
    case insecure
    case local
    case none
}

struct SecurityIndicatorView: View {
  let status: SecurityStatus
  
  var body: some View {
    Group {
      switch status {
      case .secure:
        Image(systemName: "lock.fill")
          .foregroundColor(.secondary.opacity(0.5))
      case .insecure:
        Image(systemName: "lock.slash.fill")
          .foregroundColor(.orange)
      case .local:
        Image(systemName: "doc.fill")
          .foregroundColor(.blue)
      case .none:
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary.opacity(0.5))
      }
    }
    .font(.system(size: 12, weight: .bold))
    .frame(width: 22, height: 16, alignment: .center)
  }
}
