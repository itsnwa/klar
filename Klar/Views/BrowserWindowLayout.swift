import AppKit
import Combine
import QuartzCore
import SwiftUI

extension View {
    /// The window's models, as the environment of each SwiftUI tree in the
    /// window: the window's own and the two `BrowserWindowLayout` hosts,
    /// which don't inherit it. The session is a plain reference, so passing
    /// it on observes none of them.
    func browserEnvironment(_ session: BrowserWindowSession) -> some View {
        self
            .environmentObject(session.tabManager)
            .environmentObject(session.sidebarManager)
            .environment(session.sidebarStateManager)
            .environmentObject(session.spaceSelection)
            .environmentObject(session.findManager)
            .environmentObject(session.nativeWindowButtons)
            .environmentObject(session.floatingSidebarManager)
            .environmentObject(session.toolbarManager)
            .focusEffectDisabled()
    }
}

/// The sidebar and the page, laid out by AppKit rather than SwiftUI.
struct BrowserWindowLayout: NSViewRepresentable {
    let session: BrowserWindowSession

    func makeNSView(context: Context) -> BrowserWindowLayoutView {
        BrowserWindowLayoutView(session: session)
    }

    func updateNSView(_ view: BrowserWindowLayoutView, context: Context) {}
}

/// Lays out the sidebar (`SidebarArea`) and the page (`BrowserContentArea`),
/// each in a hosting view of its own, so showing or hiding the sidebar
/// costs the main thread next to nothing per frame.
///
/// When SwiftUI animated the sidebar's offset and the page's padding, every
/// frame of the slide laid out the whole window again, moved every hosted
/// AppKit view and made AppKit work out the title bar's drag regions anew.
/// Here, the sidebar's frame goes to where it ends up at once, and a Core
/// Animation spring slides its layer there on the render server. The page
/// has to lay out at each width as it goes, so it gets one frame per display
/// frame, worked out from the same spring started at the same moment. Out
/// of sight, the sidebar is hidden, so it's neither drawn nor hit.
///
/// The sidebar is above the page, so the floating sidebar's shadow falls on
/// the page.
final class BrowserWindowLayoutView: NSView, CAAnimationDelegate {
    /// The frame around an inset page (Settings › Appearance › Inset web
    /// pages). Its leading side is here, since it moves with the sidebar;
    /// `ContentAreaShape` has the others.
    nonisolated static let pageInset: CGFloat = 6
    /// How far past the window's edge the hidden sidebar is, so the
    /// floating one's shadow goes too
    private static let hiddenSidebarClearance: CGFloat = 20
    /// Close enough to the end of the slide to stop
    private static let settledProgress = 0.0005
    private static let settledInset = 0.05

    private let session: BrowserWindowSession
    private let sidebarState: SidebarStateManager
    private let sidebarHost: NSHostingView<AnyView>
    private let contentHost: NSHostingView<AnyView>
    private let windowState: WindowState
    private var insetObserver: AnyCancellable?
    private var fullScreenObservers: [NSObjectProtocol] = []
    /// The window's radius out of full screen
    private var windowedCornerRadius = WindowState.defaultCornerRadius
    /// Settings › Appearance › Inset web pages, which full screen leaves out
    private var isInsetSetting: Bool

    private var isSidebarShown: Bool
    /// 1 with the page beside the docked sidebar, 0 with the page from the
    /// window's edge (sidebar hidden or floating)
    private var dockedProgress: SpringValue
    private var leadingInset: SpringValue
    private var displayLink: CADisplayLink?
    private var slidesInFlight = 0

    init(session: BrowserWindowSession) {
        self.session = session
        let sidebarState = session.sidebarStateManager
        self.sidebarState = sidebarState
        let windowState = WindowState()
        self.windowState = windowState
        sidebarHost = Self.host(SidebarArea(), session: session)
        contentHost = Self.host(BrowserContentArea(windowState: windowState), session: session)
        isSidebarShown = sidebarState.isVisible
        dockedProgress = SpringValue(sidebarState.isVisible && !sidebarState.isFloating ? 1 : 0)
        isInsetSetting = TOMLSettingsManager.shared.insetWebView
        leadingInset = SpringValue(isInsetSetting ? Double(Self.pageInset) : 0)
        super.init(frame: .zero)

        wantsLayer = true
        addSubview(contentHost)
        addSubview(sidebarHost)
        sidebarHost.isHidden = !isSidebarShown

        sidebarState.onLayoutChange = { [weak self] in
            self?.sidebarStateDidChange()
        }
        insetObserver = TOMLSettingsManager.shared.$insetWebView
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isInset in
                self?.isInsetSetting = isInset
                self?.updateLeadingInset()
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sized and placed by this view alone: no constraints from SwiftUI's
    /// sizes, and no safe area, as the window's own content ignores it
    private static func host<Content: View>(_ content: Content, session: BrowserWindowSession) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.browserEnvironment(session)))
        host.sizingOptions = []
        host.safeAreaRegions = []
        return host
    }

    private var spring: Spring { sidebarState.slideSpring }

    /// The page's area, on screen: where a tab dragged from the sidebar
    /// shows as its page (`SidebarDraggedRowView.Shape.page`)
    var contentScreenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(contentHost.convert(contentHost.bounds, to: nil))
    }

    /// The sidebar, on screen, while it shows: where a tab dragged from any
    /// window's sidebar shows as a row
    var shownSidebarScreenFrame: CGRect? {
        guard let window, !sidebarHost.isHidden else { return nil }
        return window.convertToScreen(sidebarHost.convert(sidebarHost.bounds, to: nil))
    }

    // MARK: - Changes

    private func sidebarStateDidChange() {
        let now = CACurrentMediaTime()
        // Before the window is up there's nothing to animate
        let animated = window != nil

        if sidebarState.isVisible != isSidebarShown {
            isSidebarShown = sidebarState.isVisible
            slideSidebar(animated: animated, at: now)
        }

        let docked: Double = sidebarState.isVisible && !sidebarState.isFloating ? 1 : 0
        if docked != dockedProgress.target {
            if animated {
                dockedProgress.move(to: docked, at: now, spring: spring, epsilon: Self.settledProgress)
            } else {
                dockedProgress.jump(to: docked)
            }
        }

        // A new width goes into the frames at once
        layoutHosts(at: now)
        runDisplayLinkIfMoving(at: now)
    }

    /// Inset, unless the window is in full screen
    private func updateLeadingInset() {
        let now = CACurrentMediaTime()
        let inset = isInsetSetting && !windowState.isFullScreen ? Double(Self.pageInset) : 0
        guard inset != leadingInset.target else { return }
        if window != nil {
            leadingInset.move(to: inset, at: now, spring: spring, epsilon: Self.settledInset)
        } else {
            leadingInset.jump(to: inset)
        }
        layoutHosts(at: now)
        runDisplayLinkIfMoving(at: now)
    }

    // MARK: - Sidebar

    private var sidebarX: CGFloat {
        isSidebarShown ? 0 : -(sidebarState.customSidebarWidth + Self.hiddenSidebarClearance)
    }

    /// Moves the sidebar's frame to where it ends up and slides its layer
    /// there from where it was: an additive animation of the difference, so
    /// one started mid-slide carries on from wherever the last one is.
    private func slideSidebar(animated: Bool, at time: CFTimeInterval) {
        let oldX = sidebarHost.frame.minX
        let newX = sidebarX
        if isSidebarShown {
            sidebarHost.isHidden = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sidebarHost.setFrameOrigin(NSPoint(x: newX, y: 0))

        if animated, oldX != newX, let layer = sidebarHost.layer {
            let slide = CASpringAnimation(keyPath: "position.x")
            slide.mass = CGFloat(spring.mass)
            slide.stiffness = CGFloat(spring.stiffness)
            slide.damping = CGFloat(spring.damping)
            slide.duration = slide.settlingDuration
            slide.fromValue = oldX - newX
            slide.toValue = 0
            slide.isAdditive = true
            // On the same clock as the page's frames
            slide.beginTime = layer.convertTime(time, from: nil)
            slide.fillMode = .backwards
            slide.delegate = self
            slidesInFlight += 1
            layer.add(slide, forKey: "slide-\(time)")
        } else if !isSidebarShown {
            sidebarHost.isHidden = true
        }
        CATransaction.commit()
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        slidesInFlight = max(slidesInFlight - 1, 0)
        if slidesInFlight == 0 && !isSidebarShown {
            sidebarHost.isHidden = true
        }
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutHosts(at: CACurrentMediaTime())
    }

    private func layoutHosts(at time: CFTimeInterval) {
        let width = sidebarState.customSidebarWidth
        let sidebarFrame = NSRect(x: sidebarX, y: 0, width: width, height: bounds.height)
        if sidebarHost.frame != sidebarFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sidebarHost.frame = sidebarFrame
            CATransaction.commit()
        }

        // The sidebar overshoots, the page doesn't: past its target and back,
        // it would widen again, and for a frame its background shows past
        // content (a video) that fills it and hasn't caught up
        let progress = min(max(CGFloat(dockedProgress.value(at: time, spring: spring)), 0), 1)
        let inset = min(max(CGFloat(leadingInset.value(at: time, spring: spring)), 0), Self.pageInset)
        // On whole points, not pixels: a page laid out at half a point more
        // leaves the last pixel column to its background where an element
        // fills the width in whole CSS pixels, a white line flickering at the
        // page's edge as the spring settles.
        let leading = (progress * width + (1 - progress) * inset).rounded()
        let contentFrame = NSRect(x: leading, y: 0, width: max(bounds.width - leading, 0), height: bounds.height)
        if contentHost.frame != contentFrame {
            contentHost.frame = contentFrame
        }
    }

    // MARK: - Display link

    private func runDisplayLinkIfMoving(at time: CFTimeInterval) {
        let isMoving = dockedProgress.isMoving(at: time) || leadingInset.isMoving(at: time)
        if isMoving, displayLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !isMoving {
            stopDisplayLink()
        }
    }

    /// Lays the page out for the moment this frame is shown
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        layoutHosts(at: time)
        if !dockedProgress.isMoving(at: time) && !leadingInset.isMoving(at: time) {
            stopDisplayLink()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            // Before it's seen, so its frame from last time goes in first
            session.attach(to: window, layoutView: self)
        } else {
            stopDisplayLink()
        }
        observeFullScreen()
        updateWindowState()
    }

    // MARK: - Window state

    /// No inset in full screen, from the moment it starts until it starts
    /// back to a window. The corners are square once it's there, and
    /// rounded again as soon as it starts back: the window's own radius is
    /// still the full screen's 0 then, so it's the one it had before, read
    /// again once it's a window.
    private func observeFullScreen() {
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fullScreenObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addMainObserver(forName: NSWindow.willEnterFullScreenNotification, object: window) { [weak self] _ in
                self?.setFullScreen(true)
            },
            center.addMainObserver(forName: NSWindow.didEnterFullScreenNotification, object: window) { [weak self] _ in
                self?.setWindowCornerRadius(0)
            },
            center.addMainObserver(forName: NSWindow.willExitFullScreenNotification, object: window) { [weak self] _ in
                guard let self else { return }
                self.setFullScreen(false)
                self.setWindowCornerRadius(self.windowedCornerRadius)
            },
            center.addMainObserver(forName: NSWindow.didExitFullScreenNotification, object: window) { [weak self] _ in
                self?.updateWindowState()
            },
        ]
    }

    private func updateWindowState() {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        setFullScreen(isFullScreen)
        if isFullScreen {
            setWindowCornerRadius(0)
        } else {
            if let radius = Self.cornerRadius(of: window), radius > 0 {
                windowedCornerRadius = radius
            }
            setWindowCornerRadius(windowedCornerRadius)
        }
    }

    private func setFullScreen(_ isFullScreen: Bool) {
        guard windowState.isFullScreen != isFullScreen else { return }
        windowState.isFullScreen = isFullScreen
        updateLeadingInset()
    }

    private func setWindowCornerRadius(_ radius: CGFloat) {
        if windowState.cornerRadius != radius {
            windowState.cornerRadius = radius
        }
    }

    /// The window's own corner radius (private `_cornerRadius`; 16 pt on
    /// macOS 27)
    private static func cornerRadius(of window: NSWindow) -> CGFloat? {
        let selector = NSSelectorFromString("_cornerRadius")
        guard window.responds(to: selector),
              let radius = window.value(forKey: "_cornerRadius") as? NSNumber
        else { return nil }
        return CGFloat(radius.doubleValue)
    }

    isolated deinit {
        fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// What the page's shape follows of the window: its corners, which the
/// page's are concentric with, and full screen, which leaves out the inset
@Observable
final class WindowState {
    static let defaultCornerRadius: CGFloat = 16
    var cornerRadius: CGFloat = WindowState.defaultCornerRadius
    var isFullScreen = false
}

/// A value moving to its target on a spring, worked out for any moment, so
/// each frame shows where it is when the frame is on screen
struct SpringValue {
    private(set) var target: Double
    private var origin: Double
    private var initialVelocity = 0.0
    private var start: CFTimeInterval = 0
    private var end: CFTimeInterval = 0

    init(_ value: Double) {
        target = value
        origin = value
    }

    func isMoving(at time: CFTimeInterval) -> Bool {
        time < end
    }

    func value(at time: CFTimeInterval, spring: Spring) -> Double {
        guard isMoving(at: time) else { return target }
        return origin + spring.value(target: target - origin, initialVelocity: initialVelocity, time: max(time - start, 0))
    }

    /// From where it is at `time`, keeping its speed
    mutating func move(to newTarget: Double, at time: CFTimeInterval, spring: Spring, epsilon: Double) {
        let current = value(at: time, spring: spring)
        let velocity = isMoving(at: time)
            ? spring.velocity(target: target - origin, initialVelocity: initialVelocity, time: max(time - start, 0))
            : 0
        origin = current
        target = newTarget
        initialVelocity = velocity
        start = time
        end = time + spring.settlingDuration(target: newTarget - current, initialVelocity: velocity, epsilon: epsilon)
    }

    mutating func jump(to newTarget: Double) {
        target = newTarget
        origin = newTarget
        end = 0
    }
}
