import Foundation
import WebKit

/// Decides when background tabs give up their web view.
///
/// A background tab keeps its page, however many there are and however long
/// they go unused: its web view is out of the window, so WebKit
/// throttles the page and, 4 minutes later, suspends its WebContent process,
/// which then uses no CPU while macOS compresses the memory it holds. Going
/// back to it is instant. Only when the system runs low on memory is a
/// background tab suspended (`TabManager.suspendTab`): its web view let go.
/// It keeps its place in the tab list and the sidebar, and loads again —
/// back/forward list, scroll position and form data included — when it's
/// next activated. Pinned sites stay loaded, unless memory runs out.
///
/// Klar does this on its own, with no setting. It isn't unloading a saved
/// tab (`SidebarTabManager.unloadTab`), which closes the tab's page and
/// leaves only its row.
final class TabSuspensionManager {
    private weak var tabManager: TabManager?

    /// When each live background tab was last the active one.
    private var backgroundedAt: [UUID: Date] = [:]
    /// Tabs whose page is being asked whether it can be suspended.
    private var pendingChecks: Set<UUID> = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(tabManager: TabManager) {
        self.tabManager = tabManager

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self, let event = self.memoryPressureSource?.data else { return }
            self.handleMemoryPressure(event)
        }
        source.resume()
    }

    isolated deinit {
        memoryPressureSource?.cancel()
    }

    /// Call whenever the active tab changes.
    func activeTabDidChange(from oldID: UUID?, to newID: UUID?) {
        if let oldID {
            backgroundedAt[oldID] = Date()
        }
        if let newID {
            backgroundedAt.removeValue(forKey: newID)
        }
        // Forget tabs closed meanwhile.
        if let tabManager, backgroundedAt.count > tabManager.tabs.count {
            let ids = Set(tabManager.tabs.map(\.id))
            backgroundedAt = backgroundedAt.filter { ids.contains($0.key) }
        }
    }

    // MARK: - Policy

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let isCritical = event.contains(.critical)
        logWarning(.tabManagement, "Memory pressure (\(isCritical ? "critical" : "warning")) - suspending background tabs")

        suspendTabs(idleFor: isCritical ? 0 : 60, includingPinnedSites: isCritical)
        WebViewPool.shared.clearPool()
        for store in SpaceManager.shared.allWebsiteDataStores {
            store.removeData(
                ofTypes: [WKWebsiteDataTypeMemoryCache],
                modifiedSince: .distantPast,
                completionHandler: {}
            )
        }
    }

    private func suspendTabs(idleFor interval: TimeInterval, includingPinnedSites: Bool) {
        let cutoff = Date().addingTimeInterval(-interval)
        for background in liveBackgroundTabs(includingPinnedSites: includingPinnedSites) where background.since <= cutoff {
            suspendIfPossible(background.tab)
        }
    }

    /// Background tabs that have a web view, with when they went to the
    /// background.
    private func liveBackgroundTabs(includingPinnedSites: Bool) -> [(tab: BrowserTab, since: Date)] {
        guard let tabManager else { return [] }
        let sidebarManager = tabManager.sidebarManager

        var live: [(tab: BrowserTab, since: Date)] = []
        var liveIDs = Set<UUID>()
        // Not the tabs on screen: the active one, or its split view's panes
        for tab in tabManager.tabs where !tab.isSuspended && !tab.isEmpty && !tabManager.splitViews.isVisible(tab.id) {
            // One opened in the background and never shown counts from when
            // it opened or last navigated.
            let since = backgroundedAt[tab.id] ?? tab.lastActiveAt
            liveIDs.insert(tab.id)
            if !includingPinnedSites, sidebarManager?.isPinnedSite(browserTabID: tab.id) == true { continue }
            live.append((tab, since))
        }
        pendingChecks.formIntersection(liveIDs)

        return live
    }

    /// Suspends the tab unless its page holds something a reload would lose
    /// (see `TabWebViewCoordinator.checkSuspendable`).
    private func suspendIfPossible(_ tab: BrowserTab) {
        // No web view yet (it's created on the next render) or any more.
        guard let coordinator = TabWebViewCoordinator.coordinator(for: tab.id),
              pendingChecks.insert(tab.id).inserted else { return }

        let tabID = tab.id
        coordinator.checkSuspendable { [weak self, weak tab] isSuspendable in
            guard let self else { return }
            self.pendingChecks.remove(tabID)
            guard isSuspendable, let tab, let tabManager = self.tabManager else { return }
            tabManager.suspendTab(tab)
        }
    }
}
