import SwiftUI
import Foundation

/// How far the sidebar is zoomed out: the active space's tabs; the overview
/// of the library and every space; or one of the library's full lists.
enum SidebarLevel: Equatable {
    case space
    case overview
    case list(SidebarLibraryList)
}

/// The library's lists, shared by every space.
enum SidebarLibraryList: String, CaseIterable, Identifiable {
    case downloads, readingList, history, explore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .readingList: return "Reading List"
        case .history: return "History"
        case .explore: return "Explore"
        }
    }

    var symbol: String {
        switch self {
        case .downloads: return "arrow.down.circle"
        case .readingList: return "eyeglasses"
        case .history: return "clock"
        case .explore: return "sparkles"
        }
    }
}

/// Observed property by property (`@Observable`): showing or hiding the
/// sidebar re-runs only the views that read `isVisible`. As an
/// `ObservableObject`, every view using the manager (the space bar, the URL
/// bar, the overview…) ran its body again in the slide's first frame.
@Observable
class SidebarStateManager {
    var isVisible: Bool = false {
        didSet { if isVisible != oldValue { onLayoutChange?() } }
    }
    // The didSet only tells the window's layout, which sets AppKit frames.
    // Chaining a synchronous write into TabManager here (the old
    // updateWebViewInteractionState path) caused AttributeGraph cycles while
    // BrowserView depended on the derived shouldDisableWebViewInteraction;
    // BrowserView reads isFloating directly instead.
    var isFloating: Bool = false {
        didSet { if isFloating != oldValue { onLayoutChange?() } }
    }
    /// Back to `.space` whenever something is opened from the library.
    private(set) var level: SidebarLevel = .space
    var customSidebarWidth: CGFloat = 280 { // Make width customizable
        didSet { if customSidebarWidth != oldValue { onLayoutChange?() } }
    }

    /// The window's layout (`BrowserWindowLayoutView`), told in the same
    /// turn as the change: a resize drag's new width has to reach the
    /// sidebar's AppKit frame in the same frame as its SwiftUI one.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    // Animation state tracking
    @ObservationIgnored private var isAnimating: Bool = false
    @ObservationIgnored private var pendingVisibilityWork: DispatchWorkItem?
    @ObservationIgnored private var pendingAnimationResetWork: DispatchWorkItem?

    // Debouncing for hideFloating to prevent rapid successive calls
    @ObservationIgnored private var lastHideFloatingCall: Date = .distantPast
    private let hideFloatingDebounceInterval: TimeInterval = 0.1

    // Reference to TabManager for controlling pointer events
    @ObservationIgnored weak var tabManager: TabManager?

    // Sidebar configuration
    static let collapsedWidth: CGFloat = 0
    static let defaultSidebarWidth: CGFloat = 280
    // The title bar row (window buttons, sidebar toggle, back/forward, reload) needs ~230
    static let minSidebarWidth: CGFloat = 240
    static let maxSidebarWidth: CGFloat = 500

    // Animation configuration: the sidebar's spring (95% of the way in five
    // frames at 60 fps, overshooting ~1%)
    static let animationDuration: Double = 0.155
    static let animationEasing = Animation.easeInOut(duration: animationDuration)

    // Floating sidebar animation configuration
    private let floatingAnimationDuration: Double = SidebarStateManager.animationDuration
    private let floatingAnimationBounce: Double = 0.18
    
    var floatingAnimation: Animation {
      .spring(slideSpring)
    }

    /// The sidebar's slide, shared by SwiftUI's animations in it and the
    /// window's own layout, which runs it on Core Animation for the sidebar
    /// and frame by frame for the page
    var slideSpring: Spring {
        Spring(duration: floatingAnimationDuration, bounce: floatingAnimationBounce)
    }
    
    /// Where the window keeps whether its sidebar shows, and its width
    @ObservationIgnored private let visibleKey: String
    @ObservationIgnored private let widthKey: String

    init(defaults: WindowDefaults) {
        visibleKey = defaults.key("SidebarVisible")
        widthKey = defaults.key("SidebarWidth")
        // Load saved sidebar state
        loadSidebarState()
    }
    
    // MARK: - Public Methods
    
    /// Toggle the sidebar visibility
    func toggle() {
        // If floating, convert to docked instead of toggling
        if isFloating {
            dock()
            return
        }
        
        // Prevent toggle during animation
        guard !isAnimating else {
            return 
        }
        
        withAnimation(Self.animationEasing) {
            isVisible.toggle()
        }
        saveSidebarStateAfterSliding()
    }

    /// Show the sidebar
    func show() {
        withAnimation(Self.animationEasing) {
            isVisible = true
        }
        saveSidebarStateAfterSliding()
    }
    
    /// Show sidebar in floating mode
    func showFloating() {
        // Prevent multiple calls during animation
        guard !isAnimating else { return }
        
        isAnimating = true
        
        // Cancel any pending operations
        pendingVisibilityWork?.cancel()
        pendingAnimationResetWork?.cancel()
        
        // Set floating state first to create the container
        isFloating = true
        
        // Create work items for delayed operations
        pendingVisibilityWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isVisible = true
            
            // Reset animation flag after animation completes
            self.pendingAnimationResetWork = DispatchWorkItem { [weak self] in
                self?.isAnimating = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.floatingAnimationDuration, 
                                         execute: self.pendingAnimationResetWork!)
        }
        
        // Execute the visibility work after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: pendingVisibilityWork!)
        
        // Disable pointer events on web content when floating sidebar appears
        tabManager?.setActiveTabPointerEventsEnabled(false)
        // Don't save floating state - it's temporary
    }
    
    /// Convert floating sidebar to docked
    func dock() {
        // Prevent docking during animation
        guard !isAnimating else {
            return 
        }
        
        // Only process if currently floating
        if isFloating {
            // Cancel any pending operations
            pendingVisibilityWork?.cancel()
            pendingAnimationResetWork?.cancel()
            
            isAnimating = true
            
            // The window's layout moves the page beside the sidebar (BrowserWindowLayoutView)
            isFloating = false
            
            // Reset animation flag after morph completes
            pendingAnimationResetWork = DispatchWorkItem { [weak self] in
                self?.isAnimating = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + floatingAnimationDuration,
                                         execute: pendingAnimationResetWork!)
            
            // Re-enable pointer events when converting to docked
            tabManager?.setActiveTabPointerEventsEnabled(true)
            saveSidebarState()
        }
    }
    
    /// Hide floating sidebar (used by mouse tracking)
    func hideFloating() {
        // Debouncing to prevent rapid successive calls that cause crashes
        let now = Date()
        if now.timeIntervalSince(lastHideFloatingCall) < hideFloatingDebounceInterval {
            return
        }
        lastHideFloatingCall = now
        
        if isFloating {
            // Cancel any pending operations from showFloating()
            pendingVisibilityWork?.cancel()
            pendingAnimationResetWork?.cancel()
            
            isAnimating = true
            
            // First, set visibility to false to trigger slide-out animation
            // Keep isFloating = true during the animation so the view remains mounted
            isVisible = false
            
            // After animation completes, remove the floating state and reset animation flag
            pendingAnimationResetWork = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.isFloating = false
                self.isAnimating = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + floatingAnimationDuration, 
                                         execute: pendingAnimationResetWork!)
            
            // Re-enable pointer events when hiding floating sidebar
            tabManager?.setActiveTabPointerEventsEnabled(true)
        }
    }
    
    /// Goes to `level`, showing the sidebar if it's hidden: a cross-fade,
    /// or with `animated` off, at once (a pinch or a swipe that has already
    /// moved there).
    func show(_ level: SidebarLevel, animated: Bool = true) {
        guard self.level != level else { return }
        var transaction = Transaction(animation: animated ? Self.levelAnimation : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            self.level = level
        }
        if level != .space && !isVisible {
            show()
        }
    }

    /// Opens the overview, or goes back to the space from it.
    func toggleOverview() {
        show(level == .overview ? .space : .overview)
    }

    static let levelAnimation = Animation.easeInOut(duration: 0.25)
    
    /// Update sidebar width with constraints. Not animated: the window's
    /// layout sets the sidebar's AppKit frame to the new width at once, and
    /// SwiftUI's frame inside it has to match.
    func setSidebarWidth(_ width: CGFloat) {
        let constrainedWidth = max(Self.minSidebarWidth, min(Self.maxSidebarWidth, width))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            customSidebarWidth = constrainedWidth
        }
        saveSidebarState()
    }
    
    /// Get the current sidebar width based on visibility
    var currentWidth: CGFloat {
        return isVisible ? customSidebarWidth : Self.collapsedWidth
    }

    var sidebarWidth: CGFloat {
        return customSidebarWidth
    }
    
    // MARK: - Persistence
    
    func saveSidebarState() {
        UserDefaults.standard.set(isVisible, forKey: visibleKey)
        UserDefaults.standard.set(customSidebarWidth, forKey: widthKey)
    }

    /// Saved once the sidebar has slid in or out: in the slide's first
    /// frame, which already takes longest, the writes could cost it its
    /// deadline.
    private func saveSidebarStateAfterSliding() {
        DispatchQueue.main.asyncAfter(deadline: .now() + floatingAnimationDuration) { [weak self] in
            self?.saveSidebarState()
        }
    }
    
    private func loadSidebarState() {
        // Default to hidden for a cleaner initial experience
        isVisible = UserDefaults.standard.bool(forKey: visibleKey)
        // Load custom width, default to 280 if not set
        let savedWidth = UserDefaults.standard.double(forKey: widthKey)
        if savedWidth > 0 {
            customSidebarWidth = max(Self.minSidebarWidth, min(Self.maxSidebarWidth, CGFloat(savedWidth)))
        } else {
            customSidebarWidth = Self.defaultSidebarWidth
        }
    }
} 
