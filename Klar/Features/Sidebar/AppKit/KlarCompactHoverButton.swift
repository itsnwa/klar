import AppKit

/// AppKit equivalent of `KlarButton.compact` from the SwiftUI side: a
/// 16×16 image-only button that fades a rounded primary-tinted
/// background in on hover and out on exit, both over 0.15s.
///
/// Implemented as a layer-hosting `NSView` wrapper around an inner
/// `NSButton`. Subclassing `NSButton` directly doesn't work because
/// `NSButtonCell` fills the bezel area when it draws, which paints over
/// `layer.backgroundColor` and erases the rounded hover fill. Splitting
/// the bg into the wrapper's own layer keeps it untouched by the cell.
///
/// Caller is responsible for setting `image`, `target`, `action`,
/// `symbolConfiguration`, `contentTintColor`, and `toolTip` (forwarded
/// to the inner button via the property accessors below). The intrinsic
/// content size pins to 16×16.
final class KlarCompactHoverButton: NSView {
    private static let frameSize: CGFloat = 18
    private static let cornerRadius: CGFloat = 6
    private static let hoverFadeDuration: CFTimeInterval = 0.15
    private static let hoverFillAlpha: CGFloat = 0.1

    private let button = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHoveringInternal: Bool = false

    // MARK: - Pass-through API

    var image: NSImage? {
        get { button.image }
        set { button.image = newValue }
    }
    var symbolConfiguration: NSImage.SymbolConfiguration? {
        get { button.symbolConfiguration }
        set { button.symbolConfiguration = newValue }
    }
    var contentTintColor: NSColor? {
        get { button.contentTintColor }
        set { button.contentTintColor = newValue }
    }
    weak var target: AnyObject? {
        get { button.target }
        set { button.target = newValue }
    }
    var action: Selector? {
        get { button.action }
        set { button.action = newValue }
    }
    override var toolTip: String? {
        get { button.toolTip }
        set { button.toolTip = newValue }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Layer-hosting: we own the layer entirely so the rounded
        // background paint can't be clobbered by NSButtonCell.
        let bg = CALayer()
        bg.cornerRadius = Self.cornerRadius
        bg.cornerCurve = .continuous
        bg.backgroundColor = NSColor.clear.cgColor
        bg.actions = [
            "backgroundColor": NSNull(),
            "cornerRadius": NSNull()
        ]
        layer = bg
        wantsLayer = true

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.frameSize, height: Self.frameSize)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHoveringInternal else { return }
        isHoveringInternal = true
        animateHoverBackground(to: NSColor.labelColor.withAlphaComponent(Self.hoverFillAlpha).cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHoveringInternal else { return }
        isHoveringInternal = false
        animateHoverBackground(to: NSColor.clear.cgColor)
    }

    private func animateHoverBackground(to color: CGColor) {
        guard let layer = layer else { return }
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        anim.toValue = color
        anim.duration = Self.hoverFadeDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.backgroundColor = color
        layer.add(anim, forKey: "backgroundColor")
    }
}
