import Foundation
import WebKit
import ObjectiveC
import os.log

// Coordinator manages the WebView for a specific tab
class TabWebViewCoordinator: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, @unchecked Sendable {
    let tab: BrowserTab
    let webView: WKWebView
    private weak var tabManager: TabManager?
    private var observersAdded = false
    private var observerKeyPaths: Set<String> = []
    private var uiDelegate: CustomWKUIDelegate!
    
    /// Whether tearDown or performCleanup has run.
    private var isCleanedUp = false
    private var webViewCleanedUp = false
    
    // Track explicit favicon refresh requests (for reload functionality)
    private var faviconRefreshRequested = false
    /// Favicon cache key (host and port) the tab's icon was last fetched for.
    private var lastFaviconCacheKey: String?
    /// The icons the page lists, loaded by WebKit (`showPageIcon`).
    private lazy var pageIconLoader = PageIconLoader(isPrivate: tab.isPrivate)
    
    /// The history entry the page was last at: a new one without a load is
    /// a navigation within the page (`updateURL`)
    private var lastHistoryItem: WKBackForwardListItem?

    // Track when we're showing an error page to preserve original URL
    private var isShowingErrorPage = false
    private var originalFailedURL: String?
    /// The address the certificate error page on screen is about, which its
    /// Proceed Anyway may be taken for (handleSSLBypassMessage).
    private var certificateErrorURL: String?
    
    // Track when we cancel navigation for downloads to avoid showing error page
    private var cancelledForDownload = false
    
    // Track pointer events state to avoid redundant CSS operations
    private var pointerEventsEnabled = true

    /// The color the page last reported while its tab was off screen, where
    /// it isn't applied (see handleBackgroundColorUpdate).
    private var backgroundColorWhileHidden: String?

    /// When the page's web process last ended, to tell a page that keeps
    /// crashing from a one-off (webViewWebContentProcessDidTerminate).
    private var lastWebProcessTermination: Date?
    private static let repeatedCrashInterval: TimeInterval = 30

    /// Tells an answer to the latest suspend check from a stale one.
    private var suspendCheckGeneration = 0

    /// Web views whose page reported that the user typed into something the
    /// suspend-time form check can't see — a rich-text editor, or any field
    /// in a frame (the `userEdited` message). Kept per web view rather than
    /// per coordinator: a window.open child's messages arrive through its
    /// opener's handlers. Cleared when the main frame commits a new document.
    fileprivate static let webViewsWithUnsavedEdits = NSHashTable<WKWebView>.weakObjects()


    /// Messages the page scripts post to this coordinator: background colour
    /// updates, window drags, blob downloads and SSL bypass, plus the password
    /// autofill bridge (content script in
    /// WebViewConfiguration.addAutofillBridgeScript, native side
    /// AutofillCoordinator.shared, routed via userContentController:didReceive:).
    private static let scriptMessageNames = [
        "backgroundColorUpdate",
        "windowDrag",
        "blobDownload",
        "sslBypass",
        "autofillFieldFocused",
        "autofillIconClicked",
        "autofillFormSubmitted"
    ]


    // MARK: - Pre-configured WebView handoff (window.open opener bridge)
    // Holds WebViews built inside CustomWKUIDelegate.createWebViewWith with the
    // unmodified configuration WebKit handed us. Each is keyed by the predetermined
    // tab UUID that gets posted with the CreateNewTab notification, so when SwiftUI
    // renders the new tab and instantiates this coordinator, createWebView(for:)
    // picks up the same WKWebView instance (preserving window.opener / postMessage)
    // instead of pulling a fresh one from the pool.
    private static let preconfiguredWebViewLock = NSLock()
    private static var preconfiguredWebViews: [UUID: WKWebView] = [:]

    static func stashPreconfiguredWebView(_ webView: WKWebView, for tabId: UUID) {
        preconfiguredWebViewLock.lock()
        defer { preconfiguredWebViewLock.unlock() }
        preconfiguredWebViews[tabId] = webView
    }

    private static func takePreconfiguredWebView(for tabId: UUID) -> WKWebView? {
        preconfiguredWebViewLock.lock()
        defer { preconfiguredWebViewLock.unlock() }
        return preconfiguredWebViews.removeValue(forKey: tabId)
    }
    
    /// True when this coordinator adopted a WKWebView built inside
    /// CustomWKUIDelegate.createWebViewWith. Such a WebView's
    /// WKUserContentController may be shared with the parent (per
    /// WKWebViewConfiguration's shallow copy semantics), so we skip our own
    /// message-handler / userScript wiring to avoid tearing out the parent's
    /// handlers or hitting `add(_:name:)`'s "already registered" exception.
    private let isAdoptedWebView: Bool

    init(tab: BrowserTab, tabManager: TabManager? = nil) {
        self.tab = tab
        self.tabManager = tabManager

        // Initialize WebView — adopt the createWebViewWith handoff if present so
        // window.opener stays wired up; otherwise build a fresh one.
        if let preconfigured = Self.takePreconfiguredWebView(for: tab.id) {
            self.webView = preconfigured
            self.isAdoptedWebView = true
        } else {
            self.webView = Self.createWebView(for: tab)
            self.isAdoptedWebView = false
        }

        super.init()

        // The tab has a web view again; pick up what its last one showed.
        let suspendedState = tab.resume()
        if let pageZoom = suspendedState.pageZoom {
            webView.pageZoom = pageZoom
        }

        // One-time global observer registration. Done lazily here so it
        // doesn't need explicit wiring in app startup.
        Self.registerGlobalObserversIfNeeded()

        // Register this coordinator (must be after super.init). Held weakly
        // so ARC can deallocate the coordinator when its tab/SwiftUI owner
        // releases it, without depending on the ForceCoordinatorCleanup
        // notification being posted.
        Self.allTabCoordinators[tab.id] = WeakCoordinator(self)
        
        // Configure WebView
        setupWebView()
        // Adopted WebViews are already mid-load via WebKit's createWebViewWith
        // path. Calling loadInitialContent here would issue a second
        // webView.load(...) for the same URL, racing the in-flight request.
        if !isAdoptedWebView {
            loadInitialContent(restoring: suspendedState.interactionState)
        }
    }

    // MARK: - WebView Creation

    private static func createWebView(for tab: BrowserTab) -> WKWebView {
        // A suspended tab — restored from the last session, or put to sleep
        // in the background — comes back because Klar reloads it, not
        // because the user just opened that page, so it mustn't start
        // playing sound on its own. Nor does one loaded in the background
        // (a pinned site). Muted videos still play.
        let allowAutoplay = !tab.isSuspended && !tab.isLoadedInBackground

        // A space with a separate profile, and a private tab, have a data
        // store of their own, which pooled WebViews (on the shared one) don't use.
        let usesSharedDataStore = !tab.isPrivate && SpaceManager.shared.profileID(of: tab) == nil

        // Pooled WebViews autoplay, and file URLs may need a different
        // security context, so neither gets one.
        if allowAutoplay, usesSharedDataStore, !tab.url.hasPrefix("file://"),
           let preWarmedWebView = WebViewPool.shared.getPreWarmedWebView() {
            return preWarmedWebView
        }
        return WebViewConfiguration.shared.createWebView(
            allowAutoplay: allowAutoplay && !tab.url.hasPrefix("file://"),
            dataStore: SpaceManager.shared.websiteDataStore(for: tab)
        )
    }
    
    // MARK: - Setup Methods
    
    private func setupWebView() {
        // Create and assign delegates
        self.uiDelegate = CustomWKUIDelegate(tabId: tab.id, isPrivate: tab.isPrivate)
        webView.navigationDelegate = self
        webView.uiDelegate = uiDelegate
        pageIconLoader.onIcon = { [weak self] favicon, url in
            self?.showPageIcon(favicon, for: url)
        }
        pageIconLoader.attach(to: webView)
        if let webView = webView as? CustomWKWebView {
            webView.tabID = tab.id
            webView.tabManager = tabManager
        }

        // Adopted WebViews skip message-handler wiring — see isAdoptedWebView doc.
        // The popup inherits the parent's user scripts via the (likely-shared)
        // userContentController, which is enough for OAuth callback flows.
        if !isAdoptedWebView {
            let contentController = webView.configuration.userContentController

            // Add geolocation bridge with tab ID
            let geolocationBridge = GeolocationBridge(tabId: tab.id)
            contentController.add(geolocationBridge, name: "geolocationBridge")

            // WKUserContentController retains its handlers, and this
            // coordinator retains the web view that owns the controller, so
            // registering `self` directly was a cycle: a closed or unloaded
            // tab's coordinator, WKWebView and page were never freed. The
            // proxy only holds us weakly.
            let handler = TabScriptMessageHandler(self)
            for name in Self.scriptMessageNames {
                contentController.add(handler, name: name)
            }

            // Shared and stateless, so it needs no weak proxy.
            contentController.add(UnsavedEditsMessageHandler.shared, name: "userEdited")
        }

        // Setup observers
        setupObservers()

        // Initialize navigation state
        updateCanGoBack()
        updateCanGoForward()

        // Sync any state already present on the WebView before observers attached.
        // Relevant for the createWebViewWith handoff: WebKit may have already begun
        // loading the URL (and even set title) by the time SwiftUI instantiates this
        // coordinator, and KVO with `.new` won't replay those values.
        lastHistoryItem = webView.backForwardList.currentItem
        if webView.url != nil { updateURL() }
        if let title = webView.title, !title.isEmpty { updateTitle() }
    }
    
    private func setupObservers() {
        let keyPaths = ["URL", "title", "estimatedProgress", "canGoBack", "canGoForward", "_isPlayingAudio"]
        
        for keyPath in keyPaths {
            webView.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
            observerKeyPaths.insert(keyPath)
        }
        
        observersAdded = true
    }
    
    // MARK: - Global Notification Dispatcher

    // Tab-targeted notifications go through one static dispatcher rather
    // than per-coordinator observers: it reads the tabId from userInfo and
    // delivers to that coordinator alone, a dictionary lookup instead of an
    // N-coordinator fan-out.

    private static var globalObserversRegistered = false

    /// Tab-targeted notifications. Each carries a `"tabId"` UUID string in
    /// userInfo; the dispatcher routes the notification to that coordinator
    /// only, instead of broadcasting to every live coordinator.
    private static let globalNotificationNames: [String] = [
        "ReloadWebView",
        "FocusWebView",
        "ToggleWebInspector",
        "GoBackWebView",
        "GoForwardWebView",
        "ForceCoordinatorCleanup",
        "NavigateWebView",
        "ZoomInWebView",
        "ZoomOutWebView",
        "ResetZoomWebView",
        "MediaControlMuteTab"
    ]

    private static func registerGlobalObserversIfNeeded() {
        guard !globalObserversRegistered else { return }
        globalObserversRegistered = true

        for name in globalNotificationNames {
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: nil // run synchronously on the posting thread; we hop to main below if needed
            ) { notification in
                guard let tabIdString = notification.userInfo?["tabId"] as? String,
                      let tabId = UUID(uuidString: tabIdString) else {
                    return
                }
                // Only used on the main thread
                nonisolated(unsafe) let notification = notification
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        TabWebViewCoordinator.coordinator(for: tabId)?.routeGlobalNotification(notification)
                    }
                } else {
                    DispatchQueue.main.async {
                        TabWebViewCoordinator.coordinator(for: tabId)?.routeGlobalNotification(notification)
                    }
                }
            }
        }
    }

    private func routeGlobalNotification(_ notification: Notification) {
        switch notification.name.rawValue {
        case "ReloadWebView": handleReload(notification)
        case "FocusWebView": handleFocus(notification)
        case "ToggleWebInspector": handleInspectorToggle(notification)
        case "GoBackWebView": handleGoBack(notification)
        case "GoForwardWebView": handleGoForward(notification)
        case "ForceCoordinatorCleanup": handleForceCleanup(notification)
        case "NavigateWebView": handleNavigate(notification)
        case "ZoomInWebView": handleZoomIn(notification)
        case "ZoomOutWebView": handleZoomOut(notification)
        case "ResetZoomWebView": handleResetZoom(notification)
        case "MediaControlMuteTab": handleMediaControlMute(notification)
        default: break
        }
    }
    
    // MARK: - Navigation and Loading
    
    private func loadInitialContent(restoring suspendedState: Any?) {
        // A tab coming back from suspension picks up where its last web view
        // left off — unless the user has since asked for another page.
        if let suspendedState, !tab.pendingUserNavigation {
            webView.interactionState = suspendedState
            return
        }

        guard !tab.isEmpty else {
            return
        }
        
        guard let url = URL(string: tab.url) else {
            return
        }
        
        // Handle file URLs with loadFileURL for better compatibility
        if url.isFileURL {
            if FileManager.default.fileExists(atPath: url.path) {
                let readAccessURL = url.deletingLastPathComponent()
                webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
            }
        } else {
            let request = URLRequest(url: url)
            webView.load(request)
        }
        
        tab.clearPendingNavigation()
    }
    
    func loadPendingNavigation() {
        guard !tab.isEmpty else {
            tab.clearPendingNavigation()
            return
        }
        
        guard let url = URL(string: tab.url) else {
            tab.clearPendingNavigation()
            return
        }
        
        // Check if WebView is in a stuck state
        if webView.isLoading && webView.estimatedProgress == 0.0 {
            webView.stopLoading()
            
            // Brief delay to allow WebView to reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, !self.isCleanedUp else { return }
                // Handle file URLs with loadFileURL for better compatibility
                if url.isFileURL {
                    let readAccessURL = url.deletingLastPathComponent()
                    self.webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
                } else {
                    self.webView.load(URLRequest(url: url))
                }
                self.tab.clearPendingNavigation()
            }
        } else {
            // Handle file URLs with loadFileURL for better compatibility
            if url.isFileURL {
                if FileManager.default.fileExists(atPath: url.path) {
                    let readAccessURL = url.deletingLastPathComponent()
                    webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
                } else {
                    // File doesn't exist, clear pending navigation
                    tab.clearPendingNavigation()
                }
            } else {
                webView.load(URLRequest(url: url))
            }
            tab.clearPendingNavigation()
        }
    }
    
    // MARK: - Pointer Events Control
    
    func setPointerEventsEnabled(_ enabled: Bool) {
        // Only update if state actually changes to avoid redundant CSS operations
        guard pointerEventsEnabled != enabled else { return }
        
        pointerEventsEnabled = enabled
        
        if enabled {
            removePointerEventsCSS()
        } else {
            injectPointerEventsCSS()
        }
    }
    
    private func injectPointerEventsCSS() {
        // Check if cleanup has started to prevent JavaScript evaluation on deallocated WebView
        guard !isCleanedUp else { return }
        
        let css = "* { pointer-events: none !important; } html { cursor: default !important; }"
        
        let javascript = """
            (function() {
                try {
                    var style = document.getElementById('klar-disable-pointer-events');
                    if (style) return; // Already injected
                    
                    style = document.createElement('style');
                    style.id = 'klar-disable-pointer-events';
                    style.textContent = '\(css)';
                    
                    var target = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
                    if (target) {
                        target.appendChild(style);
                    }
                } catch (e) {
                    console.error('Klar: Failed to inject pointer-events CSS:', e);
                }
            })();
        """
        
        webView.evaluateJavaScript(javascript) { [isPrivate = tab.isPrivate] _, error in
            if let error = error {
                logError(.webView, "Failed to inject pointer-events CSS: \(error)", isPrivate: isPrivate)
            }
            // Success case is expected - no need to log
        }
    }
    
    private func removePointerEventsCSS() {
        // Check if cleanup has started to prevent JavaScript evaluation on deallocated WebView
        guard !isCleanedUp else { return }
        
        let javascript = """
            (function() {
                try {
                    var style = document.getElementById('klar-disable-pointer-events');
                    if (style && style.parentNode) {
                        style.parentNode.removeChild(style);
                    }
                } catch (e) {
                    console.error('Klar: Failed to remove pointer-events CSS:', e);
                }
            })();
        """
        
        webView.evaluateJavaScript(javascript) { [isPrivate = tab.isPrivate] _, error in
            if let error = error {
                logError(.webView, "Failed to remove pointer-events CSS: \(error)", isPrivate: isPrivate)
            }
            // Success case is expected - no need to log
        }
    }
    // MARK: - Notification Handlers
    
    private func handleReload(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }
        
        tab.isLoading = true
        tab.estimatedProgress = 0.0
        
        // Set flag to indicate favicon refresh was explicitly requested
        faviconRefreshRequested = true
        
        // Request favicon refresh for this URL
        NotificationCenter.default.post(
            name: .faviconRefreshRequested,
            object: tab.url
        )
        
        // If we're showing an error page, reload the original failed URL instead of "about:blank"
        if isShowingErrorPage, let originalURL = originalFailedURL, let url = URL(string: originalURL) {
            // Reset error page state
            isShowingErrorPage = false
            tab.isShowingErrorPage = false
            originalFailedURL = nil
            
            // Load the original URL that failed
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }
    
    private func handleFocus(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }
        
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check cleanup state again
            guard !self.isCleanedUp else { return }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                // Final cleanup check before accessing WebView
                guard !self.isCleanedUp else { return }
                
                if let window = self.webView.window {
                    window.makeFirstResponder(self.webView)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        
                        // Final cleanup check
                        guard !self.isCleanedUp else { return }
                        
                        self.webView.window?.makeFirstResponder(self.webView)
                    }
                }
            }
        }
    }
    
    /// Whether the page's Web Inspector is open, docked or in a window of
    /// its own, however it was opened: ⌥⌘I, Inspect Element or Show Page
    /// Source in the page's menu. Closed with its own button too.
    private var isInspectorOpen: Bool {
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else { return false }
        return inspector.value(forKey: "isVisible") as? Bool ?? false
    }

    private func handleInspectorToggle(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            guard let inspector = self.webView.value(forKey: "_inspector") as? NSObject else { return }

            let selector = NSSelectorFromString(self.isInspectorOpen ? "close" : "show")
            if inspector.responds(to: selector) {
                // Release builds keep developer extras off until asked:
                // with them on, WebKit retains every page's console output.
                if !self.isInspectorOpen {
                    WebViewConfiguration.enableDeveloperTools(for: self.webView)
                }
                inspector.perform(selector)
            }
        }
    }

    private func handleGoBack(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            // Check if this tab has a parent and no WebKit back history
            if let parentTabId = self.tab.parentTabId, !self.webView.canGoBack {
                logDebug(.webView, "🔙 New tab has no back history - closing and returning to parent tab")

                // Post notification to close this tab and activate parent
                NotificationCenter.default.post(
                    name: NSNotification.Name("CloseTabAndReturnToParent"),
                    object: nil,
                    userInfo: [
                        "tabId": self.tab.id.uuidString,
                        "parentTabId": parentTabId.uuidString
                    ]
                )
            } else if self.webView.canGoBack {
                // Standard WebKit back navigation
                self.webView.goBack()

                // Force background color extraction after navigation
            }
            // If no parent and no back history, do nothing (no back navigation available)
        }
    }

    private func handleGoForward(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            if self.webView.canGoForward {
                self.webView.goForward()

                // Force background color extraction after navigation
            }
        }
    }
    
    private func handleForceCleanup(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }
        
        performCleanup()
    }
    
    /// Tears the web view down right away. SwiftUI calls this through
    /// `TabWebView.dismantleNSView` when the tab's view leaves the window —
    /// the tab was closed, unloaded or suspended, or the window itself went
    /// away — so no page keeps running (or playing audio) where nobody can
    /// see it. Idempotent; the ForceCoordinatorCleanup path may already
    /// have run.
    func tearDown() {
        let isCleanedUpAlready = isCleanedUp
        isCleanedUp = true

        // Still in the tab list: the tab was suspended, or the window
        // closed. Remember what the page showed for its next web view.
        if !isCleanedUpAlready, let tabManager, tabManager.tabs.contains(where: { $0 === tab }) {
            // pageZoom isn't part of interactionState.
            tab.markSuspended(interactionState: restorableInteractionState(), pageZoom: webView.pageZoom)

            // Not while SwiftUI is still tearing views down: these publish.
            let tab = self.tab
            DispatchQueue.main.async {
                guard tab.isSuspended else { return }
                tab.isLoading = false
                tab.estimatedProgress = 0
                tab.isPlayingMedia = false
                tab.isMediaMuted = false
                MediaControlManager.shared.cleanupTab(tab.id)
                // The sidebar row's audio button only follows this.
                NotificationCenter.default.post(
                    name: NSNotification.Name("TabMediaStateChanged"),
                    object: nil,
                    userInfo: ["tabId": tab.id.uuidString, "isPlaying": false, "isMediaMuted": false]
                )
            }
        }

        Self.forgetCoordinator(for: tab.id, owner: ObjectIdentifier(self))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        pageIconLoader.detach(from: webView)
        removeAllObservers()
        terminateWebViewProcess()
    }

    /// What the page shows — back/forward list, scroll position, form data —
    /// in a form a new web view can restore. Error pages and local files
    /// load from their URL again instead.
    func restorableInteractionState() -> Any? {
        guard webView.url != nil, !isShowingErrorPage, !tab.url.hasPrefix("file://") else { return nil }
        return webView.interactionState
    }

    /// Whether the web view stays in the window while its tab is in the
    /// background (WebViewContainerView.setActive): a docked inspector sits
    /// next to it, playing media keeps rendering, and a call keeps its
    /// camera and microphone. (The Now Playing preview borrows the web view
    /// itself while it shows it.)
    var keepsWebViewInWindow: Bool {
        let mediaState = MediaControlManager.shared.tabMediaStates[tab.id]
        let isPlayingMuted = mediaState.map { $0.isMediaMuted && !$0.isMediaPaused } ?? false
        return isInspectorOpen || tab.isPlayingMedia || isPlayingMuted
            || webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
    }

    /// Whether this tab's page can be taken down without losing something the
    /// user would miss: audible media (or media they muted from the
    /// sidebar), a camera or microphone in use, an open inspector, windows it
    /// opened that are still open, or edits — reported ones in editors and
    /// frames, and form fields, which the page is asked about.
    func checkSuspendable(_ completion: @escaping (Bool) -> Void) {
        let mediaState = MediaControlManager.shared.tabMediaStates[tab.id]
        let isPlayingMuted = mediaState.map { $0.isMediaMuted && !$0.isMediaPaused } ?? false
        // Windows this page opened with window.open lose their window.opener
        // with it, and the popups it hosts close with it.
        let tabID = tab.id
        let hasOpenChildTab = tabManager?.tabs.contains {
            $0.parentTabId == tabID && $0.hasOpener && !$0.isSuspended
        } ?? false
        guard !isCleanedUp, !tab.isPlayingMedia, !isPlayingMuted, !isInspectorOpen,
              !Self.webViewsWithUnsavedEdits.contains(webView), !hasOpenChildTab, !uiDelegate.hasOpenPopups,
              webView.cameraCaptureState == .none,
              webView.microphoneCaptureState == .none else {
            completion(false)
            return
        }

        // One answer per check: the page's, or — if it doesn't give one —
        // a timeout's. A page that can't answer is hung, and the best
        // candidate there is.
        suspendCheckGeneration &+= 1
        let generation = suspendCheckGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.suspendCheckGeneration == generation else { return }
            self.suspendCheckGeneration &+= 1
            completion(true)
        }

        // In Klar's own script world, where the page's scripts can't get in
        // the way; the DOM is shared.
        webView.evaluateJavaScript(Self.hasEditedFormFieldsScript, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.suspendCheckGeneration == generation else { return }
            self.suspendCheckGeneration &+= 1
            let hasEdits = (try? result.get()) as? Bool ?? false
            completion(!hasEdits)
        }
    }

    /// True when the page has form fields that differ from what it loaded
    /// with, or a focused rich-text editor. Main frame only.
    private static let hasEditedFormFieldsScript = """
        (() => {
            for (const field of document.querySelectorAll('input, textarea, select')) {
                if (field.disabled) continue;
                switch (field.type) {
                // Range and color report a default value with no value
                // attribute, so they'd always look edited.
                case 'hidden': case 'submit': case 'button': case 'reset': case 'image': case 'file':
                case 'range': case 'color':
                    continue;
                case 'checkbox': case 'radio':
                    if (field.checked !== field.defaultChecked) return true;
                    continue;
                case 'select-one': case 'select-multiple':
                    for (const option of field.options) {
                        if (option.selected !== option.defaultSelected) return true;
                    }
                    continue;
                default:
                    if (field.value !== field.defaultValue) return true;
                }
            }
            const focused = document.activeElement;
            return !!(focused && focused.isContentEditable);
        })()
        """

    private func performCleanup() {
        // Set cleanup state immediately to prevent further callbacks
        isCleanedUp = true
        
        // Remove from coordinator tracking immediately - thread-safe
        Self.forgetCoordinator(for: tab.id, owner: ObjectIdentifier(self))
        
        // Clean up WebView delegates immediately to prevent callbacks
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        pageIconLoader.detach(from: webView)

        // Remove observers and clean up WebView process
        DispatchQueue.main.async { [weak self] in
            self?.removeAllObservers()
            self?.terminateWebViewProcess()
        }
    }
    
    private func removeAllObservers() {
        guard observersAdded else { return }
        
        for keyPath in observerKeyPaths {
            removeObserverSafely(keyPath: keyPath)
        }
        observersAdded = false
        observerKeyPaths.removeAll()
    }
    
    private func handleNavigate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              let urlString = userInfo["url"] as? String,
              tabIdString == tab.id.uuidString else { return }
        
        guard let url = URL(string: urlString) else {
            logError(.webView, "❌ Invalid URL for navigation in tab \(tab.id.uuidString.prefix(8)): \(urlString)", isPrivate: tab.isPrivate)
            return
        }
        
        logDebug(.webView, "🔄 Direct navigation for tab \(tab.id.uuidString.prefix(8)): \(urlString)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            // Handle file URLs with loadFileURL for better security and compatibility
            if url.isFileURL {
                if FileManager.default.fileExists(atPath: url.path) {
                    self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                } else {
                    logError(.webView, "🗂️ File does not exist at path: \(url.path)", isPrivate: self.tab.isPrivate)
                }
            } else {
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    // MARK: - Zoom Handlers

    private func handleZoomIn(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            let currentZoom = self.webView.pageZoom
            let newZoom = min(currentZoom * 1.2, 5.0) // Max zoom 5x, increment by 20%
            self.webView.pageZoom = newZoom
        }
    }

    private func handleZoomOut(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            let currentZoom = self.webView.pageZoom
            let newZoom = max(currentZoom / 1.2, 0.25) // Min zoom 25%, decrement by 20%
            self.webView.pageZoom = newZoom
        }
    }

    private func handleResetZoom(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              tabIdString == tab.id.uuidString else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleanedUp else { return }
            self.webView.pageZoom = 1.0
        }
    }
    
    private func updateMediaPlaybackState() {
        // Get the playing state from the WebView's private API
        let isPlaying = webView.value(forKey: "_isPlayingAudio") as? Bool ?? false
        
        // Update both the BrowserTab and MediaControlManager
        tab.isPlayingMedia = isPlaying
        MediaControlManager.shared.updatePlaybackState(for: tab.id, isPlaying: isPlaying)
        
        // Notify UI components about media state change
        NotificationCenter.default.post(
            name: NSNotification.Name("TabMediaStateChanged"),
            object: nil,
            userInfo: [
                "tabId": tab.id.uuidString,
                "isPlaying": isPlaying
            ]
        )
    }
    
    private func handleMediaControlMute(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIdString = userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString),
              tabId == tab.id,
              let shouldMute = userInfo["shouldMute"] as? Bool else { return }
        
        // Update the BrowserTab mute state
        tab.isMediaMuted = shouldMute
        
        // Execute the comprehensive mute script through MediaControlManager
        MediaControlManager.shared.executeMuteScript(in: webView, shouldMute: shouldMute)
        
        // Notify UI components about mute state change
        NotificationCenter.default.post(
            name: NSNotification.Name("TabMediaStateChanged"),
            object: nil,
            userInfo: [
                "tabId": tab.id.uuidString,
                "isMediaMuted": shouldMute
            ]
        )
    }

    /// Clean up WebView to allow proper deallocation while preserving user data
    private func terminateWebViewProcess() {
        // Prevents double cleanup
        guard !webViewCleanedUp else { return }
        webViewCleanedUp = true

        // Stop loading and detach delegates BEFORE further teardown so any
        // in-flight navigation callbacks fire into a no-op delegate. We
        // intentionally do NOT load("about:blank") here — that would spin up
        // a fresh page (allocating a JS context and re-injecting all five
        // user scripts) milliseconds before the WebContent process tears
        // down anyway, and was responsible for a large transient memory
        // spike on tab close.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // Pause all media using native API
        webView.pauseAllMediaPlayback(completionHandler: { })

        // Remove from view hierarchy
        webView.removeFromSuperview()

        // The userContentController is left as it is. Windows this page
        // opened with window.open adopt web views that share it (see
        // isAdoptedWebView), and stripping it took their user scripts and
        // message handlers too. Nothing needs it emptied: the handlers hold
        // this coordinator weakly (TabScriptMessageHandler) and the
        // geolocation bridge holds web views weakly, so it goes away with
        // the last web view using it.
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? "unknown"
        
        // Handle blob URL downloads - these need special handling via JavaScript.
        // Many sites (e.g. ElevenLabs) implement downloads by creating a transient
        // <a download> element, clicking it, then removing it from the DOM before
        // our JS gets a chance to inspect it — so we fetch the captured blob URL
        // directly instead of looking it up by href. We also accept `.other` here
        // because programmatic navigations like `location.href = blobUrl` don't
        // fire as `.linkActivated`.
        if url.hasPrefix("blob:") &&
            (navigationAction.navigationType == .linkActivated ||
             navigationAction.navigationType == .other) {
            logDebug(.webView, "📥 Detected blob URL download attempt: \(url)")
            decisionHandler(.cancel)

            // JSON-encode the URL so embedded quotes/backslashes can't break the script.
            let escapedUrl = (try? JSONSerialization.data(withJSONObject: [url]))
                .flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? url

            let jsScript = """
                (function() {
                    const blobUrl = \(escapedUrl);

                    // Best-effort filename hint: any matching <a download> still in DOM.
                    let filename = '';
                    for (const link of document.querySelectorAll('a[href^="blob:"]')) {
                        if (link.href === blobUrl) {
                            filename = link.download || link.getAttribute('download') || '';
                            break;
                        }
                    }

                    fetch(blobUrl)
                        .then(r => r.blob())
                        .then(blob => {
                            const reader = new FileReader();
                            reader.onloadend = function() {
                                window.webkit.messageHandlers.blobDownload.postMessage({
                                    dataUrl: reader.result,
                                    filename: filename,
                                    mimeType: blob.type || 'application/octet-stream',
                                    size: blob.size,
                                    originalBlobUrl: blobUrl
                                });
                            };
                            reader.readAsDataURL(blob);
                        })
                        .catch(error => {
                            console.error('Failed to download blob:', error);
                        });
                })();
            """

            webView.evaluateJavaScript(jsScript) { [isPrivate = tab.isPrivate] (result, error) in
                if let error = error {
                    logError(.webView, "Failed to execute blob download JavaScript: \(error)", isPrivate: isPrivate)
                }
            }
            return
        }
        
        // Handle deep links and custom URL schemes
        if DeepLinkHandler.shared.shouldHandleAsDeepLink(url) {
            DeepLinkHandler.shared.handleDeepLink(url, from: webView)
            decisionHandler(.cancel)
            return
        }
        
        // Handle reload of error pages - redirect to original failed URL
        if isShowingErrorPage && url == "about:blank" && navigationAction.navigationType == .reload {
            if let originalURL = originalFailedURL, let originalURLObj = URL(string: originalURL) {
                logDebug(.webView, "🔄 Reloading error page - redirecting to original URL: \(originalURL)")
                webView.load(URLRequest(url: originalURLObj))
                decisionHandler(.cancel)
                return
            }
        }
        
        // A link ⌘-clicked or middle-clicked opens in a new tab, in the
        // background unless ⇧ is down too. Also a
        // target="_blank" link: WebKit asks here before createWebViewWith.
        // Not while a context menu item is opening the link.
        if navigationAction.opensLinkInNewTab,
           (webView as? CustomWKWebView)?.contextualMenuAction == nil,
           let tabManager {
            decisionHandler(.cancel)
            tabManager.createNewTab(url: url, parentTabId: tab.id, activate: !navigationAction.opensInBackground)
            return
        }

        // Check for cross-domain navigation in saved tabs
        if let tabManager = tabManager,
           let sidebarManager = tabManager.sidebarManager,
           let savedTabId = sidebarManager.browserToSidebarTabMapping[tab.id],
           let _ = sidebarManager.sidebarStructure.tabs[savedTabId] {
            
            // This is a saved tab - check if navigation is cross-domain
            let currentURL = tab.url
            let isAutomatic = isAutomaticNavigation(navigationAction)
            
            // Allow certain types of navigation within saved tabs:
            // 1. about:blank (iframe initialization, blank pages)
            // 2. javascript: URLs (internal scripts)
            // 3. data: URLs (inline content)
            // 4. Same-domain navigation (including non-existent pages)
            // 5. Empty current URL (initial load)
            // 6. Automatic/programmatic navigation (embeds, iframes, redirects)
            // 7. OAuth redirects (authentication flow)
            let shouldAllowNavigation = currentURL.isEmpty ||
                                       url.hasPrefix("about:") ||
                                       url.hasPrefix("javascript:") ||
                                       url.hasPrefix("data:") ||
                                       URLUtilities.isSameSite(currentURL, url) ||
                                       isAutomatic ||
                                       isOAuthRedirect(from: currentURL, to: url)
            
            if !shouldAllowNavigation {
                // True cross-domain navigation from saved tab - create new regular tab
                logDebug(.webView, "🚫 User-initiated cross-domain navigation from saved tab: \(currentURL) → \(url), creating new tab")
                
                DispatchQueue.main.async {
                    _ = tabManager.createNewTab(url: url, parentTabId: self.tab.id)
                }
                
                decisionHandler(.cancel)
                return
            }
        }

        if MicrosoftEntraSSO.handle(navigationAction, in: webView, decisionHandler: decisionHandler) {
            return
        }

        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else {
            decisionHandler(.allow)
            return
        }
        
        let urlString = url.absoluteString
        let mimeType = navigationResponse.response.mimeType ?? ""
        
        // Check if this is a downloadable file by examining the MIME type and file extension
        let fileExtension = url.pathExtension.lowercased()
        let isDownloadableFile = isDownloadableMimeType(mimeType) || isDownloadableFileExtension(fileExtension)
        
        if isDownloadableFile && navigationResponse.canShowMIMEType == false {
            cancelledForDownload = true
            decisionHandler(.download)
            return
        }

        // Also handle cases where the browser can't display the content type
        if !navigationResponse.canShowMIMEType && !mimeType.isEmpty {
            logDebug(.webView, "📥 Cannot display MIME type, starting download: \(urlString) (MIME: \(mimeType))")
            cancelledForDownload = true
            decisionHandler(.download)
            return
        }
        
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let tabAge = Date().timeIntervalSince(tab.createdAt)
        let shouldAutoClose = isDownloadOnlyTab(tab: tab, age: tabAge)

        if shouldAutoClose {
            DownloadManager.shared.registerDownloadTab(tab.id)
        }

        DownloadManager.shared.setupWKDownload(download, fromTabId: shouldAutoClose ? tab.id : nil)
    }

    // MARK: - Authentication Challenge Handling

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protectionSpace = challenge.protectionSpace

        // Handle server trust (SSL/TLS)
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Check if user has chosen to bypass SSL for this host
            if let credential = SSLBypassManager.shared.credential(for: challenge) {
                completionHandler(.useCredential, credential)
                return
            }

            // Otherwise use default system handling
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Handle HTTP Basic/Digest authentication
        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {

            // First, check for existing credentials in Keychain
            if let existingCredential = URLCredentialStorage.shared.defaultCredential(for: protectionSpace) {
                logDebug(.webView, "Using stored credential for \(protectionSpace.host)")
                completionHandler(.useCredential, existingCredential)
                return
            }

            // No stored credentials, show dialog
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    // Coordinator gone — cancel the auth challenge to avoid leaking the handler
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                self.showAuthenticationDialog(
                    for: protectionSpace,
                    webView: webView,
                    completionHandler: completionHandler
                )
            }
            return
        }

        // For other authentication methods, use default handling
        completionHandler(.performDefaultHandling, nil)
    }

    private func showAuthenticationDialog(
        for protectionSpace: URLProtectionSpace,
        webView: WKWebView,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Authentication Required"
        alert.informativeText = "The server \(protectionSpace.host) requires a username and password."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        // Create fields container
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 82))

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 58, width: 300, height: 24))
        usernameField.placeholderString = "Username"

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        passwordField.placeholderString = "Password"

        let rememberCheckbox = NSButton(checkboxWithTitle: "Remember this password in my keychain", target: nil, action: nil)
        rememberCheckbox.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        rememberCheckbox.state = .on  // Default to saving

        containerView.addSubview(usernameField)
        containerView.addSubview(passwordField)
        containerView.addSubview(rememberCheckbox)

        alert.accessoryView = containerView

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                let persistence: URLCredential.Persistence = rememberCheckbox.state == .on ? .permanent : .forSession
                let credential = URLCredential(
                    user: usernameField.stringValue,
                    password: passwordField.stringValue,
                    persistence: persistence
                )

                // Store credential if user wants to remember
                if rememberCheckbox.state == .on {
                    URLCredentialStorage.shared.setDefaultCredential(credential, for: protectionSpace)
                }

                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        if let window = webView.presentationWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                usernameField.becomeFirstResponder()
            }
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            let response = alert.runModal()
            handleResponse(response)
        }
    }

    private func isDownloadableMimeType(_ mimeType: String) -> Bool {
        let downloadableMimeTypes = [
            "application/octet-stream",
            "application/x-apple-diskimage",
            "application/zip",
            "application/x-zip-compressed",
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/x-rar-compressed",
            "application/x-7z-compressed",
            "application/x-tar",
            "application/gzip",
            "application/x-bzip2",
            "application/x-debian-package",
            "application/x-rpm",
            "application/vnd.android.package-archive",
            "application/x-msi",
            "application/x-executable",
            "application/x-dmg"
        ]
        
        return downloadableMimeTypes.contains(mimeType.lowercased())
    }
    
    private func isDownloadableFileExtension(_ fileExtension: String) -> Bool {
        let downloadableExtensions = [
            "dmg", "pkg", "zip", "rar", "7z", "tar", "gz", "bz2",
            "exe", "msi", "deb", "rpm", "apk",
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "mp3", "mp4", "avi", "mov", "mkv", "flv", "wmv",
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "svg",
            "iso", "img", "bin", "app"
        ]
        
        return downloadableExtensions.contains(fileExtension.lowercased())
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check cleanup state again
            guard !self.isCleanedUp else { return }
            
            // Don't clear error page state here - only clear it on successful navigation
            // This prevents URL updates to "about:blank" if this navigation fails again

            // Extra logging for file URLs
            if let url = webView.url, url.isFileURL {
                logDebug(.webView, "🗂️ File URL provisional navigation started: \(url.absoluteString)")
            }

            self.tab.isLoading = true
            self.updateProgress()
        }
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: edits reported for the last one are gone with it,
        // and so are its location requests, what was paused in it and the
        // autofill suggestions for its boxes.
        Self.webViewsWithUnsavedEdits.remove(webView)
        GeolocationBridge.pageDidChange(in: webView)
        MediaControlManager.shared.pageDidChange(for: tab.id)
        AutofillCoordinator.shared.dismissSuggestions(in: webView)
        // A navigation: the open tab goes along, unless it started it
        lastHistoryItem = webView.backForwardList.currentItem
        tab.didNavigate()
    }

    /// The page's web process ended: it crashed, or the system stopped it.
    /// Without this WebKit reloads by itself, and a page that crashes on
    /// every load (a WebKit bug, or an experimental feature turned on in
    /// Settings › Feature Flags) went on crashing twice a second, with the
    /// stuck-load recovery reloading too. Now: a background tab reloads
    /// when it's shown again, the active one reloads once, and a second
    /// crash soon after shows an error page instead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        let crashedRecently = lastWebProcessTermination.map { now.timeIntervalSince($0) < Self.repeatedCrashInterval } ?? false
        lastWebProcessTermination = now
        logWarning(.webView, "Web content process of tab \(tab.id.uuidString.prefix(8)) ended\(crashedRecently ? " again" : "")")

        tab.isLoading = false
        tab.estimatedProgress = 0
        guard !tab.isEmpty, let url = URL(string: tab.url) else { return }

        guard let tabManager, tabManager.splitViews.isVisible(tab.id) else {
            tabManager?.suspendTab(tab)
            return
        }
        if crashedRecently {
            showErrorPage(for: tab.url, errorType: .pageCrashed(hasFeatureFlags: !FeatureFlagsManager.shared.overrides.isEmpty))
        } else if webView.backForwardList.currentItem != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: url))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check cleanup state again
            guard !self.isCleanedUp else { return }
            
            // Don't clear error page state if this is just the error page HTML finishing loading
            let webViewURL = webView.url?.absoluteString ?? ""
            if self.isShowingErrorPage && webViewURL == "about:blank" {
                logDebug(.webView, "🔴 Ignoring didFinish for error page HTML (about:blank) - preserving error state")
                
                // Still update loading state for the tab
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.tab.hasLoadedContent = true
                self.updateProgress()
                return
            }
            
            // Clear error page state on successful navigation to a real URL
            if self.isShowingErrorPage {
                logDebug(.webView, "✅ Clearing error page state after successful navigation to: \(webViewURL)")
            }
            self.isShowingErrorPage = false
            self.tab.isShowingErrorPage = false
            self.originalFailedURL = nil
            
            // For file URLs, check if content actually loaded
            if let url = webView.url, url.isFileURL {
                logDebug(.webView, "🗂️ File URL finished loading: \(url.absoluteString)")
                
                // Check page content to see if it actually loaded
                webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML.length : 0") { [isPrivate = self.tab.isPrivate] result, error in
                    if let error = error {
                        logError(.webView, "🗂️ Error checking file content: \(error)", isPrivate: isPrivate)
                    } else if let length = result as? Int {
                        logDebug(.webView, "🗂️ File page HTML length: \(length) characters")
                        if length == 0 {
                            logWarning(.webView, "⚠️ File URL loaded but page appears empty")
                        }
                    }
                }
                
                // Also check the title
                logDebug(.webView, "🗂️ File page title: '\(webView.title ?? "No title")'")
            }
            
            self.tab.isLoading = false
            self.tab.estimatedProgress = 0.0
            self.tab.hasLoadedContent = true
            self.updateProgress()
            
            // Fetch favicon after page finishes loading (in case URL didn't change but content did)
            if let webViewURL = webView.url?.absoluteString,
               !webViewURL.isEmpty {
                
                // Check if favicon refresh was explicitly requested or if this is a regular tab
                let shouldUpdateFavicon = faviconRefreshRequested || 
                    !(tabManager?.sidebarManager?.browserToSidebarTabMapping[tab.id] != nil)
                
                if shouldUpdateFavicon {
                    // Update favicon - either explicitly requested or regular tab
                    fetchFavicon(for: webViewURL, force: faviconRefreshRequested)
                    
                    // Reset the flag after using it
                    if faviconRefreshRequested {
                        faviconRefreshRequested = false
                        logDebug(.webView, "Updated favicon for saved tab due to explicit refresh request")
                    }
                }

                revalidateFavicon(for: webViewURL)
            }
            
            // Track page visit for successful loads
            self.trackPageVisitIfNeeded()
        }
    }
    
    // MARK: - History Tracking
    
    private func trackPageVisitIfNeeded() {
        guard let url = webView.url?.absoluteString,
              !url.isEmpty,
              !shouldIgnoreURLForHistory(url) else { return }
        
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalTitle = title.isEmpty ? (extractDomainFromURL(url) ?? "Untitled") : title
        
        // Post notification to track page visit
        NotificationCenter.default.post(
            name: NSNotification.Name("TrackPageVisit"),
            object: nil,
            userInfo: [
                "url": url,
                "title": finalTitle,
                "tabId": tab.id.uuidString
            ]
        )
    }
    
    private func shouldIgnoreURLForHistory(_ url: String) -> Bool {
        let ignoredPatterns = [
            "about:",
            "chrome:",
            "chrome-extension:",
            "safari:",
            "data:",
            "javascript:",
            "file://",
            "\(KlarSchemeHandler.scheme):",
        ]
        
        return ignoredPatterns.contains { url.hasPrefix($0) }
    }
    
    private func extractDomainFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Check if this failure was due to cancelling for download
        if cancelledForDownload {
            cancelledForDownload = false // Reset the flag
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }
        
        // Check if this is a cancelled navigation (often happens with back/forward navigation)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }

        // WebKit signals "Plug-in handled load" (WebKitErrorPlugInWillHandleLoad) when its
        // native handler takes over a load — e.g. raw mp4/video URLs. The content actually
        // plays, so suppress the error page. Raw media has no HTML <title>,
        // so derive a title from the URL filename (falling back to host).
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 204 {
            let mediaURL = webView.url ?? URL(string: tab.url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if (self.tab.title.isEmpty || self.tab.title == "New Tab"), let url = mediaURL {
                    let rawFilename = url.lastPathComponent
                    let filename = rawFilename.removingPercentEncoding ?? rawFilename
                    let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
                    let derivedTitle = (!filename.isEmpty && filename != "/") ? filename : host
                    if let title = derivedTitle, title != self.tab.title {
                        self.tab.title = title
                        self.tabManager?.notifyTabDidUpdate(tabId: self.tab.id)
                    }
                }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }

        // Determine the actual failed URL - avoid using about:blank if we're already showing an error page
        let failedURL: String
        if let webViewURL = webView.url?.absoluteString, webViewURL != "about:blank" {
            failedURL = webViewURL
        } else if isShowingErrorPage, let originalURL = originalFailedURL {
            // If we're already showing an error page and the WebView URL is about:blank,
            // this is likely a retry attempt that failed, so use the original failed URL
            failedURL = originalURL
        } else {
            // Fallback to tab URL
            failedURL = tab.url
        }

        logError(.webView, "❌ Navigation failed for tab \(tab.id.uuidString.prefix(8)) URL: \(failedURL) with error: \(error.localizedDescription)", isPrivate: tab.isPrivate)
        
        // Extra logging for file URLs
        if let url = webView.url, url.isFileURL {
            logError(.webView, "🗂️ File URL navigation failed: \(url.absoluteString)", isPrivate: tab.isPrivate)
            logError(.webView, "🗂️ Error details: \(error)", isPrivate: tab.isPrivate)
            
            // Check if file exists
            if FileManager.default.fileExists(atPath: url.path) {
                logDebug(.webView, "🗂️ File exists at path: \(url.path)")
            } else {
                logError(.webView, "🗂️ File does not exist at path: \(url.path)", isPrivate: tab.isPrivate)
            }
        }
        
        // Show custom error page
        showErrorPage(for: failedURL, error: error)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tab.isLoading = false
            self.tab.estimatedProgress = 0.0
            self.updateProgress()
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Check if this failure was due to cancelling for download
        if cancelledForDownload {
            cancelledForDownload = false // Reset the flag
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }
        
        // Check if this is a cancelled navigation (often happens with back/forward navigation)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }

        // A redirect to Microsoft's sign-in that MicrosoftEntraSSO cancelled
        // ("Frame load interrupted") to load it again with its headers.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102,
           MicrosoftEntraSSO.isAuthority(nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) {
            return
        }

        // WebKit signals "Plug-in handled load" (WebKitErrorPlugInWillHandleLoad) when its
        // native handler takes over a load — e.g. raw mp4/video URLs. The content actually
        // plays, so suppress the error page. Raw media has no HTML <title>,
        // so derive a title from the URL filename (falling back to host).
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 204 {
            let mediaURL = webView.url ?? URL(string: tab.url)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if (self.tab.title.isEmpty || self.tab.title == "New Tab"), let url = mediaURL {
                    let rawFilename = url.lastPathComponent
                    let filename = rawFilename.removingPercentEncoding ?? rawFilename
                    let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
                    let derivedTitle = (!filename.isEmpty && filename != "/") ? filename : host
                    if let title = derivedTitle, title != self.tab.title {
                        self.tab.title = title
                        self.tabManager?.notifyTabDidUpdate(tabId: self.tab.id)
                    }
                }
                self.tab.isLoading = false
                self.tab.estimatedProgress = 0.0
                self.updateProgress()
            }
            return
        }

        // The address that failed is the error's: by now webView.url is back
        // at the page before it (a link, a redirect, a typed address).
        // Avoid using about:blank if we're already showing an error page.
        let failedURL: String
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            failedURL = failingURL.absoluteString
        } else if let webViewURL = webView.url?.absoluteString, webViewURL != "about:blank" {
            failedURL = webViewURL
        } else if isShowingErrorPage, let originalURL = originalFailedURL {
            // If we're already showing an error page and the WebView URL is about:blank,
            // this is likely a retry attempt that failed, so use the original failed URL
            failedURL = originalURL
        } else {
            // Fallback to tab URL
            failedURL = tab.url
        }

        logError(.webView, "❌ Failed to load URL for tab \(tab.id.uuidString.prefix(8)): \(failedURL) with error: \(error.localizedDescription)", isPrivate: tab.isPrivate)
        
        // Extra logging for file URLs
        if let url = webView.url, url.isFileURL {
            logError(.webView, "🗂️ File URL provisional navigation failed: \(url.absoluteString)", isPrivate: tab.isPrivate)
            logError(.webView, "🗂️ Error details: \(error)", isPrivate: tab.isPrivate)
            
            // Check if file exists
            if FileManager.default.fileExists(atPath: url.path) {
                logDebug(.webView, "🗂️ File exists at path: \(url.path)")
            } else {
                logError(.webView, "🗂️ File does not exist at path: \(url.path)", isPrivate: tab.isPrivate)
            }
        }
        
        // Show custom error page
        showErrorPage(for: failedURL, error: error)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tab.isLoading = false
            self.tab.estimatedProgress = 0.0
            self.updateProgress()
        }
    }
    
    
    // MARK: - KVO
    
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }
        let objectID = (object as AnyObject?).map(ObjectIdentifier.init)

        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  objectID == ObjectIdentifier(self.webView) else { return }

            guard !self.isCleanedUp else {
                logDebug(.webView, "Ignoring KVO callback for \(keyPath) - coordinator is cleaned up")
                return
            }
            
            switch keyPath {
            case "URL": self.updateURL()
            case "title": self.updateTitle()
            case "estimatedProgress": self.updateProgress()
            case "canGoBack": self.updateCanGoBack()
            case "canGoForward": self.updateCanGoForward()
            case "_isPlayingAudio": self.updateMediaPlaybackState()
            default: break
            }
        }
    }
    
    private func updateURL() {
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        guard let webViewURL = webView.url?.absoluteString else { return }
        
        // Don't update tab URL to "about:blank" when showing error page
        if isShowingErrorPage && webViewURL == "about:blank" {
            return
        }
        
        // Additional safety: Don't update to about:blank if we have a real URL already
        if webViewURL == "about:blank" && !tab.url.isEmpty && !tab.url.hasPrefix("about:") {
            return
        }
        
        tab.updateURLFromWebView(webViewURL)
        // A new entry in the page's history without a load: it went
        // somewhere itself (pushState, back or forward within the page). A
        // load's own entry comes with its commit; an address the page
        // rewrote (replaceState) or a redirect has none.
        if !webView.isLoading, let item = webView.backForwardList.currentItem, item !== lastHistoryItem {
            lastHistoryItem = item
            tab.didNavigate()
        }
        // Don't notify sidebar about URL updates when showing error page or during startup
        if !isShowingErrorPage && !(tabManager?.isInStartupLoadingPhase ?? false) {
            tabManager?.notifyTabDidUpdate(tabId: tab.id)
        } else if tabManager?.isInStartupLoadingPhase == true {
            logDebug(.webView, "🔴 Skipping sidebar notification for URL update during startup: '\(webViewURL)'")
        }
        
        // Check if favicon refresh was explicitly requested or if this is a regular tab
        let shouldUpdateFavicon = faviconRefreshRequested || 
            !(tabManager?.sidebarManager?.browserToSidebarTabMapping[tab.id] != nil)
        
        if shouldUpdateFavicon {
            // Update favicon - either explicitly requested or regular tab
            fetchFavicon(for: webViewURL, force: faviconRefreshRequested)
            
            // Reset the flag after using it
            if faviconRefreshRequested {
                faviconRefreshRequested = false
                logDebug(.webView, "Updated favicon for saved tab due to explicit refresh request")
            }
        }
    }
    
    private func updateTitle() {
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        let newTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if !newTitle.isEmpty && newTitle != tab.title {
            tab.title = newTitle
            // Don't notify sidebar about title updates when showing error page or during startup
            if !isShowingErrorPage && !(tabManager?.isInStartupLoadingPhase ?? false) {
                tabManager?.notifyTabDidUpdate(tabId: tab.id)
            } else {
                let reason = isShowingErrorPage ? "error page" : "startup loading"
                logDebug(.webView, "🔴 Skipping sidebar notification for \(reason) title: '\(newTitle)'")
            }
        } else if newTitle.isEmpty && tab.title == "New Tab" {
            if let host = webView.url?.host {
                let fallbackTitle = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                if !fallbackTitle.isEmpty && fallbackTitle != tab.title {
                    tab.title = fallbackTitle
                    // Don't notify sidebar about title updates when showing error page or during startup
                    if !isShowingErrorPage && !(tabManager?.isInStartupLoadingPhase ?? false) {
                        tabManager?.notifyTabDidUpdate(tabId: tab.id)
                    } else {
                        let reason = isShowingErrorPage ? "error page" : "startup loading"
                        logDebug(.webView, "🔴 Skipping sidebar notification for \(reason) fallback title: '\(fallbackTitle)'")
                    }
                }
            }
        }
    }
    
    private func updateProgress() {
        // Check cleanup state before proceeding
        guard !isCleanedUp else { return }
        
        // Only update tab.estimatedProgress from webView if we're still loading
        // When loading finishes, we manually set it to 0.0 in the navigation delegates
        // The progress bar observes the active tab's published
        // `estimatedProgress`/`isLoading` directly.
        if tab.isLoading {
            tab.estimatedProgress = webView.estimatedProgress
        }
    }
    
    // Only on a change: these also run while SwiftUI makes the tab's view
    // (setupWebView), where publishing even the same value is a warning.
    private func updateCanGoBack() {
        // Check cleanup state before proceeding
        guard !isCleanedUp, tab.canGoBack != webView.canGoBack else { return }
        tab.canGoBack = webView.canGoBack
    }
    
    private func updateCanGoForward() {
        // Check cleanup state before proceeding
        guard !isCleanedUp, tab.canGoForward != webView.canGoForward else { return }
        tab.canGoForward = webView.canGoForward
    }
    
    private func fetchFavicon(for url: String, force: Bool = false) {
        Task { @MainActor [weak self] in
            // The cache is keyed by host and port, so another URL on the same
            // host can't yield another icon: pushState, hash changes and
            // redirects within a site don't need another lookup — or another
            // favicon publish rippling through the UI.
            let cacheKey = FaviconCacheManager.shared.generateCacheKey(for: url)
            if !force, cacheKey == self?.lastFaviconCacheKey, self?.tab.favicon != nil { return }

            let favicon = await FaviconCacheManager.shared.getFavicon(for: url, persist: self?.tab.isPrivate != true, retryingMiss: force)
            if favicon != nil {
                self?.lastFaviconCacheKey = cacheKey
            } else if cacheKey == self?.lastFaviconCacheKey, self?.tab.favicon != nil {
                // The page's own icon came meanwhile (showPageIcon).
                return
            }
            guard self?.tab.favicon !== favicon else { return }

            // Update UI on main actor
            self?.tab.favicon = favicon
            // Don't propagate favicon updates to sidebar during error pages or startup
            if !(self?.isShowingErrorPage ?? false) && !(self?.tabManager?.isInStartupLoadingPhase ?? false) {
                self?.tabManager?.notifyTabDidUpdate(tabId: self?.tab.id)
            } else {
                let reason = (self?.isShowingErrorPage ?? false) ? "error page" : "startup loading"
                logDebug(.webView, "🔴 Skipping sidebar notification for favicon update during \(reason)")
            }
            
            // Notify all FaviconViews that a favicon was loaded for this URL
            if let favicon = favicon {
                NotificationCenter.default.post(
                    name: .faviconCached,
                    object: url,
                    userInfo: ["image": favicon, "private": self?.tab.isPrivate == true]
                )
            }
        }
    }
    
    /// A stored icon over a week old is looked up again once the site has
    /// loaded (saved tabs' too); rows hear of a new one by `.faviconCached`.
    private func revalidateFavicon(for url: String) {
        guard !tab.isPrivate, !isShowingErrorPage else { return }
        Task { @MainActor [weak self] in
            guard let favicon = await FaviconCacheManager.shared.revalidateIfStale(for: url),
                  let self, !self.isCleanedUp else { return }
            let cacheManager = FaviconCacheManager.shared
            guard cacheManager.generateCacheKey(for: self.tab.url) == cacheManager.generateCacheKey(for: url) else { return }
            self.tab.favicon = favicon
            self.tabManager?.notifyTabDidUpdate(tabId: self.tab.id)
        }
    }

    /// An icon the page listed, loaded with the page's own cookies
    /// (`PageIconLoader`): a site behind a browser check answers Klar's own
    /// lookup with the check's page. Rows hear of it by `.faviconCached`.
    private func showPageIcon(_ favicon: NSImage, for url: String) {
        guard !isCleanedUp, !isShowingErrorPage else { return }
        let cacheKey = FaviconCacheManager.shared.generateCacheKey(for: url)
        guard FaviconCacheManager.shared.generateCacheKey(for: tab.url) == cacheKey else { return }
        lastFaviconCacheKey = cacheKey
        guard tab.favicon !== favicon else { return }
        tab.favicon = favicon
        if !(tabManager?.isInStartupLoadingPhase ?? false) {
            tabManager?.notifyTabDidUpdate(tabId: tab.id)
        }
    }

    // MARK: - Error Handling
    
    /// Show a custom error page for the given URL and error
    private func showErrorPage(for url: String, error: Error) {
        showErrorPage(for: url, errorType: ErrorPageGenerator.determineErrorType(from: error, url: url))
    }

    private func showErrorPage(for url: String, errorType: ErrorPageGenerator.ErrorType) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // The address that failed, which a reload tries again, and the
            // tab's, so the URL bar shows it to copy or retry
            self.originalFailedURL = url
            if self.tab.url != url {
                self.tab.updateURLFromWebView(url)
                // Not through notifyTabDidUpdate: a saved tab would take
                // the error page's title
                if let tabManager = self.tabManager, tabManager.activeTabId == self.tab.id {
                    tabManager.objectWillChange.send()
                }
            }
            logDebug(.webView, "🔴 Setting isShowingErrorPage = true for URL: \(url)")
            self.isShowingErrorPage = true
            self.tab.isShowingErrorPage = true
            // Only a certificate error's page offers to go on anyway
            if case .sslError = errorType {
                self.certificateErrorURL = url
            } else {
                self.certificateErrorURL = nil
            }

            let errorHTML = ErrorPageGenerator.generateErrorPage(for: url, errorType: errorType)
            
            // Load the error page
            self.webView.loadHTMLString(errorHTML, baseURL: nil)
            
            // Mark tab as having loaded content (even if it's an error page)
            self.tab.hasLoadedContent = true
            
            // Update tab title to reflect the error state
            self.tab.title = url
        }
    }
    
    // MARK: - Recovery Methods
    
    /// Check if tab is stuck in loading state and attempt recovery
    func checkAndRecoverStuckState() {
        guard tab.isLoading else { return }
        
        // Check for multiple stuck conditions:
        // 1. Loading with no progress for extended time
        // 2. Estimated progress is 0 but loading flag is true
        // 3. WebView reports loading but URL is still empty
        let hasNoProgress = webView.estimatedProgress == 0.0
        let hasEmptyURL = webView.url == nil
        let titleStillNewTab = tab.title == "New Tab"
        
        if hasNoProgress && (hasEmptyURL || titleStillNewTab) {
            logWarning(.webView, "🔧 Tab \(tab.id.uuidString.prefix(8)) appears stuck (progress: \(webView.estimatedProgress), URL: \(webView.url?.absoluteString ?? "nil"), title: \(tab.title)), attempting recovery")
            recoverStuckTab()
        }
    }
    
    /// Attempt to recover a tab that's stuck in loading state
    private func recoverStuckTab() {
        webView.stopLoading()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.tab.isLoading = false
            self.tab.estimatedProgress = 0.0
            self.updateProgress()
            
            // Clear pending navigation state
            self.tab.clearPendingNavigation()
            
            logDebug(.webView, "🔄 Attempting to reload stuck tab \(self.tab.id.uuidString.prefix(8))")
            
            // Attempt to reload if we have a valid URL
            if !self.tab.isEmpty, let url = URL(string: self.tab.url) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.webView.load(URLRequest(url: url))
                }
            }
        }
    }
    
    // MARK: - Changing windows

    /// The view showing the web view (`TabWebView`): another one's than the
    /// view being taken down once its tab has gone to another window.
    weak var containerView: WebViewContainerView?

    /// Its tab is going to another window, whose view hasn't taken it yet:
    /// the view it leaves keeps it alive (`TabWebView.dismantleNSView`).
    private(set) var isChangingWindows = false

    /// Coordinators whose tabs are on their way to another window, until
    /// that window's view adopts them
    private static var coordinatorsChangingWindows: [UUID: TabWebViewCoordinator] = [:]

    /// A tab goes to another window (`BrowserWindowSession.moveTab`): its
    /// page, web view and all, waits for that window's view to take it,
    /// instead of being taken down with the view it leaves. Given up after
    /// a while (the window never showed it): suspended then, it reloads
    /// when shown, as any tab whose web view went.
    static func prepareToChangeWindows(tabID: UUID, to tabManager: TabManager) {
        guard let coordinator = coordinator(for: tabID) else { return }
        coordinator.setTabManager(tabManager)
        coordinator.isChangingWindows = true
        coordinatorsChangingWindows[tabID] = coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak coordinator] in
            guard let coordinator, coordinator.isChangingWindows,
                  coordinatorsChangingWindows[tabID] === coordinator else { return }
            coordinatorsChangingWindows[tabID] = nil
            coordinator.isChangingWindows = false
            coordinator.tearDown()
        }
    }

    /// The coordinator of a tab that came from another window, for the
    /// view showing it here; nil for a tab that didn't.
    static func adoptAfterChangingWindows(tabID: UUID, tabManager: TabManager) -> TabWebViewCoordinator? {
        guard let coordinator = coordinatorsChangingWindows.removeValue(forKey: tabID),
              coordinator.isChangingWindows else { return nil }
        coordinator.isChangingWindows = false
        coordinator.setTabManager(tabManager)
        return coordinator
    }

    private func setTabManager(_ tabManager: TabManager) {
        self.tabManager = tabManager
        (webView as? CustomWKWebView)?.tabManager = tabManager
    }

    // MARK: - Helper Methods
    
    // Track all active coordinators via weak references so ARC can drive
    // deallocation. The ForceCoordinatorCleanup notification path still
    // shoots down coordinators eagerly, but is no longer required for
    // correctness — when SwiftUI releases its strong reference the entry
    // here goes nil and the coordinator deallocates.
    private final class WeakCoordinator {
        weak var value: TabWebViewCoordinator?
        init(_ value: TabWebViewCoordinator) { self.value = value }
    }
    private static var allTabCoordinators: [UUID: WeakCoordinator] = [:]

    /// Drops `tabId`'s registry entry once its coordinator is going away —
    /// but not one a newer coordinator for the same tab has since taken.
    private static func forgetCoordinator(for tabId: UUID, owner: ObjectIdentifier) {
        guard let entry = allTabCoordinators[tabId] else { return }
        if let current = entry.value, ObjectIdentifier(current) != owner { return }
        allTabCoordinators.removeValue(forKey: tabId)
    }

    // Static method to access coordinator for a specific tab
    static func coordinator(for tabId: UUID) -> TabWebViewCoordinator? {
        allTabCoordinators[tabId]?.value
    }

    /// Settings › General › Web developer tools, for the tabs open now. A
    /// page whose inspector is open keeps it until it's closed. Developer
    /// extras is the configuration's preferences, shared with the popups the
    /// page opened.
    static func setDeveloperTools(_ enabled: Bool) {
        for coordinator in allTabCoordinators.values.compactMap(\.value) where !coordinator.isCleanedUp {
            guard enabled || !coordinator.isInspectorOpen else { continue }
            coordinator.webView.configuration.preferences.setValue(enabled, forKey: "developerExtrasEnabled")
            coordinator.webView.isInspectable = enabled
        }
    }

    // MARK: - Utility Methods for Domain Checking
    
    /// Helper to detect OAuth redirect URLs that should always be allowed in saved tabs
    private func isOAuthRedirect(from currentURL: String, to targetURL: String) -> Bool {
        // Check if we're coming from an OAuth provider (like GitHub) and going to an OAuth callback
        guard let currentHost = URL(string: currentURL)?.host,
              let targetHost = URL(string: targetURL)?.host else { return false }
        
        // Common OAuth providers
        let oauthProviders = ["github.com", "google.com", "microsoft.com", "facebook.com", "twitter.com", "discord.com"]
        let isFromOAuthProvider = oauthProviders.contains { currentHost.hasSuffix($0) }
        
        // Check if target URL looks like an OAuth callback
        let targetURLString = targetURL.lowercased()
        let isOAuthCallback = targetURLString.contains("/callback") ||
                             targetURLString.contains("/oauth") ||
                             targetURLString.contains("code=") ||
                             targetURLString.contains("state=")
        
        let result = isFromOAuthProvider && isOAuthCallback
        if result {
            logDebug(.webView, "🔐 Detected OAuth redirect: \(currentHost) → \(targetHost)")
        }
        
        return result
    }
    
    /// Check if navigation is automatic/programmatic (not user-initiated)
    private func isAutomaticNavigation(_ navigationAction: WKNavigationAction) -> Bool {
        let navType = navigationAction.navigationType
        
        // Navigation types that are typically automatic/programmatic:
        // - .other: Programmatic navigation, redirects, form submissions, iframe loads
        // - .formSubmitted: Form submissions (could be automatic)
        // - .formResubmitted: Form resubmissions (could be automatic)
        // 
        // Navigation types that are typically user-initiated:
        // - .linkActivated: User clicked a link
        // - .backForward: User used back/forward buttons
        // - .reload: User reloaded the page
        
        let isAutomatic: Bool
        switch navType {
        case .other:
            // This includes iframes, embeds, redirects, and programmatic navigation
            // We allow these for saved tabs to prevent breaking legitimate page functionality
            isAutomatic = true
        case .formSubmitted, .formResubmitted:
            // Form submissions could be automatic (AJAX) or user-initiated
            // For now, we'll allow them to prevent breaking form functionality
            isAutomatic = true
        case .linkActivated, .backForward, .reload:
            // These are clearly user-initiated actions
            isAutomatic = false
        @unknown default:
            // For unknown types, err on the side of allowing the navigation
            isAutomatic = true
        }
        
        return isAutomatic
    }
    
    // MARK: - Cleanup
    
    isolated deinit {
        // Absolutely minimal deinit to prevent any crashes
        // Set cleanup state directly without using dispatch queues
        isCleanedUp = true

        Self.forgetCoordinator(for: tab.id, owner: ObjectIdentifier(self))

        // Remove notification observers (this should be safe)
        NotificationCenter.default.removeObserver(self)

        // Remove KVO observers
        removeAllObservers()

        // If terminateWebViewProcess() already ran (the normal close path via
        // performCleanup() or tearDown()), the web view is already stopped
        // and detached.
        guard !webViewCleanedUp else { return }
        webViewCleanedUp = true

        // Clear delegates to prevent any callbacks (an isolated deinit: on
        // the main actor). The userContentController is left alone, as in
        // terminateWebViewProcess(). We intentionally skip a final
        // load("about:blank") here — see the matching note there. It
        // allocated a fresh JS context + re-injected all user scripts moments
        // before ARC would tear the WebView down anyway, causing a large
        // transient memory spike on tab close.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.pauseAllMediaPlayback(completionHandler: { })
        webView.removeFromSuperview()
    }
    
    // MARK: - Background Color Extraction
    
    // WKScriptMessageHandler implementation for background color updates
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // A popup window this page opened shares its content controller, so
        // its messages arrive here too (see TabScriptMessageHandler). What's
        // about this tab's own page isn't for those: the popup's color became
        // the tab's, and a press at the top of its page dragged this window.
        let isOwnPage = message.webView === webView

        if message.name == "backgroundColorUpdate" {
            guard isOwnPage else { return }
            handleBackgroundColorUpdate(message.body)
        } else if message.name == "windowDrag" {
            guard isOwnPage else { return }
            handleWindowDragMessage(message.body)
        } else if message.name == "blobDownload" {
            handleBlobDownloadMessage(message.body)
        } else if message.name == "sslBypass" {
            guard isOwnPage else { return }
            handleSSLBypassMessage(message)
        } else if message.name.hasPrefix("autofill") {
            // The autofill bridge is only meaningful for the active tab —
            // background tabs reporting form events would race the user.
            guard tabManager?.activeTabId == tab.id else { return }
            // The frame WebKit reports decides which site's logins apply and
            // where they're filled; the page's own claims aren't trusted.
            let frame = message.frameInfo
            DispatchQueue.main.async {
                // The web view the field is in: a popup's own, for its fields
                guard let sourceWebView = message.webView else { return }
                AutofillCoordinator.shared.handle(
                    name: message.name,
                    body: message.body,
                    frame: frame,
                    webView: sourceWebView
                )
            }
        }
    }

    private func handleBackgroundColorUpdate(_ messageBody: Any) {
        // Parse the simple message format: { color: "rgb(...)", timestamp: ... }
        guard let colorData = messageBody as? [String: Any],
              let colorString = colorData["color"] as? String,
              !colorString.isEmpty else {
            return
        }

        // tab.backgroundColor is only read for the tabs on screen (see
        // BrowserContentArea): the active one, or its split view's panes, any
        // of which may become the active one. MutationObserver-driven color
        // updates from background tabs (sites with animated/scroll-driven
        // backgrounds, theme switches, ad rotators) fire continuously and
        // would otherwise hop to main and re-trigger SwiftUI invalidation for
        // nothing. They're only noted, and the last one is applied once the
        // tab is shown: a page reports a color once, so a page that loaded
        // off screen (a pinned site, a tab switched away from as it loaded)
        // otherwise kept the color of the page before it, or black.
        guard tabManager?.splitViews.isVisible(tab.id) == true else {
            backgroundColorWhileHidden = colorString
            return
        }
        backgroundColorWhileHidden = nil

        DispatchQueue.main.async { [weak self] in
            self?.applyBackgroundColor(colorString)
        }
    }

    /// The tab is on screen (`TabWebView.updateNSView`): its page's color, if
    /// it reported one while it wasn't, counts now.
    func applyBackgroundColorReportedWhileHidden() {
        guard let colorString = backgroundColorWhileHidden else { return }
        backgroundColorWhileHidden = nil
        // Not during SwiftUI's update: this publishes.
        DispatchQueue.main.async { [weak self] in
            self?.applyBackgroundColor(colorString)
        }
    }

    private func applyBackgroundColor(_ colorString: String) {
        guard !isCleanedUp else { return }

        // Parse the color string to Color object
        let newColor = BackgroundColorExtractor.parseColor(colorString)
        let newHex = BackgroundColorExtractor.colorToHex(newColor)

        // Also for an unchanged color: a resumed tab's web view is new
        webView.setUndrawnAreaColor(newColor)

        // Only update if the color actually changed
        if newHex != tab.extractedHexColor {
            tab.backgroundColor = newColor
            tab.extractedHexColor = newHex

            // Notify tab manager of update (skip during error pages or startup)
            if !isShowingErrorPage && !(tabManager?.isInStartupLoadingPhase ?? false) {
                tabManager?.notifyTabDidUpdate(tabId: tab.id)
            } else if tabManager?.isInStartupLoadingPhase == true {
                logDebug(.webView, "🔴 Skipping sidebar notification for background color update during startup")
            }
        }
    }
    
    
    // Helper method for safe observer removal
    private func removeObserverSafely(keyPath: String) {
        // Only attempt removal if we actually added this observer
        guard observerKeyPaths.contains(keyPath) else {
            logDebug(.webView, "Skipping removal of observer for '\(keyPath)' - was never added")
            return
        }
        
        // Remove from tracking immediately to prevent double removal
        observerKeyPaths.remove(keyPath)
        
        // Perform the actual observer removal
        // Note: KVO removeObserver can throw NSException but not Swift Error
        // The crash protection comes from removing from observerKeyPaths first
        webView.removeObserver(self, forKeyPath: keyPath, context: nil)
    }
    
    private func handleBlobDownloadMessage(_ messageBody: Any) {
        guard let messageDict = messageBody as? [String: Any],
              let dataUrl = messageDict["dataUrl"] as? String else {
            logError(.webView, "Invalid blob download message format", isPrivate: tab.isPrivate)
            return
        }

        let mimeType = messageDict["mimeType"] as? String ?? "application/octet-stream"
        let size = messageDict["size"] as? Int ?? 0
        let originalBlobUrl = messageDict["originalBlobUrl"] as? String ?? ""

        // The DOM hint is best-effort: ElevenLabs and friends remove the <a download>
        // before our script runs, so we synthesize a name from the MIME type instead.
        let providedFilename = (messageDict["filename"] as? String) ?? ""
        let filename = providedFilename.isEmpty
            ? "download.\(DownloadManager.shared.fileExtension(forMimeType: mimeType))"
            : providedFilename

        logDebug(.webView, "📥 Processing blob download: \(filename) (\(mimeType), \(size) bytes)")

        DispatchQueue.main.async {
            DownloadManager.shared.startDataURLDownload(
                dataUrl: dataUrl,
                filename: filename,
                mimeType: mimeType,
                originalUrl: originalBlobUrl
            )
        }
    }
    
    // MARK: - SSL Bypass Handling

    /// "Proceed Anyway" on Klar's certificate error page. The handler is in
    /// the page's world, where any page can post to it, so the only request
    /// taken is that page's, for the address it's about: any site could
    /// otherwise have had certificate errors ignored for any host.
    private func handleSSLBypassMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isShowingErrorPage,
              webView.url?.absoluteString == "about:blank",
              let urlString = certificateErrorURL, urlString == message.body as? String,
              let url = URL(string: urlString),
              let host = url.host else {
            logError(.webView, "Ignored an SSL bypass request that isn't the certificate error page's: \(message.body)", isPrivate: tab.isPrivate)
            return
        }
        certificateErrorURL = nil

        logDebug(.webView, "🔓 User requested SSL bypass for: \(host)")

        // Add the host to the bypass list
        SSLBypassManager.shared.addBypass(for: host)

        isShowingErrorPage = false
        tab.isShowingErrorPage = false
        webView.load(URLRequest(url: url))
    }

    // MARK: - Window Drag Handling

    private func handleWindowDragMessage(_ messageBody: Any) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check cleanup state
            guard !self.isCleanedUp else { return }
            
            // Get the window to perform drag
            guard let window = self.webView.window else { return }
            
            // Create a synthetic mouse down event at current cursor position
            let mouseLocation = NSEvent.mouseLocation
            let windowLocation = window.convertPoint(fromScreen: mouseLocation)
            
            // Create a mouse down event for dragging
            guard let mouseEvent = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowLocation,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            ) else { return }
            
            // Use native window dragging API
            window.performDrag(with: mouseEvent)
        }
    }
    
    // MARK: - Download Tab Detection
    
    private func isDownloadOnlyTab(tab: BrowserTab, age: TimeInterval) -> Bool {
        // Be more lenient for newer tabs (created within last 30 seconds)
        let isNewTab = age < 30.0
        
        // Check if tab has minimal content (likely a download-only page)
        let hasMinimalContent = hasMinimalTabContent(tab: tab)
        
        // Check if URL suggests a download/redirect server
        let isRedirectURL = isLikelyRedirectURL(url: tab.url)
        
        // For newer tabs, be more permissive
        if isNewTab {
            return hasMinimalContent || isRedirectURL
        }
        
        // For older tabs, require both minimal content AND redirect patterns
        return hasMinimalContent && isRedirectURL
    }
    
    private func hasMinimalTabContent(tab: BrowserTab) -> Bool {
        // Check for empty or generic tab titles
        let genericTitles = [
            "", "New Tab", "Untitled", "Loading...", "Document",
            "Index of", "Directory listing", "File download"
        ]
        
        let normalizedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Empty tab or generic title
        if tab.isEmpty || genericTitles.contains(where: { normalizedTitle.contains($0.lowercased()) }) {
            return true
        }
        
        // Very short titles often indicate redirect/download pages
        if normalizedTitle.count < 10 && !normalizedTitle.contains(" ") {
            return true
        }
        
        return false
    }
    
    private func isLikelyRedirectURL(url: String) -> Bool {
        guard let parsedURL = URL(string: url) else { return false }
        
        let host = parsedURL.host?.lowercased() ?? ""
        let path = parsedURL.path.lowercased()
        
        // Known download/CDN domains
        let downloadDomains = [
            "dl.google.com", "download.microsoft.com", "github.com",
            "releases.ubuntu.com", "download.mozilla.org", "files.pythonhosted.org"
        ]
        
        if downloadDomains.contains(where: { host.contains($0) }) {
            return true
        }
        
        // Generic download/redirect patterns
        let downloadPaths = [
            "/download", "/dl/", "/files/", "/releases/", "/get/",
            "/redirect", "/link/", "/go/", "/out/"
        ]
        
        if downloadPaths.contains(where: { path.contains($0) }) {
            return true
        }
        
        // File extension in path (direct file downloads)
        let fileExtensions = [
            ".zip", ".dmg", ".pkg", ".exe", ".msi", ".deb", ".rpm",
            ".tar.gz", ".tar.bz2", ".rar", ".7z", ".iso"
        ]
        
        if fileExtensions.contains(where: { path.contains($0) }) {
            return true
        }
        
        return false
    }
} 

/// Hands a page's script messages to its tab's coordinator, which it holds
/// only weakly. WKUserContentController keeps a strong reference to every
/// handler it is given, so registering the owner of the web view directly
/// would keep that owner — and with it the web view and its page — alive
/// forever.
///
/// The windows a page opens share its content controller (see
/// `isAdoptedWebView`), so their messages arrive here too. One opened as a
/// tab has a coordinator of its own, and its messages go there, also once
/// the tab that opened it has closed: they used to be taken for its
/// opener's, so such a tab had no autofill and no page color, and nothing
/// at all without its opener. A popup window's go to its opener's.
private final class TabScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: TabWebViewCoordinator?

    init(_ coordinator: TabWebViewCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let webView = message.webView
        if let coordinator, coordinator.webView === webView {
            coordinator.userContentController(userContentController, didReceive: message)
        } else if let tabID = (webView as? CustomWKWebView)?.tabID,
                  let tabCoordinator = TabWebViewCoordinator.coordinator(for: tabID), tabCoordinator.webView === webView {
            tabCoordinator.userContentController(userContentController, didReceive: message)
        } else {
            coordinator?.userContentController(userContentController, didReceive: message)
        }
    }
}

/// Notes which web views' pages reported an edit a reload would lose (the
/// `userEdited` message; see `TabWebViewCoordinator.webViewsWithUnsavedEdits`).
/// It goes by the message's web view, which also covers a window.open child
/// whose messages arrive through its opener's handlers — even once the
/// opener's coordinator is gone.
private final class UnsavedEditsMessageHandler: NSObject, WKScriptMessageHandler {
    static let shared = UnsavedEditsMessageHandler()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        TabWebViewCoordinator.webViewsWithUnsavedEdits.add(webView)
    }
}

extension WKNavigationAction {
    /// A link clicked with ⌘ or the middle button, which opens in a new tab
    /// instead of this one: a page's address, not a download or a script
    var opensLinkInNewTab: Bool {
        guard navigationType == .linkActivated, !shouldPerformDownload,
              let scheme = request.url?.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return false }
        // WebKit's button numbers: 1 left, 2 right, 4 middle
        return modifierFlags.contains(.command) || buttonNumber == 4
    }

    /// Whether a new tab for it opens behind this one: ⇧ brings it to the front
    var opensInBackground: Bool {
        !modifierFlags.contains(.shift)
    }
}
