import AppKit

/// The line between a space's saved tabs and its regular tabs. Hovered, with
/// regular tabs below, it makes room at its right for Close All, which
/// closes them, the ones in groups too. Its row covers the
/// spacing above and below the line, so there's something to hover.
final class SidebarDividerView: NSView {
    /// Close All was clicked.
    var onCloseAll: (() -> Void)?

    /// Whether there are regular tabs to close: without, hovering shows
    /// the line alone.
    var canCloseAll = false {
        didSet {
            guard canCloseAll != oldValue else { return }
            updateShowsButton()
        }
    }

    private static let buttonGap: CGFloat = 10

    private let lineView: NSBox = {
        let box = NSBox()
        box.boxType = .separator
        return box
    }()
    private let closeAllButton = SidebarCloseAllButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            updateShowsButton()
        }
    }
    private var showsButton = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        lineView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(lineView)
        closeAllButton.translatesAutoresizingMaskIntoConstraints = true
        closeAllButton.alphaValue = 0
        closeAllButton.isHidden = true
        closeAllButton.action = { [weak self] in
            self?.onCloseAll?()
        }
        addSubview(closeAllButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layoutContents(animated: false)
    }

    /// The list sets its frame directly, which doesn't always ask for a
    /// layout pass
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContents(animated: false)
    }

    /// The line's end before Close All while it shows, else the row's
    private func layoutContents(animated: Bool) {
        let lineY = ((bounds.height - 1) / 2).rounded(.down)
        let buttonSize = closeAllButton.preferredSize
        let buttonFrame = CGRect(
            x: bounds.maxX - buttonSize.width,
            y: ((bounds.height - buttonSize.height) / 2).rounded(),
            width: buttonSize.width,
            height: buttonSize.height
        )
        closeAllButton.frame = buttonFrame
        let lineWidth = showsButton ? max(0, buttonFrame.minX - Self.buttonGap) : bounds.width
        let lineFrame = CGRect(x: 0, y: lineY, width: lineWidth, height: 1)
        if animated {
            lineView.animator().frame = lineFrame
        } else {
            lineView.frame = lineFrame
        }
    }

    private func updateShowsButton() {
        let shows = isHovering && canCloseAll
        guard shows != showsButton else { return }
        showsButton = shows
        if shows {
            closeAllButton.isHidden = false
        } else {
            closeAllButton.setHovered(false)
        }
        let animates = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animates ? 0.15 : 0
            closeAllButton.animator().alphaValue = shows ? 1 : 0
            layoutContents(animated: animates)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.showsButton else { return }
                self.closeAllButton.isHidden = true
            }
        })
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovering = false }
    }
}

/// Close All: text that lightens under the pointer and acts when let go
/// over it.
private final class SidebarCloseAllButton: NSView {
    var action: (() -> Void)?

    private let label = NSTextField(labelWithString: "Close All")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateColor() }
    }
    private var isPressed = false {
        didSet { updateColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        addSubview(label)
        toolTip = "Close the tabs below"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Its label's size, with a little more to click on its left. Laid out
    /// by frame, since the divider sets its frame directly (starting at
    /// zero), which constraints inside would conflict with.
    var preferredSize: CGSize {
        let size = label.intrinsicContentSize
        return CGSize(width: ceil(size.width) + Self.leadingInset, height: ceil(size.height))
    }

    private static let leadingInset: CGFloat = 4

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        label.frame = CGRect(x: Self.leadingInset, y: 0,
                             width: max(0, bounds.width - Self.leadingInset), height: bounds.height)
    }

    func setHovered(_ hovered: Bool) {
        if isHovered != hovered { isHovered = hovered }
    }

    private func updateColor() {
        label.textColor = isPressed ? .labelColor : isHovered ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if isPressed != inside { isPressed = inside }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { action?() }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Close All" }
    override func accessibilityHelp() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}
