import Foundation
import AppKit
import WebKit

/// Custom NSView container that uses frame-based layout instead of autolayout
/// to avoid conflicts with WKWebView's web inspector when docked
final class WebViewContainerView: NSView {
  private let webView: WKWebView

  /// Each tab's container, by its web view, for while that's out of the window.
  private static let containers = NSMapTable<WKWebView, WebViewContainerView>.weakToWeakObjects()

  /// The container a tab's web view belongs in, whether or not it's in it.
  static func container(of webView: WKWebView) -> WebViewContainerView? {
    containers.object(forKey: webView)
  }

  init(webView: WKWebView) {
    self.webView = webView
    super.init(frame: .zero)
    Self.containers.setObject(self, forKey: webView)
    setupWebView()
  }

  private var isActive = false
  private var keepsWebViewInWindow = false
  /// The view this background tab's web view is lent to — the Now Playing
  /// preview, which shows its video live. It stays there until it's given
  /// back or the tab is shown.
  private weak var borrower: NSView?

  /// The tabs on screen, in every window: the active one, or the panes of
  /// its split view. Once others are shown in a window, its shown ones stay
  /// there until those have drawn.
  private static let shown = NSHashTable<WebViewContainerView>.weakObjects()
  /// The tabs taking the place of those in `shown`, until they've drawn.
  private static let incoming = NSHashTable<WebViewContainerView>.weakObjects()
  /// Tells a reveal apart from the ones of earlier times this tab was shown.
  private var showCount = 0

  /// Shows the tab (on screen: the active tab, or a pane of its split view)
  /// or hides it. A hidden tab's web view leaves the window unless
  /// `keepsWebViewInWindow`: in a window, even hidden, WebKit keeps the
  /// page's rendered layers ready to show (about 20 MB a tab at 1200×800);
  /// out of it, the system may reclaim them.
  func setActive(_ isActive: Bool, keepsWebViewInWindow: Bool) {
    let wasActive = self.isActive
    self.isActive = isActive
    self.keepsWebViewInWindow = keepsWebViewInWindow
    if isActive {
      borrower = nil
    }
    if borrower == nil, isActive || keepsWebViewInWindow {
      addWebViewIfNeeded()
    }
    if isActive {
      if !wasActive {
        show()
      }
    } else if Self.shown.contains(self) || Self.incoming.contains(self) {
      // A tab on screen stays until those taking its place have drawn.
      if Self.incoming.contains(self) {
        Self.incoming.remove(self)
        hide()
      }
      Self.hideShownUnlessReplaced(in: window)
    } else {
      hide()
    }
  }

  /// A web view coming back to the window may have lost its rendered layers
  /// (see setActive), and until WebKit draws it again it's blank: white,
  /// even in dark mode, for as long as the main thread is busy switching
  /// (a space's sidebar, say). So it joins the window transparent, and the
  /// tabs on screen stay there until it has drawn: those it replaces, or
  /// the panes it joins.
  private func show() {
    isHidden = false
    guard let window, Self.shown.allObjects.contains(where: { $0 !== self && $0.window === window }) else {
      reveal()
      return
    }
    alphaValue = 0
    Self.incoming.add(self)
    showCount += 1
    let showCount = showCount
    let revealIfStillShowing: @MainActor () -> Void = { [weak self] in
      guard let self, self.isActive, self.showCount == showCount, self.alphaValue == 0 else { return }
      self.reveal()
    }
    guard webView.doAfterNextPresentationUpdate(revealIfStillShowing) else {
      reveal()
      return
    }
    // In case WebKit has nothing to draw for it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: revealIfStillShowing)
  }

  private func reveal() {
    alphaValue = 1
    Self.shown.add(self)
    Self.incoming.remove(self)
    Self.hideReplacedOnceDrawn(in: window)
  }

  private func hide() {
    isHidden = true
    alphaValue = 0
    if borrower == nil, !isActive, !keepsWebViewInWindow, webView.superview === self {
      webView.removeFromSuperview()
    }
  }

  /// Once every tab coming on screen in a window has drawn, the ones they
  /// replace there go.
  private static func hideReplacedOnceDrawn(in window: NSWindow?) {
    guard !incoming.allObjects.contains(where: { $0.window === window }) else { return }
    for container in shown.allObjects where !container.isActive && container.window === window {
      shown.remove(container)
      container.hide()
    }
  }

  /// No tab took a shown one's place (a space with none open), or the one
  /// taking it went too: the shown ones go once SwiftUI has updated the
  /// other tabs too.
  private static func hideShownUnlessReplaced(in window: NSWindow?) {
    DispatchQueue.main.async { [weak window] in
      hideReplacedOnceDrawn(in: window)
    }
  }

  /// Lends this background tab's web view to `host`, which adds it as its
  /// subview. The web view keeps its size, so the page doesn't lay out
  /// again. Nil for the active tab.
  func lendWebView(to host: NSView) -> WKWebView? {
    guard !isActive else { return nil }
    // Still on screen for the tabs taking its place: those show now.
    if Self.shown.contains(self) {
      Self.incoming.allObjects.filter { $0.window === window }.forEach { $0.reveal() }
    }
    borrower = host
    return webView
  }

  /// Takes the web view back from `host` (from whoever has it, if nil), and
  /// puts it where `setActive` last left it.
  func reclaimWebView(from host: NSView? = nil) {
    guard let borrower, host == nil || borrower === host else { return }
    self.borrower = nil
    if webView.superview === borrower {
      webView.removeFromSuperview()
    }
    if isActive || keepsWebViewInWindow {
      addWebViewIfNeeded()
    }
  }

  /// A pane of the split view on screen: its handle and close button, over
  /// the top of the page
  private var paneControls: SplitPaneControlsView?

  /// Shows the pane controls for the tab, or none (nil)
  func setPaneControls(tabID: UUID?, tabManager: TabManager) {
    guard let tabID else {
      paneControls?.removeFromSuperview()
      paneControls = nil
      return
    }
    let controls = paneControls ?? SplitPaneControlsView()
    if paneControls == nil {
      // Above the web view, which is added below everything
      addSubview(controls)
      paneControls = controls
    }
    controls.tabID = tabID
    controls.tabManager = tabManager
    controls.placeAtTop(of: self)
  }

  /// Rounded as a pane of a split view, which the content area's shape
  /// doesn't clip on its own; square (0) otherwise
  func setCornerRadius(_ radius: CGFloat) {
    guard let layer, layer.cornerRadius != radius else { return }
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    layer.masksToBounds = radius > 0
  }

  private func addWebViewIfNeeded() {
    guard webView.superview !== self else { return }
    // Laid out for the tab's current size in one step, as on unhiding.
    sizeBeforeHiding = nil
    webView.frame = bounds
    addSubview(webView, positioned: .below, relativeTo: nil)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupWebView() {
    // Enable layer-backed rendering for smooth resizing performance
    wantsLayer = true
    autoresizesSubviews = true
    
    // Optimize layer redraw policy for better resize performance
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    
    // Disable autolayout for the WebView to avoid conflicts with inspector
    webView.translatesAutoresizingMaskIntoConstraints = true
    
    // Configure autoresizing mask to fill the container - let AppKit handle the layout
    webView.autoresizingMask = [.width, .height]
    
    // Add to container
    addSubview(webView)
    
    // Set initial frame - autoresizing mask will handle future updates
    webView.frame = bounds
  }
  
  
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    
    // Ensure layer configuration is applied after view hierarchy is established
    if superview != nil && wantsLayer {
      layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
  }
  
  /// The size the subviews were last laid out for, while this (background)
  /// tab is hidden. Resizing a hidden web view makes its page lay out again
  /// for nothing — on every window resize, and on every frame of the
  /// sidebar sliding in or out — so it catches up in one step when shown.
  private var sizeBeforeHiding: NSSize?

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    paneControls?.placeAtTop(of: self)
    // A background tab's web view, out of the window, gets the tab's size
    // once, so a page opened in the background loads for it. After that it
    // catches up when it's added back.
    if webView.superview !== self {
      if webView.frame.isEmpty {
        webView.frame = bounds
      }
      return
    }
    // The first real layout (from zero) always goes through.
    if isHidden, oldSize.width > 0, oldSize.height > 0 {
      if sizeBeforeHiding == nil {
        sizeBeforeHiding = oldSize
      }
      return
    }
    // Let autoresizing mask handle the frame updates automatically
    super.resizeSubviews(withOldSize: oldSize)
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    guard let oldSize = sizeBeforeHiding else { return }
    sizeBeforeHiding = nil
    if oldSize != bounds.size {
      // Autoresizing applies the whole change at once (and a docked
      // inspector re-lays itself out from the web view's new frame).
      super.resizeSubviews(withOldSize: oldSize)
    }
  }

  override var acceptsFirstResponder: Bool {
    return false // Let the WebView handle first responder
  }
  
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return webView.acceptsFirstMouse(for: event)
  }
  
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Use normal hit testing - no overlay interception
    return super.hitTest(point)
  }
  
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
  }
  
  override func mouseDragged(with event: NSEvent) {
    super.mouseDragged(with: event)
  }
  
  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
  }
  
}

extension WKWebView {
  /// The window for this page's sheets and popups. A background tab's web
  /// view is out of the window (WebViewContainerView.setActive), so for it
  /// that's the window the tab is in.
  var presentationWindow: NSWindow? {
    window ?? WebViewContainerView.container(of: self)?.window
  }

  /// Whether this is a private tab's page (or a popup of one): they share a
  /// data store that keeps nothing.
  var isPrivateBrowsing: Bool {
    !configuration.websiteDataStore.isPersistent
  }

  /// Runs `body` once the page's next drawing is on screen. Private
  /// (`_doAfterNextPresentationUpdate:`); false, without running it, if
  /// it's not there.
  func doAfterNextPresentationUpdate(_ body: @escaping () -> Void) -> Bool {
    let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
    // A block argument, which perform(_:with:) doesn't pass as one: call
    // the method's implementation as a C function. WebKit keeps the block
    // until then, so it's escaping (a non-escaping one traps once it has).
    typealias DoAfterIMP = @convention(c) (NSObject, Selector, @escaping @convention(block) () -> Void) -> Void
    guard responds(to: selector), let implementation = method(for: selector) else { return false }
    let doAfter = unsafeBitCast(implementation, to: DoAfterIMP.self)
    doAfter(self, selector, body)
    return true
  }
}
