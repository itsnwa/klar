import SwiftUI
import WebKit
import Combine
import ObjectiveC
import AppKit

// Individual WebView for each tab - persists its state
struct TabWebView: NSViewRepresentable {
    typealias NSViewType = WebViewContainerView
    @ObservedObject var tab: BrowserTab
    /// Plain reference, deliberately not observed: TabManager publishes on
    /// every navigation of the active tab, and observing it here re-ran
    /// `updateNSView` for every open tab each time.
    let tabManager: TabManager
    /// On screen: the active tab, or a pane of its split view
    let isVisible: Bool
    let isInteractionEnabled: Bool
    /// A pane of a split view is rounded on its own; a page alone is
    /// clipped by the content area's shape (0)
    let cornerRadius: CGFloat
    /// A pane of the split view on screen: a handle to move it, and a button
    /// to take it out, over its top while hovered
    let showsPaneControls: Bool
    let shouldForceArrowCursor: Bool
    
    func makeNSView(context: Context) -> WebViewContainerView {
        let containerView = WebViewContainerView(webView: context.coordinator.webView)
        context.coordinator.containerView = containerView
        return containerView
    }
    
    func updateNSView(_ containerView: WebViewContainerView, context: Context) {
        let webView = context.coordinator.webView

        // This tab has a live web view, so it isn't suspended — even if it
        // was marked so and re-activated before BrowserView dropped its view
        // (an unreported suspended tab would later lose its view unchecked).
        if tab.isSuspended {
            _ = tab.resume()
        }

        // Only the tabs on screen are visible and interactive; the others'
        // web views leave the window unless they need it
        containerView.setActive(isVisible, keepsWebViewInWindow: !isVisible && context.coordinator.keepsWebViewInWindow)
        containerView.setCornerRadius(cornerRadius)
        containerView.setPaneControls(tabID: showsPaneControls ? tab.id : nil, tabManager: tabManager)

        // When tab becomes visible, check for stuck state immediately
        if isVisible && tab.isLoading && tab.title == "New Tab" && webView.estimatedProgress == 0.0 {
            // Slight delay to avoid interfering with normal loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                context.coordinator.checkAndRecoverStuckState()
            }
        }
        
        // Critical: Disable all mouse interactions when UI elements are being hovered
        if isVisible {
            context.coordinator.applyBackgroundColorReportedWhileHidden()
            webView.allowsBackForwardNavigationGestures = isInteractionEnabled
            // Use CSS-based pointer control for consistency with floating sidebar
            context.coordinator.setPointerEventsEnabled(isInteractionEnabled)
            
            // Autoplay is configured during WebView creation
        } else {
            webView.allowsBackForwardNavigationGestures = false
            // Tabs off screen don't need pointer event management - only those on screen
            
            // Autoplay is configured during WebView creation
        }
        
        // Handle pending navigation
        if isVisible && tab.pendingUserNavigation && !webView.isLoading {
            context.coordinator.loadPendingNavigation()
        }
        
        // Periodically check for stuck loading states when tab is on screen
        if isVisible && tab.isLoading {
            context.coordinator.checkAndRecoverStuckState()
        }
    }
    
    /// A tab from another window keeps its page: that window's coordinator
    func makeCoordinator() -> TabWebViewCoordinator {
        TabWebViewCoordinator.adoptAfterChangingWindows(tabID: tab.id, tabManager: tabManager)
            ?? TabWebViewCoordinator(tab: tab, tabManager: tabManager)
    }

    static func dismantleNSView(_ containerView: WebViewContainerView, coordinator: TabWebViewCoordinator) {
        // Out of the Now Playing preview, if it has it.
        containerView.reclaimWebView()
        // Its tab went to another window, whose view has the page or will
        guard !coordinator.isChangingWindows, coordinator.containerView === containerView else { return }
        coordinator.tearDown()
    }
} 