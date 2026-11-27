import AppKit

/// Custom AppKit equivalent of the SwiftUI `NewTabButton`: a plus-icon + "New
/// Tab" label row with a 12pt rounded hover background. Holding ⌥ over it
/// turns it into New Private Tab, as a click with ⌥ opens one.
final class SidebarNewTabButton: NSView {
    /// Called with whether the new tab is a private one.
    var actionHandler: ((_ isPrivate: Bool) -> Void)?

    private static let plusImage = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
    private static let privateImage = NSImage(systemSymbolName: "sunglasses.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))

    private let bgView = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "New Tab")
    private let optionHintField = NSTextField(labelWithString: "⌥")

    private var isHovering: Bool = false {
        didSet { updateHoverFill() }
    }
    private var isOptionHeld = false {
        didSet {
            guard isOptionHeld != oldValue else { return }
            updateContent()
        }
    }
    private var trackingArea: NSTrackingArea?
    /// Watches ⌥ while the pointer is over the row: modifier changes go to
    /// the key window's first responder, not the view under the pointer.
    private var flagsMonitor: Any?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
    }

    private func configureSubviews() {
        bgView.translatesAutoresizingMaskIntoConstraints = false
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 12
        bgView.layer?.backgroundColor = .clear
        addSubview(bgView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = .secondaryLabelColor
        iconView.image = Self.plusImage
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.cell?.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        optionHintField.translatesAutoresizingMaskIntoConstraints = false
        optionHintField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        optionHintField.textColor = .tertiaryLabelColor
        optionHintField.isHidden = true
        addSubview(optionHintField)

        // Short of required: the button starts out 0 pt wide, until the
        // list lays it out, and the hint can't fit there.
        let optionHintTrailing = optionHintField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        optionHintTrailing.priority = .init(999)

        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // On the tab rows' favicons and titles
            iconView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SidebarTabRowView.faviconCenterX),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarTabRowView.titleLeading),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: optionHintField.leadingAnchor, constant: -8),

            optionHintTrailing,
            optionHintField.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 38)
        ])

        toolTip = "Create new tab (hold ⌥ for a private tab)"
    }

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
        isHovering = true
        isOptionHeld = event.modifierFlags.contains(.option)
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isOptionHeld = event.modifierFlags.contains(.option)
            return event
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isOptionHeld = false
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        actionHandler?(event.modifierFlags.contains(.option))
    }

    private func updateHoverFill() {
        bgView.layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : .clear
    }

    private func updateContent() {
        iconView.image = isOptionHeld ? Self.privateImage : Self.plusImage
        titleField.stringValue = isOptionHeld ? "New Private Tab" : "New Tab"
        optionHintField.isHidden = !isOptionHeld
    }
}
