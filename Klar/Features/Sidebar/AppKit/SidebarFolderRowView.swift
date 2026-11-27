import AppKit

/// A group's row: its icon (`SidebarGroupIconBox`) and its name. A saved
/// group's, or a group of regular tabs' (configured as a `SidebarFolder` of
/// the same ID).
final class SidebarFolderRowView: NSView, NSTextFieldDelegate {
    private let bgView = NSView()
    private let iconBox = SidebarGroupIconBox()
    private let titleField = NSTextField(labelWithString: "")

    private(set) var representedFolderID: UUID?
    private weak var sidebarManager: SidebarManager?

    private var iconBoxLeadingConstraint: NSLayoutConstraint!
    private var bgLeadingConstraint: NSLayoutConstraint!
    private var isHovering: Bool = false
    /// A drag over the sidebar would drop into this folder.
    private var isDropTarget: Bool = false

    /// What the last `configure` applied. The rows view reconfigures every
    /// visible row on each reload, so an identical call has to cost nothing.
    private struct Configuration: Equatable {
        var folderID: UUID
        var title: String
        var icon: String
        var faviconURLs: [String]
        var leadingInset: CGFloat
        var isRenaming: Bool
    }
    private var configuration: Configuration?

    /// Title captured when entering rename mode. Used to revert if the user
    /// dismisses the edit with Escape.
    private var preEditTitle: String = ""
    /// Tracks whether the cell is *currently* in rename mode. Used so that
    /// repeated `configure(...)` calls (which happen when several
    /// publishers fire in quick succession after creating a folder) don't
    /// re-set `isEditable`, re-call `selectText`, or overwrite the
    /// in-progress edit value — any of which would disrupt the field
    /// editor and silently steal keystrokes.
    private var renamingNow: Bool = false

    /// The icon's frame within this cell's coordinate system. Computed
    /// directly from the current indent rather than read from
    /// `iconBox.frame` so popover positioning is correct even for nested
    /// groups whose layout pass hasn't run yet.
    var iconFrameInSelf: NSRect {
        let side = SidebarGroupIcon.size
        let leading = SidebarGroupIcon.inset + currentExtraLeadingInset
        // Cell uses its default (non-flipped) coords, so y is measured
        // from the BOTTOM. Centered vertically within the cell.
        let y = max(0, (bounds.height - side) / 2)
        return NSRect(x: leading, y: y, width: side, height: side)
    }

    /// Last-applied `extraLeadingInset` from `configure(...)`. Drives both
    /// the icon's leading constraint and `iconFrameInSelf`.
    private var currentExtraLeadingInset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var allowsVibrancy: Bool { false }

    private func configureSubviews() {
        bgView.translatesAutoresizingMaskIntoConstraints = false
        // Force immediate layer creation (layer-hosting) so the actions
        // dict and cornerRadius below take effect on the first render.
        // With lazy `wantsLayer = true` the actions dict was set on a
        // not-yet-created layer (no-op), letting cornerRadius animate
        // implicitly on first display.
        bgView.layer = CALayer()
        bgView.wantsLayer = true
        // Same NSNull-actions pattern as SidebarTabRowView — guarantees
        // cornerRadius/cornerCurve/backgroundColor commit instantly even
        // when the cell is initialized inside an outer animation context.
        bgView.layer?.actions = [
            "cornerRadius": NSNull(),
            "cornerCurve": NSNull(),
            "backgroundColor": NSNull()
        ]
        bgView.layer?.cornerRadius = SidebarGroupIcon.rowCornerRadius
        bgView.layer?.cornerCurve = .continuous
        bgView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bgView)

        iconBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBox)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = NSFont.systemFont(ofSize: 14)
        titleField.textColor = .labelColor
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.focusRingType = .none
        addSubview(titleField)

        iconBoxLeadingConstraint = iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarGroupIcon.inset)
        bgLeadingConstraint = bgView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            bgLeadingConstraint,
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),

            iconBoxLeadingConstraint,
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: SidebarGroupIcon.size),
            iconBox.heightAnchor.constraint(equalToConstant: SidebarGroupIcon.size),

            // Where the tabs' titles start
            titleField.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: SidebarGroupIcon.titleGap),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// `faviconURLs`: the addresses whose favicons it shows without an icon
    /// (`SidebarGroupFavicons`)
    func configure(
        with folder: SidebarFolder,
        sidebarManager: SidebarManager,
        isRenaming: Bool,
        extraLeadingInset: CGFloat = 0,
        faviconURLs: [String] = []
    ) {
        self.sidebarManager = sidebarManager
        let newConfiguration = Configuration(
            folderID: folder.id,
            title: folder.displayTitle,
            icon: folder.icon,
            faviconURLs: faviconURLs,
            leadingInset: extraLeadingInset,
            isRenaming: isRenaming
        )
        let old = configuration
        guard newConfiguration != old else { return }
        configuration = newConfiguration
        representedFolderID = folder.id
        currentExtraLeadingInset = extraLeadingInset

        if old?.leadingInset != extraLeadingInset {
            applyLeadingInset(extraLeadingInset)
        }

        if isRenaming {
            if !renamingNow {
                renamingNow = true
                titleField.stringValue = folder.displayTitle
                preEditTitle = folder.displayTitle
                titleField.isEditable = true
                titleField.isSelectable = true
                // Deferred so the cell is in a window's responder chain
                // before we try to engage the field editor.
                DispatchQueue.main.async { [weak titleField] in
                    titleField?.selectText(nil)
                }
            }
            // If we're already renaming, leave the field alone so the
            // user's in-progress edits aren't overwritten.
        } else {
            renamingNow = false
            if titleField.stringValue != folder.displayTitle {
                titleField.stringValue = folder.displayTitle
            }
            if titleField.isEditable {
                titleField.isEditable = false
                titleField.isSelectable = false
            }
        }

        iconBox.configure(icon: folder.icon, faviconURLs: faviconURLs)
    }

    /// Indents it now, without implicit animations. A dragged row's view
    /// (`SidebarDraggedRowView`) sets it frame by frame.
    func applyLeadingInset(_ inset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconBoxLeadingConstraint.constant = SidebarGroupIcon.inset + inset
        bgLeadingConstraint.constant = inset
        // A new row, configured before it has a frame, is laid out once
        // it gets one: at zero size its constraints can't all be met
        if !bounds.isEmpty {
            layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
    }

    func setDropTarget(_ targeted: Bool) {
        guard isDropTarget != targeted else { return }
        isDropTarget = targeted
        updateBackgroundFill()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuration = nil
        representedFolderID = nil
        sidebarManager = nil
        iconBox.prepareForReuse()
        titleField.isEditable = false
        titleField.isSelectable = false
        renamingNow = false
        isHovering = false
        isDropTarget = false
        iconBoxLeadingConstraint.constant = SidebarGroupIcon.inset
        bgLeadingConstraint.constant = 0
        currentExtraLeadingInset = 0
        updateBackgroundFill()
    }

    private func updateBackgroundFill() {
        if isDropTarget {
            bgView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else if isHovering {
            bgView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        } else {
            bgView.layer?.backgroundColor = .clear
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape: revert and exit rename mode without committing.
            titleField.stringValue = preEditTitle
            sidebarManager?.isRenaming = nil
            titleField.isEditable = false
            titleField.isSelectable = false
            window?.makeFirstResponder(window)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let folderID = representedFolderID, titleField.isEditable else { return }
        let textMovementRaw = obj.userInfo?["NSTextMovement"] as? Int
        if textMovementRaw == NSTextMovement.cancel.rawValue {
            titleField.stringValue = preEditTitle
        } else {
            let newValue = titleField.stringValue
            sidebarManager?.updateCustomTitle(for: folderID, title: newValue)
        }
        sidebarManager?.isRenaming = nil
        titleField.isEditable = false
        titleField.isSelectable = false
    }
}

extension SidebarFolderRowView: SidebarHoverable {
    func setHovered(_ hovered: Bool) {
        guard isHovering != hovered else { return }
        isHovering = hovered
        updateBackgroundFill()
    }
}

// MARK: - Icon

/// A group's icon: a rounded rect, its corners concentric with its row's,
/// holding the icon picked for it, or else its first tabs' favicons
/// stacked (`SidebarGroupFavicons`), each cut out of the one behind it.
nonisolated enum SidebarGroupIcon {
    /// The corners of the rows it's in (`SidebarTabRowView`'s too)
    static let rowCornerRadius: CGFloat = 12
    /// In its row: this far in from the row's top, bottom and leading
    /// edges, centered on the tabs' favicons
    static let size: CGFloat = 24
    static let inset: CGFloat = 7
    /// The row's corners less how far in it is
    static let cornerRadius: CGFloat = rowCornerRadius - inset
    /// Its name starts where the tabs' titles do
    static let titleGap: CGFloat = 7
    /// The icon picked for it
    static let glyphPointSize: CGFloat = 14

    /// The icon picked for a group, at `pointSize`; nil for its favicons
    static func glyph(for icon: String, pointSize: CGFloat = glyphPointSize) -> NSImage? {
        guard !icon.isEmpty, icon != FolderIcons.defaultIcon else { return nil }
        return Icomoji(icon).image(pointSize: pointSize, weight: .medium)
    }

    /// For a tab whose favicon isn't there yet
    static func placeholder(pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// Where each of `count` favicons goes in a box `side` points square,
    /// front first: the first at the bottom left, the others behind it,
    /// each a step up and to the right
    static func stackFrames(count: Int, side: CGFloat) -> [CGRect] {
        let count = min(count, SidebarGroupFavicons.maxCount)
        let iconSize: CGFloat
        let step: CGFloat
        switch count {
        case 0: return []
        case 1: (iconSize, step) = (14, 0)
        case 2: (iconSize, step) = (13, 3)
        default: (iconSize, step) = (12, 3)
        }
        let scale = side / size
        let margin = (size - iconSize - step * CGFloat(count - 1)) / 2
        return (0..<count).map { index in
            let origin = (margin + step * CGFloat(index)) * scale
            return CGRect(x: origin, y: origin, width: iconSize * scale, height: iconSize * scale)
        }
    }

    /// Favicons stacked in a box `side` points square, the first in front
    static func stack(_ favicons: [NSImage], side: CGFloat) -> NSImage? {
        let frames = stackFrames(count: favicons.count, side: side)
        guard !frames.isEmpty else { return nil }
        let images = Array(favicons.prefix(frames.count))
        // 1 pt between them in a row's box
        let gap = side / size
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { @Sendable _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Back to front, each cut out of what's behind it first
            for index in images.indices.reversed() {
                let frame = frames[index]
                let radius = frame.width / 4
                if index < images.count - 1 {
                    context.saveGState()
                    context.setBlendMode(.clear)
                    context.addPath(CGPath(roundedRect: frame.insetBy(dx: -gap, dy: -gap),
                                           cornerWidth: radius + gap, cornerHeight: radius + gap, transform: nil))
                    context.fillPath()
                    context.restoreGState()
                }
                context.saveGState()
                context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
                images[index].draw(in: frame)
                context.restoreGState()
            }
            return true
        }
    }

    /// A group's icon for a menu, `side` points square: the box with its
    /// favicons, those cached by now, or the icon picked for it alone
    @MainActor static func menuImage(icon: String, faviconURLs: [String], side: CGFloat = 16) -> NSImage? {
        if let glyph = glyph(for: icon, pointSize: 13) {
            return glyph
        }
        let cache = FaviconCacheManager.shared
        let favicons = faviconURLs.map { cache.cachedFavicon(for: $0) ?? placeholder(pointSize: 9) ?? NSImage() }
        let stack = stack(favicons, side: side)
        let radius = cornerRadius * side / size
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { @Sendable rect in
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            stack?.draw(in: rect)
            return true
        }
    }
}

/// A group's icon in its row (`SidebarGroupIcon`): the rounded rect, and
/// the icon picked for the group or its favicons, each loaded as needed
/// and shown again as it changes.
final class SidebarGroupIconBox: NSView {
    private let glyphView = NSImageView()
    private let stackView = NSImageView()
    private var icon: String?
    private var faviconURLs: [String] = []
    private var faviconTask: Task<Void, Never>?
    private var faviconObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = SidebarGroupIcon.cornerRadius
        layer?.cornerCurve = .continuous

        for view in [glyphView, stackView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.imageScaling = .scaleNone
            view.imageAlignment = .alignCenter
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        glyphView.contentTintColor = NSColor.labelColor.withAlphaComponent(0.8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        faviconTask?.cancel()
        faviconObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var allowsVibrancy: Bool { false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The icon picked for the group (none: `FolderIcons.defaultIcon` or
    /// empty), else the favicons of `faviconURLs`
    func configure(icon: String, faviconURLs: [String]) {
        guard icon != self.icon || faviconURLs != self.faviconURLs else { return }
        self.icon = icon
        self.faviconURLs = faviconURLs
        if let glyph = SidebarGroupIcon.glyph(for: icon) {
            glyphView.image = glyph
            glyphView.isHidden = false
            stackView.image = nil
            stackView.isHidden = true
            stopFollowingFavicons()
        } else {
            glyphView.image = nil
            glyphView.isHidden = true
            stackView.isHidden = false
            showFavicons()
            followFavicons()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon = nil
        faviconURLs = []
        glyphView.image = nil
        stackView.image = nil
        stopFollowingFavicons()
    }

    private func showFavicons() {
        let cache = FaviconCacheManager.shared
        let placeholder = SidebarGroupIcon.placeholder(pointSize: 11)
        let favicons = faviconURLs.compactMap { cache.cachedFavicon(for: $0) ?? placeholder }
        stackView.image = SidebarGroupIcon.stack(favicons, side: SidebarGroupIcon.size)
    }

    /// Loads the favicons not cached yet, and shows them again as any of
    /// them changes (cached, or another appearance's)
    private func followFavicons() {
        stopFollowingFavicons()
        guard !faviconURLs.isEmpty else { return }
        let cache = FaviconCacheManager.shared
        let urls = faviconURLs
        let missing = urls.filter { cache.cachedFavicon(for: $0) == nil }
        if !missing.isEmpty {
            faviconTask = Task { [weak self] in
                for url in missing {
                    _ = await FaviconCacheManager.shared.getFavicon(for: url)
                }
                guard let self, !Task.isCancelled, self.faviconURLs == urls else { return }
                self.showFavicons()
            }
        }
        let sites = Set(urls.map(cache.generateCacheKey(for:)))
        faviconObservers = [Notification.Name.faviconCached, .faviconAppearanceChanged].map { name in
            NotificationCenter.default.addMainObserver(forName: name) { [weak self] note in
                guard let self, note.userInfo?["private"] as? Bool != true else { return }
                // Kept by host and port: any page of the site will do
                if let url = note.object as? String, !sites.contains(cache.generateCacheKey(for: url)) { return }
                self.showFavicons()
            }
        }
    }

    private func stopFollowingFavicons() {
        faviconTask?.cancel()
        faviconTask = nil
        faviconObservers.forEach { NotificationCenter.default.removeObserver($0) }
        faviconObservers.removeAll()
    }
}
