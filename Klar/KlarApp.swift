import SwiftUI
import AppKit
import ApplicationServices

// Custom AppDelegate to handle URL events
class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingLinks: [ExternalLink] = []
    private var isProcessingURL = false
    
    /// A browser window has been up long enough for links to open in it
    private var isWindowReady = false
    private var windowReadyObserver: NSObjectProtocol?
    private var hasRequestedWindowCreation = false
    /// What starts with the first window has
    private var hasStarted = false

    // NotificationCenter block-observer tokens (removed in deinit)
    private var notificationObservers: [NSObjectProtocol] = []

    isolated deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        if let token = windowReadyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent new window creation for external URLs when app is already running
        NSApp.setActivationPolicy(.regular)

        // Links wait for a window again once the last one closes
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willCloseNotification,
            object: nil
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.handleWindowWillClose(window)
        })

        // Register Apple Event handler for URL events at the lowest level.
        // This intercepts kAEGetURL events before NSApplication can route them
        // to application(_:open:), which would suppress SwiftUI's initial
        // WindowGroup window creation during cold launch.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Files opened with Klar (Finder, Open With, `open page.html`), for
        // the same reason: through application(_:open:) SwiftUI would take
        // them as a request for a window.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // A second instance can't start: LSMultipleInstancesProhibited is set
        // in Info.plist.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The windows going away now come back at next launch, tabs and all
        BrowserWindowSession.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release the prewarmed WebView pool so its WKWebView instances (and
        // their backing Web Content processes) can be torn down cleanly.
        WebViewPool.shared.clearPool()

        // Icons' last use, saved together rather than one by one.
        FaviconCacheManager.shared.saveNow()

        // Opened again, or updated, Klar picks up Apple Passwords without a
        // new code.
        ApplePasswordsManager.shared.handOver()
    }

    /// Disable focus ring on the window's content view. Not again on every
    /// activation, which walked the whole view tree: the SwiftUI trees have
    /// `.focusEffectDisabled()` (`browserEnvironment`), and Klar's AppKit
    /// fields turn their own focus rings off.
    func setupFocusRingHandling(for window: NSWindow) {
        if let contentView = window.contentView {
            contentView.focusRingType = .none
            Self.disableFocusRingRecursively(for: contentView)
        }
    }

    static func disableFocusRingRecursively(for view: NSView) {
        view.focusRingType = .none
        for subview in view.subviews {
            disableFocusRingRecursively(for: subview)
        }
    }

    @MainActor
    private func handleWindowWillClose(_ window: NSWindow) {
        guard BrowserWindow.isBrowserWindow(window),
              !BrowserWindowSession.open.contains(where: { $0.window !== window }) else { return }
        // The last browser window: a link opened from now on asks for a new one
        isWindowReady = false
        hasRequestedWindowCreation = false
        if let token = windowReadyObserver {
            NotificationCenter.default.removeObserver(token)
            windowReadyObserver = nil
        }
    }
    
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even if window is closed
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-check Reading List access after app gains focus.
        // Lets users see updates after granting Full Disk Access without restarting Klar.
        Task { @MainActor in
            await SafariReadingListManager.shared.refreshOnActivation()
        }
    }
    
    func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
        return false
    }

    /// A browser window is up (`BrowserWindowSession.configureWindow`):
    /// what Klar starts with its first window, and links waiting for one.
    @MainActor
    func browserWindowDidAppear(_ window: NSWindow) {
        hasRequestedWindowCreation = false
        startOnce()

        guard !isWindowReady, windowReadyObserver == nil else { return }
        // Window is ready when it becomes key and is fully displayed
        windowReadyObserver = NotificationCenter.default.addMainObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // Small delay to ensure everything is ready
                self?.markWindowReady()
            }
        }
        
        // Also handle case where window is already key
        if window.isKeyWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.markWindowReady()
            }
        }
    }

    /// Once, with the first window
    @MainActor
    private func startOnce() {
        guard !hasStarted else { return }
        hasStarted = true

        // The other windows open last time, now that the first is up
        BrowserWindowSession.openRestoredWindows()

        // Not in init: with sync on, starting it (CloudKit,
        // reading its state) would hold up the window.
        CloudSyncManager.shared.start()
        AppUpdater.shared.start()

        // Apple Passwords, if Klar was paired with it when
        // it last quit
        Task { @MainActor in
            await ApplePasswordsManager.shared.resumeHandedOverPairing()
        }

        // What changed, on the first launch after an update
        WhatsNew.shared.showLaunchNotes()

        // Initialize Safari Reading List integration (starts
        // watching Bookmarks.plist once it can be read)
        Task { @MainActor in
            await SafariReadingListManager.shared.refresh()
        }
    }
    
    private func markWindowReady() {
        guard !isWindowReady else { return }

        isWindowReady = true

        // The didBecomeKey observer fires every time the window is activated.
        // We only need it once — remove it now to avoid running this on every focus change.
        if let token = windowReadyObserver {
            NotificationCenter.default.removeObserver(token)
            windowReadyObserver = nil
        }

        // Process any pending URLs now that window is ready
        processPendingURLs()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A browser window open (or in the Dock): bring the one in front
        // forward. Only Settings or another window showing: AppKit wouldn't
        // make one, so open it here.
        let hasBrowserWindow = BrowserWindow.current != nil
        if hasBrowserWindow || flag {
            return !BrowserWindow.show()
        }
        // No windows: SwiftUI makes a new one, with the last one's tabs
        return true
    }
    
    // Handles URL events from external apps (default browser, link clicks, etc.)
    // via NSAppleEventManager. Registered in applicationWillFinishLaunching to
    // intercept kAEGetURL before NSApplication, allowing SwiftUI to create the
    // initial window during cold launch while still preventing duplicate windows
    // on warm launch.
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            return
        }
        openURLs([urlString], from: LinkRouter.sourceApp(of: event))
    }

    /// Opens each file in a tab of its own, as links are.
    @objc func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let files = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        // A list of files, or a single one.
        let items = files.numberOfItems > 0
            ? (1...files.numberOfItems).compactMap { files.atIndex($0) }
            : [files]
        let urlStrings = items.compactMap { item -> String? in
            guard let data = item.coerce(toDescriptorType: DescType(typeFileURL))?.data,
                  let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
            return url.absoluteString
        }
        openURLs(urlStrings, from: LinkRouter.sourceApp(of: event))
    }

    /// `sourceApp`: the bundle identifier of the app that sent them, read
    /// from the event as it arrives, for the link routes (`LinkRouter`).
    private func openURLs(_ urlStrings: [String], from sourceApp: String?) {
        guard !urlStrings.isEmpty else { return }
        let links = urlStrings.map { ExternalLink(address: $0, sourceApp: sourceApp) }

        let hasBrowserWindow = BrowserWindow.current != nil
        if isWindowReady, hasBrowserWindow {
            links.forEach { handleURL($0) }
        } else {
            pendingLinks.append(contentsOf: links)
            ensureWindowExists()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// During cold launch via URL, SwiftUI suppresses default WindowGroup window
    /// creation, and with every window closed nothing opens one for a link.
    /// Opens it with SwiftUI's action, or, before the menu commands have
    /// handed that over, by sending a kAEReopenApplication event to ourselves
    /// — the same mechanism as clicking the dock icon. Once per window: the
    /// flag is cleared when a window appears or the last one closes.
    private func ensureWindowExists() {
        guard !hasRequestedWindowCreation else { return }
        hasRequestedWindowCreation = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard self != nil, BrowserWindow.current == nil else { return }

            // A window SwiftUI made that isn't up yet, or a new one
            if BrowserWindow.show() { return }

            // No window — send ourselves a reopen event to trigger SwiftUI window creation
            let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let reopenEvent = NSAppleEventDescriptor.appleEvent(
                withEventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            let _ = try? reopenEvent.sendEvent(options: .noReply, timeout: -1)
        }
    }

    /// Where the link routes send it (`LinkRouter`): a new tab, the
    /// window's own empty tab, or a tab already at the page.
    func handleURL(_ link: ExternalLink, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard LinkRouter.shared.open(link) else {
                completion?()
                return
            }
            // Call completion after a short delay to allow navigation to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                completion?()
            }
        }
    }
    
    func processNextURL() {
        guard !isProcessingURL, !pendingLinks.isEmpty else { return }
        
        // Don't process URLs until a window is ready
        guard isWindowReady else {
            return
        }
        
        isProcessingURL = true
        let link = pendingLinks.removeFirst()
        
        handleURL(link) { [weak self] in
            DispatchQueue.main.async {
                self?.isProcessingURL = false
                // Process next URL if any
                self?.processNextURL()
            }
        }
    }
    
    func processPendingURLs() {
        // Only process URLs if window is ready
        guard isWindowReady else {
            return
        }

        // Process all pending URLs
        while !pendingLinks.isEmpty && !isProcessingURL {
            processNextURL()
        }
    }
    
}

// Custom toolbar delegate to prevent hit testing interference
class CustomToolbarDelegate: NSObject, NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        return nil // Return nil to ensure no items are added
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }
}

class ToolbarManager: ObservableObject {
    private var windowToolbar: NSToolbar?
    var toolbarDelegate = CustomToolbarDelegate()
    @Published var isFullscreen = false

    // NotificationCenter block-observer tokens (removed in deinit)
    private var notificationObservers: [NSObjectProtocol] = []

    isolated deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    func setupFullscreenObservers(for window: NSWindow, with toolbar: NSToolbar) {
        self.windowToolbar = toolbar

        // A window opened again after the last one closed: that one's
        // observers go, and none holds on to its window.
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()

        // Listen for fullscreen transitions to manage toolbar visibility
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window
        ) { [weak self, weak window] _ in
            guard let window else { return }
            self?.handleFullscreenTransition(entering: true, for: window)
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window
        ) { [weak self, weak window] _ in
            guard let window else { return }
            self?.handleFullscreenTransition(entering: false, for: window)
        })
    }
    
    private func handleFullscreenTransition(entering: Bool, for window: NSWindow) {
        isFullscreen = entering
        
        if entering {
            // Remove toolbar when entering fullscreen for cleaner experience
            window.toolbar = nil

            // Remove the content view corner radius so the web view fills the
            // screen edge-to-edge with square corners in fullscreen.
            window.contentView?.layer?.cornerRadius = 0
        } else {
            // Restore toolbar when exiting fullscreen to maintain 26pt corner radius
            window.toolbar = self.windowToolbar

            // Force window to recalculate its frame with toolbar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.titlebarAppearsTransparent = true
                // Trigger a layout update to ensure proper corner radius
                if let contentView = window.contentView {
                    // Restore the rounded top corners used in windowed mode.
                    contentView.layer?.cornerRadius = 13.0
                    contentView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                    contentView.needsLayout = true
                    contentView.layoutSubtreeIfNeeded()
                }
            }
        }
    }
}

/// File › New Window, New Tab and Close Window. Also hands SwiftUI's
/// openWindow to `BrowserWindow`, for the Dock icon, links with every
/// window closed, and the windows restored at launch.
struct BrowserWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = (BrowserWindow.openWindow = openWindow)
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                BrowserWindow.openNew()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab...") {
                BrowserWindow.perform { _ = $0.tabManager.createNewTab() }
            }
            .keyboardShortcut("t", modifiers: .command)

            // Any window in front: a browser window, Settings, a popup
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

/// Klar's executable is also the keeper that holds Apple's Passwords helper
/// for a while after Klar quits (ApplePasswordsHandover), which has to start
/// before any of the app does.
@main
enum KlarMain {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == ApplePasswordsHandover.keeperArgument {
            ApplePasswordsHandover.runKeeper()
        }
        KlarApp.main()
    }
}

struct KlarApp: App {
    // The app's models live in each window's session (`BrowserWindowSession`)
    // and app-wide singletons, not here: as `@StateObject`s the App would
    // observe every one of them, re-running `body` — the window group and
    // all the menu commands — on each change any of them publishes (every
    // page load, every Find keystroke, every sidebar edit). Views observe
    // what they read via `.environmentObject`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Before anything saves settings or data, which would make a new
        // install look like an update. A new install starts with the setup.
        Onboarding.recordLaunch()
        WhatsNew.shared.recordLaunch()

        // The trackers' list, looked up (or compiled, after an update) while
        // the windows open; a page that comes first waits for it
        TrackerBlocker.shared.start()

        // Private tabs lock when the Mac locks or sleeps, or Klar has been
        // in the background a while
        PrivateTabLock.shared.start()

        // The windows open at quit, each with its tabs, before any window
        // or web view needs them. They open once the first window is up.
        BrowserWindowSession.restoreAll()

        // One for every window: it finds the window a key was typed in
        _ = KeyboardHandler.shared

        // Share menus' Add to Reading List leaves Safari in the background
        SharingService.offerKlarReadingList()

        // The installed extensions; they start once a window is up, and
        // tabs get web views after that, so pages get their content scripts.
        ExtensionManager.shared.start()

        // iCloud sync, while Settings › iCloud is on. Starts with the window.
        let cloudSync = CloudSyncManager.shared
        cloudSync.register(SidebarStore.shared, as: .sidebar)
        cloudSync.register(TOMLSettingsManager.shared, as: .settings)
        cloudSync.register(ExtensionManager.shared, as: .extensions)
        cloudSync.register(SitePermissionsManager.shared, as: .sitePermissions)
        cloudSync.register(OpenTabStore.shared, as: .openTabs)
        cloudSync.register(ExploreLibrary.shared, as: .explore)

        // Configure app defaults
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
    }

    var body: some Scene {
        // Each window shows a session of its own, named by its value
        WindowGroup(id: "main", for: UUID.self) { $sessionID in
            let session = BrowserWindowSession.session(forWindowValue: sessionID)
            ContentView(session: session)
                .browserEnvironment(session)
                .background(.clear)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    // Once the window is up
                    DispatchQueue.main.async {
                        guard let window = session.configureWindow() else { return }
                        appDelegate.setupFocusRingHandling(for: window)
                        appDelegate.browserWindowDidAppear(window)
                    }
                }
        } defaultValue: {
            // At launch, from the Dock, for a link: a window restored or
            // waiting for one, else a new one
            BrowserWindowSession.idForNewWindow()
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        // A new window's size, before there's a saved one (SwiftUI's own
        // default is 900×450).
        .defaultSize(width: 1400, height: 840)
        // Klar brings back its windows itself, each with its own tabs
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: Set(["main"]))
        .commands {
            AboutCommands()
            UpdateCommands()

            BrowserWindowCommands()
          
            CommandGroup(replacing: .saveItem) {
              // Hiding the close
              Button("Open Command Palette") {
                BrowserWindow.perform { $0.tabManager.openCommandPaletteForNavigation() }
              }
              .keyboardShortcut("l", modifiers: .command)
            }
            
            // Add Edit menu with Find commands. In another window
            // (Settings' search field, a popup's page) they're that window's.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find...") {
                    if let session = BrowserWindow.keySession {
                        session.findManager.handleFindShortcut()
                    } else {
                        BrowserWindow.findInKeyWindow(.showFindInterface)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                
                Button("Find Next") {
                    if let session = BrowserWindow.keySession {
                        session.findManager.findNext()
                    } else {
                        BrowserWindow.findInKeyWindow(.nextMatch)
                    }
                }
                .keyboardShortcut("g", modifiers: .command)
                
                Button("Find Previous") {
                    if let session = BrowserWindow.keySession {
                        session.findManager.findPrevious()
                    } else {
                        BrowserWindow.findInKeyWindow(.previousMatch)
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                
                Button("Use Selection for Find") {
                    if let session = BrowserWindow.keySession {
                        session.findManager.useSelectionForFind()
                    } else {
                        BrowserWindow.findInKeyWindow(.setSearchString)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                
                Button("Jump to Selection") {
                    if let session = BrowserWindow.keySession {
                        session.findManager.jumpToSelection()
                    } else {
                        BrowserWindow.sendToKeyWindow(#selector(NSResponder.centerSelectionInVisibleArea(_:)))
                    }
                }
                .keyboardShortcut("j", modifiers: .command)
            }
          
            CommandMenu(.init("Tabs")) {

              Button("New Tab...") {
                BrowserWindow.perform { $0.tabManager.openCommandPaletteForNewTab() }
              }
              .keyboardShortcut("t", modifiers: .command)

              Button("New Private Tab...") {
                BrowserWindow.perform { $0.tabManager.openCommandPaletteForNewTab(isPrivate: true) }
              }
              .keyboardShortcut("t", modifiers: [.command, .shift])

              // Every window's, until Touch ID or the password unlocks them
              Button("Lock Private Tabs") {
                PrivateTabLock.shared.lock()
              }

              Button("Tab Actions...") {
                BrowserWindow.perform { $0.tabManager.openCommandPaletteForTabActions() }
              }
              .keyboardShortcut("k", modifiers: .command)

              // In another window (Settings, a popup, an extension's window,
              // the Web Inspector), ⌘W closes that window
              Button("Close Tab") {
                  if let tabManager = BrowserWindow.keySession?.tabManager {
                      if let activeTab = tabManager.activeTab {
                          tabManager.closeTabUndoably(activeTab)
                      }
                  } else {
                      NSApp.keyWindow?.performClose(nil)
                  }
              }
              .keyboardShortcut("w", modifiers: .command)

              Divider()

              // A new pane beside the tab, side by side or below it, with
              // the command palette open to pick what goes in it
              Button("Split Horizontally") {
                BrowserWindow.perform { $0.tabManager.splitActiveTab(.horizontal) }
              }
              .keyboardShortcut("d", modifiers: .command)

              Button("Split Vertically") {
                BrowserWindow.perform { $0.tabManager.splitActiveTab(.vertical) }
              }
              .keyboardShortcut("d", modifiers: [.command, .shift])

              Button("Close Split View") {
                BrowserWindow.perform { $0.tabManager.closeSplitView() }
              }

              // The active tab's split view: the pane beside it that way
              Button("Select Left Pane") {
                BrowserWindow.perform { $0.tabManager.focusPane(toward: .left) }
              }
              .keyboardShortcut(.leftArrow, modifiers: [.control, .command])

              Button("Select Right Pane") {
                BrowserWindow.perform { $0.tabManager.focusPane(toward: .right) }
              }
              .keyboardShortcut(.rightArrow, modifiers: [.control, .command])

              Button("Select Pane Above") {
                BrowserWindow.perform { $0.tabManager.focusPane(toward: .top) }
              }
              .keyboardShortcut(.upArrow, modifiers: [.control, .command])

              Button("Select Pane Below") {
                BrowserWindow.perform { $0.tabManager.focusPane(toward: .bottom) }
              }
              .keyboardShortcut(.downArrow, modifiers: [.control, .command])
              
              Divider()
              
              Button("Next Tab") {
                BrowserWindow.perform { $0.tabManager.navigateToNextTab() }
              }
              .keyboardShortcut(.downArrow, modifiers: [.command, .option])
              
              Button("Previous Tab") {
                BrowserWindow.perform { $0.tabManager.navigateToPreviousTab() }
              }
              .keyboardShortcut(.upArrow, modifiers: [.command, .option])
              
              Button("Reveal Tab in Sidebar") {
                BrowserWindow.perform { session in
                  guard let activeTabId = session.tabManager.activeTabId else { return }
                  let sidebarStateManager = session.sidebarStateManager
                  // The active space is the active tab's
                  sidebarStateManager.show(.space)
                  if !sidebarStateManager.isVisible {
                      sidebarStateManager.show()
                  }
                  session.sidebarManager.revealTab(withBrowserTabID: activeTabId)
                }
              }
              
            }

            CommandMenu(.init("Spaces")) {
              Button("Overview") {
                BrowserWindow.perform { $0.sidebarStateManager.toggleOverview() }
              }
              .keyboardShortcut("o", modifiers: [.command, .shift])

              Button("Next Space") {
                BrowserWindow.perform { session in
                  session.spaceSelection.switchToAdjacentSpace(by: 1)
                  session.sidebarStateManager.show(.space)
                }
              }
              .keyboardShortcut("]", modifiers: [.control, .command])

              Button("Previous Space") {
                BrowserWindow.perform { session in
                  session.spaceSelection.switchToAdjacentSpace(by: -1)
                  session.sidebarStateManager.show(.space)
                }
              }
              .keyboardShortcut("[", modifiers: [.control, .command])

              Divider()

              ForEach(1...9, id: \.self) { number in
                Button("Space \(number)") {
                  BrowserWindow.perform { session in
                    session.spaceSelection.switchToSpace(at: number - 1)
                    session.sidebarStateManager.show(.space)
                  }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .control)
              }

              Divider()

              Button("New Space") {
                BrowserWindow.perform { session in
                  SpaceManager.shared.createSpace()
                  session.sidebarStateManager.show(.space)
                }
              }

              Button("Space Settings…") {
                SettingsWindowController.shared.showSettings(category: .spaces, spaceID: BrowserWindowSession.current.spaceSelection.currentSpaceID)
              }

              Divider()

              Button("History") {
                BrowserWindow.perform { $0.sidebarStateManager.show(.list(.history)) }
              }
              .keyboardShortcut("y", modifiers: .command)

              Button("Downloads") {
                BrowserWindow.perform { $0.sidebarStateManager.show(.list(.downloads)) }
              }
              .keyboardShortcut("l", modifiers: [.command, .option])

              Button("Reading List") {
                BrowserWindow.perform { $0.sidebarStateManager.show(.list(.readingList)) }
              }
              .keyboardShortcut("2", modifiers: [.control, .command])

            }
          
            // The browser's pages only, not one behind Settings or a popup
            CommandGroup(after: .sidebar) {
              Button("Zoom In") {
                BrowserWindow.keySession?.tabManager.zoomIn()
              }
              .keyboardShortcut("+", modifiers: .command)
              
              Button("Zoom Out") {
                BrowserWindow.keySession?.tabManager.zoomOut()
              }
              .keyboardShortcut("-", modifiers: .command)
              
              Button("Reset Zoom") {
                BrowserWindow.keySession?.tabManager.resetZoom()
              }
              .keyboardShortcut("0", modifiers: .command)
            }
          
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    SettingsWindowController.shared.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(replacing: .help) {
              // Empty - removes the default help item
            }
            
            CommandGroup(after: .help) {
                Button("Follow on Bluesky") {
                  BrowserWindow.perform { _ = $0.tabManager.createNewTab(url: "https://bsky.app/profile/nichl.as") }
                }
                Button("Set as Default Browser") {
                    DefaultBrowser.makeDefault()
                }
            }
        }
    }
}
