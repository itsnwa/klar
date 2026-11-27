import SwiftUI

struct SidebarView: View {
    // Only what `body` reads. Every observed object re-runs `body` on each of
    // its changes — SidebarManager would on every folder toggle, selection
    // and title change, in the same frame as the list's own animation. The
    // AppKit sections pick up the managers they need from the environment.
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @EnvironmentObject var nativeWindowButtons: NativeWindowButtons
    @EnvironmentObject var toolbarManager: ToolbarManager

    var body: some View {
        ZStack {
            // Main sidebar content
            VStack(spacing: 0) {
                // Always show title bar controls
                sidebarTitleBar
                
                // Current URL display
                // Nothing below: the content under it starts right away,
                // its own inset in (`SidebarLayoutMetrics.contentEdgeInset`)
                CurrentURLView()
                    .padding(.horizontal, 6)
                    .padding(.top, 8)

                // Content area: the pinned sites over the space's tabs, the
                // overview, or a full list
                SidebarZoomContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Now Playing widget (visible when media tab is not the active tab)
                NowPlayingWidget(isShown: sidebarStateManager.isVisible)
                    .animation(.easeInOut(duration: 0.2), value: MediaControlManager.shared.hasActiveMedia)
                    .animation(.easeInOut(duration: 0.2), value: tabManager.activeTabId)

                // An update on its way, and Restart to Update
                UpdateCard()

                // The spaces. Its 28 pt buttons are centered in the bar's
                // height, so they sit 6 from the sidebar's sides and bottom.
                SpaceBarDropContainer()
                    .frame(height: 32)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: sidebarStateManager.customSidebarWidth)
        .clipped()
        // On the fixed-width frame, so it stays at the visible edge even if a row overflows
        .overlay(alignment: .trailing) {
            SidebarResizeHandle()
                .environment(sidebarStateManager)
        }
        .ignoresSafeArea(.all, edges: .top)
    }
    
    // MARK: - Sidebar Title Bar
    
    @ViewBuilder
    private var sidebarTitleBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // Native window controls spacing - same as regular title bar when sidebar is open
            // In fullscreen, no need to reserve space for window control buttons
            Spacer()
                .frame(width: toolbarManager.isFullscreen ? 8 : 98)
            
            // Sidebar toggle button
            KlarButton.titleBar(action: {
                if sidebarStateManager.isFloating {
                    sidebarStateManager.dock()
                } else {
                    sidebarStateManager.toggle()
                }
            }) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
            }
            .accessibility(label: Text(sidebarStateManager.isFloating ? "Dock Sidebar" : "Toggle Sidebar"))
            .help(sidebarStateManager.isFloating ? "Dock Sidebar (⌘S)" : "Toggle Sidebar (⌘S)")
            
            // Use spacer like regular title bar when sidebar is visible (no divider)
            Spacer()
          
            // Back and forward hover as one item
            KlarButtonGroup {
                KlarButton.titleBarSegment(action: {
                    tabManager.goBackInCurrentTab()
                }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14))
                        .foregroundColor(tabManager.activeTab?.canGoBack == true ? .secondary : .secondary.opacity(0.4))
                        .frame(width: 16, height: 16)
                }
                .disabled(tabManager.activeTab?.canGoBack != true)
                .accessibility(label: Text("Go Back"))
                .help("Go Back (⌘←)")

                KlarButton.titleBarSegment(action: {
                    tabManager.goForwardInCurrentTab()
                }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14))
                        .foregroundColor(tabManager.activeTab?.canGoForward == true ? .secondary : .secondary.opacity(0.4))
                        .frame(width: 16, height: 16)
                }
                .disabled(tabManager.activeTab?.canGoForward != true)
                .accessibility(label: Text("Go Forward"))
                .help("Go Forward (⌘→)")
            }
            .padding(.trailing, 4)
          
            KlarButton.titleBar(action: {
                tabManager.reloadCurrentTab()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(tabManager.tabs.isEmpty ? .secondary.opacity(0.4) : .secondary)
                    .frame(width: 16, height: 16)
            }
            .disabled(tabManager.tabs.isEmpty)
            .accessibility(label: Text("Refresh Page"))
            .help("Refresh Page (⌘R)")
        }
        .frame(height: 38)
        .padding(.trailing, 6)
        .padding(.top, 7)
        .nativeWindowButtons(nativeWindowButtons)
        .background(Color.clear)
    }
    
    
}

// MARK: - Sidebar Resize Handle

/// Drags the sidebar's trailing edge to resize it. Nothing shows but the
/// resize cursor.
struct SidebarResizeHandle: View {
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
              guard isHovering != hovering else { return }
              self.isHovering = hovering
              DispatchQueue.main.async {
                if (self.isHovering) {
                  NSCursor.resizeLeftRight.push()
                } else {
                  NSCursor.pop()
                }
              }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartX = gesture.startLocation.x
                            dragStartWidth = sidebarStateManager.customSidebarWidth
                        }
                        
                        // Calculate new width based on absolute mouse position
                        let deltaX = gesture.location.x - dragStartX
                        let newWidth = dragStartWidth + deltaX
                        
                        // Throttle updates for better performance
                        DispatchQueue.main.async {
                            sidebarStateManager.customSidebarWidth = max(
                                SidebarStateManager.minSidebarWidth,
                                min(SidebarStateManager.maxSidebarWidth, newWidth)
                            )
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        // Save the final width
                        sidebarStateManager.saveSidebarState()
                        
                        // Optionally snap to a nice width on drag end
                        let currentWidth = sidebarStateManager.customSidebarWidth
                        let snappedWidth = round(currentWidth / 10) * 10 // Snap to nearest 10px
                        if abs(currentWidth - snappedWidth) > 2 {
                            sidebarStateManager.setSidebarWidth(snappedWidth)
                        }
                    }
            )
        .frame(width: 4)
        .padding(.horizontal, 2)
        .padding(.vertical, 32)
    }
}
