import AppKit
import SwiftUI
import WebKit

/// Tail-less floating panel that hosts the autofill suggestions popover.
/// We use NSPanel rather than NSPopover here because NSPopover always paints
/// a tail/arrow pointing at its anchor and exposes no public API to suppress
/// it; a borderless NSPanel positioned manually below the input field
/// gives us the same visual style without the arrow.
@MainActor
final class AutofillSuggestionPanel {
    private let panel: NSPanel
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var dismissHandler: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 212, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        self.panel = panel
    }

    /// The screen rect of `rect`, given in CSS pixels of the web view's
    /// viewport. CSS y runs down from the viewport's top, screen y up from
    /// the bottom of the primary screen; a CSS pixel is `pageZoom` points.
    static func screenRect(forViewportRect rect: CGRect, in webView: WKWebView) -> NSRect? {
        guard let window = webView.window else { return nil }
        let webViewScreenRect = window.convertToScreen(webView.convert(webView.bounds, to: nil))
        let zoom = webView.pageZoom
        return NSRect(
            x: webViewScreenRect.minX + rect.minX * zoom,
            y: webViewScreenRect.maxY - rect.maxY * zoom,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    /// Presents `view` as a tail-less popover just below `anchor`, the input
    /// field's rect on screen.
    func present<Content: View>(
        view: Content,
        below anchor: NSRect,
        in window: NSWindow,
        onDismiss: @escaping () -> Void
    ) {
        dismissHandler = onDismiss

        let wrapped = ZStack {
            VisualEffectView(material: .menu, blendingMode: .behindWindow, state: .active)
            view
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        let controller = NSHostingController(rootView: wrapped)
        panel.contentViewController = controller

        // SwiftUI publishes the intrinsic size after the view lays out.
        let contentSize = controller.view.fittingSize
        panel.setContentSize(contentSize)

        let panelOrigin = NSPoint(
            x: anchor.minX,
            y: anchor.minY - contentSize.height - 4 // 4pt gap below input
        )
        panel.setFrameOrigin(panelOrigin)
        panel.orderFrontRegardless()
        installDismissMonitors(for: window)
    }

    func dismiss() {
        removeDismissMonitors()
        panel.orderOut(nil)
        releaseContentWhenHidden()
        let handler = dismissHandler
        dismissHandler = nil
        handler?()
    }

    /// Drops the hosted SwiftUI view once the panel is hidden: its callbacks
    /// capture the web view the suggestions were shown for, which would
    /// otherwise stay alive until the next presentation. Deferred a turn
    /// because dismiss() can run from inside one of those callbacks.
    private func releaseContentWhenHidden() {
        guard let dismissedContent = panel.contentViewController else { return }
        DispatchQueue.main.async { [weak self, weak dismissedContent] in
            // Not if a newer presentation has replaced it meanwhile.
            guard let self = self, !self.panel.isVisible,
                  let dismissedContent, self.panel.contentViewController === dismissedContent else { return }
            self.panel.contentViewController = nil
            // Clearing the controller doesn't necessarily detach its view.
            self.panel.contentView = NSView()
        }
    }

    /// It stays where the field was on screen, so anything that moves the
    /// field or leaves it closes it: a click outside it, a key other than
    /// the arrows (Return, Tab, ⌃Tab, ⌘W, typing), scrolling or zooming the
    /// page, and the window moving, resizing or going. Tab switches and new
    /// pages come from AutofillCoordinator.
    private func installDismissMonitors(for window: NSWindow) {
        removeDismissMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .magnify, .smartMagnify]
        ) { [weak self] event in
            guard let self = self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { // Escape
                    self.dismiss()
                    return nil
                }
                if !Self.arrowKeyCodes.contains(event.keyCode) { self.dismiss() }
            default:
                // Scrolling a long list of accounts in the panel is fine.
                if event.window != self.panel { self.dismiss() }
            }
            return event
        }
        // Click outside the app window also dismisses.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        let names: [Notification.Name] = [
            NSWindow.willMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willMiniaturizeNotification,
            NSWindow.willEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
            NSWindow.willCloseNotification,
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addMainObserver(forName: name, object: window) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    /// Left, right, down, up: moving the caret in the field.
    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    private func removeDismissMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
    }
}
