import SwiftUI

struct SidebarHistoryAppKitBridge: NSViewControllerRepresentable {
    @EnvironmentObject var tabManager: TabManager

    func makeNSViewController(context: Context) -> SidebarHistoryViewController {
        SidebarHistoryViewController(tabManager: tabManager)
    }

    func updateNSViewController(_ controller: SidebarHistoryViewController, context: Context) {}
}
