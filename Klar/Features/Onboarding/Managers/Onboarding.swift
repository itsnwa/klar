import AppKit
import SwiftUI

/// First launch's setup: a small window that comes out of a bank of mist
/// (`OnboardingAtmosphere`), a few screens (`OnboardingView`), and Start
/// Browsing, which grows that same window into the browser as the mist
/// clears.
///
/// It's the first browser window itself, at 400×512: the browser is laid
/// out under the setup (`OnboardingOverlay` in ContentView), see-through
/// until the window grows. Meanwhile the window can't be resized, moved or
/// made full screen, its buttons are hidden, and Klar's shortcuts and menu
/// commands leave it alone (`BrowserWindow.receivesShortcuts`, `perform`),
/// as with a sheet over it.
@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()

    /// Set on a new install and cleared once the setup is done, so quitting
    /// midway shows it again
    private static let pendingKey = "OnboardingPending"
    static let windowSize = CGSize(width: 400, height: 512)
    /// The browser window it grows into: a new window's size (KlarApp's
    /// `defaultSize`)
    private static let browserSize = CGSize(width: 1400, height: 840)
    /// Between the grown window and the screen's edges, on a small screen
    private static let screenMargin: CGFloat = 24

    enum Phase {
        /// The window is being set up, not seen yet
        case preparing
        /// Out of the mist, then the screens
        case showing
        /// Growing into the browser
        case finishing
    }

    /// The session whose window shows the setup, while one does
    private(set) var session: BrowserWindowSession?
    private(set) var phase = Phase.preparing
    /// What the screens find and choose
    let setup = OnboardingSetup()

    @ObservationIgnored private var showsInNextWindow = false
    @ObservationIgnored private var atmosphere: OnboardingAtmosphere?
    @ObservationIgnored private var windowSettings: WindowSettings?
    @ObservationIgnored private var morph: WindowMorph?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var keyMonitor: Any?

    private init() {}

    /// In `KlarApp.init`, before What's New records the launch: a new
    /// install gets the setup.
    static func recordLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: WhatsNew.lastVersionKey) == nil, !WhatsNew.hasExistingData else { return }
        defaults.set(true, forKey: pendingKey)
    }

    /// Whether the window shows the setup
    func isShowing(in window: NSWindow?) -> Bool {
        guard let window, let session else { return false }
        return session.window === window
    }

    func isShowing(in session: BrowserWindowSession) -> Bool {
        self.session === session
    }

    /// Debug builds: the setup again, in a new window
    func showInNewWindow() {
        guard session == nil else {
            session?.window?.makeKeyAndOrderFront(nil)
            return
        }
        showsInNextWindow = true
        BrowserWindow.openNew()
    }

    // MARK: - Starting

    /// A window joining its session, before it's seen
    /// (`BrowserWindowSession.attach`): the setup takes it when it's due.
    /// Whether it did, so the window's frame from last time stays out.
    func takeWindow(of session: BrowserWindowSession) -> Bool {
        guard self.session == nil, let window = session.window,
              showsInNextWindow || UserDefaults.standard.bool(forKey: Self.pendingKey) else { return false }
        showsInNextWindow = false
        self.session = session
        phase = .preparing
        setup.start(in: session)
        window.alphaValue = 0
        // Called from SwiftUI's layout of the window, which a new frame would
        // lay out again inside it: right after it, as a restored frame is.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.session === session else { return }
            self.dress(window, session: session)
        }
        return true
    }

    private func dress(_ window: NSWindow, session: BrowserWindowSession) {
        windowSettings = WindowSettings(of: window)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let frame = CGRect(
            x: visible.midX - Self.windowSize.width / 2,
            y: visible.midY - Self.windowSize.height / 2,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        ).integral
        window.setFrame(frame, display: false)
        window.minSize = Self.windowSize
        window.maxSize = Self.windowSize
        window.isMovable = false
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        Self.setButtons(of: window, hidden: true)
        session.layoutView?.alphaValue = 0

        closeObserver = NotificationCenter.default.addMainObserver(
            forName: NSWindow.willCloseNotification, object: window
        ) { [weak self] _ in
            self?.windowWillClose()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }

        window.makeKeyAndOrderFront(nil)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        atmosphere = OnboardingAtmosphere(around: window, reduceMotion: reduceMotion)
        atmosphere?.rollIn()
        OnboardingSound.intro.play()

        // Out of the mist: the window fades in as it parts, its content
        // sharpening (OnboardingView)
        phase = .showing
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.8)) { [weak window] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.3 : 1.8
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.2, 1)
                window?.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Keys

    /// Return and Escape move through the screens wherever the focus is,
    /// not only when SwiftUI's default button gets them. On the last screen
    /// the shortcuts it lists light up their rows a moment instead of acting.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard phase == .showing, isShowing(in: event.window) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            guard modifiers.isEmpty else { return event }
            if !event.isARepeat {
                setup.primaryAction()
            }
            return nil
        case 53:  // Escape
            guard modifiers.isEmpty else { return event }
            setup.back()
            return nil
        default:
            break
        }
        if setup.step == .ready, let shortcut = OnboardingSetup.Shortcut.matching(event) {
            if !event.isARepeat {
                setup.pressShortcut(shortcut)
            }
            return nil
        }
        return event
    }

    // MARK: - Finishing

    /// Start Browsing: the window grows into the browser, pushing the mist
    /// away. Resized frame by frame, the window would be laid out again for
    /// each one, the whole browser in it, and stutter; so what's seen
    /// growing is a stand-in of the window's shape that Core Animation
    /// springs on the render server (`WindowMorph`). The window itself fades
    /// out with the setup, takes the browser's frame once while hidden, and
    /// fades back in over the stand-in as the browser.
    func finish() {
        guard let session, let window = session.window, phase == .showing else { return }
        phase = .finishing
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = Self.browserFrame(around: window.frame, on: window.screen)
        OnboardingSound.finish.play()

        if !reduceMotion {
            let morph = WindowMorph(from: window.frame, to: target, below: window)
            self.morph = morph
            atmosphere?.follow { [weak morph] in morph?.currentFrame }
        }
        let clearing = atmosphere
        clearing?.clear { [weak self] in
            if self?.atmosphere === clearing {
                self?.atmosphere = nil
            }
        }

        // Out with the setup as it dissolves (OnboardingView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self, weak window] in
            guard let self, let window, self.session === session else { return }
            self.becomeBrowser(window, session: session, frame: target)
        }
        // Back in as the browser, over the stand-in as it settles
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.3 : 0.6)) { [weak self, weak window] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window?.animator().alphaValue = 1
            }
            self?.morph?.fadeOut(duration: 0.3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.65 : 1)) { [weak self] in
            self?.didFinish()
        }
    }

    /// Hidden, the window takes the browser's frame, once, and shows the
    /// browser in it
    private func becomeBrowser(_ window: NSWindow, session: BrowserWindowSession, frame: CGRect) {
        windowSettings?.restore(on: window)
        windowSettings = nil
        Self.setButtons(of: window, hidden: false)
        session.layoutView?.alphaValue = 1
        window.setFrame(frame, display: true)
    }

    /// The window is the browser's now: it opens the palette for a first
    /// tab, as a new window does, and the extensions chosen are added, each
    /// asking first.
    private func didFinish() {
        guard let session, phase == .finishing else { return }
        morph?.close()
        morph = nil
        stopObservingClose()
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        self.session = nil
        phase = .preparing
        session.tabManager.checkAndAutoShowCommandPalette()
        setup.finish()
    }

    /// Closed before it's done (⇧⌘W): the setup waits for the next window
    private func windowWillClose() {
        morph?.close()
        morph = nil
        atmosphere?.dismiss()
        atmosphere = nil
        windowSettings = nil
        stopObservingClose()
        session = nil
        phase = .preparing
    }

    private func stopObservingClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: - Window

    /// A new window's size around the setup's center, on its screen
    private static func browserFrame(around frame: CGRect, on screen: NSScreen?) -> CGRect {
        guard let visible = screen?.visibleFrame else {
            return CGRect(x: frame.midX - browserSize.width / 2, y: frame.midY - browserSize.height / 2,
                          width: browserSize.width, height: browserSize.height)
        }
        let width = min(browserSize.width, visible.width - screenMargin * 2)
        let height = min(browserSize.height, visible.height - screenMargin * 2)
        let x = min(max(frame.midX - width / 2, visible.minX + screenMargin), visible.maxX - screenMargin - width)
        let y = min(max(frame.midY - height / 2, visible.minY + screenMargin), visible.maxY - screenMargin - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private static func setButtons(of window: NSWindow, hidden: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
    }

    /// What the setup changes on its window, given back as it grows
    private struct WindowSettings {
        let minSize: NSSize
        let maxSize: NSSize
        let isMovable: Bool
        let collectionBehavior: NSWindow.CollectionBehavior

        init(of window: NSWindow) {
            minSize = window.minSize
            maxSize = window.maxSize
            isMovable = window.isMovable
            collectionBehavior = window.collectionBehavior
        }

        func restore(on window: NSWindow) {
            window.minSize = minSize
            window.maxSize = maxSize
            window.isMovable = isMovable
            window.collectionBehavior = collectionBehavior
        }
    }
}

/// A stand-in of a window's shape, springing from one frame to another on
/// the render server, in a click-through window of its own just below the
/// window it stands in for: nothing per frame on the main thread, which
/// is busy laying out the real window meanwhile.
private final class WindowMorph {
    private let overlay: NSWindow
    private let shape = CALayer()
    private let screenFrame: CGRect

    init(from origin: CGRect, to target: CGRect, below window: NSWindow) {
        screenFrame = (window.screen ?? NSScreen.main)?.frame ?? origin.union(target)
        overlay = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        overlay.isExcludedFromWindowsMenu = true
        overlay.animationBehavior = .none
        let root = CALayer()
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        // Layer-hosting: AppKit leaves the layer be
        view.layer = root
        view.wantsLayer = true
        overlay.contentView = view

        // The window's look: its background, hairline edge, corners and shadow
        var fill = CGColor(gray: 0.2, alpha: 1)
        var edge = CGColor(gray: 0.5, alpha: 0.2)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.windowBackgroundColor.cgColor
            edge = NSColor.separatorColor.cgColor
        }
        let radius = Self.cornerRadius(of: window)
        shape.backgroundColor = fill
        shape.borderColor = edge
        shape.borderWidth = 0.5
        shape.cornerRadius = radius
        shape.cornerCurve = .continuous
        shape.shadowColor = CGColor(gray: 0, alpha: 1)
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 28
        shape.shadowOffset = CGSize(width: 0, height: -14)
        root.addSublayer(shape)

        let start = origin.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let end = target.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        func outline(_ size: CGSize) -> CGPath {
            CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = end
        shape.shadowPath = outline(end.size)
        CATransaction.commit()

        let changes: [(String, Any, Any)] = [
            ("bounds", NSValue(rect: CGRect(origin: .zero, size: start.size)), NSValue(rect: CGRect(origin: .zero, size: end.size))),
            ("position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: CGPoint(x: end.midX, y: end.midY))),
            ("shadowPath", outline(start.size), outline(end.size)),
        ]
        for (keyPath, from, to) in changes {
            let spring = CASpringAnimation(perceptualDuration: 0.8, bounce: 0.12)
            spring.keyPath = keyPath
            spring.fromValue = from
            spring.toValue = to
            spring.duration = spring.settlingDuration
            shape.add(spring, forKey: keyPath)
        }
        overlay.order(.below, relativeTo: window.windowNumber)
    }

    /// Where it is now, on screen
    var currentFrame: CGRect {
        (shape.presentation() ?? shape).frame.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
    }

    func fadeOut(duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.opacity = 0
        CATransaction.commit()
        shape.add(fade, forKey: "fade")
    }

    func close() {
        overlay.close()
    }

    /// The window's own corner radius, as macOS draws it
    private static func cornerRadius(of window: NSWindow) -> CGFloat {
        guard window.responds(to: NSSelectorFromString("_cornerRadius")),
              let radius = window.value(forKey: "_cornerRadius") as? NSNumber,
              radius.doubleValue > 0 else { return WindowState.defaultCornerRadius }
        return CGFloat(radius.doubleValue)
    }
}
