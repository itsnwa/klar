import SwiftUI
import WebKit
import Combine

struct BrowserView: View {
    @EnvironmentObject var tabManager: TabManager
    /// Passed in by ContentView, which reads the sidebar's state anyway.
    /// (Previously TabManager mirrored isFloating into a @Published
    /// shouldDisableWebViewInteraction via a synchronous didSet — that chain
    /// produced AttributeGraph cycles. The mirror is gone.)
    let isSidebarFloating: Bool

    /// At launch, the enabled extensions start once the window is up; until
    /// then no tab gets a web view, so pages load with their content scripts.
    /// Not observed: ExtensionManager publishes much else.
    @State private var hasStartedExtensions = ExtensionManager.shared.hasStartedExtensions
    /// No web views either until the window is up: making one and starting
    /// its page (WebKit's processes, its font list) took about 80 ms, which
    /// held up the window when a tab was restored at launch.
    @State private var isWindowUp = false

    private var isWebViewInteractionEnabled: Bool {
        !tabManager.showCommandPalette && !isSidebarFloating
    }

    private var activeTab: BrowserTab? {
        tabManager.tabs.first { $0.id == tabManager.activeTabId }
    }

    var body: some View {
        ZStack {
            // Only show empty state if there are no tabs with content at all
            if !tabManager.tabs.contains(where: { !$0.isEmpty }) {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Each live tab keeps its own WebView while it's in the
                // list, at its pane if it's in a split view
                SplitPanesView(
                    canLoadPages: isWindowUp && hasStartedExtensions,
                    isInteractionEnabled: isWebViewInteractionEnabled
                )

                // A space with no tab open (other spaces' stay loaded behind)
                if tabManager.activeTabId == nil {
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            VStack {
              
              HStack {
                Spacer ()
                
                ToastView(toastManager: tabManager.toastManager)
                
              }
              .padding(8)
              
              Spacer()
            }
            .zIndex(1000)
            
            // Floating progress bar in bottom left
            VStack {
                Spacer()
                HStack {
                    if let activeTab = activeTab {
                        ActiveTabProgressBar(tab: activeTab)
                            .padding(EdgeInsets(top: 0, leading: 8, bottom: -16, trailing: 0))
                            .id(activeTab.id)
                    }
                    Spacer()
                }
            }
            .zIndex(1000)
            
            FindPanelOverlay()
                .zIndex(2000)
        }
        .onAppear {
            // On the next turn, once the window has been drawn.
            DispatchQueue.main.async {
                if !isWindowUp {
                    isWindowUp = true
                }
            }
        }
        .onReceive(ExtensionManager.shared.$hasStartedExtensions) { started in
            guard started, !hasStartedExtensions else { return }
            hasStartedExtensions = true
            // The window's own attempt may have given up waiting for the page.
            if !tabManager.showCommandPalette {
                tabManager.focusActiveWebView()
            }
        }
    }
}

/// The active tab's load progress. Observes just that tab, so progress
/// ticks (~60 Hz while a page loads) re-render this bar and nothing else.
private struct ActiveTabProgressBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        FloatingProgressBar(
            progress: tab.estimatedProgress,
            isVisible: tab.isLoading || tab.estimatedProgress > 0
        )
    }
}

/// Find panel - positioned 8px from top and right edges of browser view.
/// GeometryReader gives us the real container height so the panel can
/// grow to within 8pt of the bottom edge. Observes FindManager itself, so
/// Find keystrokes and streamed AI answers don't re-render BrowserView.
private struct FindPanelOverlay: View {
    @EnvironmentObject var findManager: FindManager

    var body: some View {
        GeometryReader { geo in
            VStack {
                HStack {
                    Spacer()
                    FindPanelView(
                        findManager: findManager,
                        availableHeight: max(geo.size.height - 16, 0)
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                Spacer()
            }
        }
    }
} 
