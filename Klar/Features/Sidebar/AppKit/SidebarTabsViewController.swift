import AppKit
import Combine
import SwiftUI

/// Custom-NSView-based replacement for the NSOutlineView path. Hosts a
/// single `SidebarRowsView` inside a single outer `NSScrollView` — that
/// rows view owns the entire sidebar's row hierarchy (collection header,
/// organized tabs/folders/peek, divider, new-tab button, regular tabs)
/// and lays them out manually for full animation/drag control.
final class SidebarTabsViewController: NSViewController {
    let sidebarManager: SidebarManager
    let tabManager: TabManager

    private(set) var cancellables: Set<AnyCancellable> = []

    private let scrollView = SidebarTabsScrollView()
    private let rowsView = SidebarRowsView()

    private var folderIconPickerPopover: NSPopover?
    /// See `setZoomedOut(_:)`.
    fileprivate var zoomedOutAmount: CGFloat = 0
    /// Strong reference to the currently-presented Edit URL sheet host so
    /// AppKit's sheet machinery doesn't deallocate it mid-presentation.
    /// Cleared when the sheet dismisses (save or cancel).
    private var editURLSheetHost: NSHostingController<EditURLDialog>?
    /// While a row is being renamed, ends the rename on a click anywhere
    /// outside its field. See `watchClicksOutsideRename(_:)`.
    private var renameClickMonitor: Any?

    /// Set for a preview of another space than the active one: the page
    /// beside it while swiping between spaces. It shows that space as
    /// switching to it would, and takes no part in anything else.
    let previewedSpaceID: UUID?

    init(sidebarManager: SidebarManager, tabManager: TabManager, previewing spaceID: UUID? = nil) {
        self.sidebarManager = sidebarManager
        self.tabManager = tabManager
        self.previewedSpaceID = spaceID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Scrolls without a scroller: its edge separators show there's more
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        rowsView.translatesAutoresizingMaskIntoConstraints = false
        rowsView.sidebarManager = sidebarManager
        rowsView.tabManager = tabManager
        if let previewedSpaceID {
            rowsView.previewedSpace = .init(
                spaceID: previewedSpaceID,
                selectedItemID: tabManager.spaceSelection?.itemShown(onSwitchingTo: previewedSpaceID)
            )
        } else {
            rowsView.delegate = self
        }
        scrollView.documentView = rowsView

        container.addSubview(scrollView)

        // Outer scroll fills the bridge; the rows view fills the clip view's
        // full width — the layout engine itself applies the horizontal inset
        // (`SidebarLayoutMetrics.outerHorizontalPadding`) on each row.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rowsView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            // At least as tall as what shows of it, so a drag over the empty
            // space below the rows drops at the end of the regular tabs
            rowsView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildRegularTabs()
        rowsView.reload()
        // A preview lasts for a swipe.
        if previewedSpaceID == nil {
            bind()
        }
    }

    private func bind() {
        sidebarManager.sidebarStructurePublisher
            // Dedupe by lastUpdated — `SidebarSyncManager` and friends emit
            // sidebarStructure churn during tab creation that would
            // otherwise feedback-loop the reload chain (the data layer
            // explicitly debounces via "AttributeGraph cycle" workarounds).
            // Mutation paths that need a UI refresh must bump
            // `sidebarStructure.lastUpdated` themselves (the unloaded ↔
            // loaded transition is handled via the mapping-based check in
            // `SidebarTabRowView.configure`).
            .removeDuplicates(by: { $0.lastUpdated == $1.lastUpdated })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRegularTabs()
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        // The data sinks below ask for one reload per turn between them
        // (`setNeedsReload`); what needs the rows themselves runs a pending
        // one first.
        sidebarManager.$selectedItem
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        sidebarManager.$extraSelectedItems
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        sidebarManager.$expandedFolders
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsView.setNeedsReload(animated: true)
            }
            .store(in: &cancellables)

        // The private tabs locked or unlocked: their rows hide their pages'
        // titles and icons, or show them again
        NotificationCenter.default.publisher(for: .privateTabsLockDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        // A regular tab joined or left a group, or one was renamed, here or
        // in another window or on another Mac
        NotificationCenter.default.publisher(for: .openTabGroupsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRegularTabs()
                // Its tabs slide into their group, or out of it
                self?.rowsView.setNeedsReload(animated: true)
            }
            .store(in: &cancellables)

        sidebarManager.$isRenaming
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.watchClicksOutsideRename(id != nil)
                guard let id = id else { return }
                self?.rowsView.reloadIfNeeded()
                // Rows only have views near the visible area; bring the row
                // into view first so there is a field to edit in.
                self?.rowsView.revealItem(id)
                self?.rowsView.refreshRow(forItem: id)
            }
            .store(in: &cancellables)

        sidebarManager.$scrollToItem
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] itemID in
                guard let self else { return }
                self.rowsView.reloadIfNeeded()
                // A saved tab or folder in a collapsed collection has no row.
                if self.sidebarManager.sidebarStructure.tabs[itemID] != nil
                    || self.sidebarManager.sidebarStructure.folders[itemID] != nil {
                    self.rowsView.setCollectionExpanded(true)
                }
                self.rowsView.revealItem(itemID)
            }
            .store(in: &cancellables)

        tabManager.$tabs
            // Coalesce rapid emits during tab creation/restore — `$tabs`
            // can fire many times in a row as the tab system bootstraps,
            // and each reload synchronously rebuilds the entire row tree.
            // Throttle keeps the latest value at most once per frame.
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRegularTabs()
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        tabManager.$activeTabId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        // Another space: its saved tabs, folders and regular tabs.
        tabManager.spaceSelection?.$activeSpaceID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildRegularTabs()
                self.rowsView.setCollectionExpanded(true)
                self.rowsView.reload()
                self.rowsView.enclosingScrollView?.contentView.scroll(to: .zero)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .spaceTabsDidChange, object: tabManager)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRegularTabs()
                self?.rowsView.setNeedsReload()
            }
            .store(in: &cancellables)

        // The window's own sidebar's menus, not a preview of another space's
        guard previewedSpaceID == nil else { return }
        NotificationCenter.default.publisher(for: NSNotification.Name("ShowFolderIconPicker"), object: sidebarManager)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self,
                      let folderID = note.userInfo?["folderID"] as? UUID else { return }
                self.presentFolderIconPicker(for: folderID)
            }
            .store(in: &cancellables)

        // Edit URL sheet for saved tabs. The context-menu item posts this
        // notification rather than calling us directly so the menu factory
        // stays decoupled from view-controller presentation. Mirrors the
        // SwiftUI sheet that lived inside `TabItem.swift` on `main`.
        NotificationCenter.default.publisher(for: NSNotification.Name("ShowEditURLDialog"), object: sidebarManager)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self = self,
                      let tabID = note.userInfo?["tabID"] as? UUID,
                      let url = note.userInfo?["url"] as? String else { return }
                self.presentEditURLDialog(tabID: tabID, currentURL: url)
            }
            .store(in: &cancellables)
    }

    /// The space's browser tabs that aren't saved tabs.
    private func rebuildRegularTabs() {
        let mappedBrowserIDs = Set(sidebarManager.browserToSidebarTabMapping.keys)
        let selection = tabManager.spaceSelection
        let regular = tabManager.tabs.filter { tab in
            // An empty pane of a split view isn't a tab of its own here
            guard !mappedBrowserIDs.contains(tab.id), !tabManager.isEmptyPane(tab) else { return false }
            if let previewedSpaceID {
                return SpaceManager.shared.spaceID(of: tab) == previewedSpaceID
            }
            return selection?.isInActiveSpace(tab) != false
        }
        rowsView.setRegularTabs(regular, groups: OpenTabStore.shared.groups(ofPages: regular))
    }

    private func presentEditURLDialog(tabID: UUID, currentURL: String) {
        // Dismiss any sheet that's already up — typing the keyboard
        // shortcut twice in quick succession shouldn't stack sheets.
        if let existing = editURLSheetHost {
            dismiss(existing)
            editURLSheetHost = nil
        }

        let dialog = EditURLDialog(
            initialURL: currentURL,
            onSave: { [weak self] newURL in
                self?.sidebarManager.updateTabURL(for: tabID, newURL: newURL)
                if let host = self?.editURLSheetHost {
                    self?.dismiss(host)
                    self?.editURLSheetHost = nil
                }
            },
            onCancel: { [weak self] in
                if let host = self?.editURLSheetHost {
                    self?.dismiss(host)
                    self?.editURLSheetHost = nil
                }
            }
        )

        let host = NSHostingController(rootView: dialog)
        host.preferredContentSize = NSSize(width: 400, height: 160)
        editURLSheetHost = host
        presentAsSheet(host)
    }

    private func presentFolderIconPicker(for folderID: UUID) {
        // A saved group's, or a group of regular tabs'
        let regularGroup = sidebarManager.sidebarStructure.folders[folderID] == nil
            ? OpenTabStore.shared.group(withID: folderID) : nil
        guard let icon = sidebarManager.sidebarStructure.folders[folderID]?.icon ?? regularGroup?.icon else { return }
        // Anchor the popover to the folder's cell, scrolling it into view
        // (and so giving it a cell) if needed.
        rowsView.scrollRowToVisible(.folder(folderID))
        guard let anchor = rowsView.rowView(for: .folder(folderID)) as? SidebarFolderRowView else { return }

        folderIconPickerPopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let picker = IcomojiPicker(
            selection: .icomoji(Icomoji(icon.isEmpty ? FolderIcons.defaultIcon : icon)),
            onSelect: { [weak self] choice in
                guard case .icomoji(let icomoji) = choice else { return }
                if regularGroup != nil {
                    OpenTabStore.shared.updateGroup(folderID, icon: icomoji.stored)
                } else {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ChangeFolderIcon"),
                        object: nil,
                        userInfo: [
                            "folderID": folderID.uuidString,
                            "icon": icomoji.stored
                        ]
                    )
                }
                self?.folderIconPickerPopover?.close()
                self?.folderIconPickerPopover = nil
            }
        )
        let host = NSHostingController(rootView: picker)
        host.preferredContentSize = IcomojiPicker.size
        popover.contentViewController = host

        folderIconPickerPopover = popover
        // Anchor the popover at the folder's actual icon rect rather than
        // the entire cell — the popover's pointer then aims at the icon
        // instead of floating off the cell's right edge.
        popover.show(relativeTo: anchor.iconFrameInSelf, of: anchor, preferredEdge: .maxX)
    }

    /// Clicks on other rows go to `SidebarRowsView`, which never takes
    /// keyboard focus, so the field would keep editing. Taking the focus off
    /// it ends the rename (committing the name, as Finder does); the click
    /// then goes on as usual.
    private func watchClicksOutsideRename(_ watching: Bool) {
        if !watching {
            if let renameClickMonitor { NSEvent.removeMonitor(renameClickMonitor) }
            renameClickMonitor = nil
            return
        }
        guard renameClickMonitor == nil else { return }
        renameClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self,
                  let window = event.window,
                  let fieldEditor = window.firstResponder as? NSTextView,
                  fieldEditor.isFieldEditor,
                  fieldEditor.isDescendant(of: self.rowsView) else { return event }
            // The field being edited, which can be wider than its editor.
            let field = fieldEditor.delegate as? NSView ?? fieldEditor
            let point = field.convert(event.locationInWindow, from: nil)
            if !field.bounds.contains(point) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    isolated deinit {
        cancellables.removeAll()
        if let renameClickMonitor { NSEvent.removeMonitor(renameClickMonitor) }
    }
}

// MARK: - Zooming out

extension SidebarTabsViewController {
    /// How much smaller the list gets zoomed all the way out.
    private static let zoomedOutShrink: CGFloat = 0.1
    /// How blurred it gets, in points.
    private static let zoomedOutBlur: CGFloat = 12

    /// Whether the list takes drops: only while it's the level on screen.
    func setAcceptsDrops(_ acceptsDrops: Bool) {
        rowsView.acceptsDrops = acceptsDrops
    }

    /// Zooms the list out and blurs it, by `amount` from 0 (as it is) to 1:
    /// while pinching to the overview, or back. A transform and a filter on
    /// its layer, so the rows aren't laid out again on every frame.
    func setZoomedOut(_ amount: CGFloat) {
        guard amount != zoomedOutAmount, let layer = view.layer else { return }
        zoomedOutAmount = amount
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard amount > 0 else {
            layer.sublayerTransform = CATransform3DIdentity
            layer.filters = nil
            return
        }
        // About the middle: the transform's origin is the anchor point.
        let bounds = view.bounds
        let pivotX = bounds.width * (0.5 - layer.anchorPoint.x)
        let pivotY = bounds.height * (0.5 - layer.anchorPoint.y)
        let scale = 1 - Self.zoomedOutShrink * amount
        var transform = CATransform3DMakeTranslation(pivotX, pivotY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -pivotX, -pivotY, 0)
        layer.sublayerTransform = transform

        // Core Animation's own blur (private)
        if let filterClass = NSClassFromString("CAFilter") as AnyObject?,
           let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
               .takeUnretainedValue() as? NSObject {
            blur.setValue(Self.zoomedOutBlur * amount, forKey: "inputRadius")
            layer.filters = [blur]
        }
    }
}

extension SidebarTabsViewController: NSPopoverDelegate {
    /// Let go once closed (clicked away from), with its hosting controller.
    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === folderIconPickerPopover {
            folderIconPickerPopover = nil
        }
    }
}

extension SidebarTabsViewController: SidebarRowsViewDelegate {
    func rowsView(_ rowsView: SidebarRowsView, didActivateTab tabID: UUID) {
        // Click on already-selected tab when navigated away → return to saved page.
        if sidebarManager.selectedItem == tabID,
           sidebarManager.shouldShowReturnToSavedPage(for: tabID) {
            _ = sidebarManager.returnToSavedPage(for: tabID)
        } else {
            sidebarManager.selectItem(tabID)
        }
    }

    func rowsView(_ rowsView: SidebarRowsView, didActivateRegularTab tabID: UUID) {
        sidebarManager.selectItem(tabID)
    }

    func rowsView(_ rowsView: SidebarRowsView, didToggleFolder folderID: UUID) {
        // Just mutate the manager — `$expandedFolders` Combine sink picks
        // up the change next tick and runs an animated reload.
        sidebarManager.toggleFolderExpansion(folderID)
    }

    func rowsView(_ rowsView: SidebarRowsView, didToggleCollection collectionID: UUID) {
        rowsView.setCollectionExpanded(!rowsView.collectionExpandedState())
    }

    func rowsView(_ rowsView: SidebarRowsView, didRequestRenameForItem itemID: UUID) {
        sidebarManager.startRenaming(itemID)
    }

    func rowsViewDidRequestNewTab(_ rowsView: SidebarRowsView, isPrivate: Bool) {
        tabManager.openCommandPaletteForNewTab(isPrivate: isPrivate)
    }

    func rowsView(_ rowsView: SidebarRowsView, didRequestContextMenuFor key: SidebarRowKey, at point: CGPoint) {
        // Anchor share pickers / popovers to the actual cell that was
        // right-clicked rather than the rowsView, so the picker arrow
        // points at that row instead of the top of the list. Falls back
        // to rowsView if the cell isn't currently vended.
        let anchor: NSView = rowsView.rowView(for: key) ?? rowsView
        let menu: NSMenu
        if let items = rowsView.selectedItems(forMenuOn: key) {
            // One of several tabs ⌘-clicked: for all of them
            menu = SidebarContextMenuFactory.menu(forTabs: items, sidebarManager: sidebarManager, tabManager: tabManager)
        } else {
            switch key {
            case .folder(let id) where rowsView.isRegularGroup(id):
                menu = SidebarContextMenuFactory.menu(forRegularGroup: id, sidebarManager: sidebarManager, tabManager: tabManager)
            case .peekTab(let id, _) where sidebarManager.sidebarStructure.tabs[id] == nil:
                // A regular tab peeking out of its group
                guard let browserTab = tabManager.tabs.first(where: { $0.id == id }) else { return }
                menu = SidebarRegularTabContextMenuFactory.menu(for: browserTab, sidebarManager: sidebarManager, tabManager: tabManager, anchor: anchor)
            case .tab, .peekTab, .folder, .collectionHeader:
                menu = SidebarContextMenuFactory.menu(for: key, sidebarManager: sidebarManager, tabManager: tabManager, anchor: anchor)
            case .regularTab(let id):
                guard let browserTab = tabManager.tabs.first(where: { $0.id == id }) else { return }
                menu = SidebarRegularTabContextMenuFactory.menu(for: browserTab, sidebarManager: sidebarManager, tabManager: tabManager, anchor: anchor)
            default:
                return
            }
        }
        let inWindow = rowsView.convert(point, to: nil)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: rowsView)
        } else {
            // Synthesize a click event at the right place if we don't have one
            menu.popUp(positioning: nil, at: inWindow, in: nil)
        }
    }
}

// MARK: - Scroll view

/// A sidebar list's scroll view: a separator line at its top and bottom
/// edges, toward the URL bar and the space bar, each shown while there's
/// more of the list past it. Each line is its inset in from the edge it's
/// constrained to, where the list is cut off: the scroll view's frame is
/// that much inside its alignment rect, so its own scrolling knows only the
/// height it shows (a clip view shorter than the scroll view overshot the
/// end and was pulled back).
class SidebarScrollView: NSScrollView {
    private let topSeparator = SidebarEdgeSeparator()
    private let bottomSeparator = SidebarEdgeSeparator()
    private let topSeparatorInset: CGFloat
    private let bottomSeparatorInset: CGFloat

    init(topSeparatorInset: CGFloat = SidebarLayoutMetrics.topSeparatorInset,
         bottomSeparatorInset: CGFloat = SidebarLayoutMetrics.bottomSeparatorInset) {
        self.topSeparatorInset = topSeparatorInset
        self.bottomSeparatorInset = bottomSeparatorInset
        super.init(frame: .zero)
        for separator in [topSeparator, bottomSeparator] {
            separator.alphaValue = 0
            addSubview(separator)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: -topSeparatorInset, left: 0, bottom: -bottomSeparatorInset, right: 0)
    }

    override func tile() {
        super.tile()
        let scale = window?.backingScaleFactor ?? 2
        let inset = SidebarLayoutMetrics.outerHorizontalPadding
        let width = max(0, bounds.width - inset * 2)
        let thickness = 1 / scale
        // Above the clip view, wherever `super` put it
        if let clipIndex = subviews.firstIndex(of: contentView) {
            for separator in [topSeparator, bottomSeparator]
            where subviews.firstIndex(of: separator).map({ $0 < clipIndex }) ?? true {
                addSubview(separator, positioned: .above, relativeTo: contentView)
            }
        }
        // Over the list's first and last pixel rows
        let top = CGRect(x: inset, y: bounds.maxY - thickness, width: width, height: thickness)
        let bottom = CGRect(x: inset, y: 0, width: width, height: thickness)
        topSeparator.frame = isFlipped ? bottom : top
        bottomSeparator.frame = isFlipped ? top : bottom
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // Called as the list scrolls and as its height changes
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateSeparators()
    }

    private func updateSeparators() {
        guard let documentView, contentView.isFlipped else { return }
        let visible = contentView.bounds
        let insets = contentView.contentInsets
        let document = documentView.frame
        // Half a point of slack, for fractional scroll positions
        topSeparator.setShown(visible.minY + insets.top > document.minY + 0.5)
        bottomSeparator.setShown(visible.maxY - insets.bottom < document.maxY - 0.5)
    }
}

/// One of `SidebarScrollView`'s edge separators: a hairline in the
/// system's separator color.
private final class SidebarEdgeSeparator: NSView {
    private var isShown = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = shown ? 1 : 0
        }
    }
}

/// The tabs' scroll view, without AppKit's responsive scrolling (which
/// overriding `scrollWheel(with:)` turns off): with it, a scroll's events
/// after its first go straight to the scroll view, past the window's local
/// monitors, so `SidebarGestureMonitorView` never saw a swipe over the tabs.
final class SidebarTabsScrollView: SidebarScrollView {
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }
}
