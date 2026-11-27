import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// A row of the sidebar began or stopped being dragged; the object is
    /// the dragged item's ID. Shows the pinned sites' drop slot while
    /// there are none.
    static let sidebarItemDragDidBegin = Notification.Name("klar.sidebarItemDragDidBegin")
    static let sidebarItemDragDidEnd = Notification.Name("klar.sidebarItemDragDidEnd")
    /// A tab row dragged from the list turned into the tile it'd be over the
    /// pinned sites (object: its size, an `NSValue`), centered under the
    /// pointer: the list's view of the dragged row turns into it too.
    static let sidebarItemDragDidEnterPinnedSites = Notification.Name("klar.sidebarItemDragDidEnterPinnedSites")
    /// A tab row dragged over the pinned sites, shown as a tile, left them:
    /// the row it was dragged from turns it back into the row.
    static let sidebarItemDragDidLeavePinnedSites = Notification.Name("klar.sidebarItemDragDidLeavePinnedSites")
}

/// The pinned sites' grid: as many equal columns as fit, the last row's
/// tiles as wide as the others.
nonisolated enum PinnedSitesLayout {
    static let tileHeight: CGFloat = 40
    static let minTileWidth: CGFloat = 48
    static let spacing: CGFloat = 6

    static func columns(count: Int, width: CGFloat) -> Int {
        let fitting = Int((width + spacing) / (minTileWidth + spacing))
        return max(1, min(count, fitting))
    }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = columns(count: count, width: width)
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
    }

    static func frames(count: Int, width: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = columns(count: count, width: width)
        let tileWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return (0..<count).map { index in
            let column = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            let minX = (column * (tileWidth + spacing)).rounded()
            let maxX = (column * (tileWidth + spacing) + tileWidth).rounded()
            return CGRect(x: minX, y: row * (tileHeight + spacing), width: maxX - minX, height: tileHeight)
        }
    }
}

/// What the SwiftUI side sizes the grid by.
final class PinnedSitesState: ObservableObject {
    /// The grid's slots: its tiles, and the drop's while a tab is dragged
    /// over it.
    @Published var count = 0
}

/// The pinned sites at the top of the sidebar, shared by every space: an
/// icon-only tile per site. Clicking one shows its tab; tiles drag to
/// reorder, or out into the space's saved tabs or onto a space's button.
/// Saved tabs, open tabs and links dropped here are pinned: while one is
/// dragged over the grid, the tiles make room for it, a slot the size it
/// will have.
final class PinnedSitesView: NSView {
    struct Tile: Equatable {
        let id: UUID
        let url: String
        let title: String
        let isSelected: Bool
    }

    private let sidebarManager: SidebarManager
    private let tabManager: TabManager
    private let state: PinnedSitesState

    private var tiles: [Tile] = []
    private var tileViews: [UUID: PinnedSiteTileView] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isReloadScheduled = false

    private var mouseDownTileID: UUID?
    /// The tile pressed was showing, its page gone elsewhere: back to the
    /// pinned page on `mouseUp`, not if it's dragged, so the drag carries
    /// the page it's on.
    private var returnsToPinnedPage = false
    /// What was selected before pressing a tile selected it. Dragged out of
    /// the sidebar, the tile gives the selection back, so it can be dropped
    /// beside the page that was showing, into a split view.
    private var selectionBeforePress: UUID?
    private var mouseDownLocation: CGPoint = .zero
    private static let dragStartThreshold: CGFloat = 4

    private let dropSlotView = SidebarDropSlotView()
    private let dropSlotLabel = NSTextField(labelWithString: "Drop here to pin")
    /// A tab is dragged in the sidebar while there are no pinned sites: the
    /// drop slot shows, to drop it on.
    private var showsDropHint = false
    /// Where a drag over the grid would land, among the tiles but the
    /// dragged one.
    private var dropIndex: Int?
    /// The tile being dragged: hidden, its slot gone while it's off the grid.
    private var draggedTileID: UUID?
    /// A pinned site dragged here from another window's grid: its tile here
    /// is lifted out too while it's over it, as it is out of its own.
    private var visitingTileID: UUID?
    /// The tile left out of the grid's slots
    private var hiddenTileID: UUID? {
        draggedTileID ?? visitingTileID
    }
    /// Dropped: the drop's slot stays until the dropped tile takes its place.
    private var isLanding = false
    /// Put back: its slot stays open as the tile slides back into it.
    private var isReturning = false
    /// A tab row dragged over the grid shows as the tile it becomes, under
    /// the pointer: dropped, the tile starts there.
    private var isShowingDraggedTile = false
    private var landingFrame: CGRect?
    /// Fading in, or shown: it fades out before it's hidden.
    private var isDropSlotShown = false
    /// The grid has had its first slot count, set without animation
    private var hasSetSlotCount = false

    /// Off on the overview, which has no pinned sites: faded out by
    /// SwiftUI, it takes no clicks or drops meanwhile.
    var isShown = true

    override var isFlipped: Bool { true }

    /// Every window's pinned sites
    private static let grids = NSHashTable<PinnedSitesView>.weakObjects()

    /// Whether a point on screen is over the pinned sites of the Klar window
    /// in front there, this one's or another's
    static func isOverGrid(atScreenPoint point: CGPoint) -> Bool {
        guard let window = BrowserWindowSession.session(atScreenPoint: point)?.window else { return false }
        return grids.allObjects.contains { grid in
            grid.window === window && grid.isShown && !grid.isHiddenOrHasHiddenAncestor
                && NSMouseInRect(point, window.convertToScreen(grid.convert(grid.bounds, to: nil)), false)
        }
    }

    init(sidebarManager: SidebarManager, tabManager: TabManager, state: PinnedSitesState) {
        self.sidebarManager = sidebarManager
        self.tabManager = tabManager
        self.state = state
        super.init(frame: .zero)
        Self.grids.add(self)
        wantsLayer = true
        // A row being added shows as the grid grows, not over what's below
        clipsToBounds = true

        dropSlotView.isHidden = true
        dropSlotLabel.font = .systemFont(ofSize: 12)
        dropSlotLabel.textColor = .secondaryLabelColor
        dropSlotLabel.alignment = .center
        dropSlotView.addSubview(dropSlotLabel)
        addSubview(dropSlotView)

        registerForDraggedTypes([SidebarPasteboardTypes.sidebarItem, .URL])
        bind()
        // Not while SwiftUI is making this view: the reload updates `state`.
        scheduleReload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func bind() {
        // Published before they change: the reload reads them a turn later.
        sidebarManager.sidebarStructurePublisher
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)
        sidebarManager.$selectedItem
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sidebarItemDragDidBegin)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let itemID = note.object as? UUID,
                      self.sidebarManager.canPin(itemID) else { return }
                self.setShowsDropHint(true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sidebarItemDragDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setShowsDropHint(false) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .faviconCached)
            .merge(with: NotificationCenter.default.publisher(for: .faviconAppearanceChanged))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, note.userInfo?["private"] as? Bool != true else { return }
                let cache = FaviconCacheManager.shared
                let cacheKey = (note.object as? String).map { cache.generateCacheKey(for: $0) }
                for tile in self.tiles where cacheKey == nil || cache.generateCacheKey(for: tile.url) == cacheKey {
                    self.tileViews[tile.id]?.showCachedFavicon(for: tile.url)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tiles

    private func scheduleReload() {
        guard !isReloadScheduled else { return }
        isReloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isReloadScheduled = false
            self?.reload()
        }
    }

    private func reload() {
        let structure = sidebarManager.sidebarStructure
        let newTiles: [Tile] = structure.pinnedItems.compactMap { id in
            guard let tab = structure.tabs[id] else { return nil }
            return Tile(
                id: id,
                url: tab.url,
                title: tab.displayTitle,
                isSelected: sidebarManager.selectedItem == id
            )
        }

        // The dropped tile takes the drop's slot, where it now is
        let landed = isLanding
        var landingTile: (id: UUID, frame: CGRect)?
        if landed {
            if let landingFrame, let dropIndex, newTiles.indices.contains(dropIndex),
               newTiles[dropIndex].id == hiddenTileID || !tiles.contains(where: { $0.id == newTiles[dropIndex].id }) {
                landingTile = (newTiles[dropIndex].id, landingFrame)
            }
            isLanding = false
            dropIndex = nil
            draggedTileID = nil
            visitingTileID = nil
            landingFrame = nil
        }

        if newTiles != tiles {
            tiles = newTiles
            let ids = Set(newTiles.map(\.id))
            for (id, view) in tileViews where !ids.contains(id) {
                view.removeFromSuperview()
                tileViews[id] = nil
            }
            for tile in newTiles {
                let view = tileViews[tile.id] ?? makeTileView(for: tile.id)
                view.configure(with: tile)
            }
        } else if !landed {
            return
        }
        updateSlotCount()
        // From where the dragged tile was dropped, into its slot. Put in its
        // slot at once and brought in from the drop by an additive slide:
        // its frame set to where it was dropped and animated from there in
        // the same turn, a tile already in the grid slid from its old slot,
        // the last position committed to its layer.
        if let landingTile, let view = tileViews[landingTile.id], let slot = slotFrame(of: landingTile.id) {
            view.frame = slot
            view.layoutSubtreeIfNeeded()
            // Where the drag's image was may be past the grid's edge
            clipsToBounds = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    self?.clipsToBounds = true
                    view.layer?.zPosition = 0
                }
            }
            land(view, from: landingTile.frame.origin, at: slot)
            CATransaction.commit()
            layoutSlots(animated: true)
        } else {
            layoutSlots()
        }
    }

    private func makeTileView(for id: UUID) -> PinnedSiteTileView {
        let view = PinnedSiteTileView()
        addSubview(view, positioned: .below, relativeTo: dropSlotView)
        tileViews[id] = view
        return view
    }

    /// The grid's slots in order: the tiles but the dragged one, and nil for
    /// the drop's.
    private func slots() -> [UUID?] {
        var slots: [UUID?] = tiles.map(\.id).filter { $0 != hiddenTileID }.map(Optional.some)
        if let dropIndex {
            slots.insert(nil, at: min(dropIndex, slots.count))
        } else if slots.isEmpty, showsDropHint || hiddenTileID != nil {
            // Somewhere to drop it on, with nothing pinned
            slots = [nil]
        }
        return slots
    }

    /// Where a tile's slot is in the grid as it is now
    private func slotFrame(of id: UUID) -> CGRect? {
        let slots = slots()
        guard let index = slots.firstIndex(of: id) else { return nil }
        return PinnedSitesLayout.frames(count: slots.count, width: bounds.width)[index]
    }

    /// Brings a dropped tile in from `origin`, where the drag's image was,
    /// to `frame`, its slot, over the tiles it passes. Additive, as a row
    /// lands in the list (`SidebarRowsView.land`), so nothing depends on
    /// when AppKit syncs the frame to the layer.
    private func land(_ view: NSView, from origin: CGPoint, at frame: CGRect) {
        guard let layer = view.layer else { return }
        layer.zPosition = 1
        for (keyPath, offset) in [("position.x", origin.x - frame.minX), ("position.y", origin.y - frame.minY)]
        where abs(offset) > 0.25 {
            let slide = SidebarMotion.spring(keyPath: keyPath)
            slide.isAdditive = true
            slide.fromValue = offset
            slide.toValue = 0
            // Held at the drop until the transaction's begin time comes
            // around, so it never flashes in its slot first
            slide.fillMode = .backwards
            layer.add(slide, forKey: "landing.\(keyPath)")
        }
    }

    /// The grid grows and shrinks with a row, and the sidebar below it
    /// moves along. Not the first time, as the window opens: the sites are
    /// already there. Animated then, in the same turn as KlarApp gives the
    /// window its toolbar (title bar 32 → 52 pt), SwiftUI's animated window
    /// sizing added those 20 pt to the window after every layout, up to the
    /// screen's height.
    private func updateSlotCount() {
        let count = slots().count
        defer { hasSetSlotCount = true }
        guard state.count != count else { return }
        if hasSetSlotCount {
            withAnimation(.easeInOut(duration: 0.2)) {
                state.count = count
            }
        } else {
            state.count = count
        }
    }

    override func layout() {
        super.layout()
        layoutSlots()
    }

    /// Puts the tiles and the drop's slot in place; animated, they slide
    /// there.
    private func layoutSlots(animated: Bool = false) {
        let slots = slots()
        let frames = PinnedSitesLayout.frames(count: slots.count, width: bounds.width)
        let dropSlotFrame = slots.firstIndex(where: { $0 == nil }).map { frames[$0] }

        for (id, view) in tileViews {
            view.isHidden = id == hiddenTileID
        }
        // The slot fades in where it is, then moves along with the tiles
        if let dropSlotFrame, !isDropSlotShown {
            isDropSlotShown = true
            dropSlotView.frame = dropSlotFrame
            dropSlotView.alphaValue = 0
            dropSlotView.isHidden = false
            fadeDropSlot(to: 1)
        } else if dropSlotFrame == nil, isDropSlotShown {
            isDropSlotShown = false
            fadeDropSlot(to: 0)
        }

        let place = {
            for (id, frame) in zip(slots, frames) {
                guard let id, let view = self.tileViews[id], view.frame != frame else { continue }
                view.frame = frame
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
            }
            if let dropSlotFrame, self.dropSlotView.frame != dropSlotFrame {
                self.dropSlotView.frame = dropSlotFrame
                self.dropSlotView.needsLayout = true
                self.dropSlotView.layoutSubtreeIfNeeded()
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                place()
            }
        } else {
            place()
        }

        // The label only on its own, as the grid
        dropSlotLabel.isHidden = slots.count > 1 || hiddenTileID != nil
        let labelHeight = dropSlotLabel.intrinsicContentSize.height
        dropSlotLabel.frame = CGRect(x: 0, y: ((PinnedSitesLayout.tileHeight - labelHeight) / 2).rounded(),
                                     width: dropSlotFrame?.width ?? 0, height: labelHeight)
        dropSlotView.isTargeted = dropIndex != nil
    }

    private func fadeDropSlot(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dropSlotView.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isDropSlotShown else { return }
                self.dropSlotView.isHidden = true
            }
        }
    }

    private func tileID(at point: CGPoint) -> UUID? {
        tiles.first { tileViews[$0.id]?.isHidden == false && tileViews[$0.id]?.frame.contains(point) == true }?.id
    }

    // MARK: - Drop slot

    private func setShowsDropHint(_ shows: Bool) {
        guard showsDropHint != shows else { return }
        showsDropHint = shows
        updateSlotCount()
        layoutSlots()
    }

    // MARK: - Clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let id = tileID(at: point) else {
            super.mouseDown(with: event)
            return
        }
        mouseDownTileID = id
        mouseDownLocation = point

        // Already showing it, after navigating away: back to the pinned page
        returnsToPinnedPage = sidebarManager.selectedItem == id && sidebarManager.shouldShowReturnToSavedPage(for: id)
        selectionBeforePress = sidebarManager.selectedItem == id ? nil : sidebarManager.selectedItem
        if !returnsToPinnedPage {
            sidebarManager.selectItem(id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggedTileID == nil, let id = mouseDownTileID, let view = tileViews[id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownLocation.x
        let dy = point.y - mouseDownLocation.y
        guard dx * dx + dy * dy >= Self.dragStartThreshold * Self.dragStartThreshold else { return }

        mouseDownTileID = nil
        // Drawn by the space's list, as it draws a row it drags: the tile,
        // a row over a sidebar, a link or a page out of it
        guard let list = SidebarRowsView.list(in: window) else { return }
        // Where its page is now, not where it was pinned
        let link = tiles.first { $0.id == id }.map { (url: sidebarManager.currentURL(ofSavedTab: id) ?? $0.url, title: $0.title) }
        let isSelected = sidebarManager.selectedItem == id
        let icon = view.draggingIcon()
        let colors = PinnedSiteTileView.draggedTileColors(icon: icon, isSelected: isSelected, appearance: effectiveAppearance)
        // AppKit's, should the list's not show
        let image = PinnedSiteTileView.draggingImageComponents(
            size: view.frame.size, icon: icon, isSelected: isSelected, appearance: effectiveAppearance
        )
        guard list.beginPinnedSiteDrag(
            id, link: link, tile: .init(size: view.frame.size, fill: colors.fill, border: colors.border),
            tileFrame: view.frame, tileImage: image, event: event, restoring: selectionBeforePress, from: self
        ) else { return }
        selectionBeforePress = nil

        // Its slot stays, empty, until it's dragged elsewhere
        draggedTileID = id
        dropIndex = tiles.firstIndex { $0.id == id }
        layoutSlots()
    }

    /// Its tile's drag put back: its slot opens again, as the tile slides
    /// back into it.
    func pinnedSiteDragWillReturn() {
        guard let draggedTileID, !isLanding else { return }
        isReturning = true
        dropIndex = tiles.firstIndex { $0.id == draggedTileID }
        updateSlotCount()
        layoutSlots(animated: true)
    }

    /// Its tile's drag is over (`SidebarRowsView.beginPinnedSiteDrag`): put
    /// back, the tile shows in its slot; dropped elsewhere, it's unpinned,
    /// and the reload takes it away first. Its link copied into another
    /// app, it comes back.
    func pinnedSiteDragDidEnd(operation: NSDragOperation) {
        mouseDownTileID = nil
        isReturning = false
        guard draggedTileID != nil else { return }
        let showTile: @MainActor () -> Void = { [weak self] in
            guard let self, self.draggedTileID != nil else { return }
            self.draggedTileID = nil
            self.dropIndex = nil
            self.updateSlotCount()
            self.layoutSlots(animated: !operation.isEmpty)
        }
        if operation.isEmpty {
            showTile()
        } else {
            DispatchQueue.main.async(execute: showTile)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Not dragged: still pressed
        if returnsToPinnedPage, let id = mouseDownTileID {
            _ = sidebarManager.returnToSavedPage(for: id)
        }
        returnsToPinnedPage = false
        selectionBeforePress = nil
        mouseDownTileID = nil
        super.mouseUp(with: event)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let id = tileID(at: point), let menu = makeMenu(for: id) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeMenu(for id: UUID) -> NSMenu? {
        guard let tab = sidebarManager.sidebarStructure.tabs[id], let anchor = tileViews[id] else { return nil }
        let sidebarManager = sidebarManager
        let menu = NSMenu()
        menu.autoenablesItems = false

        SidebarContextMenuFactory.addItem(menu, title: "Unpin") { sidebarManager.unpin(id) }
        menu.addItem(.separator())

        SidebarContextMenuFactory.addCopyLinkItem(menu, url: tab.url, tabManager: tabManager)
        SidebarContextMenuFactory.addShareItem(menu, url: tab.url, title: tab.displayTitle, anchor: anchor)
        if sidebarManager.isOpenHere(id), sidebarManager.shouldShowReturnToSavedPage(for: id) {
            SidebarContextMenuFactory.addItem(menu, title: "Back to Pinned Page") {
                _ = sidebarManager.returnToSavedPage(for: id)
            }
        }
        SidebarContextMenuFactory.addEditSavedPageSubmenu(menu, tabID: id, sidebarManager: sidebarManager)
        menu.addItem(.separator())

        SidebarContextMenuFactory.addMoveToSpaceSubmenu(menu, itemID: id, currentSpaceID: nil, spaceSelection: sidebarManager.spaceSelection)
        SidebarContextMenuFactory.addReadingListItem(menu, url: tab.url, title: tab.displayTitle, tabManager: tabManager)
        menu.addItem(.separator())

        SidebarContextMenuFactory.addSplitItems(menu, itemID: id, tabManager: tabManager)
        menu.addItem(.separator())

        // Always loaded: no Load or Unload Tab
        SidebarContextMenuFactory.addItem(menu, title: "Remove Pinned Site") { sidebarManager.removeTab(withID: id) }
        return menu
    }

    // MARK: - Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if isShowingDraggedTile {
            isShowingDraggedTile = false
            NotificationCenter.default.post(name: .sidebarItemDragDidLeavePinnedSites, object: nil)
        }
        clearDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isShowingDraggedTile = false
        clearDrop()
    }

    /// A tab row dragged here turns into the tile it'll be, centered under
    /// the pointer: the list's view of it (`SidebarDraggedRowView`) morphs
    /// into the tile, and back as it leaves; AppKit's image, hidden unless
    /// it can't be, becomes the tile's parts.
    /// As soon as it's over the grid, not once AppKit would suggest it
    /// (`updateDraggingItemsForDrag`, a moment later). A tile of the grid
    /// already is one, and a link has no row.
    private func showDraggedTile(_ sender: NSDraggingInfo) {
        guard !isShowingDraggedTile, draggedTileID == nil,
              let itemID = sender.draggedSidebarItemUUIDs.first else { return }
        let frame = draggedTileFrame(at: convert(sender.draggingLocation, from: nil))
        // Selected, it lands selected
        let isSelected = sidebarManager.selectedItem == itemID
        let appearance = effectiveAppearance
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                      searchOptions: [:]) { item, _, _ in
            let icon: Any? = item.imageComponents?.first(where: { $0.key == .icon })?.contents
                ?? self.favicon(of: itemID)
            let components = PinnedSiteTileView.draggingImageComponents(
                size: frame.size, icon: icon, isSelected: isSelected, appearance: appearance
            )
            item.draggingFrame = frame
            item.imageComponentsProvider = { components }
            self.isShowingDraggedTile = true
        }
        if isShowingDraggedTile {
            NotificationCenter.default.post(name: .sidebarItemDragDidEnterPinnedSites, object: NSValue(size: frame.size))
        }
    }

    private func favicon(of itemID: UUID) -> NSImage? {
        if let url = sidebarManager.sidebarStructure.tabs[itemID]?.url {
            return FaviconCacheManager.shared.memoryCachedFavicon(for: url)
        }
        return tabManager.tabs.first { $0.id == itemID }?.favicon
    }

    /// The dragged tile under the pointer, the size of the drop's slot.
    private func draggedTileFrame(at point: CGPoint) -> CGRect {
        let count = tiles.filter { $0.id != hiddenTileID }.count + 1
        let frames = PinnedSitesLayout.frames(count: count, width: bounds.width)
        let index = min(dropIndex ?? insertionIndex(at: point), count - 1)
        let size = frames[index].size
        return CGRect(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrag(sender) else {
            clearDrop()
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = dropIndex ?? insertionIndex(at: point)
        // The drag's image goes as it's dropped: the tile shows where it was
        landingFrame = isShowingDraggedTile || draggedTileID != nil ? draggedTileFrame(at: point) : nil
        dropIndex = index
        isLanding = true
        if let itemID = sender.draggedSidebarItemUUIDs.first {
            sidebarManager.pin(itemID: itemID, at: index)
        } else if let url = sender.draggedWebURL {
            sidebarManager.pin(url: url, at: index)
        } else {
            isLanding = false
            landingFrame = nil
            clearDrop()
            return false
        }
        // In the same turn, so the tile is there as the drag's image goes
        reload()
        return true
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else {
            clearDrop()
            return []
        }
        // One of these tiles, from another window's grid: worked out
        // without it, as in its own grid
        let visitor = draggedTileID == nil ? sender.draggedSidebarItemUUIDs.first.flatMap { id in
            tiles.contains { $0.id == id } ? id : nil
        } : nil
        let isNewVisitor = visitingTileID != visitor
        visitingTileID = visitor
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        if dropIndex != index || isNewVisitor {
            dropIndex = index
            updateSlotCount()
            layoutSlots(animated: true)
        }
        showDraggedTile(sender)
        return sender.draggedSidebarItemUUIDs.isEmpty ? .copy : .move
    }

    private func clearDrop() {
        guard !isLanding, !isReturning, dropIndex != nil || visitingTileID != nil else { return }
        dropIndex = nil
        visitingTileID = nil
        updateSlotCount()
        layoutSlots(animated: true)
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        guard isShown else { return false }
        if let itemID = sender.draggedSidebarItemUUIDs.first {
            return sidebarManager.canPin(itemID)
        }
        return sender.draggedWebURL != nil
    }

    /// Where a drop at `point` goes, among the tiles but the dragged one:
    /// the slot under it, in the grid with room made for it. That grid is
    /// the same wherever the slot is, so the slot stays put under the
    /// pointer.
    private func insertionIndex(at point: CGPoint) -> Int {
        let count = tiles.filter { $0.id != hiddenTileID }.count
        let columns = PinnedSitesLayout.columns(count: count + 1, width: bounds.width)
        let row = max(0, Int(point.y / (PinnedSitesLayout.tileHeight + PinnedSitesLayout.spacing)))
        let columnWidth = (bounds.width + PinnedSitesLayout.spacing) / CGFloat(columns)
        let column = min(max(0, Int(point.x / columnWidth)), columns - 1)
        return min(row * columns + column, count)
    }
}

// MARK: - Drop slot

/// Where a drop lands, among the pinned sites or the rows of the sidebar: a
/// dashed outline, as the overview's New Space card, stronger while a drag
/// is over it.
final class SidebarDropSlotView: NSView {
    private let borderLayer = CAShapeLayer()

    var isTargeted = false {
        didSet {
            if isTargeted != oldValue {
                updateBorderColor()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.lineDashPattern = [4, 3]
        layer?.addSublayer(borderLayer)
        updateBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The outline follows a new size on the next layout, however the
    /// frame was set.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Along with the slot while it slides and resizes, else at once
        CATransaction.begin()
        CATransaction.setDisableActions(!NSAnimationContext.current.allowsImplicitAnimation)
        borderLayer.frame = bounds
        // The card's shape, stroked inside its edge. None before the slot
        // has a size: inset, an empty rect is the null rect, at infinity,
        // which Core Animation won't draw ("ignoring invalid path").
        let outline = bounds.insetBy(dx: 0.5, dy: 0.5)
        borderLayer.path = outline.isNull ? nil : RoundedRectangle(cornerRadius: 12, style: .continuous)
            .path(in: outline).cgPath
        CATransaction.commit()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            borderLayer.strokeColor = NSColor.labelColor.withAlphaComponent(isTargeted ? 0.3 : 0.15).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }
}

// MARK: - Dragging image

extension NSDraggingItem.ImageComponentKey {
    /// A dragged tab's rounded fill: a row's, or a pinned site's tile's
    /// over the pinned sites. With `.icon` (its favicon) and `.label` (the
    /// row's title), AppKit morphs one into the other.
    static let tabBackground = NSDraggingItem.ImageComponentKey("klar.tabBackground")
}

/// Nonisolated: an image's drawing handler runs on whichever thread draws it.
nonisolated enum PinnedSiteDragImage {
    /// A rounded rectangle, as a row's or a tile's layer draws it.
    static func roundedRect(size: CGSize, cornerRadius: CGFloat, fill: CGColor,
                            border: CGColor? = nil, borderWidth: CGFloat = 0) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(fill)
            context.fillPath()
            if let border, borderWidth > 0 {
                // Inside the edge, as a layer's border
                let inset = rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
                context.addPath(RoundedRectangle(cornerRadius: cornerRadius - borderWidth / 2, style: .continuous)
                    .path(in: inset).cgPath)
                context.setStrokeColor(border)
                context.setLineWidth(borderWidth)
                context.strokePath()
            }
            return true
        }
    }
}

// MARK: - Tile

/// A pinned site: its favicon, and its title as the tooltip. Selected, it takes on the favicon's color: a faint
/// fill, and a border in the color itself.
final class PinnedSiteTileView: NSView {
    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    static let iconSize: CGFloat = 18

    private let iconView = FaviconImageView(frame: .zero)
    private var tile: PinnedSitesView.Tile?
    private var faviconColor: NSColor?
    private var isHovering = false
    private var faviconTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull()]

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.image = Self.globe
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        faviconTask?.cancel()
    }

    func configure(with tile: PinnedSitesView.Tile) {
        guard tile != self.tile else { return }
        let urlChanged = tile.url != self.tile?.url
        self.tile = tile
        toolTip = tile.title
        setAccessibilityLabel(tile.title)
        if urlChanged {
            iconView.image = Self.globe
            iconView.contentTintColor = .secondaryLabelColor
            faviconColor = nil
            loadFavicon()
        }
        updateFill()
    }

    func loadFavicon() {
        guard let url = tile?.url else { return }
        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let image = await FaviconCacheManager.shared.getFavicon(for: url),
                  let self, !Task.isCancelled, self.tile?.url == url else { return }
            self.showFavicon(image)
        }
    }

    func showCachedFavicon(for url: String) {
        guard let image = FaviconCacheManager.shared.cachedFavicon(for: url) else { return }
        faviconTask?.cancel()
        showFavicon(image)
    }

    private func showFavicon(_ image: NSImage) {
        guard iconView.image !== image else { return }
        iconView.image = image
        iconView.contentTintColor = nil
        faviconColor = Self.prominentColor(of: image)
        updateFill()
    }

    /// Its favicon to drag: the image itself, sharp at any size; the globe
    /// symbol as drawn, in its tint.
    func draggingIcon() -> NSImage? {
        if let image = iconView.image, !image.isTemplate {
            return image
        }
        let rect = iconView.bounds
        guard !rect.isEmpty, let bitmap = iconView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        iconView.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    // Clicks go to the tile rather than its image view, and from there up
    // to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = Self.iconSize
        iconView.frame = CGRect(x: ((bounds.width - size) / 2).rounded(), y: ((bounds.height - size) / 2).rounded(),
                                width: size, height: size)
    }

    // MARK: Fill

    private func updateFill() {
        let isSelected = tile?.isSelected == true
        let colors = Self.fill(isSelected: isSelected, isHovering: isHovering, faviconColor: faviconColor,
                               appearance: effectiveAppearance)
        layer?.backgroundColor = colors.fill
        if let border = colors.border {
            layer?.borderColor = border
        }
        layer?.borderWidth = colors.border == nil ? 0 : Self.borderWidth
    }

    static let borderWidth: CGFloat = 1.5

    /// The tile's fill, and its border while it's selected.
    private static func fill(isSelected: Bool, isHovering: Bool, faviconColor: NSColor?,
                             appearance: NSAppearance) -> (fill: CGColor, border: CGColor?) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var colors: (fill: CGColor, border: CGColor?) = (NSColor.clear.cgColor, nil)
        appearance.performAsCurrentDrawingAppearance {
            if isSelected {
                let color = selectionColor(faviconColor, isDark: isDark)
                colors = (color.withAlphaComponent(isDark ? 0.18 : 0.12).cgColor, color.cgColor)
            } else if isHovering {
                colors = (NSColor.labelColor.withAlphaComponent(0.1).cgColor, nil)
            } else {
                colors = (NSColor.labelColor.withAlphaComponent(0.05).cgColor, nil)
            }
        }
        return colors
    }

    // MARK: Dragging

    /// A tab dragged over the pinned sites as the tile it becomes, `size`
    /// and with the tab row's favicon (SidebarTabRowView's dragging image,
    /// whose parts these replace). Not hovered: as it shows once dropped.
    static func draggingImageComponents(size: CGSize, icon: Any?, isSelected: Bool,
                                        appearance: NSAppearance) -> [NSDraggingImageComponent] {
        let colors = draggedTileColors(icon: icon as? NSImage, isSelected: isSelected, appearance: appearance)

        let background = NSDraggingImageComponent(key: .tabBackground)
        background.frame = CGRect(origin: .zero, size: size)
        background.contents = PinnedSiteDragImage.roundedRect(size: size, cornerRadius: 12, fill: colors.fill,
                                                              border: colors.border, borderWidth: borderWidth)
        var components = [background]
        if let icon {
            let iconComponent = NSDraggingImageComponent(key: .icon)
            iconComponent.frame = CGRect(x: ((size.width - iconSize) / 2).rounded(),
                                         y: ((size.height - iconSize) / 2).rounded(),
                                         width: iconSize, height: iconSize)
            iconComponent.contents = FaviconStyle.draggingContents(icon, size: iconComponent.frame.size)
            components.append(iconComponent)
        }
        return components
    }

    /// A dragged tab's fill and border as the tile it becomes, not hovered:
    /// as it shows once dropped. Its favicon's color, when it's selected.
    static func draggedTileColors(icon: NSImage?, isSelected: Bool,
                                  appearance: NSAppearance) -> (fill: CGColor, border: CGColor?) {
        let faviconColor = isSelected ? icon.flatMap(prominentColor(of:)) : nil
        return fill(isSelected: isSelected, isHovering: false, faviconColor: faviconColor, appearance: appearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    /// The favicon's color, a dark one lightened in dark mode to stand out
    /// from the sidebar; without one, a gray.
    private static func selectionColor(_ color: NSColor?, isDark: Bool) -> NSColor {
        guard let color else { return .secondaryLabelColor }
        guard isDark, let rgb = color.usingColorSpace(.sRGB), rgb.brightnessComponent < 0.6 else { return color }
        return rgb.blended(withFraction: 0.6 - rgb.brightnessComponent, of: .white) ?? color
    }

    /// The favicon's main color: the hue most of its colorful pixels share,
    /// averaged. None for a black, white or gray one.
    static func prominentColor(of image: NSImage) -> NSColor? {
        let side = 16
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let isDrawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard isDrawn else { return nil }

        let binCount = 12
        var weights = [CGFloat](repeating: 0, count: binCount)
        var reds = weights, greens = weights, blues = weights
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Premultiplied
            let red = min(1, CGFloat(pixels[offset]) / 255 / alpha)
            let green = min(1, CGFloat(pixels[offset + 1]) / 255 / alpha)
            let blue = min(1, CGFloat(pixels[offset + 2]) / 255 / alpha)
            let maxValue = max(red, green, blue)
            guard maxValue > 0.15 else { continue }
            let saturation = (maxValue - min(red, green, blue)) / maxValue
            guard saturation > 0.3 else { continue }

            let hue = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).hueComponent
            let bin = min(Int(hue * CGFloat(binCount)), binCount - 1)
            let weight = saturation * alpha
            weights[bin] += weight
            reds[bin] += red * weight
            greens[bin] += green * weight
            blues[bin] += blue * weight
        }
        // A few pixels' worth at least, not a stray one
        guard let bin = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[bin] >= 2 else { return nil }
        let weight = weights[bin]
        return NSColor(srgbRed: reds[bin] / weight, green: greens[bin] / weight, blue: blues[bin] / weight, alpha: 1)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        updateFill()
    }
}

// MARK: - SwiftUI

/// The pinned sites, sized to their rows: nothing while there are none,
/// unless a tab is being dragged.
struct PinnedSitesSection: View {
    @ObservedObject var state: PinnedSitesState
    /// Off on the overview: no clicks or drops land on it.
    var isShown = true

    nonisolated static let horizontalPadding: CGFloat = 6

    /// How far under the URL bar the grid starts, when there's one. The
    /// overview's first card starts there too.
    nonisolated static let topInset: CGFloat = 8

    nonisolated private static func topPadding(count: Int) -> CGFloat {
        count > 0 ? topInset : 0
    }

    /// The section's height at a width, its padding included. Nonisolated
    /// for `PinnedSitesSpace`'s layout.
    nonisolated static func height(count: Int, width: CGFloat) -> CGFloat {
        topPadding(count: count)
            + PinnedSitesLayout.height(count: count, width: width - 2 * horizontalPadding)
    }

    var body: some View {
        let topPadding = Self.topPadding(count: state.count)
        // Animated by the grid as it changes
        PinnedSitesBridge(state: state, count: state.count, isShown: isShown)
            .padding(.top, topPadding)
            .padding(.horizontal, Self.horizontalPadding)
    }
}

/// Room for the pinned sites over a page, as tall as they are at the width
/// it's given: it changes in the same transaction as they do, so the page
/// moves along with them.
struct PinnedSitesSpace: Layout {
    let count: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: PinnedSitesSection.height(count: count, width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

private struct PinnedSitesBridge: NSViewRepresentable {
    @EnvironmentObject var sidebarManager: SidebarManager
    @EnvironmentObject var tabManager: TabManager
    let state: PinnedSitesState
    let count: Int
    let isShown: Bool

    func makeNSView(context: Context) -> PinnedSitesView {
        let view = PinnedSitesView(sidebarManager: sidebarManager, tabManager: tabManager, state: state)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PinnedSitesView, context: Context) {
        view.isShown = isShown
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PinnedSitesView, context: Context) -> CGSize? {
        let width = proposal.width ?? view.bounds.width
        return CGSize(width: width, height: PinnedSitesLayout.height(count: count, width: width))
    }
}
