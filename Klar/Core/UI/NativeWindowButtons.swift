import AppKit
import SwiftUI

class NativeWindowButtons: ObservableObject {
    private weak var window: NSWindow?
    private weak var titleBarView: NSView?
    // Plain state, not @Published: SidebarView holds this object as an
    // environment object, and publishing these re-rendered the sidebar on
    // every sheet and fullscreen change for nothing.
    private var isFullscreen = false
    private var hasActiveSheet = false
    private var configurationRetries = 0
    private let maxRetries = 3
    private var retryTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pendingRepositionWork: DispatchWorkItem?

    // Window identity tracking
    private var originalWindowNumber: Int?
    
    func configure(window: NSWindow) {
        // Validate this is the correct window to configure
        if !validateWindowForConfiguration(window) {
            return
        }

        // WindowButtonsConfigurator.updateNSView fires this every time
        // SidebarView's body re-renders. If the same window is already
        // wired up, skip the full setup — re-registering observers and
        // re-running setupWindowButtonsWithRetry on every render churned
        // tracking-area updates and added load to AppKit's layout pass.
        if self.window === window && !notificationObservers.isEmpty {
            return
        }

        self.window = window
        configurationRetries = 0
        // A window restored in full screen gets no willEnterFullScreen
        isFullscreen = window.styleMask.contains(.fullScreen)
        
        // Track window identity
        originalWindowNumber = window.windowNumber
        
        // Cancel any existing retry timer
        retryTimer?.invalidate()
        retryTimer = nil
        
        setupWindowButtonsWithRetry()

        // Remove any existing observers before adding new ones
        removeNotificationObservers()

        // Listen for window resize events to maintain button positioning
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.didResizeNotification,
            object: window
        ) { [weak self] _ in
            self?.repositionWindowButtons()
        })

        // Listen for fullscreen transitions
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window
        ) { [weak self] _ in
            self?.handleFullscreenTransition(entering: true)
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willExitFullScreenNotification,
            object: window
        ) { [weak self] _ in
            self?.handleFullscreenTransition(entering: false)
        })

        // Listen for sheet events to restore button positioning
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.willBeginSheetNotification,
            object: window
        ) { [weak self] _ in
            self?.hasActiveSheet = true
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.didEndSheetNotification,
            object: window
        ) { [weak self] _ in
            self?.hasActiveSheet = false
            // Restore button positioning after a short delay to ensure sheet is fully dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.repositionWindowButtons()
            }
            // Double-check positioning after a longer delay as a safety measure
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.repositionWindowButtons()
            }
        })

        // App / window activation: AppKit re-runs theme-frame layout when the window
        // becomes key/main again (e.g. opening via external URL, Cmd-Tab back, dock-icon
        // click) and can reclaim the standard buttons to their default position. We
        // schedule a coalesced reposition after each of these events.
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window
        ) { [weak self] _ in
            self?.scheduleReposition(delay: 0.05)
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: window
        ) { [weak self] _ in
            self?.scheduleReposition(delay: 0.05)
        })

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil
        ) { [weak self] _ in
            self?.scheduleReposition(delay: 0.1)
        })

        // Window goes from occluded/hidden back to visible
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            if window.occlusionState.contains(.visible) {
                self.scheduleReposition(delay: 0.05)
            }
        })

        // Tracking-area updates correlate with theme-frame layout passes — documented
        // as the primary repositioning trigger. Observe on the window's contentView.
        if let contentView = window.contentView {
            notificationObservers.append(NotificationCenter.default.addMainObserver(
                forName: NSView.didUpdateTrackingAreasNotification,
                object: contentView
            ) { [weak self] _ in
                self?.scheduleReposition(delay: 0.0)
            })
        }
    }

    /// Coalesce reposition calls — multiple observers can fire in quick succession on
    /// app activation, and AppKit needs a moment to settle before we move buttons.
    private func scheduleReposition(delay: TimeInterval) {
        pendingRepositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.repositionWindowButtons()
        }
        pendingRepositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func removeNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    isolated deinit {
        removeNotificationObservers()
        retryTimer?.invalidate()
        pendingRepositionWork?.cancel()
    }
    
    func attachToTitleBar(_ titleBarView: NSView) {
        // Same view, same parent → buttons are already attached. Skipping
        // here matters because WindowButtonsConfigurator.updateNSView calls
        // attachToTitleBar on every SidebarView body update; re-running
        // repositionWindowButtons removes/re-adds the standard buttons,
        // which forces AppKit to recalculate tracking areas and feeds back
        // into our didUpdateTrackingAreasNotification observer.
        //
        // ONLY short-circuit if the buttons are *still* parented under
        // this titleBarView. After sidebar-collapse animations, fullscreen
        // exits, and various window state changes AppKit can reclaim the
        // standard buttons back to its own title bar. If we early-return
        // unconditionally we never re-parent them and they end up pinned
        // to the window's top-left while the sidebar slides away — which
        // was the regression introduced by commit 34e8a7a2.
        if self.titleBarView === titleBarView,
           let closeButton = self.window?.standardWindowButton(.closeButton),
           closeButton.superview === titleBarView {
            return
        }
        self.titleBarView = titleBarView
        repositionWindowButtons()
        // Safety-net: at launch the first reposition can silently no-op
        // (e.g. the title-bar NSView's geometry isn't settled, or one of
        // the early-return guards in repositionWindowButtons trips
        // momentarily). Without this, the buttons stay pinned to the
        // window's default position until the user activates the app and
        // didUpdateTrackingAreasNotification finally forces a re-attach.
        // `scheduleReposition` already coalesces, and this only runs when
        // we *did* re-parent (the early-return above was bypassed).
        scheduleReposition(delay: 0.1)
    }
    
    // MARK: - Private Implementation
    
    private func handleFullscreenTransition(entering: Bool) {
        isFullscreen = entering
        
        if entering {
            // Reset buttons to their default positions when entering fullscreen
            resetButtonsToDefault()
        } else {
            // Re-position buttons when exiting fullscreen
            self.repositionWindowButtons()
        }
    }
    
    private func resetButtonsToDefault() {
        guard let window = window else { return }
        
        // Get the native window control buttons
        guard let closeButton = window.standardWindowButton(.closeButton),
              let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton) else {
            return
        }
        
        // Remove buttons from title bar view and let them return to default position
        closeButton.removeFromSuperview()
        miniaturizeButton.removeFromSuperview()
        zoomButton.removeFromSuperview()
        
        // Make sure they're visible and enabled in fullscreen
        closeButton.isHidden = false
        miniaturizeButton.isHidden = false
        zoomButton.isHidden = false
        closeButton.isEnabled = true
        miniaturizeButton.isEnabled = true
        zoomButton.isEnabled = true
    }
    
    private func setupWindowButtonsWithRetry() {
        guard let window = window else { return }
        
        // Configure window for native buttons
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        
        // Make sure buttons are visible, unless first launch's setup shows in
        // the window: it shows them as it grows into the browser (Onboarding)
        let isHidden = Onboarding.shared.isShowing(in: window)
        window.standardWindowButton(.closeButton)?.isHidden = isHidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isHidden
        window.standardWindowButton(.zoomButton)?.isHidden = isHidden
        
        // Position the buttons and validate configuration
        if validateButtonConfiguration() {
            repositionWindowButtons()
        } else {
            scheduleConfigurationRetry()
        }
    }
    
    private func validateButtonConfiguration() -> Bool {
        guard let window = window else { return false }
        
        // Check that all buttons exist and are accessible
        let closeButton = window.standardWindowButton(.closeButton)
        let miniaturizeButton = window.standardWindowButton(.miniaturizeButton)
        let zoomButton = window.standardWindowButton(.zoomButton)
        
        return closeButton != nil && miniaturizeButton != nil && zoomButton != nil
    }
    
    private func scheduleConfigurationRetry() {
        configurationRetries += 1
        
        if configurationRetries <= maxRetries {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setupWindowButtonsWithRetry()
                }
            }
        }
    }
    
    private func validateWindowForConfiguration(_ window: NSWindow) -> Bool {
        // Check if we already have a valid window configured
        if let existingWindow = self.window, existingWindow.windowNumber != 0 {
            // If this is the same window, allow reconfiguration
            if existingWindow.windowNumber == window.windowNumber {
                return true
            }
            
            // Check if existing window is still valid: open, not one that
            // closed before this one was opened again
            let allWindows = NSApplication.shared.windows
            if allWindows.contains(existingWindow) && existingWindow.contentView != nil
                && (existingWindow.isVisible || existingWindow.isMiniaturized || NSApp.isHidden) {
                // Existing window is still valid, don't reconfigure with a different window
                return false
            }
        }
        
        // Validate the new window
        guard window.contentView != nil else {
            return false
        }
        
        return true
    }
    
    private func validateCurrentWindow() -> Bool {
        guard let window = window else { return false }
        
        // Check if window is still valid
        let allWindows = NSApplication.shared.windows
        guard allWindows.contains(window) else {
            return false
        }
        
        // Check if window number changed (shouldn't happen but defensive)
        if let originalNumber = originalWindowNumber, window.windowNumber != originalNumber {
            return false
        }
        
        return true
    }
    
    private func repositionWindowButtons() {
        guard let window = window,
              let titleBarView = titleBarView else { return }
        
        // Validate the window is still the correct one
        if !validateCurrentWindow() {
            return
        }
        
        // Don't reposition if we're in fullscreen - let buttons stay in default position
        if isFullscreen {
            return
        }
        
        // Don't reposition if a sheet is active - wait for it to close
        if hasActiveSheet {
            return
        }
        
        // Get the native window control buttons
        guard let closeButton = window.standardWindowButton(.closeButton),
              let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton) else {
            return
        }
        
        // Calculate positions within the title bar view. The sidebar (and so
        // the title bar view) is flush with the window's top-left corner, so
        // these are effectively window coordinates: they match where macOS 27
        // natively puts the buttons in a toolbar window (close at x=19,
        // centers 26pt from the top, 23pt apart).
        let buttonSpacing: CGFloat = 23
        let leftMargin: CGFloat = 19
        let topMargin: CGFloat = 12
        let placements = [
            (closeButton, CGPoint(x: leftMargin, y: topMargin)),
            (miniaturizeButton, CGPoint(x: leftMargin + buttonSpacing, y: topMargin)),
            (zoomButton, CGPoint(x: leftMargin + (buttonSpacing * 2), y: topMargin))
        ]

        // Already in place. Moving them anyway updates tracking areas, which
        // posts the very notification that scheduled this call.
        if placements.allSatisfy({ $0.0.superview === titleBarView && $0.0.frame.origin == $0.1 }) {
            return
        }
        
        // Remove buttons from their current parent and add to title bar view.
        // Don't override button size - let them maintain their native size;
        // just position them using setFrameOrigin.
        for (button, origin) in placements {
            button.removeFromSuperview()
            titleBarView.addSubview(button)
            button.setFrameOrigin(origin)
        }
    }
}

// MARK: - SwiftUI Integration

extension View {
    func nativeWindowButtons(_ manager: NativeWindowButtons) -> some View {
        self.background(WindowButtonsConfigurator(manager: manager))
    }
}

private struct WindowButtonsConfigurator: NSViewRepresentable {
    let manager: NativeWindowButtons
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                manager.configure(window: window)
                // Pass this view as the title bar view to attach buttons to
                manager.attachToTitleBar(nsView)
            }
        }
    }
}
