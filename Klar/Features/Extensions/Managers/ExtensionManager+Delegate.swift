import AppKit
import WebKit

/// What WebKit asks of Klar on extensions' behalf: windows and tabs to
/// open, permissions to approve, popups to show and native apps to reach.
extension ExtensionManager: WKWebExtensionControllerDelegate {
    enum DelegateError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }

    // MARK: Windows and tabs

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        bridge.windowsInFocusOrder
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        NSApp.isActive ? bridge.focusedWindow : nil
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let parent = configuration.parentTab as? ExtensionTab
        guard let tab = bridge.openTab(url: configuration.url, active: configuration.shouldBeActive, parent: parent) else {
            return completionHandler(nil, DelegateError.unavailable("Klar couldn't open the tab."))
        }
        if configuration.shouldBeMuted {
            tab.setMuted(true, for: extensionContext) { _ in }
        }
        if configuration.shouldBeActive {
            bridge.browserWindow(of: tab)?.makeKeyAndOrderFront(nil)
        }
        completionHandler(tab, nil)
    }

    /// A popup window (an extension's own small window) gets a window of
    /// its own, anything else a new browser window with its tabs.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        if configuration.windowType == .popup {
            let popup = bridge.openPopupWindow(
                url: configuration.tabURLs.first,
                frame: configuration.frame,
                focused: configuration.shouldBeFocused,
                context: extensionContext
            )
            return completionHandler(popup, nil)
        }

        let window = bridge.openBrowserWindow(urls: configuration.tabURLs, focused: configuration.shouldBeFocused)
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let url = extensionContext.optionsPageURL else {
            return completionHandler(DelegateError.unavailable("The extension has no options page."))
        }
        showExtensionPage(url)
        completionHandler(nil)
    }

    // MARK: Permissions

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        Task {
            let allowed = await ExtensionPermissionPrompt.confirmRequest(
                from: extensionContext,
                permissions: Set(permissions.map(\.rawValue)),
                matchPatterns: []
            )
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let patterns = Set(urls.compactMap { url -> WKWebExtension.MatchPattern? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return try? WKWebExtension.MatchPattern(scheme: scheme, host: host, path: "/*")
        })
        Task {
            let allowed = await ExtensionPermissionPrompt.confirmRequest(
                from: extensionContext,
                permissions: [],
                matchPatterns: patterns
            )
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        Task {
            let allowed = await ExtensionPermissionPrompt.confirmRequest(
                from: extensionContext,
                permissions: [],
                matchPatterns: matchPatterns
            )
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    // MARK: Actions

    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionDidChange()
    }

    /// Hangs the action's popup from its URL bar button — or the puzzle
    /// button when it isn't pinned — sliding the sidebar in first if it's
    /// hidden, the way the passwords prompt does.
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            return completionHandler(DelegateError.unavailable("The extension has no popup."))
        }
        if let webView = action.popupWebView {
            ExtensionPopupCloser.shared.attach(to: webView, of: action)
        }
        let id = context.uniqueIdentifier
        // In the window in front, whose toolbar the action is in
        let sidebar = AutofillAnchorRegistry.shared.sidebarStateManager()
        let needsReveal = sidebar.map { !$0.isVisible && !$0.isFloating } ?? false
        if needsReveal { sidebar?.showFloating() }

        // Keep a floating sidebar from sliding away under the popup, until
        // it closes (or isn't shown after all: the task is cancelled).
        if let sidebar {
            FloatingSidebarBlocker.shared.beginBlocking(sidebar)
        }
        let blockUntilClosed = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: NSPopover.didCloseNotification, object: popover) {
                break
            }
            if let sidebar {
                FloatingSidebarBlocker.shared.endBlocking(sidebar)
            }
        }

        // SidebarStateManager.showFloating animates for ~0.2s; show the
        // popup once the URL bar has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsReveal ? 0.3 : 0)) { [weak self] in
            guard let self else { return }
            let anchor = [self.actionAnchor(for: id), self.puzzleAnchor, AutofillAnchorRegistry.shared.urlBarView()]
                .compactMap { $0 }
                .first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            if let anchor {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            } else if let webView = self.bridge.activeTab?.webView {
                let rect = NSRect(x: webView.bounds.maxX - 40, y: webView.bounds.maxY - 8, width: 1, height: 1)
                popover.show(relativeTo: rect, of: webView, preferredEdge: .minY)
            } else {
                blockUntilClosed.cancel()
                return completionHandler(DelegateError.unavailable("Klar's window isn't open."))
            }
            completionHandler(nil)
        }
    }

    // MARK: Native messaging

    func webExtensionController(_ controller: WKWebExtensionController,
                                sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let applicationIdentifier else {
            return replyHandler(nil, ExtensionNativeMessaging.Error.invalidHostName)
        }
        nativeMessaging.sendMessage(
            message,
            toHost: applicationIdentifier,
            extensionID: extensionContext.uniqueIdentifier,
            replyHandler: replyHandler
        )
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        nativeMessaging.connect(port, extensionID: extensionContext.uniqueIdentifier, completionHandler: completionHandler)
    }
}

/// Closes an extension's popup when its page calls window.close(), which
/// klar-compat.js passes on: WebKit only lets a script close a window it
/// opened, or one with no history yet, and a popup that routes within itself
/// has some, so Chrome extensions' popups stayed open.
final class ExtensionPopupCloser: NSObject, WKScriptMessageHandler {
    static let shared = ExtensionPopupCloser()

    /// Each popup web view's action, until either goes.
    private let actions = NSMapTable<WKWebView, WKWebExtension.Action>.weakToWeakObjects()

    func attach(to webView: WKWebView, of action: WKWebExtension.Action) {
        actions.setObject(action, forKey: webView)
        let name = ExtensionCompatibility.closePopupHandler
        let userContentController = webView.configuration.userContentController
        // Adding a name twice raises.
        userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
        userContentController.add(self, contentWorld: .page, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let action = actions.object(forKey: webView) else { return }
        action.closePopup()
    }
}
