import AppKit

/// Header row shown above the outline (e.g. "Personal"). Matches the
/// SwiftUI `collectionHeader` from the original sidebar:
///   * Chevron on the left, sized so the title aligns with tab and folder
///     titles below (chevron lives in a 22pt slot identical to the
///     favicon slot in `SidebarTabRowView`).
///   * Title in mixed case, 14pt regular.
///   * Ellipsis menu on the right, revealed on hover, to access "Rename
///     Collection" / "New Folder" without right-clicking.
final class SidebarCollectionHeaderView: NSView, NSTextFieldDelegate {
    private let chevronSlot = NSView()
    private let chevronView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let menuButton = KlarCompactHoverButton()
    private var trackingArea: NSTrackingArea?

    var representedCollectionID: UUID?
    weak var sidebarManager: SidebarManager?

    private var rawTitle: String = ""
    private var preEditTitle: String = ""
    private var renamingNow: Bool = false
    private var isHovering: Bool = false

    private(set) var isExpanded: Bool = true

    var onToggle: (() -> Void)?
    /// Builds the same menu the right-click context-menu factory does.
    /// Wired up by the rows view so the factory keeps owning all menu
    /// construction in one place.
    var menuProvider: (() -> NSMenu?)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureSubviews() {
        chevronSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronSlot)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleProportionallyUpOrDown
        chevronView.contentTintColor = .secondaryLabelColor
        // SF Symbols renders `chevron.right` at noticeably larger optical
        // size than `chevron.down` for the same point size — use the same
        // glyph and rotate it 90° on the layer when collapsed.
        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        chevronSlot.addSubview(chevronView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // As New Tab's
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.cell?.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.focusRingType = .none
        titleField.delegate = self
        addSubview(titleField)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Collection menu")
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.isHidden = true
        addSubview(menuButton)

        // Short of required: the header starts out 0 pt wide, until the
        // list lays it out, and the button can't fit there.
        let menuButtonTrailing = menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        menuButtonTrailing.priority = .init(999)

        NSLayoutConstraint.activate([
            chevronSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevronSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronSlot.widthAnchor.constraint(equalToConstant: 22),
            chevronSlot.heightAnchor.constraint(equalToConstant: 22),

            chevronView.centerXAnchor.constraint(equalTo: chevronSlot.centerXAnchor),
            chevronView.centerYAnchor.constraint(equalTo: chevronSlot.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            titleField.leadingAnchor.constraint(equalTo: chevronSlot.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -8),

            menuButtonTrailing,
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 18),
            menuButton.heightAnchor.constraint(equalToConstant: 18),

            heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    func setTitle(_ title: String) {
        rawTitle = title
        // Every reload of the rows comes here (a tab opening, iCloud), also
        // while the name is being typed: that isn't replaced, as with a tab's
        // or a folder's. Once renaming ends, the field shows `rawTitle`.
        guard !renamingNow else { return }
        titleField.stringValue = title
    }

    func setRenaming(_ renaming: Bool) {
        if renaming {
            if !renamingNow {
                renamingNow = true
                titleField.stringValue = rawTitle
                preEditTitle = rawTitle
                titleField.isEditable = true
                titleField.isSelectable = true
                DispatchQueue.main.async { [weak titleField] in
                    titleField?.selectText(nil)
                }
            }
        } else {
            renamingNow = false
            titleField.isEditable = false
            titleField.isSelectable = false
            titleField.stringValue = rawTitle
        }
    }

    /// Points the chevron down (expanded) or right (collapsed). Animated, it
    /// turns with the rows' expand/collapse.
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        chevronView.wantsLayer = true
        guard let layer = chevronView.layer else { return }
        let target: CGFloat = expanded ? 0 : .pi / 2  // CCW 90° → chevron.right
        let current = layer.presentation()?.transform ?? layer.transform
        let currentAngle = atan2(current.m12, current.m11)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = Self.chevronTransform(angle: target)
        CATransaction.commit()
        guard animated else {
            layer.removeAnimation(forKey: Self.chevronAnimationKey)
            return
        }
        // Keyframes rather than one from/to transform: Core Animation
        // interpolates a transform's translation linearly, so a rotation
        // about the center would wobble off-center mid-turn.
        let steps = 12
        let rotation = CAKeyframeAnimation(keyPath: "transform")
        rotation.values = (0...steps).map { step -> NSValue in
            let angle = currentAngle + (target - currentAngle) * CGFloat(step) / CGFloat(steps)
            return NSValue(caTransform3D: Self.chevronTransform(angle: angle))
        }
        rotation.duration = SidebarMotion.perceptualDuration
        rotation.timingFunction = SidebarMotion.easeOut
        layer.add(rotation, forKey: Self.chevronAnimationKey)
    }

    private static let chevronAnimationKey = "chevronRotation"

    /// Rotation by `angle` about the chevron's center. A layer transform
    /// (rather than `frameCenterRotation`, which shifts the bounding box on
    /// every AutoLayout pass) composed as translate-rotate-translate, because
    /// anchor-point tweaks get clobbered by AutoLayout's frame updates.
    private static func chevronTransform(angle: CGFloat) -> CATransform3D {
        let center: CGFloat = 6  // chevronView is 12x12 (constraint)
        var transform = CATransform3DMakeTranslation(center, center, 0)
        transform = CATransform3DRotate(transform, angle, 0, 0, 1)
        return CATransform3DTranslate(transform, -center, -center, 0)
    }

    override func mouseDown(with event: NSEvent) {
        if titleField.isEditable {
            super.mouseDown(with: event)
            return
        }
        // Toggle only when the click landed on the chevron / title area —
        // not on the ellipsis menu button.
        let pt = convert(event.locationInWindow, from: nil)
        if menuButton.frame.contains(pt) {
            super.mouseDown(with: event)
            return
        }
        onToggle?()
    }

    @objc private func showMenu() {
        guard let menu = menuProvider?() else { return }
        // Anchor the popup just below the ellipsis button.
        let origin = NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: menuButton)
    }

    // MARK: - Hover (reveal/hide menu button)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
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

    override func mouseEntered(with event: NSEvent) {
        if !isHovering {
            isHovering = true
            menuButton.isHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isHovering {
            isHovering = false
            menuButton.isHidden = true
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.stringValue = preEditTitle
            sidebarManager?.isRenaming = nil
            setRenaming(false)
            window?.makeFirstResponder(window)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let collectionID = representedCollectionID, titleField.isEditable else { return }
        let textMovementRaw = obj.userInfo?["NSTextMovement"] as? Int
        if textMovementRaw == NSTextMovement.cancel.rawValue {
            // Already reverted by the doCommand path.
        } else {
            let newValue = titleField.stringValue
            sidebarManager?.updateCustomTitle(for: collectionID, title: newValue)
            rawTitle = newValue
        }
        sidebarManager?.isRenaming = nil
        setRenaming(false)
    }
}
