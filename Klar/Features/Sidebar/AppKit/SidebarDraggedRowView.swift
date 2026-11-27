import AppKit
import SwiftUI

/// The row being dragged from the list, as the list draws it for the whole
/// drag in place of AppKit's image of it (hidden, `SidebarDragImageWindow`):
/// the row itself, live, in a window of its own (`SidebarDragPanel`), so it
/// shows anywhere, past Klar's window and over other apps. As it takes the
/// indent a drop would land at, it narrows on a spring, frame by frame, its
/// title truncating as it goes. Over the pinned sites, it turns into the
/// tile it would be there; out of the sidebar, a tab turns into a link: a
/// card with the page above the row, its address under the title; and over
/// the window's pages, where it'd go into a split view, the page alone.
final class SidebarDraggedRowView: NSView {
    /// A tab's or a folder's row view, configured as the row picked up,
    /// `layoutRow`.
    let row: NSView
    let layoutRow: SidebarRow
    /// Where the pointer holds it.
    let grabOffset: CGPoint
    private var inset: SpringValue
    private var displayLink: CADisplayLink?
    private static let spring = Spring(duration: SidebarMotion.perceptualDuration, bounce: 0)
    /// Close enough to the indent to stop, in points
    private static let settledInset = 0.05

    /// What it shows as, beside the row.
    enum Shape {
        case row
        /// A pinned site's tile, centered under the pointer.
        case tile(Tile)
        /// A link: the page above the row, `address` under its title.
        case link(address: String)
        /// Over the window's pages: the link's page alone, its row gone.
        case page
    }

    struct Tile {
        let size: CGSize
        let fill: CGColor
        let border: CGColor?
    }

    private(set) var shape: Shape = .row
    /// Counts changes of shape, so a finished one that's been overtaken
    /// leaves the parts alone.
    private var shapeChange = 0
    /// The page, at the top of the link's card. Until there's one, the
    /// tab's favicon.
    var thumbnail: NSImage? {
        didSet {
            thumbnailLayer.contents = thumbnail
            placeholderLayer.isHidden = thumbnail != nil
        }
    }
    /// The page's aspect in the link's card, height to width.
    static let thumbnailAspect: CGFloat = 10 / 16
    private static let cardPadding: CGFloat = 4
    /// How far up from the page's bottom the pointer is, over the pages:
    /// the page under the pointer's arrow
    private static let pagePointerInset: CGFloat = 24

    /// The fill, page and favicon that stand in for the row's as it changes
    /// shape, in a layer-hosting view under the row: flipped, as AppKit
    /// sets which way up its layer is from the view's.
    private let partsView = FlippedView()
    private let fillLayer = CALayer()
    private let thumbnailLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let iconLayer = CALayer()

    override var isFlipped: Bool { true }

    init(row: NSView, for layoutRow: SidebarRow, grabOffset: CGPoint) {
        self.row = row
        self.layoutRow = layoutRow
        self.grabOffset = grabOffset
        inset = SpringValue(Double(layoutRow.depth) * SidebarLayoutMetrics.depthIndent)
        super.init(frame: CGRect(origin: .zero, size: row.frame.size))
        wantsLayer = true

        let host = CALayer()
        partsView.layer = host
        partsView.wantsLayer = true
        partsView.frame = bounds
        partsView.autoresizingMask = [.width, .height]
        partsView.isHidden = true
        fillLayer.cornerRadius = 12
        fillLayer.cornerCurve = .continuous
        fillLayer.shadowColor = NSColor.black.cgColor
        fillLayer.shadowRadius = 12
        fillLayer.shadowOffset = CGSize(width: 0, height: 4)
        thumbnailLayer.cornerRadius = 12 - Self.cardPadding
        thumbnailLayer.cornerCurve = .continuous
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.contentsGravity = .resizeAspectFill
        placeholderLayer.contentsGravity = .resizeAspect
        FaviconStyle.clip(placeholderLayer)
        thumbnailLayer.addSublayer(placeholderLayer)
        iconLayer.contentsGravity = .resizeAspect
        FaviconStyle.clip(iconLayer)
        for layer in [fillLayer, thumbnailLayer, iconLayer] {
            host.addSublayer(layer)
        }
        addSubview(partsView)

        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        addSubview(row)
        // As it is when it's picked up, and opaque
        (row as? SidebarHoverable)?.setHovered(true)
        (row as? SidebarTabRowView)?.setDragged(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Not there for the pointer: a drop goes to what's under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Indent

    /// Indents it as deep as `depth`, from wherever it is.
    func setDepth(_ depth: Int) {
        let target = Double(depth) * SidebarLayoutMetrics.depthIndent
        guard target != inset.target else { return }
        let now = CACurrentMediaTime()
        if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inset.move(to: target, at: now, spring: Self.spring, epsilon: Self.settledInset)
        } else {
            inset.jump(to: target)
        }
        applyInset(at: now)
        if inset.isMoving(at: now), displayLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // A drag runs the run loop in the event-tracking mode.
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Lays the row out at the indent it has when this frame is on screen
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        applyInset(at: link.targetTimestamp)
        if !inset.isMoving(at: link.targetTimestamp) {
            stopDisplayLink()
        }
    }

    private func applyInset(at time: CFTimeInterval) {
        // On whole pixels, so the title doesn't shimmer as it goes
        let scale = window?.backingScaleFactor ?? 2
        let value = (CGFloat(inset.value(at: time, spring: Self.spring)) * scale).rounded() / scale
        switch row {
        case let tab as SidebarTabRowView: tab.applyLeadingInset(value)
        case let folder as SidebarFolderRowView: folder.applyLeadingInset(value)
        default: break
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        }
    }

    // MARK: - Shape

    /// Turns a tab's row into `newShape`: its fill and favicon move and
    /// resize into the tile's or the card's on a spring, the page grows in
    /// above it as a link, and the title and buttons fade out for a tile.
    func setShape(_ newShape: Shape) {
        guard let tabRow = row as? SidebarTabRowView, Self.kind(of: newShape) != Self.kind(of: shape) else { return }
        let oldShape = shape
        shape = newShape
        shapeChange += 1
        let change = shapeChange
        let parts = tabRow.dragParts()
        let animates = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .row = oldShape {
            // From the row's own
            fillLayer.frame = parts.fillFrame
            fillLayer.backgroundColor = parts.fill
            fillLayer.borderColor = parts.border?.color
            fillLayer.borderWidth = parts.border?.width ?? 0
            fillLayer.shadowOpacity = 0
            thumbnailLayer.frame = Self.collapsed(parts.fillFrame)
            thumbnailLayer.opacity = 0
            iconLayer.frame = parts.iconFrame
            iconLayer.contents = parts.icon
            iconLayer.isHidden = true
            partsView.isHidden = false
            tabRow.setFillHidden(true)
        }
        // Before the animations it waits for
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.shapeChange == change else { return }
            self.settle(tabRow)
        }
        switch newShape {
        case .tile(let tile):
            iconLayer.isHidden = false
            tabRow.setIconHidden(true)
            tabRow.setLinkAddress(nil)
            let frame = CGRect(x: (grabOffset.x - tile.size.width / 2).rounded(),
                               y: (grabOffset.y - tile.size.height / 2).rounded(),
                               width: tile.size.width, height: tile.size.height)
            let iconSize = PinnedSiteTileView.iconSize
            let iconFrame = CGRect(x: (frame.midX - iconSize / 2).rounded(), y: (frame.midY - iconSize / 2).rounded(),
                                   width: iconSize, height: iconSize)
            moveFill(to: frame, fill: tile.fill, border: tile.border, shadow: 0, animated: animates)
            move(thumbnailLayer, to: Self.collapsed(frame), opacity: 0, animated: animates)
            move(iconLayer, to: iconFrame, opacity: 1, animated: animates)
            fade(row, to: 0, animated: animates)
        case .link(let address):
            tabRow.setLinkAddress(address)
            let card = cardFrame(around: parts.fillFrame)
            showPage(placeholder: parts.icon)
            moveFill(to: card, fill: linkFill(), border: nil, shadow: 0.3, animated: animates)
            move(thumbnailLayer, to: thumbnailFrame(in: card), opacity: 1, animated: animates)
            move(iconLayer, to: parts.iconFrame, opacity: 1, animated: animates)
            fade(row, to: 1, animated: animates)
        case .page:
            // The row under it folding away, and down under the pointer
            let card = pageCardFrame(around: parts.fillFrame)
            showPage(placeholder: parts.icon)
            moveFill(to: card, fill: linkFill(), border: nil, shadow: 0.3, animated: animates)
            move(thumbnailLayer, to: thumbnailFrame(in: card), opacity: 1, animated: animates)
            move(iconLayer, to: parts.iconFrame, opacity: 0, animated: animates)
            fade(row, to: 0, animated: animates)
        case .row:
            tabRow.setLinkAddress(nil)
            moveFill(to: parts.fillFrame, fill: parts.fill, border: parts.border?.color,
                     borderWidth: parts.border?.width ?? 0, shadow: 0, animated: animates)
            move(thumbnailLayer, to: Self.collapsed(parts.fillFrame), opacity: 0, animated: animates)
            move(iconLayer, to: parts.iconFrame, opacity: 1, animated: animates)
            fade(row, to: 1, animated: animates)
        }
        CATransaction.commit()
    }

    /// Once a change has settled, the row's own fill and favicon take over
    /// again where the stand-ins ended up. At once: their layers are this
    /// view's own, whose default action for hiding is a fade, and the two
    /// fills cross-fading covered less than either does, the row flashing
    /// darker for a moment.
    private func settle(_ tabRow: SidebarTabRowView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch shape {
        case .tile, .page:
            break
        case .link:
            iconLayer.isHidden = true
            tabRow.setIconHidden(false)
        case .row:
            partsView.isHidden = true
            iconLayer.isHidden = true
            tabRow.setFillHidden(false)
            tabRow.setIconHidden(false)
        }
    }

    private static func kind(of shape: Shape) -> Int {
        switch shape {
        case .row: return 0
        case .tile: return 1
        case .link: return 2
        case .page: return 3
        }
    }

    /// The page in the card, the favicon in its place until there's one
    private func showPage(placeholder: NSImage?) {
        placeholderLayer.contents = placeholder
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumbnailLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    /// The link's card: the row's fill, grown up to hold the page.
    private func cardFrame(around fill: CGRect) -> CGRect {
        let padding = Self.cardPadding
        let pageHeight = ((fill.width - padding * 2) * Self.thumbnailAspect).rounded()
        return CGRect(x: fill.minX, y: fill.minY - pageHeight - padding,
                      width: fill.width, height: fill.height + pageHeight + padding)
    }

    /// The page alone: the link's card without the row at its bottom,
    /// moved down so it's under the pointer, a little way up from its bottom.
    private func pageCardFrame(around fill: CGRect) -> CGRect {
        let link = cardFrame(around: fill)
        let height = link.height - fill.height + Self.cardPadding
        return CGRect(x: link.minX, y: (grabOffset.y + Self.pagePointerInset - height).rounded(),
                      width: link.width, height: height)
    }

    private func thumbnailFrame(in card: CGRect) -> CGRect {
        let padding = Self.cardPadding
        let width = card.width - padding * 2
        return CGRect(x: card.minX + padding, y: card.minY + padding,
                      width: width, height: (width * Self.thumbnailAspect).rounded())
    }

    /// The page with no height, at the top of `frame`.
    private static func collapsed(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + cardPadding, y: frame.minY + cardPadding,
               width: max(0, frame.width - cardPadding * 2), height: 0)
    }

    /// Opaque, to stand out wherever it's dragged: the dragged row's own
    /// color, so turning into the card changes only its shape.
    private func linkFill() -> CGColor {
        var fill = SidebarTabRowView.draggedFill.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = SidebarTabRowView.draggedFill.cgColor
        }
        return fill
    }

    /// From where they are on screen: midway, where the last change has
    /// them; else where they were put.
    private func onScreen(_ layer: CALayer) -> CALayer {
        layer.animationKeys()?.isEmpty == false ? layer.presentation() ?? layer : layer
    }

    private func moveFill(to frame: CGRect, fill: CGColor, border: CGColor?,
                          borderWidth: CGFloat = PinnedSiteTileView.borderWidth, shadow: Float, animated: Bool) {
        let from = onScreen(fillLayer)
        let fromValues: [(String, Any?)] = [("bounds", NSValue(rect: from.bounds)), ("position", NSValue(point: from.position))]
        let fromFill = from.backgroundColor
        let fades: [(String, Any?)] = [("borderWidth", from.borderWidth), ("shadowOpacity", from.shadowOpacity)]
        fillLayer.frame = frame
        fillLayer.backgroundColor = fill
        fillLayer.borderColor = border ?? fillLayer.borderColor
        fillLayer.borderWidth = border == nil ? 0 : borderWidth
        fillLayer.shadowOpacity = shadow
        guard animated else { return }
        let colorFade = CAKeyframeAnimation(keyPath: "backgroundColor")
        colorFade.values = Self.crossFade(from: fromFill, to: fill)
        colorFade.duration = SidebarMotion.perceptualDuration
        colorFade.timingFunction = SidebarMotion.easeOut
        fillLayer.add(colorFade, forKey: "backgroundColor")
        for (keyPath, value) in fromValues {
            let spring = SidebarMotion.spring(keyPath: keyPath)
            spring.fromValue = value
            fillLayer.add(spring, forKey: keyPath)
        }
        for (keyPath, value) in fades {
            let fade = CABasicAnimation(keyPath: keyPath)
            fade.fromValue = value
            fade.duration = SidebarMotion.perceptualDuration
            fade.timingFunction = SidebarMotion.easeOut
            fillLayer.add(fade, forKey: keyPath)
        }
    }

    /// From one fill to another as if one faded out over the other. A plain
    /// color animation goes through a lighter or darker fill on the way
    /// between an opaque one and a faint one (the card and a row's): it
    /// moves the color while the opacity is still high. These steps are
    /// premultiplied, as the two would add up on screen.
    private static func crossFade(from: CGColor?, to: CGColor, steps: Int = 12) -> [CGColor] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [from ?? to, to] }
        func premultiplied(_ color: CGColor?) -> [CGFloat] {
            guard let components = color?.converted(to: space, intent: .defaultIntent, options: nil)?.components,
                  components.count == 4 else { return [0, 0, 0, 0] }
            let alpha = components[3]
            return [components[0] * alpha, components[1] * alpha, components[2] * alpha, alpha]
        }
        let start = premultiplied(from), end = premultiplied(to)
        return (0...steps).compactMap { step in
            let t = CGFloat(step) / CGFloat(steps)
            let value = zip(start, end).map { $0 + ($1 - $0) * t }
            let alpha = value[3]
            guard alpha > 0 else { return CGColor(colorSpace: space, components: [0, 0, 0, 0]) }
            return CGColor(colorSpace: space, components: [value[0] / alpha, value[1] / alpha, value[2] / alpha, alpha])
        }
    }

    private func move(_ layer: CALayer, to frame: CGRect, opacity: Float, animated: Bool) {
        let from = onScreen(layer)
        let fromBounds = from.bounds, fromPosition = from.position, fromOpacity = from.opacity
        layer.frame = frame
        layer.opacity = opacity
        if layer === thumbnailLayer {
            placeholderLayer.frame = Self.placeholderFrame(in: frame.size)
        }
        guard animated else { return }
        for (keyPath, value) in [("bounds", NSValue(rect: fromBounds)), ("position", NSValue(point: fromPosition))] {
            let spring = SidebarMotion.spring(keyPath: keyPath)
            spring.fromValue = value
            layer.add(spring, forKey: keyPath)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.duration = SidebarMotion.perceptualDuration
        fade.timingFunction = SidebarMotion.easeOut
        layer.add(fade, forKey: "opacity")
    }

    /// The favicon in the middle of the page's place, while there's no page.
    private static func placeholderFrame(in size: CGSize) -> CGRect {
        let side: CGFloat = 32
        return CGRect(x: ((size.width - side) / 2).rounded(), y: ((size.height - side) / 2).rounded(),
                      width: side, height: side)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func fade(_ view: NSView, to alpha: CGFloat, animated: Bool) {
        let from = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.alphaValue = alpha
        guard animated else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = Float(alpha)
        fade.duration = SidebarMotion.perceptualDuration * 0.6
        fade.timingFunction = SidebarMotion.easeOut
        view.layer?.add(fade, forKey: "opacity")
    }

    /// An address as a link shows it: without its scheme, "www." or a
    /// trailing slash.
    static func displayAddress(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        var address = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path
        if !path.isEmpty, path != "/" {
            address += path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return address
    }
}

/// The dragged row's window: see-through, click-through, and as big as the
/// screen the pointer is on, at the dragging level, like AppKit's own for a
/// drag's image.
final class SidebarDragPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        // Gone at once when the row lands: fading out, it ghosted over the
        // row taking its place in the list
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView?.wantsLayer = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Covers the screen `point` is on (screen coordinates).
    func cover(screenAt point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main,
              frame != screen.frame else { return }
        setFrame(screen.frame, display: false)
    }
}

/// AppKit draws a drag's image in a window of its own, which it puts up in
/// this process as the drag first moves, though not as an `NSWindow`. While
/// the list draws the dragged row itself, it hides that window with the
/// window server's private `SLSSetWindowAlpha`, as there's no public way to:
/// a new image (or none) cross-fades.
enum SidebarDragImageWindow {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetWindowAlpha = @convention(c) (Int32, CGWindowID, Float) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnectionID: MainConnectionID? = skyLight
        .flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: MainConnectionID.self) }
    private static let setWindowAlpha: SetWindowAlpha? = skyLight
        .flatMap { dlsym($0, "SLSSetWindowAlpha") }
        .map { unsafeBitCast($0, to: SetWindowAlpha.self) }

    /// The drag's window: this process's, at the dragging level, above
    /// `window`, other than `panel` (the dragged row's, at the same level).
    /// None before the drag first moves.
    static func find(above window: NSWindow, other panel: NSWindow?) -> CGWindowID? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let level = Int(CGWindowLevelForKey(.draggingWindow))
        let panelID = panel.map { CGWindowID($0.windowNumber) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber))
            as? [[String: Any]] ?? []
        let info = windows.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == level
                && $0[kCGWindowNumber as String] as? CGWindowID != panelID
        }
        return info?[kCGWindowNumber as String] as? CGWindowID
    }

    /// Whether it took.
    static func setHidden(_ hidden: Bool, _ windowID: CGWindowID) -> Bool {
        guard let mainConnectionID, let setWindowAlpha else { return false }
        return setWindowAlpha(mainConnectionID(), windowID, hidden ? 0 : 1) == 0
    }
}
