import SwiftUI

struct SidebarTabsAppKitBridge: NSViewControllerRepresentable {
    /// Another space than the active one, to preview while swiping to it.
    var previewedSpaceID: UUID? = nil
    /// How far zoomed out and blurred, from 0 to 1, while pinching.
    var zoomedOut: CGFloat = 0
    /// Whether the list takes drops: only while it's the level on screen.
    var acceptsDrops = true
    @EnvironmentObject var sidebarManager: SidebarManager
    @EnvironmentObject var tabManager: TabManager

    func makeNSViewController(context: Context) -> SidebarTabsViewController {
        SidebarTabsViewController(sidebarManager: sidebarManager, tabManager: tabManager, previewing: previewedSpaceID)
    }

    func updateNSViewController(_ controller: SidebarTabsViewController, context: Context) {
        controller.setZoomedOut(zoomedOut)
        controller.setAcceptsDrops(previewedSpaceID == nil && acceptsDrops)
    }
}
