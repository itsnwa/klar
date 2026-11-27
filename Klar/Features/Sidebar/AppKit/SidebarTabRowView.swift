import AppKit
import Combine

/// Mode that drives the trailing action button's symbol + behaviour.
enum SidebarTabRowMode {
    /// Organized sidebar tab: minus = unload, xmark = remove (when unloaded).
    case organized
    /// Regular browser tab in the footer: xmark = close browser tab.
    case regular
}

final class SidebarTabRowView: NSView, NSTextFieldDelegate {
    /// Symbol images shared by every row rather than rebuilt on each configure.
    private enum Symbols {
        static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        static let closeTab = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        static let removeFromSidebar = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from sidebar")
        static let unload = NSImage(systemSymbolName: "minus", accessibilityDescription: "Unload tab")
        static let speaker = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute tab")
        static let speakerMuted = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Unmute tab")
        static let privateTab = NSImage(systemSymbolName: "sunglasses.fill", accessibilityDescription: "Private tab")
    }

    /// Favicon's leading edge: 8pt row padding plus 3pt to center the 16pt
    /// icon in the 22pt slot that tab, folder and header rows align on.
    private static let faviconLeading: CGFloat = 11
    /// Between the favicon and the title.
    private static let titleGap: CGFloat = 11
    /// On either side of the audio button, when it shows between them. The
    /// audio slot starts this far after the favicon; hidden, it keeps the
    /// rest of `titleGap`.
    private static let audioGap: CGFloat = 8
    private static let hiddenAudioWidth = titleGap - audioGap
    private static let visibleAudioWidth = 18 + audioGap

    private let bgView = NSView()
    private let faviconView = FaviconImageView(frame: .zero)
    private let audioContainer = NSView()
    /// Created the first time this row shows a playing or muted tab.
    private var audioButton: KlarCompactHoverButton?
    private let titleField = NSTextField(labelWithString: "")
    /// Created the first time this row shows "Return to saved page", or
    /// its address as a link.
    private var subtitleField: NSTextField?
    /// Dragged out of the sidebar as a link (`SidebarDraggedRowView`): its
    /// address, under the title, in place of its buttons.
    private var linkAddress: String?
    private let actionButton = KlarCompactHoverButton()
    /// Where the action button shows on hover: created the first time this
    /// row shows a private tab.
    private var privateIndicator: NSImageView?

    private var audioWidthConstraint: NSLayoutConstraint!
    private var faviconLeadingConstraint: NSLayoutConstraint!
    private var bgLeadingConstraint: NSLayoutConstraint!
    private var titleCenterYConstraint: NSLayoutConstraint!

    private(set) var representedTabID: UUID?
    private weak var sidebarManager: SidebarManager?
    private weak var tabManager: TabManager?
    private var isCurrentlyUnloaded: Bool = false
    private var mode: SidebarTabRowMode = .organized
    private var isPrivate = false

    /// What the last `configure` applied. The rows view reconfigures every
    /// visible row on each reload, so an identical call has to cost nothing.
    private struct Configuration: Equatable {
        var tabID: UUID
        var title: String
        var url: String
        var isUnloaded: Bool
        var mode: SidebarTabRowMode
        var isPrivate: Bool
        var leadingInset: CGFloat
        var isRenaming: Bool
    }
    private var configuration: Configuration?

    private var isHovering: Bool = false
    private var isShowingSubtitle = false

    /// Title captured when entering rename mode. Used to revert if the user
    /// dismisses the edit with Escape (NSTextMovement.cancel).
    private var preEditTitle: String = ""
    /// Tracks whether the cell is *currently* in rename mode (see
    /// SidebarFolderRowView for rationale).
    private var renamingNow: Bool = false

    private var faviconTask: Task<Void, Never>?
    private var faviconObservers: [NSObjectProtocol] = []
    private var mediaObserver: NSObjectProtocol?
    /// Combine subscriptions to the underlying `BrowserTab`'s `$title` and
    /// `$url` for live updates while the user navigates without switching
    /// tabs. Only active for `.regular` mode (saved tabs intentionally
    /// keep their bookmarked title/URL — see `SidebarSyncManager`).
    private var browserTabCancellables: Set<AnyCancellable> = []
    private var savedTabTitleCancellable: AnyCancellable?
    /// Last URL we triggered a favicon load for. Lets `$url` updates skip
    /// a redundant cache fetch when the URL didn't actually change.
    private var lastLoadedFaviconURL: String?

    private var isPlaying: Bool = false
    private var isMuted: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureSubviews() {
        bgView.translatesAutoresizingMaskIntoConstraints = false
        // Force layer creation now (layer-hosting) instead of
        // letting AppKit create it lazily after `wantsLayer = true`.
        // Lazy creation means `bgView.layer?.actions = [...]` on the
        // next line was a no-op until the layer existed — by which
        // point AppKit's default actions for cornerRadius/backgroundColor
        // were in effect, so the first peek render animated cornerRadius
        // from its implicit starting value to 12.
        bgView.layer = CALayer()
        bgView.wantsLayer = true
        // Permanently disable implicit animations on cornerRadius,
        // cornerCurve, and backgroundColor by mapping them to NSNull in
        // the layer's actions dict. This is more reliable than
        // `CATransaction.setDisableActions` (which only affects the
        // current transaction) and works regardless of whether init runs
        // inside an outer animation context.
        bgView.layer?.actions = [
            "cornerRadius": NSNull(),
            "cornerCurve": NSNull(),
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            // Shown again at once by a dragged row (`setFillHidden`), not
            // faded in under its stand-in
            "hidden": NSNull()
        ]
        bgView.layer?.cornerRadius = 12
        bgView.layer?.cornerCurve = .continuous
        bgView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bgView)

        // The NSImageView is a fixed 16x16 so every favicon — regardless of
        // the source image's natural size — renders at the same stable
        // visual size.
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        faviconView.imageAlignment = .alignCenter
        faviconView.image = Symbols.globe
        faviconView.contentTintColor = .secondaryLabelColor
        addSubview(faviconView)

        audioContainer.translatesAutoresizingMaskIntoConstraints = false
        audioContainer.wantsLayer = true
        audioContainer.layer?.masksToBounds = true
        addSubview(audioContainer)

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

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        actionButton.isHidden = true
        addSubview(actionButton)

        audioWidthConstraint = audioContainer.widthAnchor.constraint(equalToConstant: Self.hiddenAudioWidth)
        faviconLeadingConstraint = faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.faviconLeading)
        bgLeadingConstraint = bgView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        // Title's vertical position animates between 0 (no subtitle) and -6
        // (subtitle showing) to make room for the subtitle below — mirrors
        // the SwiftUI .offset(y: showSubtitle ? 0 : 6) animation.
        titleCenterYConstraint = titleField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0)

        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            bgLeadingConstraint,
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),

            faviconLeadingConstraint,
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            audioContainer.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: Self.audioGap),
            audioContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            audioContainer.heightAnchor.constraint(equalToConstant: 22),
            audioWidthConstraint,

            titleField.leadingAnchor.constraint(equalTo: audioContainer.trailingAnchor),
            titleCenterYConstraint,
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 18),
            actionButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    func configure(
        with tab: SidebarTab,
        sidebarManager: SidebarManager,
        tabManager: TabManager,
        isRenaming: Bool,
        extraLeadingInset: CGFloat = 0,
        mode: SidebarTabRowMode = .organized,
        isPrivate: Bool = false
    ) {
        self.sidebarManager = sidebarManager
        self.tabManager = tabManager
        // Derive the loaded-vs-unloaded state from the live mapping rather
        // than `tab.isUnloaded`. The mapping is updated synchronously when
        // a saved tab is loaded (see `SidebarTabManager.loadTab`),
        // whereas `tab.isUnloaded` is flipped inside a `DispatchQueue.main.async`
        // block — by the time we reach here on the synchronous selection path,
        // the structure flag is still stale, but the mapping is current.
        let hasMapping = sidebarManager.sidebarToBrowserTabMapping[tab.id] != nil
        // In this window: open in another one only, it's unloaded here
        let isUnloaded = mode == .organized && !hasMapping
        let newConfiguration = Configuration(
            tabID: tab.id,
            title: tab.displayTitle,
            url: tab.url,
            isUnloaded: isUnloaded,
            mode: mode,
            isPrivate: isPrivate,
            leadingInset: extraLeadingInset,
            isRenaming: isRenaming
        )
        let old = configuration
        guard newConfiguration != old else { return }
        configuration = newConfiguration

        let changingTab = old?.tabID != tab.id
        let modeChanged = old?.mode != mode
        representedTabID = tab.id
        isCurrentlyUnloaded = isUnloaded
        self.mode = mode
        if self.isPrivate != isPrivate {
            self.isPrivate = isPrivate
            applyPrivateIndicator()
        }

        if old?.leadingInset != extraLeadingInset {
            applyLeadingInset(extraLeadingInset)
        }

        if isRenaming {
            if !renamingNow {
                renamingNow = true
                titleField.stringValue = tab.displayTitle
                preEditTitle = tab.displayTitle
                titleField.isEditable = true
                titleField.isSelectable = true
                // Deferred so the cell is in a window's responder chain
                // before we try to engage the field editor.
                DispatchQueue.main.async { [weak titleField] in
                    titleField?.selectText(nil)
                }
            }
            // Otherwise leave the field alone — repeated configures from
            // back-to-back publisher emits would otherwise overwrite the
            // user's in-progress edits and re-detach the field editor.
        } else {
            renamingNow = false
            if titleField.stringValue != tab.displayTitle {
                titleField.stringValue = tab.displayTitle
            }
            if titleField.isEditable {
                titleField.isEditable = false
                titleField.isSelectable = false
            }
        }

        if old?.isUnloaded != isUnloaded || modeChanged {
            applyActionButtonState()
        }

        // An unloaded (or closed) saved tab has no web view to play
        // anything, and its page never reported that playback stopped.
        if isUnloaded, isPlaying || isMuted {
            isPlaying = false
            isMuted = false
            applyAudioState(animated: true)
        }

        if changingTab {
            isPlaying = false
            isMuted = false
            applyAudioState(animated: false)
            loadFavicon(for: tab.url)
            lastLoadedFaviconURL = tab.url
            attachMediaObserver(for: tab.id)
            syncMediaStateFromManager(for: tab.id)
            attachBrowserTabObservers(for: tab.id, tabManager: tabManager)
            attachSavedTabTitleObserver(for: tab.id, sidebarManager: sidebarManager)
        } else {
            if modeChanged {
                // Same tab, mode flipped (e.g. organized ↔ regular via
                // promote/demote). Reattach observers so they're scoped to the
                // current mode.
                attachBrowserTabObservers(for: tab.id, tabManager: tabManager)
                attachSavedTabTitleObserver(for: tab.id, sidebarManager: sidebarManager)
            }
            if mode == .organized, lastLoadedFaviconURL != tab.url {
                // The saved tab now points somewhere else (Edit URL, update to
                // current page): its icon may have changed too.
                loadFavicon(for: tab.url)
                lastLoadedFaviconURL = tab.url
            }
        }
    }

    /// Subscribe to the underlying `BrowserTab`'s `$title` and `$url` so
    /// the cell tracks live navigation. Saved (organized) tabs keep their
    /// bookmark title/URL deliberately — `SidebarSyncManager` doesn't
    /// mirror navigation into the saved tab — so we only attach in
    /// `.regular` mode where the cell shows the browser tab directly.
    private func attachBrowserTabObservers(for tabID: UUID, tabManager: TabManager) {
        browserTabCancellables.removeAll()
        guard mode == .regular,
              let browserTab = tabManager.tabs.first(where: { $0.id == tabID }) else { return }

        browserTab.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self = self, !self.renamingNow else { return }
                let resolved = newTitle.isEmpty ? "New Tab" : newTitle
                if self.titleField.stringValue != resolved {
                    self.titleField.stringValue = resolved
                }
            }
            .store(in: &browserTabCancellables)

        browserTab.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newURL in
                guard let self = self, !newURL.isEmpty else { return }
                if self.lastLoadedFaviconURL == newURL { return }
                self.lastLoadedFaviconURL = newURL
                self.loadFavicon(for: newURL)
            }
            .store(in: &browserTabCancellables)
    }

    /// A saved tab's page title changes in the structure without reloading
    /// the sidebar (`SidebarTabManager.updateTabState`): it's shown here.
    private func attachSavedTabTitleObserver(for tabID: UUID, sidebarManager: SidebarManager) {
        savedTabTitleCancellable = nil
        guard mode == .organized else { return }
        savedTabTitleCancellable = sidebarManager.savedTabTitleDidChange
            .filter { $0 == tabID }
            .sink { [weak self, weak sidebarManager] _ in
                guard let self, !self.renamingNow,
                      let tab = sidebarManager?.sidebarStructure.tabs[tabID] else { return }
                self.configuration?.title = tab.displayTitle
                if self.titleField.stringValue != tab.displayTitle {
                    self.titleField.stringValue = tab.displayTitle
                }
            }
    }

    private func applyActionButtonState() {
        switch mode {
        case .regular:
            actionButton.image = Symbols.closeTab
            actionButton.toolTip = "Close tab"
        case .organized:
            if isCurrentlyUnloaded {
                actionButton.image = Symbols.removeFromSidebar
                actionButton.toolTip = "Remove from sidebar"
            } else {
                actionButton.image = Symbols.unload
                actionButton.toolTip = "Unload tab"
            }
        }
    }

    /// A private tab shows its glyph where the close button is, until the
    /// row is hovered.
    private func applyPrivateIndicator() {
        guard isPrivate || privateIndicator != nil else { return }
        let indicator = privateIndicator ?? makePrivateIndicator()
        indicator.isHidden = !isPrivate || isHovering || linkAddress != nil
    }

    private func makePrivateIndicator() -> NSImageView {
        let indicator = NSImageView(image: Symbols.privateTab ?? NSImage())
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        indicator.contentTintColor = .secondaryLabelColor
        indicator.toolTip = "Private tab"
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: actionButton.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor)
        ])
        privateIndicator = indicator
        return indicator
    }

    private(set) var isSelected: Bool = false
    /// The active tab's row, not just one ⌘-clicked along with it: only it
    /// offers to go back to its saved page
    private var isActive = false
    func setSelected(_ selected: Bool, isActive: Bool? = nil) {
        let isActive = isActive ?? selected
        guard isSelected != selected || self.isActive != isActive else { return }
        isSelected = selected
        self.isActive = isActive
        updateBackgroundFill()
        updateSubtitleVisibility()
    }

    /// The title and buttons in their own colors, selected or not: the
    /// selection's fill is a light one
    private func applyTints() {
        audioButton?.contentTintColor = .secondaryLabelColor
        actionButton.contentTintColor = .secondaryLabelColor
        privateIndicator?.contentTintColor = .secondaryLabelColor
        titleField.textColor = .labelColor
        subtitleField?.textColor = .secondaryLabelColor
    }

    private func updateSubtitleVisibility() {
        var shouldShow = linkAddress != nil
        if !shouldShow, isSelected, isActive, isHovering, let id = representedTabID, let manager = sidebarManager {
            shouldShow = manager.shouldShowReturnToSavedPage(for: id)
        }
        if shouldShow {
            (subtitleField ?? makeSubtitleField()).stringValue = linkAddress ?? "Return to saved page"
        }
        guard shouldShow != isShowingSubtitle else { return }
        isShowingSubtitle = shouldShow
        if shouldShow {
            let field = subtitleField ?? makeSubtitleField()
            field.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.allowsImplicitAnimation = true
                field.animator().alphaValue = 1
                // Title shifts up so subtitle has room below it.
                self.titleCenterYConstraint.animator().constant = -6
                self.layoutSubtreeIfNeeded()
            }
        } else if let field = subtitleField {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.20
                ctx.allowsImplicitAnimation = true
                field.animator().alphaValue = 0
                self.titleCenterYConstraint.animator().constant = 0
                self.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self, weak field] in
                MainActor.assumeIsolated {
                    guard let self = self, !self.isShowingSubtitle else { return }
                    field?.isHidden = true
                }
            })
        }
    }

    private func makeSubtitleField() -> NSTextField {
        let field = NSTextField(labelWithString: "Return to saved page")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        field.cell?.usesSingleLineMode = true
        field.alphaValue = 0
        field.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor),
            field.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: -2)
        ])
        subtitleField = field
        return field
    }

    private func updateBackgroundFill() {
        let fill: NSColor = isDragged ? Self.draggedFill
            : isSelected ? Self.selectedFill : isHovering ? Self.hoverFill : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bgView.layer?.backgroundColor = fill.cgColor
            bgView.layer?.borderColor = Self.selectedBorder.cgColor
        }
        bgView.layer?.borderWidth = isSelected || isDragged ? Self.selectedBorderWidth : 0
    }

    /// The row being dragged (`SidebarDraggedRowView`): opaque, in the
    /// selected row's color with its border, selected or not, as the link's
    /// card it turns into out of the sidebar is
    private var isDragged = false
    func setDragged(_ dragged: Bool) {
        guard isDragged != dragged else { return }
        isDragged = dragged
        updateBackgroundFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundFill()
    }

    // MARK: - Selection

    /// Under the pointer: a faint fill
    static let hoverFill = NSColor.labelColor.withAlphaComponent(0.05)
    /// The selected row (the active tab, the item of a library list): a
    /// monochrome fill, a little lighter than the hover one, so white over
    /// the sidebar in both appearances
    static let selectedFill = NSColor(name: "SidebarSelectedRowFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1)
            : NSColor.white.withAlphaComponent(0.6)
    }
    /// And a border, half as strong as the Now Playing preview's
    static let selectedBorder = NSColor.labelColor.withAlphaComponent(0.1)
    static let selectedBorderWidth: CGFloat = 0.5
    /// A dragged row's fill, and the link's card's: opaque, so it reads
    /// over whatever it's dragged across, and as the selected fill shows
    /// over the sidebar, so a row dropped back in lands in the same color
    static let draggedFill = NSColor(name: "SidebarDraggedRowFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.157, green: 0.157, blue: 0.157, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.965, alpha: 1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuration = nil
        representedTabID = nil
        sidebarManager = nil
        tabManager = nil
        isCurrentlyUnloaded = false
        mode = .organized
        faviconTask?.cancel()
        faviconTask = nil
        faviconObservers.forEach { NotificationCenter.default.removeObserver($0) }
        faviconObservers.removeAll()
        if let token = mediaObserver {
            NotificationCenter.default.removeObserver(token)
            mediaObserver = nil
        }
        browserTabCancellables.removeAll()
        savedTabTitleCancellable = nil
        lastLoadedFaviconURL = nil
        faviconView.image = Symbols.globe
        faviconView.contentTintColor = .secondaryLabelColor
        // Back from a dragged row shown as a tile or a link
        setFillHidden(false)
        setIconHidden(false)
        linkAddress = nil
        titleField.isEditable = false
        titleField.isSelectable = false
        renamingNow = false
        isSelected = false
        isActive = false
        isHovering = false
        isDragged = false
        isShowingSubtitle = false
        subtitleField?.alphaValue = 0
        subtitleField?.isHidden = true
        actionButton.isHidden = true
        isPlaying = false
        isMuted = false
        audioWidthConstraint.constant = Self.hiddenAudioWidth
        audioContainer.alphaValue = 0
        faviconLeadingConstraint.constant = Self.faviconLeading
        bgLeadingConstraint.constant = 0
        titleCenterYConstraint.constant = 0
        applyTints()
        updateBackgroundFill()
    }

    // MARK: - Dragging

    /// Disables implicit Core Animation actions for the constraint constant
    /// changes AND lays out now, so bgView and favicon land at their indent
    /// before the row is first drawn instead of visibly sliding into it on
    /// the next layout pass. A dragged row's view (`SidebarDraggedRowView`)
    /// sets it frame by frame.
    func applyLeadingInset(_ inset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faviconLeadingConstraint.constant = Self.faviconLeading + inset
        bgLeadingConstraint.constant = inset
        // A new row, configured before it has a frame, is laid out once
        // it gets one: at zero size its constraints can't all be met
        if !bounds.isEmpty {
            layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
    }

    /// Its fill and favicon as the dragged row (`SidebarDraggedRowView`)
    /// turns into a pinned site's tile: where they are, the fill hovered as
    /// it is when it's picked up (and its border, selected), and the favicon
    /// as it is, sharp at the tile's larger size (the globe symbol as drawn,
    /// in its tint).
    func dragParts() -> (fillFrame: CGRect, fill: CGColor, border: (color: CGColor, width: CGFloat)?,
                         iconFrame: CGRect, icon: NSImage?) {
        layoutSubtreeIfNeeded()
        var fill = bgView.layer?.backgroundColor ?? .clear
        if fill.alpha == 0 {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fill = Self.hoverFill.cgColor
            }
        }
        var border: (color: CGColor, width: CGFloat)?
        if let layer = bgView.layer, layer.borderWidth > 0, let color = layer.borderColor {
            border = (color, layer.borderWidth)
        }
        let icon = faviconView.image.flatMap { $0.isTemplate ? nil : $0 }
            ?? snapshot(of: faviconView, in: faviconView.bounds)
        return (bgView.frame, fill, border, faviconView.frame, icon)
    }

    /// While the dragged row shows as a tile or a link, the tile's or the
    /// card's fill and favicon stand in for the row's.
    func setFillHidden(_ hidden: Bool) {
        bgView.isHidden = hidden
    }

    func setIconHidden(_ hidden: Bool) {
        faviconView.isHidden = hidden
    }

    /// Dragged out of the sidebar as a link: `address` under the title, and
    /// no buttons. Nil, the row again.
    func setLinkAddress(_ address: String?) {
        guard linkAddress != address else { return }
        linkAddress = address
        actionButton.isHidden = !isHovering || address != nil
        applyPrivateIndicator()
        updateSubtitleVisibility()
    }

    /// Where the favicon's middle is, across a row.
    static let faviconCenterX = faviconLeading + 8
    /// Where the title starts, across a row: after the favicon and the
    /// hidden audio slot.
    static let titleLeading = faviconLeading + 16 + audioGap + hiddenAudioWidth

    /// A split view's pane dragged by its handle, as the row it'd be
    /// among the tabs, in the same parts as a row's own
    /// (there's none to draw from): `width` wide, with its title and `icon`,
    /// opaque as a dragged row is (`setDragged`).
    static func draggingImageComponents(title: String, icon: Any?, width: CGFloat,
                                        appearance: NSAppearance) -> [NSDraggingImageComponent] {
        let height = SidebarLayoutMetrics.standardRowHeight
        var fill = NSColor.clear.cgColor
        var border = NSColor.clear.cgColor
        var titleColor = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            fill = draggedFill.cgColor
            border = selectedBorder.cgColor
            titleColor = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }

        let background = NSDraggingImageComponent(key: .tabBackground)
        background.frame = CGRect(x: 0, y: 0, width: width, height: height)
        background.contents = PinnedSiteDragImage.roundedRect(
            size: background.frame.size, cornerRadius: 12, fill: fill,
            border: border, borderWidth: selectedBorderWidth
        )
        var components = [background]

        // As the title field lays out, up to the action button
        let titleX = titleLeading
        let titleWidth = width - titleX - 34
        if titleWidth > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: titleColor, .paragraphStyle: paragraph
            ])
            let textHeight = ceil(text.size().height)
            let label = NSDraggingImageComponent(key: .label)
            label.frame = CGRect(x: titleX, y: 0, width: titleWidth, height: height)
            // Drawn on whichever thread draws the image: not the main
            // actor's. The string is immutable, only read there.
            nonisolated(unsafe) let drawnTitle = text
            label.contents = NSImage(size: label.frame.size, flipped: false) { @Sendable rect in
                drawnTitle.draw(in: CGRect(x: 0, y: ((rect.height - textHeight) / 2).rounded(),
                                          width: rect.width, height: textHeight))
                return true
            }
            components.append(label)
        }

        if let icon {
            let component = NSDraggingImageComponent(key: .icon)
            component.frame = CGRect(x: faviconLeading, y: ((height - 16) / 2).rounded(), width: 16, height: 16)
            component.contents = FaviconStyle.draggingContents(icon, size: component.frame.size)
            components.append(component)
        }
        return components
    }

    private func snapshot(of view: NSView, in rect: CGRect) -> NSImage? {
        guard !rect.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: - Favicon

    private func loadFavicon(for urlString: String) {
        faviconTask?.cancel()
        faviconTask = nil
        if let image = FaviconCacheManager.shared.cachedFavicon(for: urlString, persist: !isPrivate) {
            faviconView.image = image
            faviconView.contentTintColor = nil
        } else {
            loadFaviconAsync(for: urlString)
        }

        let center = NotificationCenter.default
        faviconObservers.forEach { center.removeObserver($0) }
        faviconObservers = [.faviconCached, .faviconAppearanceChanged].map { name in
            center.addMainObserver(forName: name) { [weak self] note in
                guard let self, self.isPrivate || note.userInfo?["private"] as? Bool != true else { return }
                // Icons are kept by host and port, so any page of the site will do.
                let cache = FaviconCacheManager.shared
                if let url = note.object as? String,
                   cache.generateCacheKey(for: url) != cache.generateCacheKey(for: urlString) { return }
                if let image = cache.cachedFavicon(for: urlString, persist: !self.isPrivate) {
                    self.faviconTask?.cancel()
                    self.faviconView.image = image
                    self.faviconView.contentTintColor = nil
                }
            }
        }
    }

    private func loadFaviconAsync(for urlString: String) {
        let capturedID = representedTabID
        let isPrivate = isPrivate
        faviconTask = Task { [weak self] in
            let image = await FaviconCacheManager.shared.getFavicon(for: urlString, persist: !isPrivate)
            await MainActor.run { [weak self] in
                // Cancelling doesn't stop the lookup: an earlier page's icon
                // would land on the row after the tab has moved on.
                guard let self = self, !Task.isCancelled, self.representedTabID == capturedID else { return }
                if let image = image {
                    self.faviconView.image = image
                    self.faviconView.contentTintColor = nil
                }
            }
        }
    }

    // MARK: - Media state

    private func attachMediaObserver(for tabID: UUID) {
        if let token = mediaObserver {
            NotificationCenter.default.removeObserver(token)
        }
        let modeCopy = mode
        mediaObserver = NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("TabMediaStateChanged"),
            object: nil
        ) { [weak self] note in
            guard let self = self, self.representedTabID == tabID, !self.isCurrentlyUnloaded else { return }
            guard let tabIdString = note.userInfo?["tabId"] as? String,
                  let browserTabID = UUID(uuidString: tabIdString) else { return }
            let mappedID: UUID
            switch modeCopy {
            case .organized:
                mappedID = self.sidebarManager?.sidebarToBrowserTabMapping[tabID] ?? tabID
            case .regular:
                mappedID = tabID
            }
            guard browserTabID == mappedID else { return }
            if let playing = note.userInfo?["isPlaying"] as? Bool {
                self.isPlaying = playing
            }
            if let muted = note.userInfo?["isMediaMuted"] as? Bool {
                self.isMuted = muted
            }
            self.applyAudioState(animated: true)
        }
    }

    private func syncMediaStateFromManager(for tabID: UUID) {
        let mappedID: UUID
        switch mode {
        case .organized:
            mappedID = sidebarManager?.sidebarToBrowserTabMapping[tabID] ?? tabID
        case .regular:
            mappedID = tabID
        }
        if let browserTab = tabManager?.tabs.first(where: { $0.id == mappedID }) {
            isPlaying = browserTab.isPlayingMedia
            isMuted = browserTab.isMediaMuted
            applyAudioState(animated: false)
        }
    }

    private func applyAudioState(animated: Bool) {
        let visible = isPlaying || isMuted
        if visible {
            (audioButton ?? makeAudioButton()).image = isMuted ? Symbols.speakerMuted : Symbols.speaker
        } else if audioButton == nil {
            // Never shown on this row; its slot is already collapsed.
            return
        }
        let targetWidth = visible ? Self.visibleAudioWidth : Self.hiddenAudioWidth
        let targetAlpha: CGFloat = visible ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.audioWidthConstraint.animator().constant = targetWidth
                self.audioContainer.animator().alphaValue = targetAlpha
            }
        } else {
            audioWidthConstraint.constant = targetWidth
            audioContainer.alphaValue = targetAlpha
        }
    }

    private func makeAudioButton() -> KlarCompactHoverButton {
        let button = KlarCompactHoverButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(toggleMute)
        button.contentTintColor = .secondaryLabelColor
        audioContainer.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: audioContainer.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: audioContainer.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18)
        ])
        audioButton = button
        return button
    }

    // MARK: - Actions

    @objc private func toggleMute() {
        guard let tabID = representedTabID else { return }
        let mappedID: UUID
        switch mode {
        case .organized:
            mappedID = sidebarManager?.sidebarToBrowserTabMapping[tabID] ?? tabID
        case .regular:
            mappedID = tabID
        }
        MediaControlManager.shared.toggleMute(for: mappedID)
    }

    @objc private func performAction() {
        guard let tabID = representedTabID else { return }
        switch mode {
        case .regular:
            if let browserTab = tabManager?.tabs.first(where: { $0.id == tabID }) {
                tabManager?.closeTabUndoably(browserTab)
            }
        case .organized:
            if isCurrentlyUnloaded {
                sidebarManager?.removeTab(withID: tabID)
            } else {
                sidebarManager?.unloadTab(withID: tabID)
            }
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
        guard let tabID = representedTabID, titleField.isEditable else { return }
        // If the edit ended because the user pressed Escape, NSTextField
        // notifies us with NSTextMovement.cancel — revert instead of commit.
        let textMovementRaw = obj.userInfo?["NSTextMovement"] as? Int
        if textMovementRaw == NSTextMovement.cancel.rawValue {
            titleField.stringValue = preEditTitle
        } else {
            let newValue = titleField.stringValue
            sidebarManager?.updateCustomTitle(for: tabID, title: newValue)
        }
        sidebarManager?.isRenaming = nil
        titleField.isEditable = false
        titleField.isSelectable = false
    }

    isolated deinit {
        faviconTask?.cancel()
        faviconObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let token = mediaObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

extension SidebarTabRowView: SidebarHoverable {
    func setHovered(_ hovered: Bool) {
        guard isHovering != hovered else { return }
        isHovering = hovered
        actionButton.isHidden = !hovered || linkAddress != nil
        applyPrivateIndicator()
        updateBackgroundFill()
        updateSubtitleVisibility()
    }
}
