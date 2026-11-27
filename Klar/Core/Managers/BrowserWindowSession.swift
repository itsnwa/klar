import AppKit
import SwiftUI

/// A window's own values in UserDefaults: each name followed by the ID of
/// the window's session ("SavedTabs.<id>").
struct WindowDefaults {
    let sessionID: UUID

    /// What each window keeps of its own
    static let names = [
        "SavedTabs", "ActiveTabId", "TabMappings",
        "ActiveSpaceID", "LastActiveTabBySpace",
        "SidebarVisible", "SidebarWidth",
        "WindowFrame",
    ]

    func key(_ name: String) -> String {
        "\(name).\(sessionID.uuidString)"
    }

    /// Klar's values from before it had more than one window become this
    /// window's. Copied, not moved: a Klar from before still finds them.
    func adoptSingleWindowValues() {
        let defaults = UserDefaults.standard
        for name in Self.names {
            guard let value = defaults.object(forKey: name) else { continue }
            defaults.set(value, forKey: key(name))
        }
        // The frame AppKit kept for it, which SwiftUI no longer restores
        if let frame = defaults.string(forKey: "NSWindow Frame main-AppWindow-1") {
            defaults.set(frame, forKey: key("WindowFrame"))
        }
    }

    /// A new window starts with the sidebar as the window in front has it,
    /// in the same space.
    func copySidebarValues(from other: WindowDefaults) {
        let defaults = UserDefaults.standard
        for name in ["SidebarVisible", "SidebarWidth", "ActiveSpaceID"] {
            if let value = defaults.object(forKey: other.key(name)) {
                defaults.set(value, forKey: key(name))
            }
        }
    }

    func removeAll() {
        for name in Self.names {
            UserDefaults.standard.removeObject(forKey: key(name))
        }
    }
}

/// One browser window's models: its own tabs (`TabManager`), its sidebar's
/// selection and state, its active space, its find panel and its window's
/// chrome. What every window shows — saved tabs, folders, pinned sites and
/// spaces (`SidebarStore`), history, downloads — is app-wide.
///
/// Each window of the window group shows the session named by its value
/// (`WindowGroup(id: "main", for: UUID.self)`). The sessions of the windows
/// open at quit come back at launch (`restoreAll`), each opening a window
/// of its own. A session outlives its window while that's the last one:
/// closed, its tabs wait for the next window, as with a single window.
/// Closing any other window closes its tabs.
final class BrowserWindowSession {
    let id: UUID
    let defaults: WindowDefaults
    let tabManager: TabManager
    let sidebarManager: SidebarManager
    let sidebarStateManager: SidebarStateManager
    let spaceSelection: SpaceSelection
    let findManager: FindManager
    let nativeWindowButtons = NativeWindowButtons()
    let floatingSidebarManager = FloatingSidebarManager()
    let toolbarManager = ToolbarManager()

    /// The window showing it, while one does
    private(set) weak var window: NSWindow?
    /// Its sidebar and page, laid out in the window
    private(set) weak var layoutView: BrowserWindowLayoutView?
    /// Handed to a window that hasn't shown up yet
    private var isClaimed = false
    private var windowObservers: [NSObjectProtocol] = []

    private init(id: UUID) {
        self.id = id
        defaults = WindowDefaults(sessionID: id)
        tabManager = TabManager(defaults: defaults)
        sidebarManager = SidebarManager()
        sidebarStateManager = SidebarStateManager(defaults: defaults)
        findManager = FindManager(tabManager: tabManager)
        spaceSelection = SpaceSelection(defaults: defaults, sidebarManager: sidebarManager, tabManager: tabManager)

        tabManager.spaceSelection = spaceSelection
        sidebarStateManager.tabManager = tabManager
        tabManager.sidebarStateManager = sidebarStateManager
        tabManager.findManager = findManager
    }

    /// Adds a session to the windows' list, then connects its sidebar and
    /// tabs: what that does at once (restoring the tab mappings, the
    /// startup cleanup) sees this window among the others.
    private static func register(_ session: BrowserWindowSession) {
        all.append(session)
        // In this order: the sidebar's sync waits a turn, until the tab
        // mappings are restored.
        session.sidebarManager.setTabManager(session.tabManager)
        session.tabManager.setSidebarManager(session.sidebarManager)
        // A page of every open tab, before the window shows
        OpenTabStore.shared.windowDidJoin()
    }

    isolated deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Registry

    /// Every session: open windows', and one waiting for the next window.
    /// The window last in front first.
    private(set) static var all: [BrowserWindowSession] = []

    /// The sessions with a window open, the window last in front first
    static var open: [BrowserWindowSession] {
        all.filter { $0.window != nil }
    }

    /// The window in front's session — the key browser window, or the one
    /// last key — or else the one the next window shows. What menu
    /// commands, links from other apps and Settings act on.
    static var current: BrowserWindowSession {
        if let key = NSApp.keyWindow, let session = all.first(where: { $0.window === key }) {
            return session
        }
        if let session = all.first(where: { $0.window != nil }) ?? all.first {
            return session
        }
        return makeSession()
    }

    static func session(withID id: UUID) -> BrowserWindowSession? {
        all.first { $0.id == id }
    }

    /// The session of a browser window, of a sheet on one, or of a page of
    /// its in full screen (WebKit's own window, which the window in front
    /// put there).
    static func session(for window: NSWindow?) -> BrowserWindowSession? {
        guard let window else { return nil }
        if let session = all.first(where: { $0.window === window }) {
            return session
        }
        if let parent = window.sheetParent {
            return session(for: parent)
        }
        if MainActor.assumeIsolated({ BrowserWindow.isFullScreenPage(window) }) {
            return all.first { $0.window != nil }
        }
        return nil
    }

    /// The browser window in front at a point on screen, when that's what's
    /// there (not another app's window, nor nothing): for a drag from one
    /// window's sidebar into another's
    static func session(atScreenPoint point: CGPoint) -> BrowserWindowSession? {
        let number = MainActor.assumeIsolated {
            NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        }
        guard number > 0 else { return nil }
        return all.first { $0.window?.windowNumber == number }
    }

    /// The window whose tabs include this one
    static func owner(ofTab tabID: UUID) -> BrowserWindowSession? {
        all.first { session in session.tabManager.tabs.contains { $0.id == tabID } }
    }

    /// Every window's tabs
    static var allTabs: [BrowserTab] {
        all.flatMap(\.tabManager.tabs)
    }

    /// For a window opened with no session named (at launch, from the
    /// Dock): one restored or waiting for a window, else a new one's ID.
    /// Makes nothing: SwiftUI asks for this also when a window opens with
    /// a value of its own, and the session is made once a window shows it
    /// (`session(forWindowValue:)`). Opening a window for a session that
    /// already has one brings that window forward.
    static func idForNewWindow() -> UUID {
        all.last(where: { $0.window == nil && !$0.isClaimed })?.id ?? UUID()
    }

    /// For a new window (File › New Window, an extension's windows.create):
    /// a new session, or with every window closed, the last one's, whose
    /// tabs wait for the next window.
    static func sessionForNewWindow() -> BrowserWindowSession {
        if !all.contains(where: { $0.window != nil }),
           let waiting = all.first(where: { $0.window == nil && !$0.isClaimed }) {
            waiting.isClaimed = true
            return waiting
        }
        let session = makeSession()
        session.isClaimed = true
        return session
    }

    /// The session a window shows: the one it names, or a new one with
    /// that ID (a new window's, `idForNewWindow`). A window closing builds
    /// its content once more on its way out: it gets its closed session
    /// back, never a new one in the list.
    static func session(forWindowValue id: UUID) -> BrowserWindowSession {
        if let session = session(withID: id) {
            return session
        }
        if closedSessionIDs.contains(id) {
            return closedSessions.object(forKey: id as NSUUID) ?? BrowserWindowSession(id: id)
        }
        let session = makeSession(id: id)
        session.isClaimed = true
        return session
    }

    /// Sessions whose window closed with them, while their views last
    private static let closedSessions = NSMapTable<NSUUID, BrowserWindowSession>.strongToWeakObjects()
    private static var closedSessionIDs: Set<UUID> = []

    /// A new session, with no tabs, whose sidebar is as the window in
    /// front has it
    @discardableResult
    static func makeSession(id: UUID = UUID()) -> BrowserWindowSession {
        if let front = all.first(where: { $0.window != nil }) ?? all.first {
            WindowDefaults(sessionID: id).copySidebarValues(from: front.defaults)
        }
        let session = BrowserWindowSession(id: id)
        session.tabManager.opensWithNewTab = true
        register(session)
        saveSessionList()
        return session
    }

    // MARK: - Moving tabs

    /// Moves a tab to another window with its page as it is: its web view
    /// goes along, nothing reloads. A saved tab or pinned site open in
    /// another window comes to the one it's selected in this way.
    static func moveTab(_ tab: BrowserTab, to destination: TabManager, activate: Bool) {
        guard let source = owner(ofTab: tab.id)?.tabManager, source !== destination else {
            if activate, destination.tabs.contains(where: { $0 === tab }) {
                destination.activeTabId = tab.id
            }
            return
        }
        logDebug(.tabManagement, "Moving tab \(tab.id.uuidString.prefix(8)) to another window")
        TabWebViewCoordinator.prepareToChangeWindows(tabID: tab.id, to: destination)
        source.detach(tab)
        destination.adopt(tab, activate: activate)
    }

    // MARK: - Persistence

    private static let sessionListKey = "BrowserWindowSessions"

    /// The sessions of the windows open last time, before any window
    /// opens, so every window's tabs are known to the sidebars' first sync.
    /// Klar's single window from before becomes the first.
    static func restoreAll() {
        guard all.isEmpty else { return }
        let defaults = UserDefaults.standard
        if let ids = defaults.stringArray(forKey: sessionListKey) {
            for id in ids.compactMap(UUID.init(uuidString:)) where session(withID: id) == nil {
                register(BrowserWindowSession(id: id))
            }
        } else {
            let id = UUID()
            WindowDefaults(sessionID: id).adoptSingleWindowValues()
            register(BrowserWindowSession(id: id))
        }
        if all.isEmpty {
            register(BrowserWindowSession(id: UUID()))
        }
        saveSessionList()
        observeWindows()
        // Every window's tabs are restored: the open tabs in each
        OpenTabStore.shared.start()
    }

    /// The sessions to restore at launch, the window in front first
    static func saveSessionList() {
        UserDefaults.standard.set(all.map(\.id.uuidString), forKey: sessionListKey)
    }

    /// The windows restored with their sessions, once the first is up:
    /// opened back to front, so the one in front last time is again.
    static func openRestoredWindows() {
        for session in all.reversed() where session.window == nil && !session.isClaimed {
            session.isClaimed = true
            MainActor.assumeIsolated {
                BrowserWindow.openWindow?(id: "main", value: session.id)
            }
        }
    }

    /// The window in front comes first: in `current`, and in the list
    /// restored at launch.
    private static func observeWindows() {
        NotificationCenter.default.addMainObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  let session = all.first(where: { $0.window === window }) else { return }
            session.moveToFront()
        }
        NotificationCenter.default.addMainObserver(
            forName: NSWindow.willCloseNotification, object: nil
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  let session = all.first(where: { $0.window === window }) else { return }
            session.windowWillClose()
        }
    }

    // MARK: - Window

    /// The window showing this session, once it's in it. Before it's
    /// seen: the frame it had last time goes in right after this layout.
    func attach(to window: NSWindow, layoutView: BrowserWindowLayoutView) {
        self.layoutView = layoutView
        guard self.window !== window else { return }
        self.window = window
        isClaimed = false
        logDebug(.general, "Window \(window.identifier?.rawValue ?? "?") shows session \(id.uuidString.prefix(8)) (\(tabManager.tabs.count) tabs)")
        // First launch's setup takes it, at a size of its own until it
        // grows into the browser
        let isOnboarding = Onboarding.shared.takeWindow(of: self)
        if !isOnboarding, let frame = UserDefaults.standard.string(forKey: defaults.key("WindowFrame")) {
            // Called from SwiftUI's layout of the window, which a new frame
            // would lay out again inside it (a recursion AppKit warns
            // about): right after it, the window see-through until then so
            // it doesn't show at its default frame first.
            let alphaValue = window.alphaValue
            window.alphaValue = 0
            DispatchQueue.main.async { [weak window] in
                window?.setFrame(from: frame)
                window?.alphaValue = alphaValue
            }
        }
        observeFrame(of: window)
        // Key already, before it was this session's
        if window.isKeyWindow {
            moveToFront()
        } else {
            Self.saveSessionList()
        }
    }

    /// First in `all`: the window in front
    private func moveToFront() {
        guard let index = Self.all.firstIndex(where: { $0 === self }), index > 0 else { return }
        Self.all.insert(Self.all.remove(at: index), at: 0)
        Self.saveSessionList()
    }

    /// Sets up the window, once it's up: its look, the hidden toolbar that
    /// gives it its corners, its buttons, the floating sidebar and
    /// extensions. Once per window. The window, if it's this session's.
    @discardableResult
    func configureWindow() -> NSWindow? {
        guard let window else { return nil }
        guard configuredWindow !== window else { return window }
        configuredWindow = window

        MainActor.assumeIsolated {
            ExtensionManager.shared.attach(window: window, session: self)
        }

        window.isOpaque = true
        window.hasShadow = true

        // Alternative approach: Try to get 26pt corner radius without toolbar
        // First try direct window styling
        window.titlebarAppearsTransparent = true

        // Try to set corner radius directly on window's content view
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 13.0 // 26pt radius / 2 for each corner
            contentView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }

        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.isVisible = false
        toolbar.displayMode = .iconOnly
        toolbar.delegate = toolbarManager.toolbarDelegate

        window.toolbar = toolbar

        // Much more aggressive approach - try to completely remove toolbar from hit testing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
            guard let self, let window else { return }
            Self.completelyDisableToolbarHitTesting(window: window)

            // Ensure window buttons are positioned correctly after toolbar modifications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.nativeWindowButtons.configure(window: window)
            }
        }

        // Setup toolbar manager for fullscreen handling
        toolbarManager.setupFullscreenObservers(for: window, with: toolbar)

        // Configure native window buttons
        nativeWindowButtons.configure(window: window)

        // Setup floating sidebar tracking
        floatingSidebarManager.setupTracking(for: window, sidebarStateManager: sidebarStateManager)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        moveToFront()
        return window
    }

    /// The window `configureWindow` last set up
    private weak var configuredWindow: NSWindow?

    private static func disableHitTestingRecursively(_ view: NSView) {
        // Create a custom subclass that overrides hitTest at runtime
        let originalClass: AnyClass = object_getClass(view)!
        let className = "\(NSStringFromClass(originalClass))_HitTestDisabled"

        if let existingClass = NSClassFromString(className) {
            // Class already exists, just change the view's class
            object_setClass(view, existingClass)
        } else {
            // Create a new subclass that overrides hitTest
            if let newClass = objc_allocateClassPair(originalClass, className, 0) {

                // Add hitTest method that returns nil
                let hitTestImp: @convention(block) (AnyObject, NSPoint) -> NSView? = { _, _ in
                    return nil
                }

                let selector = #selector(NSView.hitTest(_:))
                let method = class_getInstanceMethod(originalClass, selector)!
                let typeEncoding = method_getTypeEncoding(method)

                class_addMethod(newClass, selector, imp_implementationWithBlock(hitTestImp), typeEncoding)
                objc_registerClassPair(newClass)

                // Change the view's class to our new subclass
                object_setClass(view, newClass)
            }
        }

        // Apply recursively to all subviews
        for subview in view.subviews {
            disableHitTestingRecursively(subview)
        }
    }

    private static func completelyDisableToolbarHitTesting(window: NSWindow) {
        guard let toolbar = window.toolbar else { return }

        // More surgical approach - only disable hit testing, don't modify layout
        if let toolbarView = toolbar.value(forKey: "toolbarView") as? NSView {

            // Only use runtime method swizzling - don't mess with view hierarchy or frames
            // This preserves the layout but makes hits pass through
            disableHitTestingRecursively(toolbarView)

            // Additionally, try to find just the interactive parts and disable those
            disableToolbarInteractiveElements(toolbarView)
        }
    }

    private static func disableToolbarInteractiveElements(_ view: NSView) {
        // Look for specific toolbar elements that might capture clicks
        // but preserve the overall toolbar structure for layout purposes
        for subview in view.subviews {
            let className = NSStringFromClass(type(of: subview))

            // Disable hit testing on specific toolbar control elements
            if className.contains("Button") || className.contains("Control") ||
               className.contains("Segment") || className.contains("Item") {
                disableHitTestingRecursively(subview)
            } else {
                // Continue searching in non-control subviews
                disableToolbarInteractiveElements(subview)
            }
        }
    }

    /// Keeps the window's frame for next launch
    private func observeFrame(of window: NSWindow) {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        let save: @MainActor (Notification) -> Void = { [weak self, weak window] _ in
            guard let self, let window, !window.styleMask.contains(.fullScreen) else { return }
            UserDefaults.standard.set(window.frameDescriptor, forKey: self.defaults.key("WindowFrame"))
        }
        windowObservers = [
            NotificationCenter.default.addMainObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, using: save),
            NotificationCenter.default.addMainObserver(forName: NSWindow.didMoveNotification, object: window, using: save),
        ]
    }

    /// The last window's session waits for the next window, tabs and all.
    /// Any other window's tabs close with it, its saved tabs are unloaded
    /// and its pinned sites go to the window in front
    /// (`TabManager.closeAllTabsForWindowClose`).
    private func windowWillClose() {
        window = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard !Self.isTerminating, Self.all.contains(where: { $0 !== self && $0.window != nil }) else {
            logDebug(.general, "Session \(id.uuidString.prefix(8)) waits for the next window")
            return
        }
        logDebug(.general, "Session \(id.uuidString.prefix(8)) closes with its window (\(tabManager.tabs.count) tabs)")
        close()
    }

    /// Quitting: windows going away don't close their sessions
    static var isTerminating = false

    private func close() {
        Self.closedSessionIDs.insert(id)
        Self.closedSessions.setObject(self, forKey: id as NSUUID)
        // While it's still among the windows, which its pinned sites move from
        tabManager.closeAllTabsForWindowClose()
        Self.all.removeAll { $0 === self }
        Self.saveSessionList()
        MainActor.assumeIsolated {
            ExtensionManager.shared.windowDidClose(self)
        }
        defaults.removeAll()
    }
}
