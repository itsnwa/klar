import AppKit
import Combine
import WebKit

/// Klar's tabs and windows as WebKit's extension APIs (tabs, windows,
/// scripting, …) see them, and the events those APIs fire.
///
/// Each browser window's session is an `ExtensionBrowserWindow`, and each
/// popup an extension opens itself (windows.create) an
/// `ExtensionPopupWindow`. Each BrowserTab gets one `ExtensionTab` for its
/// life, whichever window it's in: WebKit tells tabs apart by object
/// identity, and a tab that goes to another window is reported as moved.
/// Nothing here runs until the first extension loads (`activate()`); from
/// then on each window's tab list and active tab, and each tab's URL,
/// title, loading and audio state, are passed on to the controller as they
/// change.
@MainActor
final class ExtensionBrowserBridge {
    private unowned let controller: WKWebExtensionController

    /// By session ID
    private var browserWindows: [UUID: ExtensionBrowserWindow] = [:]
    private(set) var popupWindows: [ExtensionPopupWindow] = []

    /// Every window's tabs, by BrowserTab ID
    private var tabs: [UUID: ExtensionTab] = [:]
    /// Where a tab that left a window for another was, until that window
    /// reports it (as moved)
    private var departedTabs: [UUID: (window: ExtensionBrowserWindow, index: Int)] = [:]
    private var isActive = false
    private var focusObserver: NSObjectProtocol?

    /// Tab changes waiting to be reported together on the next turn of the
    /// main queue.
    private var pendingChanges: [ObjectIdentifier: (tab: any WKWebExtensionTab, properties: WKWebExtension.TabChangedProperties)] = [:]
    private var isFlushScheduled = false

    init(controller: WKWebExtensionController) {
        self.controller = controller
    }

    /// A browser window, once SwiftUI has made it: reported to extensions
    /// already running.
    func attach(session: BrowserWindowSession) {
        guard isActive else { return }
        openWindow(for: session)
    }

    /// The window in front's session
    private var focusedBrowserWindow: ExtensionBrowserWindow? {
        browserWindows[BrowserWindowSession.current.id]
    }

    /// The browser window in front, if it's open.
    var browserWindow: NSWindow? {
        BrowserWindow.current
    }

    /// The browser window a tab is in
    func browserWindow(of tab: ExtensionTab) -> NSWindow? {
        tab.window?.nsWindow
    }

    /// Starts reporting tabs and windows; called when an extension loads.
    /// Every window counts as open from launch, before SwiftUI has made
    /// its NSWindow: its tabs exist already.
    func activate() {
        guard !isActive else { return }
        isActive = true

        for session in BrowserWindowSession.all.reversed() {
            openWindow(for: session)
        }
        controller.didFocusWindow(focusedWindow)

        focusObserver = NotificationCenter.default.addMainObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.windowBecameKey(window)
        }
    }

    @discardableResult
    private func openWindow(for session: BrowserWindowSession) -> ExtensionBrowserWindow {
        if let window = browserWindows[session.id] { return window }
        let window = ExtensionBrowserWindow(session: session, bridge: self)
        browserWindows[session.id] = window
        controller.didOpenWindow(window)
        syncTabs(of: window)
        syncActiveTab(of: window)

        // TabManager publishes before it changes; read the new state on the
        // next turn, once the change has landed (tab indexes included).
        let tabManager = session.tabManager
        tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.syncTabs(of: window)
            }
            .store(in: &window.cancellables)
        tabManager.$activeTabId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.syncActiveTab(of: window)
            }
            .store(in: &window.cancellables)
        return window
    }

    /// A browser window closed with its tabs (any but the last one, whose
    /// tabs wait for the next window). Its pinned sites went to another
    /// window: they're reported as moved there.
    func windowDidClose(_ session: BrowserWindowSession) {
        guard isActive, let window = browserWindows.removeValue(forKey: session.id) else { return }
        window.cancellables.removeAll()
        for (index, id) in window.openTabIDs.enumerated() {
            guard let tab = tabs[id], tab.window === window else { continue }
            if let owner = BrowserWindowSession.owner(ofTab: id), owner !== session {
                departedTabs[id] = (window, index)
                syncTabs(of: openWindow(for: owner))
            } else {
                forget(tab, windowIsClosing: true)
            }
        }
        window.openTabIDs = []
        controller.didCloseWindow(window)
        controller.didFocusWindow(focusedWindow)
    }

    // MARK: - Tabs

    func tab(for browserTab: BrowserTab) -> ExtensionTab? {
        tabs[browserTab.id]
    }

    func tab(withID id: UUID) -> ExtensionTab? {
        tabs[id]
    }

    /// The active tab of the window in front
    var activeTab: ExtensionTab? {
        focusedBrowserWindow?.activeTabID.flatMap { tabs[$0] }
    }

    /// The tab showing `webView`: a Klar tab, or an extension popup window's.
    func tab(showing webView: WKWebView) -> (any WKWebExtensionTab)? {
        if let tab = tabs.values.first(where: { $0.webView === webView }) { return tab }
        return popupWindows.first { $0.tab.webView === webView }?.tab
    }

    /// Opens a Klar tab for an extension (tabs.create, an options page): in
    /// its opener's window, else the one in front.
    func openTab(url: URL?, active: Bool, parent: ExtensionTab? = nil) -> ExtensionTab? {
        let session = parent.flatMap { BrowserWindowSession.owner(ofTab: $0.browserTab.id) } ?? BrowserWindowSession.current
        let id = session.tabManager.createNewTab(
            url: url?.absoluteString ?? "",
            parentTabId: parent?.browserTab.id,
            activate: active
        )
        // Report it now rather than on the next turn, so the extension's
        // callback already finds the tab open.
        guard isActive else { return nil }
        let window = openWindow(for: session)
        syncTabs(of: window)
        if active { syncActiveTab(of: window) }
        return tabs[id]
    }

    /// Private tabs are left out: extensions don't run in them, nor learn
    /// what they show.
    private func syncTabs(of window: ExtensionBrowserWindow) {
        guard isActive, let session = window.session else { return }
        let browserTabs = session.tabManager.tabs.filter { !$0.isPrivate }
        let ids = browserTabs.map(\.id)
        guard ids != window.openTabIDs else { return }
        let current = Set(ids)

        for (index, id) in window.openTabIDs.enumerated() where !current.contains(id) {
            guard let tab = tabs[id], tab.window === window else { continue }
            if let owner = BrowserWindowSession.owner(ofTab: id), owner !== session {
                // In another window now, which reports it as moved
                departedTabs[id] = (window, index)
            } else {
                forget(tab, windowIsClosing: false)
            }
        }
        let known = Set(window.openTabIDs)
        window.openTabIDs = ids
        for browserTab in browserTabs where !known.contains(browserTab.id) {
            let id = browserTab.id
            if let tab = tabs[id] {
                // From another window
                let previous = departedTabs.removeValue(forKey: id)
                    ?? tab.window.map { ($0, $0.openTabIDs.firstIndex(of: id) ?? 0) }
                if let oldWindow = tab.window, oldWindow !== window {
                    oldWindow.openTabIDs.removeAll { $0 == id }
                }
                tab.window = window
                if let previous, previous.window !== window {
                    controller.didMoveTab(tab, from: previous.index, in: previous.window)
                }
            } else {
                let tab = ExtensionTab(browserTab: browserTab, bridge: self)
                tab.window = window
                tabs[id] = tab
                tab.startObserving()
                controller.didOpenTab(tab)
            }
        }
    }

    private func forget(_ tab: ExtensionTab, windowIsClosing: Bool) {
        tabs.removeValue(forKey: tab.browserTab.id)
        departedTabs.removeValue(forKey: tab.browserTab.id)
        tab.stopObserving()
        pendingChanges.removeValue(forKey: ObjectIdentifier(tab))
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    private func syncActiveTab(of window: ExtensionBrowserWindow) {
        guard isActive, let session = window.session else { return }
        let id = session.tabManager.activeTabId
        guard id != window.activeTabID else { return }
        let previous = window.activeTabID.flatMap { tabs[$0] }
        window.activeTabID = id
        guard let current = id.flatMap({ tabs[$0] }) else {
            if let previous { controller.didDeselectTabs([previous]) }
            return
        }
        controller.didActivateTab(current, previousActiveTab: previous)
        controller.didSelectTabs([current])
        if let previous { controller.didDeselectTabs([previous]) }
    }

    /// Collects a tab's changes and reports them on the next turn.
    func tabDidChange(_ tab: any WKWebExtensionTab, _ properties: WKWebExtension.TabChangedProperties) {
        let key = ObjectIdentifier(tab)
        var entry = pendingChanges[key] ?? (tab, [])
        entry.properties.formUnion(properties)
        pendingChanges[key] = entry
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushTabChanges()
        }
    }

    private func flushTabChanges() {
        isFlushScheduled = false
        let changes = pendingChanges.values
        pendingChanges.removeAll()
        for change in changes {
            controller.didChangeTabProperties(change.properties, for: change.tab)
        }
    }

    /// Whether the tab is one of the user's saved (sidebar) tabs, which
    /// stay put the way pinned tabs do in Chrome.
    func isSaved(_ browserTab: BrowserTab) -> Bool {
        SidebarStore.shared.browserToSidebarTabMapping[browserTab.id] != nil
    }

    // MARK: - Windows

    /// Open windows, the focused one first: a key popup, then the browser
    /// windows from the one in front back, then the other popups.
    var windowsInFocusOrder: [any WKWebExtensionWindow] {
        var windows: [any WKWebExtensionWindow] = []
        if let key = popupWindows.first(where: { $0.nsWindow.isKeyWindow }) {
            windows.append(key)
        }
        windows.append(contentsOf: BrowserWindowSession.all.compactMap { browserWindows[$0.id] })
        for popup in popupWindows where !windows.contains(where: { $0 === popup }) {
            windows.append(popup)
        }
        return windows
    }

    var focusedWindow: (any WKWebExtensionWindow)? {
        if let popup = popupWindows.first(where: { $0.nsWindow.isKeyWindow }) { return popup }
        return focusedBrowserWindow
    }

    /// A new browser window with these tabs (windows.create), the last one
    /// active. It opens on the next turn; its tabs are there already.
    func openBrowserWindow(urls: [URL?], focused: Bool) -> ExtensionBrowserWindow {
        let session = BrowserWindowSession.sessionForNewWindow()
        let urls = urls.isEmpty ? [nil] : urls
        for (index, url) in urls.enumerated() {
            _ = session.tabManager.createNewTab(url: url?.absoluteString ?? "", activate: index == urls.count - 1)
        }
        BrowserWindow.openWindow?(id: "main", value: session.id)
        if focused {
            NSApp.activate()
        }
        return openWindow(for: session)
    }

    /// A small window of the extension's own (windows.create with type
    /// "popup", e.g. a password manager's pop-out).
    func openPopupWindow(url: URL?, frame: CGRect, focused: Bool, context: WKWebExtensionContext) -> ExtensionPopupWindow {
        let popup = ExtensionPopupWindow(bridge: self, controller: controller, context: context, url: url, frame: frame)
        popupWindows.append(popup)
        controller.didOpenWindow(popup)
        controller.didOpenTab(popup.tab)
        if focused {
            popup.nsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            popup.nsWindow.orderFront(nil)
        }
        return popup
    }

    func popupWindowDidClose(_ popup: ExtensionPopupWindow) {
        guard let index = popupWindows.firstIndex(where: { $0 === popup }) else { return }
        popupWindows.remove(at: index)
        pendingChanges.removeValue(forKey: ObjectIdentifier(popup.tab))
        controller.didCloseTab(popup.tab, windowIsClosing: true)
        controller.didCloseWindow(popup)
        controller.didFocusWindow(focusedWindow)
    }

    private func windowBecameKey(_ window: NSWindow) {
        if let popup = popupWindows.first(where: { $0.nsWindow === window }) {
            controller.didFocusWindow(popup)
        } else if let session = BrowserWindowSession.session(for: window), let browserWindow = browserWindows[session.id] {
            controller.didFocusWindow(browserWindow)
        }
    }
}

// MARK: - Klar's windows

/// A browser window (its session), with the tabs last reported in it
@MainActor
final class ExtensionBrowserWindow: NSObject, WKWebExtensionWindow {
    private unowned let bridge: ExtensionBrowserBridge
    private(set) weak var session: BrowserWindowSession?
    /// Its tabs, in list order, and the active one, as last reported
    var openTabIDs: [UUID] = []
    var activeTabID: UUID?
    var cancellables: Set<AnyCancellable> = []

    init(session: BrowserWindowSession, bridge: ExtensionBrowserBridge) {
        self.session = session
        self.bridge = bridge
    }

    /// Its NSWindow, while it's open
    var nsWindow: NSWindow? { session?.window }

    private var window: NSWindow? { nsWindow }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        openTabIDs.compactMap { bridge.tab(withID: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        activeTabID.flatMap { bridge.tab(withID: $0) }
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
                        completionHandler: @escaping (Error?) -> Void) {
        guard let window else { return completionHandler(ExtensionBridgeError.noWindow) }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        switch state {
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isZoomed { window.zoom(nil) }
        case .fullscreen:
            if !isFullScreen { window.toggleFullScreen(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if isFullScreen { window.toggleFullScreen(nil) }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (window?.screen ?? NSScreen.main)?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .zero
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else { return completionHandler(ExtensionBridgeError.noWindow) }
        window.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else { return completionHandler(ExtensionBridgeError.noWindow) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else { return completionHandler(ExtensionBridgeError.noWindow) }
        window.performClose(nil)
        completionHandler(nil)
    }
}

// MARK: - Klar's tabs

@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let browserTab: BrowserTab
    private unowned let bridge: ExtensionBrowserBridge
    private var cancellables: Set<AnyCancellable> = []
    /// The window it was last reported in
    weak var window: ExtensionBrowserWindow?

    init(browserTab: BrowserTab, bridge: ExtensionBrowserBridge) {
        self.browserTab = browserTab
        self.bridge = bridge
    }

    /// The tab's web view; nil while it's suspended or not created yet.
    var webView: WKWebView? {
        TabWebViewCoordinator.coordinator(for: browserTab.id)?.webView
    }

    func startObserving() {
        report(browserTab.$url.map { _ in () }, as: .URL)
        report(browserTab.$title.map { _ in () }, as: .title)
        report(browserTab.$isLoading.removeDuplicates().map { _ in () }, as: .loading)
        report(browserTab.$isPlayingMedia.removeDuplicates().map { _ in () }, as: .playingAudio)
        report(browserTab.$isMediaMuted.removeDuplicates().map { _ in () }, as: .muted)
    }

    func stopObserving() {
        cancellables.removeAll()
    }

    private func report(_ publisher: some Publisher<Void, Never>, as properties: WKWebExtension.TabChangedProperties) {
        publisher
            .dropFirst()
            .sink { [weak self] in
                guard let self else { return }
                self.bridge.tabDidChange(self, properties)
            }
            .store(in: &cancellables)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        window?.openTabIDs.firstIndex(of: browserTab.id) ?? 0
    }

    /// The window's TabManager the tab is in
    private var tabManager: TabManager? {
        BrowserWindowSession.owner(ofTab: browserTab.id)?.tabManager
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browserTab.parentTabId.flatMap { bridge.tab(withID: $0) }
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        browserTab.isEmpty ? nil : browserTab.title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        bridge.isSaved(browserTab)
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        browserTab.isPlayingMedia
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        browserTab.isMediaMuted
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        NotificationCenter.default.post(
            name: NSNotification.Name("MediaControlMuteTab"),
            object: nil,
            userInfo: ["tabId": browserTab.id.uuidString, "shouldMute": muted]
        )
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(webView?.pageZoom ?? 1)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView else { return completionHandler(ExtensionBridgeError.tabNotLoaded) }
        webView.pageZoom = CGFloat(zoomFactor)
        bridge.tabDidChange(self, .zoomFactor)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        browserTab.isEmpty ? nil : URL(string: browserTab.url)
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard webView?.url == nil, !browserTab.isEmpty else { return nil }
        return URL(string: browserTab.url)
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !browserTab.isLoading
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let webView else { return completionHandler(nil, ExtensionBridgeError.tabNotLoaded) }
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            // A suspended tab loads it when it next gets a web view.
            browserTab.navigateToURL(url.absoluteString)
        }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView else { return completionHandler(ExtensionBridgeError.tabNotLoaded) }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView, webView.canGoBack else { return completionHandler(ExtensionBridgeError.noHistory) }
        webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView, webView.canGoForward else { return completionHandler(ExtensionBridgeError.noHistory) }
        webView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tabManager else { return completionHandler(ExtensionBridgeError.noWindow) }
        tabManager.switchToTab(browserTab)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        tabManager?.activeTabId == browserTab.id
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let url = configuration.url ?? URL(string: browserTab.url)
        let tab = bridge.openTab(url: url, active: configuration.shouldBeActive, parent: self)
        completionHandler(tab, tab == nil ? ExtensionBridgeError.noWindow : nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tabManager else { return completionHandler(ExtensionBridgeError.noWindow) }
        tabManager.closeTab(browserTab)
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

// MARK: - Extension popup windows

/// A window an extension opened for itself with windows.create — e.g. a
/// password manager's pop-out — holding one page of the extension's. Not a
/// browser window (`BrowserWindow.isBrowserWindow`).
@MainActor
final class ExtensionPopupWindow: NSObject, WKWebExtensionWindow, NSWindowDelegate {
    nonisolated static let windowIdentifier = NSUserInterfaceItemIdentifier("klar.extension-popup")

    let nsWindow: NSWindow
    private(set) var tab: ExtensionPopupTab!
    private unowned let bridge: ExtensionBrowserBridge

    /// `frame` is in screen coordinates; WebKit leaves the parts the
    /// extension didn't specify NaN.
    init(bridge: ExtensionBrowserBridge, controller: WKWebExtensionController, context: WKWebExtensionContext,
         url: URL?, frame: CGRect) {
        self.bridge = bridge
        let size = CGSize(
            width: frame.width.isFinite && frame.width > 50 ? frame.width : 420,
            height: frame.height.isFinite && frame.height > 50 ? frame.height : 640
        )
        let hasOrigin = frame.minX.isFinite && frame.minY.isFinite
        nsWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        // The extension's own pages load only in its context's configuration,
        // which makes them extension pages: in another, a password manager's
        // passkey window stayed blank. That would put the page in its background's
        // process, where the background's service worker gets its window
        // from extension.getViews, and reading it crashes the process, the
        // background with it (WebKit doesn't start it again until Klar
        // quits). A process pool of its own keeps them apart: a new
        // configuration's (processPool is set through KVC, as in
        // WebViewConfiguration), once it's no longer related to the
        // background's web view, whose pool it would have to share (WebKit
        // raises otherwise). A website gets a web page's configuration.
        let configuration: WKWebViewConfiguration
        let unrelate = NSSelectorFromString("_setRelatedWebView:")
        if url?.scheme == ExtensionManager.urlScheme,
           let extensionConfiguration = context.webViewConfiguration,
           extensionConfiguration.responds(to: unrelate) {
            configuration = extensionConfiguration.copy() as! WKWebViewConfiguration
            configuration.perform(unrelate, with: nil)
            configuration.setValue(WKWebViewConfiguration().value(forKey: "processPool"), forKey: "processPool")
        } else {
            configuration = WKWebViewConfiguration()
            WebViewConfiguration.shared.useSharedProcessPool(in: configuration)
            configuration.webExtensionController = controller
            configuration.websiteDataStore = .default()
        }
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        tab = ExtensionPopupTab(window: self, webView: webView, bridge: bridge)

        nsWindow.identifier = Self.windowIdentifier
        nsWindow.isReleasedWhenClosed = false
        nsWindow.contentView = webView
        nsWindow.delegate = self
        if hasOrigin {
            nsWindow.setFrameOrigin(frame.origin)
        } else {
            nsWindow.center()
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    func windowWillClose(_ notification: Notification) {
        tab.stopObserving()
        bridge.popupWindowDidClose(self)
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        nsWindow.isMiniaturized ? .minimized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext,
                        completionHandler: @escaping (Error?) -> Void) {
        switch state {
        case .minimized: nsWindow.miniaturize(nil)
        default: if nsWindow.isMiniaturized { nsWindow.deminiaturize(nil) }
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (nsWindow.screen ?? NSScreen.main)?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow.frame
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nsWindow.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nsWindow.close()
        completionHandler(nil)
    }
}

/// The page in an extension popup window.
@MainActor
final class ExtensionPopupTab: NSObject, WKWebExtensionTab, WKUIDelegate {
    let webView: WKWebView
    private unowned let popupWindow: ExtensionPopupWindow
    private unowned let bridge: ExtensionBrowserBridge
    private var observations: [NSKeyValueObservation] = []

    init(window: ExtensionPopupWindow, webView: WKWebView, bridge: ExtensionBrowserBridge) {
        self.popupWindow = window
        self.webView = webView
        self.bridge = bridge
        super.init()
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed(.URL) }
            },
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.popupWindow.nsWindow.title = webView.title ?? ""
                    self?.changed(.title)
                }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed(.loading) }
            }
        ]
    }

    func stopObserving() {
        observations.removeAll()
    }

    private func changed(_ properties: WKWebExtension.TabChangedProperties) {
        bridge.tabDidChange(self, properties)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { popupWindow }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        popupWindow.nsWindow.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        popupWindow.nsWindow.close()
        completionHandler(nil)
    }

    // MARK: WKUIDelegate

    /// Links the page opens in a new window go to a Klar tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            _ = bridge.openTab(url: url, active: true)
            bridge.browserWindow?.makeKeyAndOrderFront(nil)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindow.nsWindow.close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: popupWindow.nsWindow) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: popupWindow.nsWindow) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

enum ExtensionBridgeError: LocalizedError {
    case noWindow
    case tabNotLoaded
    case noHistory

    var errorDescription: String? {
        switch self {
        case .noWindow: return "Klar's window isn't open."
        case .tabNotLoaded: return "The tab isn't loaded."
        case .noHistory: return "The tab has no page to go to."
        }
    }
}
