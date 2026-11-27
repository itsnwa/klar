import Foundation
import WebKit
import AppKit
import CoreLocation
import os

// Custom WKUIDelegate that handles JavaScript dialogs and essential methods
class CustomWKUIDelegate: NSObject, WKUIDelegate {
    
    // Store popup WebViews to manage their lifecycle
    private var popupWebViews: [WKWebView] = []
    /// Open popup windows (nothing else keeps them alive) and their
    /// will-close observers, dropped together when the window closes.
    private var popupWindows: [NSWindow] = []
    private var popupWindowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Whether popup windows this page opened are still on screen; they
    /// close with this delegate.
    var hasOpenPopups: Bool {
        !popupWindows.isEmpty
    }

    // Store the tab ID for parent tab tracking when creating new tabs
    private let tabId: UUID
    /// Whether the tab is private: its errors then stay out of the log.
    private let isPrivate: Bool
    
    // Note: Location manager removed - geolocation now handled by per-tab JavaScript bridge
    
    init(tabId: UUID, isPrivate: Bool) {
        self.tabId = tabId
        self.isPrivate = isPrivate
        super.init()
        setupNotificationObservers()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCustomContextAction(_:)),
            name: NSNotification.Name("HandleCustomContextAction"),
            object: nil
        )
    }
    
    @objc private func handleCustomContextAction(_ notification: Notification) {
        // Every tab's delegate hears this notification. Only the delegate of
        // the web view the menu was opened in may act on it — otherwise each
        // open tab downloaded the image, or showed its own save panel/toast.
        guard let sourceWebView = notification.userInfo?["webView"] as? WKWebView,
              sourceWebView.uiDelegate === self else { return }
        guard let userInfo = notification.userInfo,
              let action = userInfo["action"] as? ContextualMenuAction,
              let urlString = userInfo["url"] as? String,
              let url = URL(string: urlString) else {
            logError(.webView, "Invalid custom context action notification", isPrivate: isPrivate)
            return
        }
        
        logDebug(.webView, "🔍 Handling direct custom action: \(action) for URL: \(urlString)")
        
        switch action {
        case .copyLinkAddress, .copyImageAddress:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urlString, forType: .string)
            
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowToast"),
                object: nil,
                userInfo: [
                    "message": action == .copyLinkAddress ? "Copied link address" : "Copied image address",
                    "type": "info",
                    "icon": "doc.on.clipboard",
                    "tabId": tabId.uuidString
                ]
            )
            
        case .downloadLinkedFileAs:
            showSavePanel(for: url, type: .linkedFile, in: sourceWebView)
            
        case .saveImageToDownloads:
            startDownload(from: url, in: sourceWebView)
            
        case .saveImageAs:
            showSavePanel(for: url, type: .image, in: sourceWebView)
            
        case .openLinkInNewTab, .openImageInNewTab:
            // These should be handled by createWebViewWith, but include for completeness
            NotificationCenter.default.post(
                name: NSNotification.Name("CreateNewTab"),
                object: nil,
                userInfo: ["url": urlString, "isExternalURL": false, "parentTabId": tabId.uuidString, "activate": false]
            )
        }
    }
    
    // MARK: - JavaScript Dialog Handling
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Alert"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            
            if let window = webView.presentationWindow {
                alert.beginSheetModal(for: window) { _ in
                    completionHandler()
                }
            } else {
                alert.runModal()
                completionHandler()
            }
        }
    }
    
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Confirm"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            if let window = webView.presentationWindow {
                alert.beginSheetModal(for: window) { response in
                    completionHandler(response == .alertFirstButtonReturn)
                }
            } else {
                let response = alert.runModal()
                completionHandler(response == .alertFirstButtonReturn)
            }
        }
    }
    
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Input Required"
            alert.informativeText = prompt
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            textField.stringValue = defaultText ?? ""
            textField.placeholderString = "Enter text..."
            alert.accessoryView = textField
            
            if let window = webView.presentationWindow {
                // Make the text field first responder after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    textField.becomeFirstResponder()
                }
                
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        completionHandler(textField.stringValue.isEmpty ? nil : textField.stringValue)
                    } else {
                        completionHandler(nil)
                    }
                }
            } else {
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    completionHandler(textField.stringValue.isEmpty ? nil : textField.stringValue)
                } else {
                    completionHandler(nil)
                }
            }
        }
    }
    
    // MARK: - Media Permissions
    // The site's answer, asked for the page in the tab (SitePermissionsManager)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let permissions: [SitePermission]
        switch type {
        case .camera: permissions = [.camera]
        case .microphone: permissions = [.microphone]
        case .cameraAndMicrophone: permissions = [.camera, .microphone]
        @unknown default: permissions = [.camera, .microphone]
        }
        guard let host = webView.url?.host ?? (origin.host.isEmpty ? nil : origin.host) else {
            decisionHandler(.deny)
            return
        }
        SitePermissionsManager.shared.requestAccess(to: permissions, on: host, from: webView) { allowed in
            decisionHandler(allowed ? .grant : .deny)
        }
    }
    
    // MARK: - New Window/Tab Handling with OAuth Support
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        logDebug(.webView, "🔍 createWebViewWith called!")
        
        guard let url = navigationAction.request.url else {
            logError(.webView, "createWebViewWith called with no URL", isPrivate: isPrivate)
            return nil
        }
        
        let urlString = url.absoluteString
        logDebug(.webView, "🔍 createWebViewWith URL: \(urlString)")
        
        // FIRST: Check if this is a custom context menu action
        if let customWebView = webView as? CustomWKWebView,
           let customAction = customWebView.contextualMenuAction {
            
            logDebug(.webView, "🔍 Processing custom context menu action: \(customAction) for URL: \(urlString)")
            
            // Clear the contextual menu action immediately to prevent multiple processing
            customWebView.contextualMenuAction = nil
            
            switch customAction {
            case .openLinkInNewTab, .openImageInNewTab:
                logDebug(.webView, "🔍 Opening in new tab: \(urlString)")
                // In the background
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("CreateNewTab"),
                        object: nil,
                        userInfo: [
                            "url": urlString, 
                            "isExternalURL": false,
                            "parentTabId": self.tabId.uuidString,
                            "activate": false
                        ]
                    )
                }
                return nil
                
            case .copyLinkAddress, .copyImageAddress:
                logDebug(.webView, "🔍 Copying address: \(urlString)")
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    
                    // Show toast notification
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ShowToast"),
                        object: nil,
                        userInfo: [
                            "message": customAction == .copyLinkAddress ? "Copied link address" : "Copied image address",
                            "type": "info",
                            "icon": "doc.on.clipboard",
                            "tabId": self.tabId.uuidString
                        ]
                    )
                }
                return nil
                
            case .downloadLinkedFileAs:
                logDebug(.webView, "🔍 Download linked file as: \(urlString)")
                DispatchQueue.main.async {
                    self.showSavePanel(for: url, type: .linkedFile, in: webView)
                }
                return nil
                
            case .saveImageToDownloads:
                logDebug(.webView, "🔍 Save image to Downloads: \(urlString)")
                DispatchQueue.main.async {
                    self.startDownload(from: url, in: webView)
                }
                return nil
                
            case .saveImageAs:
                logDebug(.webView, "🔍 Save image as: \(urlString)")
                DispatchQueue.main.async {
                    self.showSavePanel(for: url, type: .image, in: webView)
                }
                return nil
                

            }
        }
        
        // Handle deep links and custom URL schemes first
        if DeepLinkHandler.shared.shouldHandleAsDeepLink(urlString) {
            DeepLinkHandler.shared.handleDeepLink(urlString, from: webView)
            return nil
        }
        
        // Enhanced debugging for error page navigation
        if let currentURL = webView.url?.absoluteString {
            logDebug(.webView, "🪟 createWebViewWith called: \(currentURL) → \(urlString)")
            logDebug(.webView, "🪟 Navigation type: \(navigationAction.navigationType.rawValue)")
            logDebug(.webView, "🪟 Source frame: \(navigationAction.sourceFrame.isMainFrame ? "main" : "iframe")")
            logDebug(.webView, "🪟 Target frame: \(navigationAction.targetFrame?.isMainFrame ?? false ? "main" : "iframe/nil")")
        }
        
        // FIRST: Block tracking/advertising URLs regardless of OAuth detection
        if isTrackingOrAdvertisingURL(urlString) {
            logWarning(.webView, "🚫 BLOCKED tracking/advertising popup: \(urlString)")
            // Don't post any notifications or create any tabs for tracking URLs
            return nil
        }
        
        // Check if this is a user-initiated navigation that should open in a new tab.
        // User-initiated actions (link clicks, target="_blank" clicks) always open as tabs.
        // Script-initiated requests (navigationType == .other) are further checked below
        // against WKWindowFeatures to decide tab vs popup.
        let isUserInitiated = navigationAction.navigationType == .linkActivated
        let isUserClickFromIframe = !navigationAction.sourceFrame.isMainFrame && navigationAction.targetFrame == nil && navigationAction.navigationType != .other
        let isUserClickTargetBlank = navigationAction.sourceFrame.isMainFrame && navigationAction.targetFrame == nil && navigationAction.navigationType != .other
        let shouldOpenInNewTab = isUserInitiated || isUserClickFromIframe || isUserClickTargetBlank

        if shouldOpenInNewTab {
            let reason = isUserInitiated ? "link click" : (isUserClickFromIframe ? "iframe target=_blank" : "main frame target=_blank")
            logDebug(.webView, "👆 User-initiated navigation (\(reason)) - opening in new tab instead of popup")
            
            // Note: Download tab detection now happens when download actually starts
            
            // Create a new tab instead of a popup window: behind this one
            // for a link ⌘-clicked or middle-clicked
            let activate = !(navigationAction.opensLinkInNewTab && navigationAction.opensInBackground)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CreateNewTab"),
                    object: nil,
                    userInfo: [
                        "url": urlString,
                        "isExternalURL": false,
                        "parentTabId": self.tabId.uuidString,
                        "activate": activate
                    ]
                )
            }
            return nil
        }
        
        // Script-initiated window.open(). Whichever route we take, we MUST return a
        // WKWebView built from the supplied (unmodified) configuration — that is what
        // makes WebKit set window.opener on the new context and hand the JS caller a
        // real Window object back from window.open(). Returning nil severs that bridge
        // and silently breaks OAuth popup → window.opener.postMessage callbacks
        // (e.g. deel.com "Continue with Google").
        let hasExplicitSize = windowFeatures.width != nil || windowFeatures.height != nil
        let hasPopupChrome = windowFeatures.toolbarsVisibility?.boolValue == false
            || windowFeatures.menuBarVisibility?.boolValue == false
        let isExplicitPopup = hasExplicitSize || hasPopupChrome

        if isExplicitPopup {
            logDebug(.webView, "Script-initiated window.open() with popup features (size: \(hasExplicitSize), chrome: \(hasPopupChrome)) - hosting in popup window: \(urlString)")
            return createPopupWebView(configuration: configuration, navigationAction: navigationAction, parentWebView: webView, windowFeatures: windowFeatures)
        }

        // No explicit popup chrome → host as a regular tab, but
        // pre-build the WKWebView here so the opener bridge survives. The WebView is
        // stashed under a predetermined tab UUID; the matching TabWebViewCoordinator
        // adopts it instead of creating a fresh one from the pool.
        logDebug(.webView, "Script-initiated window.open() without popup features - hosting in new tab with opener: \(urlString)")
        let popupWebView = CustomWKWebView(frame: .zero, configuration: configuration)
        WebViewConfiguration.shared.configureWebView(popupWebView)

        let newTabId = UUID()
        TabWebViewCoordinator.stashPreconfiguredWebView(popupWebView, for: newTabId)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("CreateNewTab"),
                object: nil,
                userInfo: [
                    // Seed BrowserTab.url with the destination so BrowserView's
                    // `isEmpty` filter doesn't hide the tab before WebKit's first
                    // KVO update lands. TabManager treats predeterminedId as a
                    // signal to skip the navigateToURL/load that would otherwise
                    // race the WebKit-driven load already in flight.
                    "url": urlString,
                    "isExternalURL": false,
                    "parentTabId": self.tabId.uuidString,
                    "predeterminedTabId": newTabId.uuidString
                ]
            )
        }

        return popupWebView
    }
    
    // MARK: - Tracking/Advertising URL Detection
    
    /// Check if a URL is a tracking or advertising URL that should be blocked from creating tabs
    private func isTrackingOrAdvertisingURL(_ url: String) -> Bool {
        let lowercaseURL = url.lowercased()
        
        // Extract domain from URL for more precise matching
        let domain = extractDomain(from: lowercaseURL)
        
        // List of known tracking/advertising domains
        let trackingDomains = [
            "sync.criteo.com",
            "ssp-sync.criteo.com", 
            "sync.smartadserver.com",
            "csync.smilewanted.com",
            "csync-global.smartadserver.com",
            "sync.teads.tv",
            "sync.1dmp.io",
            "sync.richaudience.com",
            "match.adsystem.com",
            "cm.everesttech.net",
            "pixel.facebook.com",
            "googletagmanager.com",
            "google-analytics.com",
            "googleadservices.com",
            "doubleclick.net",
            "googlesyndication.com",
            "amazon-adsystem.com",
            "i.liadm.com",
            "liadm.com"
        ]
        
        // Check if domain exactly matches known tracking domains
        for trackingDomain in trackingDomains {
            if domain == trackingDomain || domain.hasSuffix("." + trackingDomain) {
                return true
            }
        }
        
        // More specific pattern checks that are less likely to catch legitimate sites
        // Only block if it's specifically a sync endpoint with tracking indicators
        if domain.contains("sync") && domain.contains("ads") {
            return true
        }
        
        // Block specific tracking pixel endpoints (but not domains that just contain "pixel")
        if domain == "pixel.facebook.com" || lowercaseURL.contains("/pixel.") || lowercaseURL.contains("/beacon.") {
            return true
        }
        
        // Block sync-container specific patterns
        if lowercaseURL.contains("sync-container") {
            return true
        }
        
        return false
    }
    
    /// Extract domain from URL for more precise matching
    private func extractDomain(from url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return ""
        }
        return host.lowercased()
    }
    
    // MARK: - Popup Window Handling
    
    private func createPopupWebView(configuration: WKWebViewConfiguration, navigationAction: WKNavigationAction, parentWebView: WKWebView, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let parentWindow = parentWebView.presentationWindow else { 
            logError(.webView, "No parent window found for popup", isPrivate: isPrivate)
            return nil 
        }
        
        logInfo(.webView, "Creating popup window for URL: \(navigationAction.request.url?.absoluteString ?? "unknown")")
        
        // Use the provided configuration with our standard WebView settings
        let popupWebView = CustomWKWebView(frame: .zero, configuration: configuration)
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        
        // Apply standard WebView configuration (includes user agent, link preview, etc.)
        WebViewConfiguration.shared.configureWebView(popupWebView)
        
        logDebug(.webView, "Popup using standard User-Agent: \(WebViewConfiguration.safariUserAgent)")
        
        // Determine popup window size
        let width = windowFeatures.width?.doubleValue ?? 500
        let height = windowFeatures.height?.doubleValue ?? 600
        
        logDebug(.webView, "Popup window size: \(width) x \(height)")
        
        // Center the popup relative to the parent window
        let parentFrame = parentWindow.frame
        let x = parentFrame.midX - width / 2
        let y = parentFrame.midY - height / 2
        
        // Create popup window
        let popupWindow = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        popupWindow.title = navigationAction.request.url?.host ?? "Popup Window"
        popupWindow.contentView = popupWebView
        popupWindow.isReleasedWhenClosed = false
        
        // Prevent the popup from blocking the main UI
        popupWindow.level = .floating
        popupWindow.hidesOnDeactivate = false
        
        // Don't use addChildWindow as it can cause focus issues
        // Instead, show as an independent window
        popupWindow.makeKeyAndOrderFront(nil)
        
        // Keep reference to parent for positioning but don't make it a child
        objc_setAssociatedObject(popupWindow, "parentWindow", parentWindow, .OBJC_ASSOCIATION_ASSIGN)
        
        logInfo(.webView, "Popup window created and shown")
        
        // Store reference to manage lifecycle
        popupWebViews.append(popupWebView)
        popupWindows.append(popupWindow)
        
        // Set up close observation. The token is kept and removed on close,
        // and the block captures weakly: a discarded token kept the block —
        // and with it this window, its web view and the parent window —
        // alive for good after every popup.
        let observer = NotificationCenter.default.addMainObserver(
            forName: NSWindow.willCloseNotification,
            object: popupWindow
        ) { [weak self, weak popupWebView, weak popupWindow] _ in
            logDebug(.webView, "Popup window will close notification received")
            guard let self = self, let popupWebView = popupWebView, let popupWindow = popupWindow else { return }
            self.handlePopupWindowClose(popupWebView: popupWebView, popupWindow: popupWindow)
        }
        popupWindowObservers[ObjectIdentifier(popupWindow)] = observer
        
        return popupWebView
    }
    
    private func handlePopupWindowClose(popupWebView: WKWebView, popupWindow: NSWindow) {
        logDebug(.webView, "Cleaning up popup window")
        
        // Since we're not using child windows anymore, no need to remove from parent
        // Just clean up our tracking
        
        // Remove from our tracking array
        if let index = popupWebViews.firstIndex(of: popupWebView) {
            popupWebViews.remove(at: index)
            logDebug(.webView, "Removed popup WebView from tracking array")
        }
        if let observer = popupWindowObservers.removeValue(forKey: ObjectIdentifier(popupWindow)) {
            NotificationCenter.default.removeObserver(observer)
        }
        popupWindows.removeAll { $0 === popupWindow }
        
        // Clean up
        popupWebView.stopLoading()
        popupWebView.navigationDelegate = nil
        popupWebView.uiDelegate = nil
        popupWindow.contentView = nil
        
        // Return focus to the opener's window
        if let openerWindow {
            openerWindow.makeKeyAndOrderFront(nil)
            logDebug(.webView, "Returned focus to the opener's window")
        }
    }

    /// The browser window of the tab whose page opened the popup
    private var openerWindow: NSWindow? {
        BrowserWindowSession.owner(ofTab: tabId)?.window ?? NSApp.mainWindow
    }
    
    // Handle popup close requests from JavaScript
    func webViewDidClose(_ webView: WKWebView) {
        logDebug(.webView, "WebView did close called")
        // Popup-window path (sized window.open) — close the hosting NSWindow.
        if let window = webView.window,
           popupWebViews.contains(webView) {
            logDebug(.webView, "Closing popup window from JavaScript")
            window.close()

            // Ensure the opener's window gets focus back
            DispatchQueue.main.async {
                self.openerWindow?.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Tab-hosted path (createWebViewWith handoff) — the OAuth callback page
        // typically calls window.close() right after posting back to the opener.
        // self.tabId is the adopting tab's ID since the coordinator constructs a
        // fresh CustomWKUIDelegate with its own tabId on setup.
        logDebug(.webView, "Closing tab \(tabId.uuidString.prefix(8)) from JavaScript window.close()")
        let closingTabId = tabId
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("CloseTab"),
                object: nil,
                userInfo: ["tabId": closingTabId.uuidString]
            )
        }
    }
    
    // MARK: - File Upload Support
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
            openPanel.canChooseDirectories = parameters.allowsDirectories
            openPanel.canChooseFiles = true
            openPanel.resolvesAliases = true
            
            if let window = webView.presentationWindow {
                openPanel.beginSheetModal(for: window) { response in
                    if response == .OK {
                        completionHandler(openPanel.urls)
                    } else {
                        completionHandler(nil)
                    }
                }
            } else {
                let response = openPanel.runModal()
                if response == .OK {
                    completionHandler(openPanel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        }
    }
    

    

    
    // MARK: - Printing

    /// WebKit's completion handlers for the print panels on screen, by
    /// operation: the page waits on it until its panel closes.
    private var printCompletions: [ObjectIdentifier: @MainActor () -> Void] = [:]

    /// `window.print()`. WebKit asks its private UI delegate
    /// (`WKUIDelegatePrivate`) and drops the call without one. The print
    /// panel is a sheet on the page's window, for the frame
    /// that called it; the page goes on (`afterprint`, the script after
    /// `print()`) once the panel closes.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject, pdfFirstPageSize: CGSize, completionHandler: @escaping @MainActor () -> Void) {
        // A background tab's page is out of the window: no sheet over
        // another page
        guard webView.window != nil else {
            logDebug(.webView, "Ignoring print() from a page that isn't on screen")
            completionHandler()
            return
        }
        runPrintPanel(for: frame, in: webView, completion: completionHandler)
    }

    /// The print panel, a sheet on the page's window, for one of its frames
    /// (a `_WKFrameHandle`) or, without one, the whole page: `window.print()`
    /// and the context menu's Print items. `completion` runs once it closes.
    func runPrintPanel(for frame: AnyObject?, in webView: WKWebView, completion: @escaping @MainActor () -> Void = {}) {
        guard let window = webView.window else {
            completion()
            return
        }

        let printInfo = NSPrintInfo.shared
        let selector = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let operation: NSPrintOperation
        if let frame, webView.responds(to: selector),
           let frameOperation = webView.perform(selector, with: printInfo, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            operation = frameOperation
        } else {
            operation = webView.printOperation(with: printInfo)
        }
        // The name Save as PDF suggests
        if let title = webView.title, !title.isEmpty {
            operation.jobTitle = title
        }
        // WebKit's printing view starts out empty, which prints blank pages
        if let view = operation.view, view.frame.isEmpty {
            view.frame = webView.bounds
        }

        printCompletions[ObjectIdentifier(operation)] = completion
        operation.runModal(
            for: window,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printCompletions.removeValue(forKey: ObjectIdentifier(operation))?()
    }

    // MARK: - Context Menu

    /// WebKit shows its private UI delegate (`WKUIDelegatePrivate`) the
    /// context menu before it opens, with what was clicked. The page keeps
    /// that for its menu (`CustomWKWebView.contextMenuHit`), which adds
    /// the items for the page or frame as it opens (`willOpenMenu`).
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func webView(_ webView: WKWebView, getContextMenuFromProposedMenu menu: NSMenu, forElement element: AnyObject, userInfo: AnyObject?, completionHandler: @escaping @MainActor (NSMenu) -> Void) {
        (webView as? CustomWKWebView)?.contextMenuHit = ContextMenuHit(element: element)
        completionHandler(menu)
    }

    isolated deinit {
        // Clean up any remaining popup WebViews
        for observer in popupWindowObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        for popupWebView in popupWebViews {
            popupWebView.window?.close()
        }
        popupWebViews.removeAll()

        // WebKit expects its print completion handlers back
        for completion in printCompletions.values {
            completion()
        }

        // Note: No location manager cleanup needed - handled by per-tab JavaScript bridge
        
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Download Detection
    // Note: Download tab detection now happens in TabWebViewCoordinator when download actually starts
}

// MARK: - WKNavigationDelegate for Popup WebViews
extension CustomWKUIDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        let urlString = url.absoluteString
        
        // Handle deep links and custom URL schemes
        if DeepLinkHandler.shared.shouldHandleAsDeepLink(urlString) {
            DeepLinkHandler.shared.handleDeepLink(urlString, from: webView)
            decisionHandler(.cancel)
            return
        }
        
        // Let popup windows handle their own navigation - no special callback detection
        if popupWebViews.contains(webView) {
            logDebug(.webView, "Navigation in popup: \(urlString)")
        }

        // Sign-in popups (MSAL.js loginPopup) need the device's headers too.
        if MicrosoftEntraSSO.handle(navigationAction, in: webView, decisionHandler: decisionHandler) {
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A popup's location requests end with its page, as a tab's do
        GeolocationBridge.pageDidChange(in: webView)
    }

    /// A certificate error the user chose to visit anyway, as in its tab
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = SSLBypassManager.shared.credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - File Download and Image Management

enum DownloadType {
    case linkedFile
    case image
}

extension CustomWKUIDelegate {
    
    func showSavePanel(for url: URL, type: DownloadType, in webView: WKWebView) {
        let savePanel = NSSavePanel()
        
        // Set default filename based on URL
        var filename = url.lastPathComponent
        
        // Remove query parameters
        if let queryIndex = filename.firstIndex(of: "?") {
            filename = String(filename[..<queryIndex])
        }
        
        // Provide fallback names
        if filename.isEmpty {
            filename = type == .image ? "image.jpg" : "download"
        } else if type == .image && !filename.contains(".") {
            filename += ".jpg"
        }
        
        savePanel.nameFieldStringValue = filename
        
        // Set title based on type
        switch type {
        case .linkedFile:
            savePanel.title = "Download Linked File As..."
        case .image:
            savePanel.title = "Save Image As..."
            savePanel.allowedContentTypes = [.image, .png, .jpeg, .gif, .webP]
        }
        
        if let window = webView.presentationWindow {
            savePanel.beginSheetModal(for: window) { [weak webView] response in
                if response == .OK, let saveURL = savePanel.url, let webView {
                    self.startDownload(from: url, in: webView, to: saveURL)
                }
            }
        } else {
            let response = savePanel.runModal()
            if response == .OK, let saveURL = savePanel.url {
                startDownload(from: url, in: webView, to: saveURL)
            }
        }
    }
    
    /// Downloads it from the tab's own web view, as other downloads are:
    /// with the page's cookies and data store (a private tab's stays
    /// private), into the downloads list. `destination` is the file picked
    /// in a save panel; without one it goes to the download folder.
    private func startDownload(from url: URL, in webView: WKWebView, to destination: URL? = nil) {
        logDebug(.webView, "Downloading \(url.absoluteString)")
        webView.startDownload(using: URLRequest(url: url)) { download in
            DownloadManager.shared.setupWKDownload(download, fromTabId: nil, destination: destination)
        }
    }
}
