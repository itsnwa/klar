import SwiftUI

struct SidebarReadingListAppKitBridge: NSViewControllerRepresentable {
    @EnvironmentObject var tabManager: TabManager

    func makeNSViewController(context: Context) -> SidebarReadingListViewController {
        SidebarReadingListViewController(tabManager: tabManager)
    }

    func updateNSViewController(_ controller: SidebarReadingListViewController, context: Context) {}
}
