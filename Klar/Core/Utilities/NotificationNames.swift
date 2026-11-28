import Foundation

extension Notification.Name {
    static let tabCloseActionChanged = Notification.Name("tabCloseActionChanged")
    static let faviconCached = Notification.Name("FaviconCached")
    /// A site's variant changed (object is its URL), or Klar changed appearance (object is nil).
    static let faviconAppearanceChanged = Notification.Name("FaviconAppearanceChanged")
    static let faviconRefreshRequested = Notification.Name("FaviconRefreshRequested")
    /// A page's count of blocked trackers changed (object is its web view;
    /// `TabWebViewCoordinator.blockedTrackerHosts`).
    static let trackersBlockedDidChange = Notification.Name("TrackersBlockedDidChange")
    /// The private tabs locked or unlocked (`PrivateTabLock.isLocked`), for AppKit views that show them.
    static let privateTabsLockDidChange = Notification.Name("PrivateTabsLockDidChange")
}

extension NotificationCenter {
    /// `addObserver(forName:object:queue: .main)` for main-actor code: the
    /// block runs on the main actor, so it uses main-actor state directly.
    @discardableResult
    func addMainObserver(forName name: Notification.Name?, object: Any? = nil, using block: @escaping @MainActor (Notification) -> Void) -> any NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { notification in
            // Delivered on the main queue, and only used there.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated { block(notification) }
        }
    }
}
