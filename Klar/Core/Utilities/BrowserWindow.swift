import AppKit
import SwiftUI

/// Klar's browser windows, the ones with the tabs, as opposed to Settings,
/// popups, extension windows, the Web Inspector, sheets, alerts and panels.
/// Klar's shortcuts for pages and tabs are for them alone: in any other
/// window, the keys are that window's. Each shows a session of its own
/// (`BrowserWindowSession`).
@MainActor
enum BrowserWindow {
    /// The browser window in front, or the one last in front, if one is
    /// open. Not one that was closed, which AppKit can list for a while after.
    static var current: NSWindow? {
        BrowserWindowSession.open.first?.window
    }

    /// SwiftUI's action that opens a window of the group, from the menu
    /// commands (`BrowserWindowCommands`), which have it from launch on,
    /// with or without a window.
    static var openWindow: OpenWindowAction?

    /// Brings the browser window in front forward, or opens one when none
    /// is open: the last one's tabs, waiting for it. Whether there is a way
    /// to open one.
    @discardableResult
    static func show() -> Bool {
        if let window = current {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: "main", value: BrowserWindowSession.idForNewWindow())
        } else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// A new browser window, with no tabs (File › New Window), or showing
    /// `url` in a tab (a page's Open Frame in New Window). With every
    /// window closed, the last one again, with its tabs.
    static func openNew(showing url: URL? = nil, isPrivate: Bool = false) {
        guard let openWindow else { return }
        let session = BrowserWindowSession.sessionForNewWindow()
        if let url {
            _ = session.tabManager.createNewTab(url: url.absoluteString, isPrivate: isPrivate)
        }
        openWindow(id: "main", value: session.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the window is the browser window. SwiftUI names a window
    /// group's windows after its id ("main-AppWindow-1").
    static func isBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.identifier?.rawValue.hasPrefix("main") == true && window.contentView != nil
    }

    /// Whether a key typed in the window is for Klar's shortcuts: it's the
    /// browser window, with no sheet over it, and not showing first launch's
    /// setup (Onboarding).
    static func receivesShortcuts(_ window: NSWindow?) -> Bool {
        isBrowserWindow(window) && window?.attachedSheet == nil && !Onboarding.shared.isShowing(in: window)
    }

    /// WebKit's own window for a page in full screen (a video, or the page
    /// itself), which belongs to the browser window's tab.
    static func isFullScreenPage(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return NSStringFromClass(type(of: window)).contains("FullScreenWindow")
    }

    /// Whether the browser's menu commands are for the window in front: it's
    /// a browser window without a sheet, or one of its pages in full screen.
    static var isKey: Bool {
        let keyWindow = NSApp.keyWindow
        return receivesShortcuts(keyWindow) || isFullScreenPage(keyWindow)
    }

    /// The session of the key browser window (or its page in full screen),
    /// for the menu's commands that are only for it (Find, zoom)
    static var keySession: BrowserWindowSession? {
        isKey ? BrowserWindowSession.current : nil
    }

    /// Runs a command for the browser window in front (a tab, a space, the
    /// command palette), bringing it forward first from any other, so the
    /// palette it opens has focus. Not while a sheet is over it, or the
    /// setup shows in it. With no browser window open, opens one for it:
    /// the last one's tabs.
    static func perform(_ command: (BrowserWindowSession) -> Void) {
        if !isKey {
            if let window = current {
                guard window.attachedSheet == nil, !Onboarding.shared.isShowing(in: window) else { return }
                window.makeKeyAndOrderFront(nil)
            } else {
                show()
            }
        }
        command(BrowserWindowSession.current)
    }

    /// Sends a Find menu command to the key window when it isn't the
    /// browser's, as the standard Find menu would: Settings' search field
    /// takes Find, a popup's page finds in itself. Klar's own Find menu
    /// replaces the standard one, so nothing else sends these.
    static func findInKeyWindow(_ action: NSTextFinder.Action) {
        // Anything that answers to tag, which these actions read the
        // command from
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        if !sendToKeyWindow(#selector(NSResponder.performTextFinderAction(_:)), from: sender) {
            // Views that only know the older find panel's actions, whose
            // tags are the same numbers
            sendToKeyWindow(#selector(NSTextView.performFindPanelAction(_:)), from: sender)
        }
    }

    /// Sends an action up the key window's own responder chain. Sent to the
    /// application instead, an action nothing in it takes would go on to
    /// the main window: the browser's page behind it.
    @discardableResult
    static func sendToKeyWindow(_ action: Selector, from sender: Any? = nil) -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return (keyWindow.firstResponder ?? keyWindow).tryToPerform(action, with: sender)
    }
}
