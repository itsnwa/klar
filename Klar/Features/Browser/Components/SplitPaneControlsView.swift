import AppKit

/// The top of a pane of the split view on screen. Hovered, it shows a handle
/// at its center, which drags the pane elsewhere in the split view, and a
/// button on its right, which takes it out of the split view. Its clicks go
/// through to the page everywhere else.
///
/// In the pane's own view (`WebViewContainerView`, `EmptyPaneTargetView`)
/// rather than over it in SwiftUI, so the page under it still gets its
/// clicks: SwiftUI would take them all.
final class SplitPaneControlsView: NSView, NSDraggingSource {
    static let height: CGFloat = 50
    /// A pane being dragged, by its tab's ID. Only the split view's panes
    /// take it.
    static let pasteboardType = NSPasteboard.PasteboardType("com.itsnwa.browser.split-pane")

    private static let inset: CGFloat = 8
    fileprivate static let dragThreshold: CGFloat = 3

    var tabID: UUID?
    weak var tabManager: TabManager?

    private var isHovering = false
    /// Glass, so only there while they show (see CLAUDE.md, Liquid Glass)
    private var handle: SplitPaneControl?
    private var closeButton: SplitPaneControl?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// Along the top of `container`
    func placeAtTop(of container: NSView) {
        let frame = CGRect(x: 0, y: container.isFlipped ? 0 : container.bounds.height - Self.height,
                           width: container.bounds.width, height: Self.height)
        if self.frame != frame {
            self.frame = frame
            layoutControls()
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovering(false)
    }

    /// The handle and the close button take their clicks; the rest go
    /// through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
            showControls()
        } else {
            hideControls()
        }
    }

    private func showControls() {
        let handle = handle ?? makeControl(symbol: "ellipsis", size: CGSize(width: 40, height: 22),
                                           help: "Drag to move this pane")
        handle.onDrag = { [weak self] event in self?.beginDrag(with: event) }
        self.handle = handle
        let closeButton = closeButton ?? makeControl(symbol: "xmark", size: CGSize(width: 26, height: 26),
                                                     help: "Remove from Split View")
        closeButton.onClick = { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.tabManager?.leaveSplitView(tabID)
        }
        self.closeButton = closeButton
        tintControls()
        layoutControls()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            handle.animator().alphaValue = 1
            closeButton.animator().alphaValue = 1
        }
    }

    private func hideControls() {
        let controls = [handle, closeButton].compactMap { $0 }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            controls.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isHovering else { return }
                self.handle?.removeFromSuperview()
                self.closeButton?.removeFromSuperview()
                self.handle = nil
                self.closeButton = nil
            }
        })
    }

    /// Glass in the window's space's color, as the command palette and Find
    /// have it (`SpaceGlass`). Each hover makes them again, so a space
    /// switched meanwhile shows the next time.
    private func tintControls() {
        let tint = SpaceGlassTint.nsColor(tabManager?.spaceSelection?.activeSpace?.color, in: effectiveAppearance)
        handle?.glassTint = tint
        closeButton?.glassTint = tint
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintControls()
    }

    private func makeControl(symbol: String, size: CGSize, help: String) -> SplitPaneControl {
        let control = SplitPaneControl(symbol: symbol, size: size)
        control.toolTip = help
        control.alphaValue = 0
        addSubview(control)
        return control
    }

    /// The handle at the top center, the close button at the top right,
    /// their centers level
    private func layoutControls() {
        let centerY = Self.inset + 13
        if let closeButton {
            let size = closeButton.frame.size
            closeButton.setFrameOrigin(CGPoint(x: bounds.width - Self.inset - size.width, y: centerY - size.height / 2))
        }
        if let handle {
            let size = handle.frame.size
            handle.setFrameOrigin(CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: centerY - size.height / 2))
        }
    }

    // MARK: - Dragging the pane

    /// The pane, as the tab's row: what dropping it beside another pane
    /// moves there (`TabManager.performSplitDrop`)
    private func beginDrag(with event: NSEvent) {
        // A locked private tab's pane stays put, as its row does
        guard let tabID, let tab = tabManager?.tabs.first(where: { $0.id == tabID }), !tab.isLocked else { return }
        let item = NSPasteboardItem()
        item.setString(tabID.uuidString, forType: Self.pasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)

        let width: CGFloat = 240
        let height = SidebarLayoutMetrics.standardRowHeight
        let pointer = convert(event.locationInWindow, from: nil)
        dragItem.draggingFrame = CGRect(x: pointer.x - SidebarTabRowView.faviconCenterX, y: (pointer.y - height / 2).rounded(),
                                        width: width, height: height)
        let components = SidebarTabRowView.draggingImageComponents(
            title: tab.title, icon: tab.favicon, width: width, appearance: effectiveAppearance
        )
        dragItem.imageComponentsProvider = { components }
        beginDraggingSession(with: [dragItem], event: event, source: self)
        setHovering(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Let go where no pane takes it
        tabManager?.splitViews.setDropTarget(nil)
    }
}

/// A glass control over a pane: the handle, dragged, or the close button,
/// clicked
private final class SplitPaneControl: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?

    var glassTint: NSColor? {
        get { glass.tintColor }
        set { glass.tintColor = newValue }
    }

    private let glass = NSGlassEffectView()
    private let imageView = NSImageView()
    private var mouseDownLocation: CGPoint?

    init(symbol: String, size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        glass.frame = bounds
        glass.cornerRadius = min(size.width, size.height) / 2
        glass.autoresizingMask = [.width, .height]
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleNone
        imageView.frame = glass.bounds
        imageView.autoresizingMask = [.width, .height]
        glass.contentView = imageView
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The whole control, glass and symbol, is one target
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        imageView.alphaValue = 0.5
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let onDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= SplitPaneControlsView.dragThreshold else { return }
        mouseDownLocation = nil
        imageView.alphaValue = 1
        onDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        imageView.alphaValue = 1
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
