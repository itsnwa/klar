import SwiftUI
import AppKit
import Combine

class FloatingSidebarManager: ObservableObject {
    private weak var sidebarStateManager: SidebarStateManager?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyWindowObservers: [NSObjectProtocol] = []
    private weak var currentWindow: NSWindow?
    private var hideTimer: Timer?
    private var activationTimer: Timer?
    private var isHiding = false
    private var lastMousePosition: CGPoint = .zero
    private var hasMouseEnteredSidebar = false
    private var cancellables: Set<AnyCancellable> = []

    // Configuration
    private let leftEdgeTriggerWidth: CGFloat = 3
    private let hideDelay: Double = 0
    private let animationDuration: Double = 0.25
    private let autoDismissDelay: Double = 1.0
    
    // MARK: - Public Methods
    
    /// Setup mouse tracking for the floating sidebar
    func setupTracking(for window: NSWindow, sidebarStateManager: SidebarStateManager) {
        // Idempotent: a reopened window must not stack another set of monitors.
        removeMouseTracking()
        cancellables.removeAll()
        currentWindow = window
        self.sidebarStateManager = sidebarStateManager
        setupMouseTracking()
        observeBlockingDialogs()
    }

    /// Clean up tracking when view disappears
    func cleanup() {
        removeMouseTracking()
        hideTimer?.invalidate()
        hideTimer = nil
        activationTimer?.invalidate()
        activationTimer = nil
        cancellables.removeAll()
    }
    
    /// Check if mouse position should trigger floating sidebar
    private func shouldShowFloatingSidebar(mouseLocation: CGPoint, windowFrame: NSRect) -> Bool {
        // Check if mouse is within left edge trigger area
        let relativeX = mouseLocation.x - windowFrame.minX
        return relativeX >= 0 && relativeX <= leftEdgeTriggerWidth && 
               mouseLocation.y >= windowFrame.minY && mouseLocation.y <= windowFrame.maxY
    }
    
    /// Check if mouse position should hide floating sidebar
    private func shouldHideFloatingSidebar(mouseLocation: CGPoint, windowFrame: NSRect, sidebarWidth: CGFloat) -> Bool {
        // Hide if mouse is in the main browser area (right of the floating sidebar)
        let relativeX = mouseLocation.x - windowFrame.minX
        let sidebarRightEdge = sidebarWidth + 8 // width + margin (sidebar is flush with the window edge)
        
        return relativeX > sidebarRightEdge && 
               mouseLocation.y >= windowFrame.minY && mouseLocation.y <= windowFrame.maxY
    }
    
    // MARK: - Mouse Tracking

    private func setupMouseTracking() {
        // Local monitor for when the mouse is within the window
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(NSEvent.mouseLocation)
            return event
        }

        // A global monitor sees the mouse outside the window, which is how a
        // move off the window's left edge is caught. It also receives every
        // mouse move made in any *other* app, though — so it only exists
        // while our window is key (the only time `handleMouseMoved` acts),
        // instead of waking Klar for each mouse move while it's in the
        // background.
        guard let window = currentWindow else { return }
        if window.isKeyWindow {
            installGlobalMonitor()
        }
        keyWindowObservers = [
            NotificationCenter.default.addMainObserver(forName: NSWindow.didBecomeKeyNotification, object: window) { [weak self] _ in
                self?.installGlobalMonitor()
            },
            NotificationCenter.default.addMainObserver(forName: NSWindow.didResignKeyNotification, object: window) { [weak self] _ in
                self?.removeGlobalMonitor()
            }
        ]
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved(NSEvent.mouseLocation)
        }
    }

    private func removeGlobalMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleMouseMoved(_ mouseLocation: CGPoint) {
        guard let window = self.currentWindow else { return }

        // Only respond when window is key (focused)
        guard window.isKeyWindow else { return }

        // NB: do not store the live mouse location on a `@Published` property
        // here. This handler runs on every `.mouseMoved` event (which WebKit's
        // own tracking areas generate continuously while the pointer is over
        // web content), and `FloatingSidebarManager` is observed by
        // `ContentView` via `@EnvironmentObject`. Publishing per-move would
        // re-evaluate the entire root view tree on every pointer move and
        // starve the WebContent process's hover/compositing updates, making
        // CSS `:hover` feel laggy. Use the local
        // `lastMousePosition` (non-published) for edge-exit detection instead.
        let windowFrame = window.frame

        // Check if mouse is in the 3px trigger area OR exited window on the left side
        let inTriggerArea = self.shouldShowFloatingSidebar(mouseLocation: mouseLocation, windowFrame: windowFrame)

        let didExitLeft = mouseLocation.x < windowFrame.minX &&
                         mouseLocation.y >= windowFrame.minY &&
                         mouseLocation.y <= windowFrame.maxY &&
                         lastMousePosition.x >= windowFrame.minX

        // Store current position for next check
        lastMousePosition = mouseLocation

        // Trigger floating sidebar when mouse is in trigger area OR exits left side
        if let sidebarState = self.sidebarStateManager,
           !sidebarState.isVisible && !sidebarState.isFloating && (inTriggerArea || didExitLeft) {
            self.showFloatingSidebar()
        }

        // Track whether mouse is currently in sidebar area
        if let sidebarState = self.sidebarStateManager,
           sidebarState.isFloating {
            let relativeX = mouseLocation.x - windowFrame.minX
            // Sidebar is flush with the window's left edge
            let sidebarRightEdge = sidebarState.customSidebarWidth

            let isInSidebar = relativeX >= 0 && relativeX <= sidebarRightEdge &&
                             mouseLocation.y >= windowFrame.minY && mouseLocation.y <= windowFrame.maxY

            if isInSidebar {
                if !hasMouseEnteredSidebar {
                    hasMouseEnteredSidebar = true
                    // Cancel auto-dismiss timer since mouse is now in sidebar
                    activationTimer?.invalidate()
                    activationTimer = nil
                }
            } else {
                // Mouse left sidebar - reset flag and restart timer if mouse exits left again
                if hasMouseEnteredSidebar && didExitLeft {
                    hasMouseEnteredSidebar = false
                    // Don't auto-dismiss while a blocking dialog is open.
                    if !isBlocked {
                        activationTimer?.invalidate()
                        activationTimer = Timer.scheduledTimer(withTimeInterval: self.autoDismissDelay, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self = self else { return }
                                if !self.hasMouseEnteredSidebar {
                                    self.hideFloatingSidebar()
                                }
                            }
                        }
                    }
                } else if hasMouseEnteredSidebar {
                    // Mouse left sidebar but didn't exit left - just reset the flag
                    hasMouseEnteredSidebar = false
                }
            }
        }

        // Check if we should hide floating sidebar (mouse moved to browser area)
        if let sidebarState = self.sidebarStateManager,
           sidebarState.isFloating && !self.isHiding &&
           self.shouldHideFloatingSidebar(mouseLocation: mouseLocation, windowFrame: windowFrame, sidebarWidth: sidebarState.customSidebarWidth) {
            self.scheduleHideFloatingSidebar()
        }
    }

    private func removeMouseTracking() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        removeGlobalMonitor()
        for observer in keyWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        keyWindowObservers.removeAll()
    }
    
    private func showFloatingSidebar() {
        DispatchQueue.main.async { [self] in
            // Cancel any pending hide timer and reset hiding state
            self.hideTimer?.invalidate()
            self.hideTimer = nil
            self.isHiding = false

            // Reset sidebar entry tracking
            self.hasMouseEnteredSidebar = false

            self.sidebarStateManager?.showFloating()

            // Start auto-dismiss timer unless a blocking dialog is suspending it.
            self.activationTimer?.invalidate()
            if !self.isBlocked {
                self.activationTimer = Timer.scheduledTimer(withTimeInterval: self.autoDismissDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self = self else { return }
                        // Only auto-dismiss if mouse never entered sidebar
                        if !self.hasMouseEnteredSidebar {
                            self.hideFloatingSidebar()
                        }
                    }
                }
            }
        }
    }
    
    private func scheduleHideFloatingSidebar() {
        // Don't schedule if timer is already running or already hiding
        guard hideTimer == nil && !isHiding else { return }
        // Don't schedule while a dialog rooted in the sidebar is open.
        guard !isBlocked else { return }

        isHiding = true

        // Schedule new hide timer
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideFloatingSidebar()
            }
        }
    }

    // MARK: - Blocking-dialog observation

    /// A dialog of this window's sidebar is open
    private var isBlocked: Bool {
        sidebarStateManager.map(FloatingSidebarBlocker.shared.isBlocked) ?? false
    }

    private func observeBlockingDialogs() {
        guard let sidebarStateManager else { return }
        let sidebar = ObjectIdentifier(sidebarStateManager)
        FloatingSidebarBlocker.shared.$blockingCounts
            .map { $0[sidebar] ?? 0 }
            .removeDuplicates()
            .sink { [weak self] newCount in
                guard let self = self else { return }
                if newCount > 0 {
                    // Dialog opened — suspend any pending auto-hide.
                    self.hideTimer?.invalidate()
                    self.hideTimer = nil
                    self.activationTimer?.invalidate()
                    self.activationTimer = nil
                    self.isHiding = false
                } else {
                    // Last dialog closed — if mouse is no longer over the
                    // sidebar, fall through to the normal hide path.
                    self.reevaluateHideAfterDialogClosed()
                }
            }
            .store(in: &cancellables)
    }

    private func reevaluateHideAfterDialogClosed() {
        guard let window = currentWindow,
              let sidebarState = sidebarStateManager,
              sidebarState.isFloating else { return }

        let mouseLocation = NSEvent.mouseLocation
        let windowFrame = window.frame
        let relativeX = mouseLocation.x - windowFrame.minX
        let sidebarRightEdge = sidebarState.customSidebarWidth
        let isInSidebar = relativeX >= 0 && relativeX <= sidebarRightEdge &&
                          mouseLocation.y >= windowFrame.minY && mouseLocation.y <= windowFrame.maxY

        if !isInSidebar {
            scheduleHideFloatingSidebar()
        }
    }
    
    private func hideFloatingSidebar() {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            self.hideTimer = nil
            self.activationTimer?.invalidate()
            self.activationTimer = nil

            self.sidebarStateManager?.hideFloating()

            // Reset state flags once SidebarStateManager's animation is over
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarStateManager.animationDuration) {
                self.isHiding = false
                self.hasMouseEnteredSidebar = false
            }
        }
    }
}
