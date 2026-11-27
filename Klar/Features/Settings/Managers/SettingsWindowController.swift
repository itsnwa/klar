import SwiftUI
import AppKit

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    /// The window's width, sidebar included (`SettingsWindow.sidebarWidth`).
    static let width: CGFloat = 750

    private var mouseDownMonitor: Any?
    
    private override init(window: NSWindow?) {
        super.init(window: window)
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupWindow()
    }
    
    private init() {
        super.init(window: nil)
        setupWindow()
    }
    
    private func setupWindow() {
        let settingsView = SettingsWindow()
        let hostingController = NSHostingController(rootView: settingsView)
        // The window keeps its own size instead of fitting the page.
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Klar Settings"
        window.toolbarStyle = .unified
        window.contentViewController = hostingController
        // Setting the content view controller sizes the window to it.
        window.setContentSize(NSSize(width: Self.width, height: 560))
        // A fixed width, only the height resizes. Before the saved frame is
        // restored, so it can't come back another width.
        window.contentMinSize = NSSize(width: Self.width, height: 400)
        window.contentMaxSize = NSSize(width: Self.width, height: 1200)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        // A frame saved while the width could change
        if window.frame.width != Self.width {
            var frame = window.frame
            frame.size.width = Self.width
            window.setFrame(frame, display: false)
        }

        self.window = window

        // A click anywhere but in a text field ends editing in one, as in
        // System Settings: SwiftUI fields otherwise keep focus.
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.endEditingIfClickedOutsideTextField(event)
            return event
        }

        logDebug(.settings, "Settings window setup completed")
    }

    private func endEditingIfClickedOutsideTextField(_ event: NSEvent) {
        guard let window, event.window === window,
              window.firstResponder is NSText,
              let contentView = window.contentView else { return }
        // The content view's superview is the window's frame view, whose
        // coordinates are the window's.
        var view = contentView.hitTest(event.locationInWindow)
        while let current = view {
            if current is NSTextField || current is NSText { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }
    
    /// The sidebar's split view item takes `SettingsWindow.sidebarWidth`
    /// and nothing else: SwiftUI's fixed column width still lets the
    /// divider be dragged. Once the window's laid out, when the split view
    /// is there.
    private func lockSidebarWidth() {
        DispatchQueue.main.async { [weak self] in
            guard let contentView = self?.window?.contentView,
                  let splitView = Self.firstSplitView(in: contentView),
                  let controller = splitView.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else {
                logDebug(.settings, "No split view controller to fix the sidebar's width")
                return
            }
            sidebar.canCollapse = false
            sidebar.minimumThickness = SettingsWindow.sidebarWidth
            sidebar.maximumThickness = SettingsWindow.sidebarWidth
        }
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView { return splitView }
        for subview in view.subviews {
            if let splitView = firstSplitView(in: subview) { return splitView }
        }
        return nil
    }

    /// `spaceID` picks the space Settings › Spaces shows (the deep link of a
    /// space's Space Settings…).
    func showSettings(category: SettingsCategory? = nil, spaceID: UUID? = nil) {
        if let spaceID {
            SpaceSettingsSelection.shared.spaceID = spaceID
        }
        if let window = self.window {
            let wasVisible = window.isVisible
            window.makeKeyAndOrderFront(nil)
            if !wasVisible {
                // AppKit focuses the first key view (the first control in General) when the
                // window becomes key without a first responder; keep focus on the window instead.
                window.makeFirstResponder(nil)
                lockSidebarWidth()
            }
            NSApp.activate(ignoringOtherApps: true)
            if let category {
                // SettingsWindow observes this and updates its selection.
                NotificationCenter.default.post(name: .openSettingsCategory, object: category)
            }
        } else {
            logError(.settings, "Settings window is nil when trying to show")
        }
    }
    
}
