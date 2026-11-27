import SwiftUI

struct SidebarDownloadsAppKitBridge: NSViewControllerRepresentable {
    @EnvironmentObject var tabManager: TabManager

    func makeNSViewController(context: Context) -> SidebarDownloadsViewController {
        SidebarDownloadsViewController(tabManager: tabManager)
    }

    func updateNSViewController(_ controller: SidebarDownloadsViewController, context: Context) {}
}
