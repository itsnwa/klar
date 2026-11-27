import AppKit
import Combine
import WebKit

/// Receives row-level events from the rows view (selection, expansion,
/// rename, etc.). The owning view controller adopts this.
protocol SidebarRowsViewDelegate: AnyObject {
    func rowsView(_ rowsView: SidebarRowsView, didActivateTab tabID: UUID)
    func rowsView(_ rowsView: SidebarRowsView, didActivateRegularTab tabID: UUID)
    func rowsView(_ rowsView: SidebarRowsView, didToggleFolder folderID: UUID)
    func rowsView(_ rowsView: SidebarRowsView, didToggleCollection collectionID: UUID)
    func rowsView(_ rowsView: SidebarRowsView, didRequestRenameForItem itemID: UUID)
    func rowsViewDidRequestNewTab(_ rowsView: SidebarRowsView, isPrivate: Bool)
    func rowsView(_ rowsView: SidebarRowsView, didRequestContextMenuFor key: SidebarRowKey, at point: CGPoint)
}

/// The motion of the sidebar list's expand/collapse. One critically damped
/// spring drives every part of it — the disclosing rows, the rows below
/// them, the clip edge revealing them — so they stay in lockstep by
/// construction, and a second toggle can pick up from wherever the first
/// one is.
enum SidebarMotion {
    /// How long the motion takes to look done. The spring keeps settling,
    /// sub-pixel, for a while after that (`settlingDuration`).
    static let perceptualDuration: CFTimeInterval = 0.2
    /// For motion a spring can't express directly (the collection chevron's
    /// keyframed rotation): an ease-out close to the spring's shape.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)

    static func spring(keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: perceptualDuration, bounce: 0)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// Custom NSView-based sidebar list. Replaces NSOutlineView entirely.
///
/// Owns the entire sidebar's row hierarchy: collection header, organized
/// tabs / folders (with peek), divider, new-tab button, regular tabs.
/// Layout is computed by `SidebarLayoutEngine`; this view gives row views
/// only to the rows in and near the visible part of the scroll view (vended
/// from small reuse pools), sets their frames, animates folder disclosure,
/// and forwards user interactions.
final class SidebarRowsView: NSView {
    weak var delegate: SidebarRowsViewDelegate?

    // The data the layout engine works against. Set by the controller.
    var sidebarManager: SidebarManager?
    var tabManager: TabManager?
    /// Set to show a space other than the active one (the page beside it
    /// while swiping), with the item switching to it would select. Nil
    /// shows the active space and its selection.
    var previewedSpace: SpacePreview?

    struct SpacePreview {
        let spaceID: UUID
        let selectedItemID: UUID?
    }

    /// The current layout, top to bottom. While a transition is running these
    /// are the frames it is heading for.
    private var rows: [SidebarRow] = []
    private var rowIndexByKey: [SidebarRowKey: Int] = [:]
    /// `bounds.width` the current `rows` were laid out for. `layout()` reloads
    /// only when this goes stale.
    private var laidOutWidth: CGFloat = -1
    /// Expansion state the current `rows` were laid out for. An animated
    /// reload diffs against it to find the folder (or the collection) that
    /// was toggled.
    private var laidOutExpandedFolders: Set<UUID> = []
    private var laidOutCollectionExpanded = true
    /// The space the current `rows` show. Switching to another lays out at
    /// once, along with what changes with it (the selection, the regular
    /// tabs), which comes in reloads queued on the main queue as it
    /// switches: animated, the rows every space has (the divider, New Tab,
    /// the regular tabs) slid from where they were in the old space.
    private var laidOutSpaceID: UUID?
    private var isSwitchingSpace = false

    /// Views of the rows in or near the visible part of the scroll view (see
    /// `realizationRect`), keyed by their stable layout key. Rows further
    /// away have no view at all, so hundreds of saved tabs cost a screenful
    /// of views — and expanding a big folder builds only what can be seen.
    private var rowViewsByKey: [SidebarRowKey: NSView] = [:]
    /// Pools of recycled row views, keyed by the row "kind" they can render.
    /// Shared by every list: a space previewed while swiping takes its rows
    /// from them instead of building a screenful on the frame the swipe
    /// starts, and gives them back as it goes, for the list the swipe lands
    /// on or the next swipe's preview.
    private static var unusedTabRowViews: [SidebarTabRowView] = []
    private static var unusedFolderRowViews: [SidebarFolderRowView] = []
    private static let maxPooledRowViews = 64
    /// How far past the visible rect rows get views, so scrolling rarely
    /// reaches a row before its view exists…
    private static let minimumOverscan: CGFloat = 300
    /// …and how much further a row may drift before its view is recycled, so
    /// scrolling back and forth doesn't churn views.
    private static let recycleHysteresis: CGFloat = 200
    private var clipViewObservers: [NSObjectProtocol] = []

    // MARK: Transitions

    /// A layout change whose animations are still running.
    private struct Transition {
        let generation: Int
        /// Set when this is a folder (or collection) disclosure, so toggling
        /// the same parent again can reverse it in place.
        let disclosure: DisclosureIdentity?
        /// Views of rows that left the layout; recycled once it settles.
        var departingViews: [SidebarRowKey: NSView]
        /// Gives a view to a row that scrolls into range while this transition
        /// runs: in the right container, moving in step with the rest.
        let placeLateRow: (SidebarRow) -> Void
    }

    private struct DisclosureIdentity {
        let parentKey: SidebarRowKey
        let isExpanding: Bool
    }

    /// How a folder's (or the collection's) rows open or close.
    private struct DisclosurePlan {
        let identity: DisclosureIdentity
        /// Index of the parent row. Every row up to and including it is the
        /// same, at the same frame, in both layouts.
        let parentIndex: Int
        /// The parent row's bottom edge — the line the group emerges from.
        let clipTop: CGFloat
        let oldGroup: [SidebarRow]
        let newGroup: [SidebarRow]
        let oldGroupHeight: CGFloat
        let newGroupHeight: CGFloat
        /// Index in `rows` of the first row below the group.
        let tailStartIndex: Int
        /// The active tab's row on each side of the toggle, when it shows on
        /// both (as the folder's peek row on the collapsed side) and is close
        /// enough to the top to travel between the two.
        let anchor: (old: SidebarRow, new: SidebarRow)?
        /// How far the group's rows slide out from behind the parent.
        let slide: CGFloat
    }

    private var transition: Transition?
    private var transitionGeneration = 0
    private static let slideAnimationKey = "sidebarRowSlide"
    /// A dropped row's slide across, from where the drag's image was.
    private static let landingAnimationKey = "sidebarRowLanding"
    private static let fadeAnimationKey = "sidebarRowFade"
    private static let fadeDuration: CFTimeInterval = 0.18
    /// Furthest a disclosing group slides out from behind its parent. Taller
    /// groups are revealed by the rows below moving away rather than slid in
    /// whole, so a 40-tab folder doesn't stream rows past the viewport.
    private static let maxDisclosureSlide: CGFloat = 3 * SidebarLayoutMetrics.standardRowHeight
    /// Furthest the peeking active tab travels between its peek spot and its
    /// place in the folder. Any deeper and the peek cross-fades instead.
    private static let maxAnchorTravel: CGFloat = 8 * SidebarLayoutMetrics.standardRowHeight

    /// Clip containers for a disclosure. `disclosureClip` starts at the
    /// parent row's bottom edge and hides anything above it, so the group
    /// slides out from behind its parent. `disclosureGroupClip`, inside it,
    /// holds the group's rows and moves with the rows below the group, so its
    /// bottom edge reveals (or covers) the group as they slide. Rectangular
    /// clipping only: a mask layer per row would cost an offscreen pass per
    /// row per frame.
    private let disclosureClip = SidebarClipView()
    private let disclosureGroupClip = SidebarClipView()

    private var hoveredKey: SidebarRowKey?
    private var trackingArea: NSTrackingArea?
    /// Folder id captured on `mouseDown` so we can fire the expand/collapse
    /// on the corresponding `mouseUp` (matching standard button-press
    /// semantics — release while still over the row commits the action,
    /// dragging off cancels it).
    private var pressedFolderID: UUID?
    /// The selected tab, pressed: activated again on `mouseUp`, which takes
    /// it back to its saved page if it's gone elsewhere. Dragging it
    /// doesn't, so the drag carries the page it's on.
    private var pressedSelectedTabID: UUID?
    /// What was selected before a press on another tab's row selected it.
    /// If that row is dragged out of the sidebar, it's selected again, so
    /// the dragged tab can be dropped beside the page that was showing.
    private var selectionBeforePress: (key: SidebarRowKey, itemID: UUID)?
    /// The tab peeking out of a closed folder as a press on another tab's
    /// row selects that one: it keeps peeking while the row is held, and
    /// for the drag that follows (`Lift.heldPeekTabID`), so the rows don't
    /// move up under the pointer.
    private var pressHeldPeekTabID: UUID?
    /// The tab the layout shows peeking, in place of the selected one
    private var heldPeekTabID: UUID? {
        lift?.heldPeekTabID ?? pressHeldPeekTabID
    }
    /// Stricter-than-system double-click threshold. The system default
    /// (`NSEvent.doubleClickInterval`, typically ~0.5s) makes it very easy
    /// to accidentally trigger a rename when the user pauses between two
    /// single clicks. We require the second click to land within
    /// `fastDoubleClickThreshold` seconds of the first to count as a
    /// rename gesture.
    private static let fastDoubleClickThreshold: TimeInterval = 0.3
    private var lastClickTime: TimeInterval = 0
    private var lastClickKey: SidebarRowKey?

    // MARK: - Drag-and-drop state

    /// Mouse-down location captured for drag-threshold detection in
    /// `mouseDragged`. Reset on `mouseUp` / drag end.
    private var dragMouseDownLocation: CGPoint = .zero
    /// Row the user pressed on. The drag, if it starts, originates here.
    private var dragMouseDownKey: SidebarRowKey?
    /// True between `beginDraggingSession` and the source's `endedAt`
    /// callback. Suppresses the deferred folder-toggle on `mouseUp`.
    private var isDraggingItem: Bool = false
    /// Pixels of movement past which a drag session is initiated.
    private static let dragStartThreshold: CGFloat = 4
    /// A row being dragged from the list, which draws it itself for the
    /// whole drag (`draggedRowView`), AppKit's image of it hidden.
    private var draggedRow: DraggedRow?
    /// The dragged row as the list draws it, from the drag's start until
    /// the layout after it, in which its row takes over.
    private var draggedRowView: SidebarDraggedRowView?
    /// Its window, over everything, while a row is dragged.
    private var dragPanel: SidebarDragPanel?
    /// The list a row is being dragged from, in any window: another
    /// window's list it's dragged over shapes it too (its indent there)
    private static weak var activeDragSource: SidebarRowsView?
    /// Every window's lists (a space's tabs, and previews of others)
    private static let lists = NSHashTable<SidebarRowsView>.weakObjects()
    /// A pinned site's drag ended put back: its tile slides back to its
    /// slot before the dragged view goes
    private var isReturningPinnedSite = false
    /// A saved tab or folder dragged over this list from another window's,
    /// lifted out of this one too while it's over it
    private var visitingItemID: UUID?
    /// The item the layout leaves out: lifted for a drag, from this list or
    /// another window's
    private var hiddenItemID: UUID? {
        lift?.itemID ?? visitingItemID
    }

    private struct DraggedRow {
        let session: NSDraggingSession
        /// The row's, and where the pointer holds it.
        let size: CGSize
        let grabOffset: CGPoint
        /// AppKit's image of it: a snapshot, shown only if its window
        /// (`SidebarDragImageWindow`, looked for as the drag first moves)
        /// can't be hidden.
        let image: NSImage?
        var imageWindow: CGWindowID?
        var hasLookedForImageWindow = false
        /// A tab's address, as it shows as a link out of the sidebar, and
        /// where its own sidebar is on screen.
        let address: String?
        let sidebarFrame: CGRect?
        /// Out of every window's sidebar, and over a window's pages
        var isOutsideSidebar = false
        var isOverPage = false
        /// Waits for a tab's page to load, to take the link's picture of it
        /// then (`snapshotPage`).
        var pageLoad: NSKeyValueObservation?
        /// The tile it'd be, over the pinned sites.
        var pinnedTile: SidebarDraggedRowView.Tile?
        /// Selected again once it's out of the sidebar (`selectionBeforePress`)
        var selectionToRestore: UUID?
        /// Picked up from the pinned sites (`beginPinnedSiteDrag`)
        var pinnedSite: PinnedSiteDrag?

        /// A pinned site's drag: the tile it is over any window's pinned
        /// sites, the grid it came from, told when it ends, and its tile's
        /// place there, on screen, which a drag put back returns to.
        struct PinnedSiteDrag {
            let tile: SidebarDraggedRowView.Tile
            weak var grid: PinnedSitesView?
            let tileScreenFrame: CGRect
        }

        /// Where it is with the pointer at `pointer`.
        func frame(at pointer: CGPoint) -> CGRect {
            CGRect(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y, width: size.width, height: size.height)
        }

        /// AppKit's image of it, `size`, as a fill, so the pinned sites don't
        /// take it for an icon.
        static func imageComponents(size: CGSize, image: NSImage?) -> [NSDraggingImageComponent] {
            let component = NSDraggingImageComponent(key: .tabBackground)
            component.frame = CGRect(origin: .zero, size: size)
            component.contents = image
            return [component]
        }
    }
    /// The row being dragged out of the list. Its place stays closed until
    /// the drag ends, wherever the drag goes.
    private var lift: Lift?
    /// Where a drag over the list would drop now: the rows make room for it
    /// (its `gap`), or the folder it would go into lights up.
    private var dropTarget: DropTarget?
    /// The list as it is without room made for a drop, and without the
    /// lifted row: what drops are worked out against, so the room made for
    /// one never moves it.
    private var dropLayoutRows: [SidebarRow] = []
    private var dropLayoutDividerIndex: Int?
    /// The lifted row and the room made that the current `rows` show. A
    /// reload that changes them animates.
    private var laidOutHiddenItemID: UUID?
    private var laidOutDropGap: DropGap?
    /// A new drop target waiting for a folder to finish opening (the drag
    /// held over it), since the disclosure's clipping can't carry over into
    /// another change.
    private var needsDropLayout = false
    /// Dropped, or put back: in the next layout, its row comes in from where
    /// the drag's image was.
    private var landing: Landing?
    /// Rows don't light up under the pointer while a drag is over the list.
    private var isDragOver = false
    /// Where a drop lands among the rows: the room made for it.
    private let dropSlotView: SidebarDropSlotView = {
        let slot = SidebarDropSlotView()
        slot.isTargeted = true
        return slot
    }()

    /// Auto-scroll timer used while a drag pointer hovers near a scroll
    /// edge. Drives `enclosingScrollView.contentView.bounds.origin.y` to
    /// pan the rows.
    private var autoScrollTimer: Timer?
    private var autoScrollVelocity: CGFloat = 0
    private static let autoScrollEdgeDistance: CGFloat = 32
    private static let autoScrollMaxSpeed: CGFloat = 14

    /// Hover-on-folder timer used during a drag to auto-expand the folder
    /// the user is hovering over (so they can drop into nested children).
    private var hoverExpandFolderID: UUID?
    private var hoverExpandTimer: Timer?
    private static let hoverExpandDelay: TimeInterval = 0.7

    /// `regularTabs` and `collectionExpanded` are local UI state owned by
    /// this view (the latter mirrors what the collection header renders).
    private(set) var regularTabs: [BrowserTab] = []
    private var regularTabsByID: [UUID: BrowserTab] = [:]
    /// The regular tabs' groups (`OpenTabStore`): each one's by tab ID, by
    /// their own, and their tabs in order
    private var regularTabGroups: [UUID: OpenTabGroup] = [:]
    private var regularGroupsByID: [UUID: OpenTabGroup] = [:]
    private var regularGroupMembers: [UUID: [UUID]] = [:]
    private var collectionExpanded: Bool = true

    /// Fixed-size views that don't change identity between layouts.
    private let dividerView = SidebarDividerView()
    private let newTabButton = SidebarNewTabButton()
    private let collectionHeaderView = SidebarCollectionHeaderView()

    override var isFlipped: Bool { true }

    /// Off while the list is out of sight (under the overview or a library
    /// list, or a space previewed while swiping), which would otherwise
    /// still take what's dropped there.
    var acceptsDrops = true {
        didSet {
            guard acceptsDrops != oldValue else { return }
            if acceptsDrops {
                registerForDraggedTypes(SidebarPasteboardTypes.dragTypes)
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        configureFixedViews()
        registerForDraggedTypes(SidebarPasteboardTypes.dragTypes)
        Self.lists.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(dragDidEnterPinnedSites(_:)),
                                               name: .sidebarItemDragDidEnterPinnedSites, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dragDidLeavePinnedSites),
                                               name: .sidebarItemDragDidLeavePinnedSites, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        for observer in clipViewObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    var totalHeight: CGFloat = 0 {
        didSet {
            if oldValue != totalHeight {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: totalHeight)
    }

    /// A reload asked for and not run yet: nil when there's none, else
    /// whether it animates.
    private var pendingReload: Bool?

    /// `reload(animated:)` on the next turn of the main queue, once for
    /// every request until then: a tab switch changes the selection and the
    /// active tab one after the other.
    func setNeedsReload(animated: Bool = false) {
        if let pending = pendingReload {
            pendingReload = pending || animated
            return
        }
        pendingReload = animated
        DispatchQueue.main.async { [weak self] in
            self?.reloadIfNeeded()
        }
    }

    /// Runs a reload asked for with `setNeedsReload`, now, for what needs
    /// the rows up to date.
    func reloadIfNeeded() {
        guard pendingReload != nil else { return }
        reload()
    }

    /// Recompute the layout from the current data and apply it. `animated`
    /// asks for the expand/collapse animation of whichever folder (or the
    /// collection) was toggled since the last layout. A drag's changes (the
    /// row it lifts out, the room made for its drop) animate anyway. Takes
    /// over a reload pending from `setNeedsReload`.
    func reload(animated: Bool = false) {
        let animated = animated || pendingReload == true
        pendingReload = nil
        guard let manager = sidebarManager else {
            applyEmpty()
            return
        }
        // Not sized yet (a space's preview as a swipe makes it): rows laid
        // out at no width break their constraints. `layout()` reloads once
        // it has one.
        guard bounds.width > 0 else { return }
        let expandedFolders = manager.expandedFolders
        let spaceID = previewedSpace?.spaceID ?? manager.spaceSelection?.currentSpaceID
        if spaceID != laidOutSpaceID {
            if laidOutSpaceID != nil {
                isSwitchingSpace = true
                DispatchQueue.main.async { [weak self] in
                    self?.isSwitchingSpace = false
                }
            }
            laidOutSpaceID = spaceID
            // A drag springing a space open: what it was over is in the old one
            lift?.hasLeftOrigin = true
            dropTarget = nil
        }
        let output = SidebarLayoutEngine.layout(SidebarLayoutEngine.Input(
            structure: manager.sidebarStructure,
            expandedFolders: expandedFolders,
            activeTabID: previewedSpace.map { $0.selectedItemID } ?? heldPeekTabID ?? manager.selectedItem,
            regularTabs: regularTabs,
            regularTabGroups: regularTabGroups.mapValues(\.id),
            collectionExpanded: collectionExpanded,
            spaceID: spaceID,
            width: bounds.width,
            hiddenItemID: hiddenItemID
        ))
        let gap = dropTarget?.gap
        let newRows = makingRoom(for: gap, in: output.rows)
        // The slot where the first regular tab would be, with none, is
        // below the gap above them
        let newTotalHeight = gap.map {
            max(output.totalHeight + SidebarLayoutMetrics.standardRowHeight,
                $0.y + SidebarLayoutMetrics.standardRowHeight + SidebarLayoutMetrics.contentBottomInsideSeparator)
        } ?? output.totalHeight
        let toggledParent = animated ? toggledDisclosureParent(expandedFolders: expandedFolders) : nil
        let dragChanged = hiddenItemID != laidOutHiddenItemID || gap != laidOutDropGap
        let landing = self.landing
        self.landing = nil
        if lift == nil, !isReturningPinnedSite {
            // The drag is over: its row takes over in this layout, coming in
            // from where it was
            removeDraggedRowView()
        } else if let draggedRowView {
            // Live, like the rows: a new title, the selection
            configure(view: draggedRowView.row, for: draggedRowView.layoutRow)
        }
        let oldRows = rows
        let oldIndexByKey = rowIndexByKey
        let geometryUnchanged = Self.haveSameGeometry(oldRows, newRows)

        rows = newRows
        rowIndexByKey = Self.indexByKey(rows)
        dropLayoutRows = output.rows
        dropLayoutDividerIndex = output.rows.firstIndex { $0.key == .divider }
        laidOutWidth = bounds.width
        laidOutExpandedFolders = expandedFolders
        laidOutCollectionExpanded = collectionExpanded
        laidOutHiddenItemID = hiddenItemID
        laidOutDropGap = gap

        if geometryUnchanged {
            // Data only (a title, a favicon, the selection highlight): leave
            // any motion in flight alone and refresh what's on screen.
            refreshRealizedRowContents()
            return
        }

        let canAnimate = window != nil
            && !oldRows.isEmpty
            && !isSwitchingSpace
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let plan = canAnimate
            ? toggledParent.flatMap { makeDisclosurePlan(parentKey: $0, oldRows: oldRows, oldIndexByKey: oldIndexByKey) }
            : nil

        if let inFlight = transition?.disclosure {
            let reverses = plan.map {
                $0.identity.parentKey == inFlight.parentKey && $0.identity.isExpanding != inFlight.isExpanding
            } ?? false
            if !reverses {
                // Its clipping can't carry over into a different change; end it
                // where it was heading.
                finishTransition()
            }
        }

        if let plan {
            runDisclosure(plan, totalHeight: newTotalHeight)
        } else if canAnimate && (animated || dragChanged || landing != nil
                                 || Self.peekKeys(in: oldRows) != Self.peekKeys(in: rows)) {
            // A peek row appearing or going away (the active tab moved into or
            // out of a collapsed folder, or was closed), or a drag: slide the
            // rows instead of jumping them.
            runGenericTransition(from: oldRows, oldIndexByKey: oldIndexByKey, totalHeight: newTotalHeight, landing: landing)
        } else {
            finishTransition()
            totalHeight = newTotalHeight
            applyLayoutImmediately()
        }
    }

    /// `rows` with room made for a drop at `gap`: the rows from its `y`
    /// down move a row further down, and the drop's slot takes their place.
    private func makingRoom(for gap: DropGap?, in rows: [SidebarRow]) -> [SidebarRow] {
        guard let gap else { return rows }
        let height = SidebarLayoutMetrics.standardRowHeight
        let indent = CGFloat(gap.depth) * SidebarLayoutMetrics.depthIndent
        let padding = SidebarLayoutMetrics.outerHorizontalPadding
        let split = rows.firstIndex { $0.frame.minY >= gap.y } ?? rows.count
        var result = Array(rows[..<split])
        result.reserveCapacity(rows.count + 1)
        result.append(SidebarRow(
            key: .dropSlot,
            frame: CGRect(x: padding + indent, y: gap.y,
                          width: max(0, bounds.width - padding * 2 - indent), height: height),
            depth: gap.depth
        ))
        for row in rows[split...] {
            result.append(SidebarRow(key: row.key, frame: row.frame.offsetBy(dx: 0, dy: height), depth: row.depth))
        }
        return result
    }

    /// Updates the unorganized browser tabs shown below the divider, and the
    /// groups they're in, by tab ID. The caller reloads afterwards.
    func setRegularTabs(_ tabs: [BrowserTab], groups: [UUID: OpenTabGroup] = [:]) {
        regularTabs = tabs
        regularTabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        regularTabGroups = groups
        regularGroupsByID = [:]
        regularGroupMembers = [:]
        for tab in tabs {
            guard let group = groups[tab.id] else { continue }
            if regularGroupsByID[group.id] == nil { regularGroupsByID[group.id] = group }
            regularGroupMembers[group.id, default: []].append(tab.id)
        }
        dividerView.canCloseAll = !tabs.isEmpty
    }

    /// The divider's Close All: every regular tab shown here, in groups or
    /// not, closed as ⌘W closes one, so one ⌘Z brings them all back
    private func closeRegularTabs() {
        guard let tabManager, !regularTabs.isEmpty else { return }
        tabManager.closeTabsUndoably(regularTabs)
    }

    /// A group of regular tabs shown here
    func isRegularGroup(_ id: UUID) -> Bool {
        regularGroupsByID[id] != nil
    }

    /// The regular tab right after a group's, where something put after
    /// the group goes; nil at the end.
    private func regularTab(after groupID: UUID) -> UUID? {
        guard let last = regularGroupMembers[groupID]?.last,
              let index = regularTabs.firstIndex(where: { $0.id == last }) else { return nil }
        return regularTabs[(index + 1)...].first { regularTabGroups[$0.id]?.id != groupID }?.id
    }

    /// The regular tab after `tabID` in its group, or after its group
    private func regularTab(followingInGroup tabID: UUID) -> UUID? {
        guard let groupID = regularTabGroups[tabID]?.id, let members = regularGroupMembers[groupID],
              let index = members.firstIndex(of: tabID) else { return nil }
        return members.indices.contains(index + 1) ? members[index + 1] : regularTab(after: groupID)
    }

    func setCollectionExpanded(_ expanded: Bool) {
        guard collectionExpanded != expanded else { return }
        collectionExpanded = expanded
        reload(animated: true)
    }

    func collectionExpandedState() -> Bool {
        return collectionExpanded
    }

    /// Returns the live row view for a layout key, if one is currently
    /// vended. Used by the controller to anchor popovers / sharing
    /// pickers to the specific cell that was right-clicked.
    func rowView(for key: SidebarRowKey) -> NSView? {
        reloadIfNeeded()
        return rowViewsByKey[key]
    }

    /// Scrolls the sidebar so the row for `key` is visible — which also
    /// gives it a view.
    func scrollRowToVisible(_ key: SidebarRowKey) {
        // A reload that just grew the list has only invalidated this view's
        // intrinsic height; lay out first, or a row past the old end can't be
        // scrolled to. (Layout can reload the rows, so look the row up after.)
        enclosingScrollView?.layoutSubtreeIfNeeded()
        guard let index = rowIndexByKey[key] else { return }
        _ = scrollToVisible(rows[index].frame.insetBy(dx: 0, dy: -8))
    }

    /// Scrolls the saved tab, folder, collection or regular tab `itemID` into
    /// view — e.g. so a row that is about to be renamed has a view to edit in.
    func revealItem(_ itemID: UUID) {
        for key in [SidebarRowKey.tab(itemID), .folder(itemID), .collectionHeader(itemID), .regularTab(itemID)] where rowIndexByKey[key] != nil {
            scrollRowToVisible(key)
            return
        }
        // The active tab inside a collapsed folder shows as that folder's peek row.
        if let peek = rows.first(where: { Self.peekUUID(of: $0.key) == itemID }) {
            scrollRowToVisible(peek.key)
        }
    }

    /// Force re-config of a single row's content (e.g. after a rename or
    /// favicon update) without recomputing the whole layout.
    func refreshRow(forItem itemID: UUID) {
        for (key, view) in rowViewsByKey {
            let matches: Bool
            switch key {
            case .tab(let id), .folder(let id), .collectionHeader(let id):
                matches = id == itemID
            case .peekTab(let tabID, _):
                matches = tabID == itemID
            default:
                matches = false
            }
            guard matches, let index = rowIndexByKey[key] else { continue }
            configure(view: view, for: rows[index])
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Recompute on width changes so rows track sidebar resizing. A width
        // change mid-transition waits for it to settle (`transitionDidSettle`
        // re-checks) instead of cutting it short.
        if laidOutWidth != bounds.width && transition == nil {
            reload()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A previewed space is done with once the swipe ends: its rows go
        // back to the shared pools
        if window == nil, previewedSpace != nil {
            applyEmpty()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        for observer in clipViewObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        clipViewObservers.removeAll()
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsBoundsChangedNotifications = true
        // Delivered synchronously (`queue: nil`): rows have to get their
        // views in the same pass as the scroll, or fast scrolling shows gaps.
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: clipView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateRealizedRows()
                    // Scrolling moves the rows under a pointer that stays put
                    self?.refreshHoveredKey()
                }
            }
            clipViewObservers.append(observer)
        }
    }

    /// Rows intersecting this get views: the scroll view's visible rect plus
    /// overscan. It depends on the clip view only — not on whether the
    /// sidebar itself is on screen — so sliding the sidebar away and back
    /// changes nothing.
    private var realizationRect: CGRect {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let overscan = max(Self.minimumOverscan, visible.height / 2)
        return visible.insetBy(dx: 0, dy: -overscan)
    }

    /// Gives views to rows that scrolled into range and recycles the ones
    /// that scrolled well out of it.
    private func updateRealizedRows() {
        guard !rows.isEmpty else { return }
        let rect = realizationRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let transition {
            // Rows scrolled into range mid-transition join it in step. Nothing
            // is recycled until it settles; this runs again then.
            for index in rowIndices(intersecting: rect) where rowViewsByKey[rows[index].key] == nil {
                transition.placeLateRow(rows[index])
            }
            return
        }
        let retainRect = rect.insetBy(dx: 0, dy: -Self.recycleHysteresis)
        for (key, view) in rowViewsByKey where !Self.isFixedRow(key) && !isPinned(key) {
            guard let index = rowIndexByKey[key], !rows[index].frame.intersects(retainRect) else { continue }
            rowViewsByKey[key] = nil
            retire(view)
        }
        for index in rowIndices(intersecting: rect) where rowViewsByKey[rows[index].key] == nil {
            let row = rows[index]
            let view = makeRowView(for: row.key)
            adopt(view, for: row, in: self)
            view.frame = row.frame
        }
    }

    /// Applies `rows` as they are: every row in range gets its view at its
    /// frame, everything else is recycled.
    private func applyLayoutImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var available = takeAllViews()
        let rect = realizationRect
        let retainRect = rect.insetBy(dx: 0, dy: -Self.recycleHysteresis)
        for row in rows where rowViewsByKey[row.key] == nil {
            let view = available.removeValue(forKey: row.key)
            let wanted = Self.isFixedRow(row.key) || isPinned(row.key)
                || row.frame.intersects(view == nil ? rect : retainRect)
            guard wanted else {
                if let view { retire(view) }
                continue
            }
            let rowView = view ?? makeRowView(for: row.key)
            adopt(rowView, for: row, in: self)
            rowView.frame = row.frame
        }
        for view in available.values {
            retire(view)
        }
        removeDisclosureClips()
        CATransaction.commit()
        refreshHoveredKey()
    }

    private func applyEmpty() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in takeAllViews().values {
            retire(view)
        }
        removeDisclosureClips()
        CATransaction.commit()
        rows.removeAll()
        rowIndexByKey.removeAll()
        totalHeight = 0
    }

    // MARK: - Disclosure

    /// The folder (or the collection) whose expansion changed since the
    /// current rows were laid out — if exactly one did.
    private func toggledDisclosureParent(expandedFolders: Set<UUID>) -> SidebarRowKey? {
        let toggledFolders = expandedFolders.symmetricDifference(laidOutExpandedFolders)
        if collectionExpanded != laidOutCollectionExpanded {
            guard toggledFolders.isEmpty, let header = rows.first, case .collectionHeader = header.key else { return nil }
            return header.key
        }
        guard toggledFolders.count == 1, let folderID = toggledFolders.first else { return nil }
        return .folder(folderID)
    }

    /// Works out how `parentKey`'s rows open or close between `oldRows` and
    /// the current `rows`. `nil` unless that toggle is the only difference
    /// between the two layouts and the parent is in view.
    private func makeDisclosurePlan(parentKey: SidebarRowKey, oldRows: [SidebarRow], oldIndexByKey: [SidebarRowKey: Int]) -> DisclosurePlan? {
        guard let parentIndex = oldIndexByKey[parentKey], rowIndexByKey[parentKey] == parentIndex else { return nil }
        let parent = rows[parentIndex]
        guard oldRows[parentIndex].frame == parent.frame, parent.frame.intersects(realizationRect) else { return nil }
        // Everything above the group is untouched…
        for index in 0..<parentIndex where oldRows[index].key != rows[index].key || oldRows[index].frame != rows[index].frame {
            return nil
        }
        let oldRange = Self.groupRange(in: oldRows, parentIndex: parentIndex)
        let newRange = Self.groupRange(in: rows, parentIndex: parentIndex)
        let oldGroup = Array(oldRows[oldRange])
        let newGroup = Array(rows[newRange])
        let clipTop = parent.frame.maxY
        let oldHeight = (oldGroup.last?.frame.maxY ?? clipTop) - clipTop
        let newHeight = (newGroup.last?.frame.maxY ?? clipTop) - clipTop
        guard oldHeight != newHeight else { return nil }
        // …and everything below it is the same rows, shifted by the change in
        // the group's height.
        let shift = newHeight - oldHeight
        guard oldRows.count - oldRange.upperBound == rows.count - newRange.upperBound else { return nil }
        for (old, new) in zip(oldRows[oldRange.upperBound...], rows[newRange.upperBound...])
        where old.key != new.key || old.frame.offsetBy(dx: 0, dy: shift) != new.frame {
            return nil
        }

        let isExpanding = newHeight > oldHeight
        // The collapsed side shows at most the active tab's peek row.
        let collapsedSide = isExpanding ? oldGroup : newGroup
        let expandedSide = isExpanding ? newGroup : oldGroup
        guard collapsedSide.count <= 1, collapsedSide.allSatisfy({ Self.isPeekKey($0.key) }) else { return nil }

        var anchor: (old: SidebarRow, new: SidebarRow)?
        if let peek = collapsedSide.first,
           let tabID = Self.peekUUID(of: peek.key),
           let match = expandedSide.first(where: { Self.tabUUID(of: $0.key) == tabID }),
           match.frame.minY - clipTop <= Self.maxAnchorTravel {
            anchor = isExpanding ? (old: peek, new: match) : (old: match, new: peek)
        }
        let slide: CGFloat
        if let anchor {
            // The rows move in step with the active tab between its peek spot
            // and its place in the folder.
            slide = (isExpanding ? anchor.new : anchor.old).frame.minY - clipTop
        } else {
            slide = min(abs(shift), Self.maxDisclosureSlide)
        }

        return DisclosurePlan(
            identity: DisclosureIdentity(parentKey: parentKey, isExpanding: isExpanding),
            parentIndex: parentIndex,
            clipTop: clipTop,
            oldGroup: oldGroup,
            newGroup: newGroup,
            oldGroupHeight: oldHeight,
            newGroupHeight: newHeight,
            tailStartIndex: newRange.upperBound,
            anchor: anchor,
            slide: slide
        )
    }

    /// Opens or closes a folder's (or the collection's) rows.
    ///
    /// The group's rows slide `plan.slide` out from behind the parent (or
    /// back behind it) inside `disclosureGroupClip`, whose bottom edge moves
    /// with the rows below the group. So the group is revealed (or covered)
    /// from the bottom as those rows slide away (or back), while its top
    /// emerges from behind the parent: no gaps, no rows crossing, and a
    /// 40-row folder only ever moves the rows that can be seen. When the
    /// active tab peeks under the folder, the slide is exactly the distance
    /// between its peek spot and its place in the folder, so it stays put on
    /// screen as the same view and the rows open around it.
    ///
    /// Everything is an additive `position.y` spring from "where it is" to
    /// its new frame. When this reverses a disclosure still in flight, "where
    /// it is" is read off the screen, clip edge included, so it turns around
    /// smoothly.
    private func runDisclosure(_ plan: DisclosurePlan, totalHeight newTotalHeight: CGFloat) {
        let onScreen = captureOnScreenPositions()
        let onScreenClipEdge = transition?.disclosure == nil ? nil : onScreenGroupClipEdge()
        let generation = nextTransitionGeneration()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.transitionDidSettle(generation: generation)
        }

        var available = takeAllViews()
        var departing: [SidebarRowKey: NSView] = [:]
        let clamp = scrollClamp(forTotalHeight: newTotalHeight)
        let rect = realizationRect.union(realizationRect.offsetBy(dx: 0, dy: -clamp))

        let clipTop = plan.clipTop
        let expandedHeight = max(plan.oldGroupHeight, plan.newGroupHeight)
        // The group clip reaches this far above `clipTop`, so its own top
        // edge never clips; `disclosureClip` does that.
        let margin = expandedHeight + plan.slide
        let groupClipOriginY = clipTop - margin
        // Where the group clip's bottom edge starts, relative to where it
        // ends: the top of the rows below the group.
        let groupClipOffset = (onScreenClipEdge ?? clipTop + plan.oldGroupHeight) - (clipTop + plan.newGroupHeight)

        disclosureClip.frame = CGRect(x: 0, y: clipTop, width: bounds.width, height: expandedHeight)
        disclosureClip.layer?.zPosition = 0
        if disclosureClip.superview !== self { addSubview(disclosureClip) }
        disclosureGroupClip.frame = CGRect(x: 0, y: -margin, width: bounds.width, height: margin + plan.newGroupHeight)
        if disclosureGroupClip.superview !== disclosureClip { disclosureClip.addSubview(disclosureGroupClip) }
        addSlide(to: disclosureGroupClip, from: groupClipOffset)

        // The parent and everything above it stay where they are.
        for row in rows[...plan.parentIndex] {
            guard let view = available.removeValue(forKey: row.key) else { continue }
            if case .collectionHeader = row.key {
                collectionHeaderView.setExpanded(collectionExpanded, animated: true)
            }
            adopt(view, for: row, in: self)
            view.frame = row.frame
            if let y = onScreen[ObjectIdentifier(view)] {
                addSlide(to: view, from: y - row.frame.minY)
            }
        }

        if plan.identity.isExpanding {
            for row in plan.newGroup {
                let isAnchor = row.key == plan.anchor?.new.key
                var view = available.removeValue(forKey: row.key)
                if view == nil, isAnchor, let peekKey = plan.anchor?.old.key {
                    view = available.removeValue(forKey: peekKey)
                }
                let restingStartY = isAnchor ? clipTop : row.frame.minY - plan.slide
                let startY = view.map { onScreen[ObjectIdentifier($0)] ?? restingStartY } ?? restingStartY
                guard view != nil || Self.sweep(from: startY, to: row.frame).intersects(rect) else { continue }
                let rowView = view ?? makeRowView(for: row.key)
                adopt(rowView, for: row, in: disclosureGroupClip)
                rowView.frame = row.frame.offsetBy(dx: 0, dy: -groupClipOriginY)
                addSlide(to: rowView, from: startY - row.frame.minY - groupClipOffset)
            }
            // The peek row, when the active tab is too deep in the folder to
            // carry over: fade it out on top while the folder opens beneath.
            for row in plan.oldGroup where row.key != plan.anchor?.old.key {
                guard let view = available.removeValue(forKey: row.key) else { continue }
                if view.superview !== self { addSubview(view) }
                view.frame = row.frame
                view.layer?.zPosition = 1
                fadeOut(view)
                departing[row.key] = view
            }
        } else {
            for row in plan.oldGroup {
                let isAnchor = row.key == plan.anchor?.old.key
                let view = available.removeValue(forKey: row.key)
                let endFrame = row.frame.offsetBy(dx: 0, dy: -plan.slide)
                let startY = view.map { onScreen[ObjectIdentifier($0)] ?? row.frame.minY } ?? row.frame.minY
                guard view != nil || Self.sweep(from: startY, to: endFrame).intersects(rect) else { continue }
                let rowView = view ?? makeRowView(for: row.key)
                if isAnchor, let peekRow = plan.anchor?.new {
                    // Carried over: it ends up as the folder's peek row.
                    adopt(rowView, for: peekRow, in: disclosureGroupClip)
                } else {
                    if rowView.superview !== disclosureGroupClip { disclosureGroupClip.addSubview(rowView) }
                    if view == nil { configure(view: rowView, for: row) }
                    rowView.alphaValue = 1
                    rowView.isHidden = false
                    rowView.layer?.zPosition = 0
                    departing[row.key] = rowView
                }
                rowView.frame = endFrame.offsetBy(dx: 0, dy: -groupClipOriginY)
                addSlide(to: rowView, from: startY - endFrame.minY - groupClipOffset)
            }
            // The peek row, when the active tab is too deep in the folder to
            // carry over: fade it in on top while the folder closes beneath.
            for row in plan.newGroup where row.key != plan.anchor?.new.key {
                let view = available.removeValue(forKey: row.key) ?? makeRowView(for: row.key)
                adopt(view, for: row, in: self)
                view.frame = row.frame
                fadeIn(view)
            }
        }

        // The rows below the group move with the group clip's bottom edge.
        let shift = plan.newGroupHeight - plan.oldGroupHeight
        for row in rows[plan.tailStartIndex...] where rowViewsByKey[row.key] == nil {
            let view = available.removeValue(forKey: row.key)
            let startY = view.map { onScreen[ObjectIdentifier($0)] ?? $0.frame.minY } ?? row.frame.minY - shift
            guard view != nil || Self.isFixedRow(row.key) || Self.sweep(from: startY, to: row.frame).intersects(rect) else { continue }
            let rowView = view ?? makeRowView(for: row.key)
            adopt(rowView, for: row, in: self)
            rowView.frame = row.frame
            addSlide(to: rowView, from: startY - row.frame.minY)
        }

        for view in available.values {
            retire(view)
        }
        let placeLateRow: (SidebarRow) -> Void = { [weak self] row in
            guard let self = self, let index = self.rowIndexByKey[row.key] else { return }
            let view = self.makeRowView(for: row.key)
            if index > plan.parentIndex && index < plan.tailStartIndex && plan.identity.isExpanding {
                self.adopt(view, for: row, in: self.disclosureGroupClip)
                view.frame = row.frame.offsetBy(dx: 0, dy: -groupClipOriginY)
                self.addSlide(to: view, from: -plan.slide - groupClipOffset, inStepWithTransition: true)
            } else {
                self.adopt(view, for: row, in: self)
                view.frame = row.frame
                if index >= plan.tailStartIndex {
                    self.addSlide(to: view, from: -shift, inStepWithTransition: true)
                }
            }
        }
        transition = Transition(
            generation: generation,
            disclosure: plan.identity,
            departingViews: departing,
            placeLateRow: placeLateRow
        )
        applyTotalHeight(newTotalHeight, scrollClamp: clamp)
        CATransaction.commit()
        refreshHoveredKey()
    }

    // MARK: - Other transitions

    /// Animates any other layout change: rows that stay slide to their new
    /// frames (from wherever they are on screen), new rows fade in, rows that
    /// left go at once while the rows below glide up into their place. The
    /// row `landing` names comes in from where the drag's image was, and the
    /// drop's slot fades out under it.
    private func runGenericTransition(from oldRows: [SidebarRow], oldIndexByKey: [SidebarRowKey: Int],
                                      totalHeight newTotalHeight: CGFloat, landing: Landing? = nil) {
        let onScreen = captureOnScreenPositions()
        let generation = nextTransitionGeneration()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.transitionDidSettle(generation: generation)
        }

        var available = takeAllViews()
        var departing: [SidebarRowKey: NSView] = [:]
        let clamp = scrollClamp(forTotalHeight: newTotalHeight)
        let rect = realizationRect.union(realizationRect.offsetBy(dx: 0, dy: -clamp))
        for row in rows where rowViewsByKey[row.key] == nil {
            let view = available.removeValue(forKey: row.key)
            let landingOrigin = landing.flatMap { $0.lands(row.key) ? $0.origin : nil }
            let startY: CGFloat? = landingOrigin?.y
                ?? view.map { onScreen[ObjectIdentifier($0)] ?? $0.frame.minY }
                ?? oldIndexByKey[row.key].map { oldRows[$0].frame.minY }
            let wanted = view != nil || Self.isFixedRow(row.key) || isPinned(row.key)
                || Self.sweep(from: startY ?? row.frame.minY, to: row.frame).intersects(rect)
            guard wanted else { continue }
            // The drop's slot, back before it had faded out
            let wasFadingOut = view.map { $0.alphaValue == 0 } ?? false
            let rowView = view ?? makeRowView(for: row.key)
            adopt(rowView, for: row, in: self)
            rowView.frame = row.frame
            if let landingOrigin {
                land(rowView, from: landingOrigin, at: row.frame)
            } else if let startY {
                addSlide(to: rowView, from: startY - row.frame.minY)
                if wasFadingOut { fadeIn(rowView) }
            } else {
                fadeIn(rowView)
            }
        }
        if let slot = available.removeValue(forKey: .dropSlot) {
            if slot.alphaValue > 0 {
                // Under the rows that close over it
                slot.layer?.zPosition = -1
                fadeOut(slot)
                departing[.dropSlot] = slot
            } else {
                retire(slot)
            }
        }
        for view in available.values {
            retire(view)
        }
        removeDisclosureClips()
        let placeLateRow: (SidebarRow) -> Void = { [weak self] row in
            guard let self = self else { return }
            let view = self.makeRowView(for: row.key)
            self.adopt(view, for: row, in: self)
            view.frame = row.frame
            if let oldIndex = oldIndexByKey[row.key] {
                self.addSlide(to: view, from: oldRows[oldIndex].frame.minY - row.frame.minY, inStepWithTransition: true)
            } else {
                self.fadeIn(view)
            }
        }
        transition = Transition(generation: generation, disclosure: nil, departingViews: departing, placeLateRow: placeLateRow)
        applyTotalHeight(newTotalHeight, scrollClamp: clamp)
        CATransaction.commit()
        refreshHoveredKey()
    }

    // MARK: - Transition bookkeeping

    private func nextTransitionGeneration() -> Int {
        transitionGeneration += 1
        return transitionGeneration
    }

    /// Core Animation's completion for the transition `generation`: hand the
    /// rows back to the rows view, recycle what left, and catch up on any
    /// width or viewport change that waited.
    private func transitionDidSettle(generation: Int) {
        guard transition?.generation == generation else { return }
        finishTransition()
        if laidOutWidth != bounds.width {
            reload()
        } else {
            updateRealizedRows()
        }
        refreshHoveredKey()
    }

    /// Ends the transition in flight at its end state: live rows move out of
    /// the clip containers to their frames, departing rows are recycled.
    private func finishTransition() {
        guard let transition else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.transition = nil
        for view in transition.departingViews.values where !rowViewsByKey.values.contains(where: { $0 === view }) {
            retire(view)
        }
        for view in rowViewsByKey.values {
            stopMotion(of: view)
            if let container = view.superview, container !== self {
                let frame = convert(view.frame, from: container)
                addSubview(view)
                view.frame = frame
            }
        }
        removeDisclosureClips()
        CATransaction.commit()
    }

    /// Ends whatever transition is in flight without settling it, and hands
    /// back every view on hand — the live ones and any still leaving — keyed
    /// by the row they show, for the caller to re-adopt or retire. Leaves
    /// `rowViewsByKey` empty. Call inside a CATransaction with actions
    /// disabled, so taking it apart and building the next one land together.
    private func takeAllViews() -> [SidebarRowKey: NSView] {
        var views = rowViewsByKey
        rowViewsByKey.removeAll()
        if let transition {
            self.transition = nil
            for (key, view) in transition.departingViews {
                if let live = views[key], live !== view {
                    retire(view)
                } else {
                    views[key] = view
                }
            }
        }
        for view in views.values {
            stopMotion(of: view)
        }
        stopMotion(of: disclosureGroupClip)
        return views
    }

    private func removeDisclosureClips() {
        guard disclosureClip.superview != nil || disclosureGroupClip.superview != nil else { return }
        stopMotion(of: disclosureGroupClip)
        // Nothing should be left inside by now; re-home anything that is.
        for view in disclosureGroupClip.subviews {
            if let key = rowViewsByKey.first(where: { $0.value === view })?.key, let index = rowIndexByKey[key] {
                addSubview(view)
                view.frame = rows[index].frame
            } else {
                retire(view)
            }
        }
        disclosureGroupClip.removeFromSuperview()
        disclosureClip.removeFromSuperview()
    }

    /// Where each view on hand is drawn right now (rowsView coords, top
    /// edge), keyed by view. Empty unless a transition is running.
    private func captureOnScreenPositions() -> [ObjectIdentifier: CGFloat] {
        guard let transition else { return [:] }
        var positions: [ObjectIdentifier: CGFloat] = [:]
        for view in rowViewsByKey.values {
            positions[ObjectIdentifier(view)] = onScreenMinY(of: view)
        }
        for view in transition.departingViews.values {
            positions[ObjectIdentifier(view)] = onScreenMinY(of: view)
        }
        return positions
    }

    /// Where the bottom edge of the group clip is drawn right now, in rowsView
    /// coords.
    private func onScreenGroupClipEdge() -> CGFloat? {
        guard disclosureGroupClip.superview != nil else { return nil }
        return onScreenMinY(of: disclosureGroupClip) + disclosureGroupClip.frame.height
    }

    /// Where `view` is drawn right now, in rowsView coords: its frame plus the
    /// slide in flight on it and on any clip container holding it. The model
    /// frame alone already holds the slide's destination.
    private func onScreenMinY(of view: NSView) -> CGFloat {
        var y = view.frame.minY + slideOffset(of: view)
        var container = view.superview
        while let current = container, current !== self {
            y += current.frame.minY + slideOffset(of: current)
            container = current.superview
        }
        return y
    }

    /// The part of `view`'s position its slide currently adds. With nothing
    /// attached, the presentation layer is just a stale snapshot, so 0.
    private func slideOffset(of view: NSView) -> CGFloat {
        guard let layer = view.layer,
              layer.animation(forKey: Self.slideAnimationKey) != nil,
              let presentation = layer.presentation() else { return 0 }
        return presentation.position.y - layer.position.y
    }

    /// Slides `view` from `offset` (points, positive is down) back to its
    /// frame. Additive, so nothing depends on when AppKit syncs the frame to
    /// the layer or on the layer's anchor point.
    ///
    /// `inStepWithTransition` is for a row joining the running transition
    /// late: its slide gets the begin time the others were given at their
    /// commit, so it sits exactly where it would be had it moved all along.
    private func addSlide(to view: NSView, from offset: CGFloat, inStepWithTransition: Bool = false) {
        guard abs(offset) > 0.25, let layer = view.layer else { return }
        let slide = SidebarMotion.spring(keyPath: "position.y")
        slide.isAdditive = true
        slide.fromValue = offset
        slide.toValue = 0
        if inStepWithTransition, let beginTime = transitionBeginTime() {
            slide.beginTime = beginTime
        } else {
            // Hold the start offset until the transaction's begin time comes
            // around (up to a frame after the commit), so a row never flashes
            // at its destination first.
            slide.fillMode = .backwards
        }
        layer.add(slide, forKey: Self.slideAnimationKey)
    }

    /// Brings a dropped row in from `origin`, where the drag's image was, to
    /// `frame`, over the rows it passes.
    private func land(_ view: NSView, from origin: CGPoint, at frame: CGRect) {
        addSlide(to: view, from: origin.y - frame.minY)
        guard let layer = view.layer else { return }
        layer.zPosition = 1
        let offset = origin.x - frame.minX
        guard abs(offset) > 0.25 else { return }
        let slide = SidebarMotion.spring(keyPath: "position.x")
        slide.isAdditive = true
        slide.fromValue = offset
        slide.toValue = 0
        slide.fillMode = .backwards
        layer.add(slide, forKey: Self.landingAnimationKey)
    }

    /// When the running transition's slides began. They're all committed
    /// together, so they share one begin time; nil until that commit has
    /// happened (a row placed before it simply starts with the others).
    private func transitionBeginTime() -> CFTimeInterval? {
        let candidates = [disclosureGroupClip as NSView] + Array(rowViewsByKey.values)
        for view in candidates {
            if let beginTime = view.layer?.animation(forKey: Self.slideAnimationKey)?.beginTime, beginTime > 0 {
                return beginTime
            }
        }
        return nil
    }

    private func fadeIn(_ view: NSView) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        view.layer?.add(fade, forKey: Self.fadeAnimationKey)
    }

    /// Fades a departing view out for good; it's recycled once the transition
    /// settles (which resets its alpha).
    private func fadeOut(_ view: NSView) {
        view.alphaValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        view.layer?.add(fade, forKey: Self.fadeAnimationKey)
    }

    private func stopMotion(of view: NSView) {
        view.layer?.removeAnimation(forKey: Self.slideAnimationKey)
        view.layer?.removeAnimation(forKey: Self.landingAnimationKey)
        view.layer?.removeAnimation(forKey: Self.fadeAnimationKey)
    }

    /// How far the clip view would have to scroll up if the list shrank to
    /// `height` — the part of the current scroll offset that would stop
    /// existing.
    private func scrollClamp(forTotalHeight height: CGFloat) -> CGFloat {
        guard height < totalHeight, let clipView = enclosingScrollView?.contentView else { return 0 }
        let visible = clipView.bounds
        return max(0, visible.origin.y - max(0, height - visible.height))
    }

    /// Sets the list's height. When it shrinks under the scroll offset (a
    /// collapse near the end of the list), scroll to where the clip view would
    /// clamp to now, and slide the whole list there from where it was, rather
    /// than letting it jump.
    private func applyTotalHeight(_ height: CGFloat, scrollClamp delta: CGFloat) {
        totalHeight = height
        guard delta > 0.5, let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let origin = clipView.bounds.origin
        clipView.scroll(to: NSPoint(x: origin.x, y: origin.y - delta))
        scrollView.reflectScrolledClipView(clipView)
        addSlide(to: self, from: slideOffset(of: self) - delta)
    }

    // MARK: - Row views

    /// Makes `view` the live view of `row`, parented in `container`, with its
    /// content refreshed. The caller sets the frame.
    private func adopt(_ view: NSView, for row: SidebarRow, in container: NSView) {
        rowViewsByKey[row.key] = view
        if view.superview !== container {
            container.addSubview(view)
        }
        configure(view: view, for: row)
        view.alphaValue = 1
        view.isHidden = false
        // Peek cells render above other rows so a sibling mid-slide can never
        // obscure the peek. The drop indicator stays at 1000 above everything.
        view.layer?.zPosition = Self.isPeekKey(row.key) ? 1 : 0
    }

    private func makeRowView(for key: SidebarRowKey) -> NSView {
        switch key {
        case .collectionHeader:
            return collectionHeaderView
        case .divider:
            return dividerView
        case .newTabButton:
            return newTabButton
        case .dropSlot:
            return dropSlotView
        case .folder:
            return Self.unusedFolderRowViews.popLast() ?? SidebarFolderRowView(frame: .zero)
        case .tab, .peekTab, .regularTab:
            return Self.unusedTabRowViews.popLast() ?? SidebarTabRowView(frame: .zero)
        }
    }

    /// Takes a row view out of the hierarchy and back to its reuse pool.
    /// Recycled cells drop their tracking areas, observers and `BrowserTab`
    /// subscriptions in `prepareForReuse`.
    private func retire(_ view: NSView) {
        // A fixed view can already be live again under a new key: the
        // header of the space switched to, whose key has that space's ID.
        // Taking it down now would leave an empty row.
        if rowViewsByKey.values.contains(where: { $0 === view }) { return }
        stopMotion(of: view)
        view.removeFromSuperview()
        view.alphaValue = 1
        view.isHidden = false
        switch view {
        case let cell as SidebarTabRowView:
            cell.prepareForReuse()
            if Self.unusedTabRowViews.count < Self.maxPooledRowViews, !Self.unusedTabRowViews.contains(where: { $0 === cell }) {
                Self.unusedTabRowViews.append(cell)
            }
        case let cell as SidebarFolderRowView:
            cell.prepareForReuse()
            if Self.unusedFolderRowViews.count < Self.maxPooledRowViews, !Self.unusedFolderRowViews.contains(where: { $0 === cell }) {
                Self.unusedFolderRowViews.append(cell)
            }
        default:
            // The fixed views are re-added when their row comes back.
            break
        }
    }

    private func refreshRealizedRowContents() {
        for (key, view) in rowViewsByKey {
            guard let index = rowIndexByKey[key] else { continue }
            configure(view: view, for: rows[index])
        }
    }

    /// The row being renamed keeps its view while scrolled away; recycling it
    /// would end the edit.
    private func isPinned(_ key: SidebarRowKey) -> Bool {
        guard let renamingID = sidebarManager?.isRenaming else { return false }
        switch key {
        case .tab(let id), .folder(let id), .collectionHeader(let id):
            return id == renamingID
        case .peekTab(let tabID, _):
            return tabID == renamingID
        default:
            return false
        }
    }

    private func configure(view: NSView, for row: SidebarRow) {
        guard let manager = sidebarManager else { return }
        switch row.key {
        case .collectionHeader(let id):
            let collection = manager.sidebarStructure.collections[id]
            collectionHeaderView.representedCollectionID = id
            collectionHeaderView.sidebarManager = manager
            collectionHeaderView.setTitle(collection?.displayTitle ?? "Saved Tabs")
            collectionHeaderView.setExpanded(collectionExpanded, animated: false)
            collectionHeaderView.setRenaming(manager.isRenaming == id)
            collectionHeaderView.onToggle = { [weak self] in
                guard let self = self else { return }
                self.delegate?.rowsView(self, didToggleCollection: id)
            }
            collectionHeaderView.menuProvider = { [weak self] in
                guard let self = self,
                      let manager = self.sidebarManager,
                      let tabManager = self.tabManager else { return nil }
                return SidebarContextMenuFactory.menu(for: .collectionHeader(id), sidebarManager: manager, tabManager: tabManager, anchor: self)
            }
        case .folder(let id):
            if let cell = view as? SidebarFolderRowView {
                if let group = regularGroupsByID[id] {
                    configureRegularGroupCell(cell, group: group, depth: row.depth)
                } else {
                    configureFolderCell(cell, folderID: id, depth: row.depth)
                }
            }
        case .tab(let id):
            if let cell = view as? SidebarTabRowView {
                configureTabCell(cell, tabID: id, depth: row.depth)
            }
        case .peekTab(let tabID, _):
            if let cell = view as? SidebarTabRowView {
                if regularTabsByID[tabID] != nil {
                    configureRegularTabCell(cell, browserTabID: tabID, depth: row.depth)
                } else {
                    configureTabCell(cell, tabID: tabID, depth: row.depth)
                }
            }
        case .regularTab(let browserTabID):
            if let cell = view as? SidebarTabRowView {
                configureRegularTabCell(cell, browserTabID: browserTabID, depth: row.depth)
            }
        case .newTabButton:
            newTabButton.actionHandler = { [weak self] isPrivate in
                guard let self = self else { return }
                self.delegate?.rowsViewDidRequestNewTab(self, isPrivate: isPrivate)
            }
        case .divider, .dropSlot:
            break
        }
    }

    private func configureTabCell(_ cell: SidebarTabRowView, tabID: UUID, depth: Int) {
        guard let manager = sidebarManager, let tabManager = tabManager,
              let tab = manager.sidebarStructure.tabs[tabID] else { return }
        let inset = CGFloat(depth) * SidebarLayoutMetrics.depthIndent
        cell.configure(
            with: tab,
            sidebarManager: manager,
            tabManager: tabManager,
            isRenaming: manager.isRenaming == tabID,
            extraLeadingInset: inset,
            mode: .organized
        )
        applySelection(to: cell, itemID: tabID, activeID: previewedSpace.map { $0.selectedItemID } ?? manager.selectedItem)
    }

    /// The active tab's row selected, and those ⌘-clicked with it, which
    /// don't offer to go back to their saved page
    private func applySelection(to cell: SidebarTabRowView, itemID: UUID, activeID: UUID?) {
        let isActive = activeID == itemID
        let isAlsoSelected = previewedSpace == nil && sidebarManager?.extraSelectedItems.contains(itemID) == true
        cell.setSelected(isActive || isAlsoSelected, isActive: isActive)
    }

    private func configureRegularTabCell(_ cell: SidebarTabRowView, browserTabID: UUID, depth: Int) {
        guard let manager = sidebarManager, let tabManager = tabManager,
              let browserTab = regularTabsByID[browserTabID] else { return }
        let synthetic = SidebarTab(
            id: browserTab.id,
            title: browserTab.title,
            url: browserTab.url,
            createdAt: browserTab.createdAt,
            order: 0,
            isUnloaded: false
        )
        cell.configure(
            with: synthetic,
            sidebarManager: manager,
            tabManager: tabManager,
            isRenaming: false,
            extraLeadingInset: CGFloat(depth) * SidebarLayoutMetrics.depthIndent,
            mode: .regular,
            isPrivate: browserTab.isPrivate
        )
        applySelection(to: cell, itemID: browserTabID,
                       activeID: previewedSpace.map { $0.selectedItemID } ?? tabManager.activeTabId)
    }

    private func configureFolderCell(_ cell: SidebarFolderRowView, folderID: UUID, depth: Int) {
        guard let manager = sidebarManager,
              let folder = manager.sidebarStructure.folders[folderID] else { return }
        cell.configure(
            with: folder,
            sidebarManager: manager,
            isRenaming: manager.isRenaming == folderID,
            extraLeadingInset: CGFloat(depth) * SidebarLayoutMetrics.depthIndent,
            faviconURLs: manager.sidebarStructure.faviconURLs(inFolder: folderID)
        )
        cell.setDropTarget(dropTarget?.folderID == folderID)
    }

    /// A group of regular tabs, as its saved group would show
    private func configureRegularGroupCell(_ cell: SidebarFolderRowView, group: OpenTabGroup, depth: Int) {
        guard let manager = sidebarManager else { return }
        var folder = SidebarFolder(id: group.id, title: group.title,
                                   icon: group.icon.isEmpty ? FolderIcons.defaultIcon : group.icon)
        folder.childrenIds = regularGroupMembers[group.id] ?? []
        let urls = (regularGroupMembers[group.id] ?? []).compactMap { regularTabsByID[$0]?.url }
        cell.configure(
            with: folder,
            sidebarManager: manager,
            isRenaming: manager.isRenaming == group.id,
            extraLeadingInset: CGFloat(depth) * SidebarLayoutMetrics.depthIndent,
            faviconURLs: SidebarGroupFavicons.urls(from: urls)
        )
        cell.setDropTarget(dropTarget?.folderID == group.id)
    }

    private func configureFixedViews() {
        // These views persist across layouts; `adopt` adds them.
        collectionHeaderView.translatesAutoresizingMaskIntoConstraints = true
        dividerView.translatesAutoresizingMaskIntoConstraints = true
        dividerView.onCloseAll = { [weak self] in
            self?.closeRegularTabs()
        }
        newTabButton.translatesAutoresizingMaskIntoConstraints = true
        dropSlotView.translatesAutoresizingMaskIntoConstraints = true
    }

    // MARK: - Layout helpers

    private static func indexByKey(_ rows: [SidebarRow]) -> [SidebarRowKey: Int] {
        var index: [SidebarRowKey: Int] = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() where index[row.key] == nil {
            index[row.key] = offset
        }
        return index
    }

    private static func haveSameGeometry(_ lhs: [SidebarRow], _ rhs: [SidebarRow]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.key != right.key || left.frame != right.frame {
            return false
        }
        return true
    }

    /// The rows directly below `parentIndex` that belong to it: a folder's
    /// descendants (the deeper rows), or the collection's organized rows.
    private static func groupRange(in rows: [SidebarRow], parentIndex: Int) -> Range<Int> {
        let parent = rows[parentIndex]
        var end = parentIndex + 1
        while end < rows.count {
            let belongs: Bool
            switch parent.key {
            case .collectionHeader:
                switch rows[end].key {
                case .folder, .tab, .peekTab: belongs = true
                default: belongs = false
                }
            default:
                belongs = rows[end].depth > parent.depth
            }
            guard belongs else { break }
            end += 1
        }
        return (parentIndex + 1)..<end
    }

    /// The area a row covers while sliding from `startY` to `frame`.
    private static func sweep(from startY: CGFloat, to frame: CGRect) -> CGRect {
        let minY = min(startY, frame.minY)
        return CGRect(x: frame.minX, y: minY, width: frame.width, height: max(startY, frame.minY) - minY + frame.height)
    }

    /// Indices of the rows intersecting `rect` vertically. `rows` run top to
    /// bottom without overlapping, so this is a binary search.
    private func rowIndices(intersecting rect: CGRect) -> Range<Int> {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].frame.maxY <= rect.minY { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < rows.count, rows[end].frame.minY < rect.maxY {
            end += 1
        }
        return low..<end
    }

    /// Index of the row containing `point`, if any.
    private func rowIndex(at point: CGPoint) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].frame.maxY <= point.y { low = mid + 1 } else { high = mid }
        }
        guard low < rows.count, rows[low].frame.contains(point) else { return nil }
        return low
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHoverFromEvent(event) }
    override func mouseMoved(with event: NSEvent) { updateHoverFromEvent(event) }
    override func mouseExited(with event: NSEvent) {
        applyHoveredKey(nil)
    }

    private func updateHoverFromEvent(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        applyHoveredKey(rowKey(at: pt))
    }

    private func refreshHoveredKey() {
        guard let window = self.window else { return }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(pt), !isDragOver {
            applyHoveredKey(rowKey(at: pt))
        } else if hoveredKey != nil {
            applyHoveredKey(nil)
        }
    }

    private func applyHoveredKey(_ key: SidebarRowKey?) {
        guard hoveredKey != key else {
            // Force-apply hover anyway in case the cell was recycled.
            if let key = key, let view = rowViewsByKey[key] as? SidebarHoverable {
                view.setHovered(true)
            }
            return
        }
        if let oldKey = hoveredKey, let view = rowViewsByKey[oldKey] as? SidebarHoverable {
            view.setHovered(false)
        }
        hoveredKey = key
        if let key = key, let view = rowViewsByKey[key] as? SidebarHoverable {
            view.setHovered(true)
        }
    }

    private func rowKey(at point: CGPoint) -> SidebarRowKey? {
        // Only tabs / folders / peek / regular-tab rows have hover bg.
        guard let index = rowIndex(at: point) else { return nil }
        switch rows[index].key {
        case .tab, .folder, .peekTab, .regularTab:
            return rows[index].key
        default:
            return nil
        }
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let key = rowKey(at: pt) else {
            super.mouseDown(with: event)
            return
        }

        // ⌘-click: a tab joins the selection, or leaves it, without being
        // shown (nor dragged)
        if event.modifierFlags.contains(.command), let id = selectableItemID(for: key) {
            dragMouseDownKey = nil
            lastClickKey = nil
            toggleExtraSelection(id)
            return
        }

        // Capture for drag detection in mouseDragged.
        dragMouseDownLocation = pt
        dragMouseDownKey = key

        let now = ProcessInfo.processInfo.systemUptime
        let isFastDoubleClick = event.clickCount >= 2
            && lastClickKey == key
            && (now - lastClickTime) <= Self.fastDoubleClickThreshold
        lastClickTime = now
        lastClickKey = key

        if isFastDoubleClick {
            switch key {
            case .tab(let id), .folder(let id), .peekTab(let id, _):
                // Not a regular tab peeking out of its group: it has no name of its own
                if regularTabsByID[id] == nil {
                    delegate?.rowsView(self, didRequestRenameForItem: id)
                }
            default:
                break
            }
            return
        }
        selectionBeforePress = nil
        pressHeldPeekTabID = nil
        switch key {
        case .tab(let id), .peekTab(let id, _):
            if sidebarManager?.selectedItem == id {
                pressedSelectedTabID = id
            } else {
                rememberSelection(beforePressing: key)
                pressHeldPeekTabID = rows.lazy.compactMap { Self.peekUUID(of: $0.key) }.first
                delegate?.rowsView(self, didActivateTab: id)
            }
        case .regularTab(let id):
            if sidebarManager?.selectedItem != id {
                rememberSelection(beforePressing: key)
                pressHeldPeekTabID = rows.lazy.compactMap { Self.peekUUID(of: $0.key) }.first
            }
            delegate?.rowsView(self, didActivateRegularTab: id)
        case .folder(let id):
            // Defer to mouseUp — releasing while still over the same folder
            // commits the toggle; drag-off cancels.
            pressedFolderID = id
        default:
            break
        }
    }

    // MARK: - Selecting several tabs

    /// The item a tab's row selects: a saved tab's ID, or a regular tab's
    private func selectableItemID(for key: SidebarRowKey) -> UUID? {
        switch key {
        case .tab(let id), .peekTab(let id, _), .regularTab(let id): return id
        default: return nil
        }
    }

    /// ⌘-clicked: in the selection with the active tab, or out of it again.
    /// The active tab stays selected.
    private func toggleExtraSelection(_ id: UUID) {
        guard let manager = sidebarManager, previewedSpace == nil, id != manager.selectedItem else { return }
        if manager.extraSelectedItems.contains(id) {
            manager.extraSelectedItems.remove(id)
        } else {
            manager.extraSelectedItems.insert(id)
        }
    }

    /// The tabs a menu on `key`'s row is for, top to bottom: every selected
    /// one with a row, when its own tab is one of several selected. Nil
    /// otherwise; a menu on a row outside the selection lets go of it.
    func selectedItems(forMenuOn key: SidebarRowKey) -> [UUID]? {
        reloadIfNeeded()
        guard let manager = sidebarManager, !manager.extraSelectedItems.isEmpty else { return nil }
        let extra = manager.extraSelectedItems
        let activeID = manager.selectedItem
        func isSelected(_ id: UUID) -> Bool { id == activeID || extra.contains(id) }
        guard let id = selectableItemID(for: key), isSelected(id) else {
            manager.extraSelectedItems.removeAll()
            return nil
        }
        var seen: Set<UUID> = []
        let items = rows.compactMap { selectableItemID(for: $0.key) }.filter { isSelected($0) && seen.insert($0).inserted }
        return items.count > 1 ? items : nil
    }

    private func rememberSelection(beforePressing key: SidebarRowKey) {
        selectionBeforePress = sidebarManager?.selectedItem.map { (key: key, itemID: $0) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedFolderID = nil
            pressedSelectedTabID = nil
            selectionBeforePress = nil
            dragMouseDownKey = nil
            if pressHeldPeekTabID != nil {
                // Let go of: the peek goes, the pressed tab selected
                pressHeldPeekTabID = nil
                reload()
            }
        }
        let pt = convert(event.locationInWindow, from: nil)
        if let pressedID = pressedSelectedTabID {
            if rowKey(at: pt).flatMap(draggedID(for:)) == pressedID {
                delegate?.rowsView(self, didActivateTab: pressedID)
            }
            return
        }
        guard let pressedID = pressedFolderID else {
            super.mouseUp(with: event)
            return
        }
        if case .folder(let id) = rowKey(at: pt), id == pressedID {
            delegate?.rowsView(self, didToggleFolder: id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingItem,
              let key = dragMouseDownKey,
              isDraggable(key) else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - dragMouseDownLocation.x
        let dy = pt.y - dragMouseDownLocation.y
        if dx * dx + dy * dy >= Self.dragStartThreshold * Self.dragStartThreshold {
            beginItemDrag(for: key, with: event)
        }
    }

    private func isDraggable(_ key: SidebarRowKey) -> Bool {
        switch key {
        case .tab, .folder, .peekTab, .regularTab: return true
        case .divider, .newTabButton, .collectionHeader, .dropSlot: return false
        }
    }

    // MARK: - Right click

    override func menu(for event: NSEvent) -> NSMenu? {
        // We deliberately don't return a menu here — that triggers
        // NSTableView-style focus rings. Instead we listen for rightMouseDown
        // and fire NSMenu.popUpContextMenu manually.
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: pt) else {
            super.rightMouseDown(with: event)
            return
        }
        delegate?.rowsView(self, didRequestContextMenuFor: rows[index].key, at: pt)
    }

    // MARK: - Drag-and-drop

    /// Resolve the UUID payload that should ride the pasteboard for `key`.
    private func draggedID(for key: SidebarRowKey) -> UUID? {
        switch key {
        case .tab(let id), .folder(let id), .regularTab(let id): return id
        case .peekTab(let id, _): return id
        default: return nil
        }
    }

    private func beginItemDrag(for key: SidebarRowKey, with event: NSEvent) {
        guard let id = draggedID(for: key), let view = rowViewsByKey[key] else { return }

        isDraggingItem = true
        // Suppress the deferred folder-toggle and any pending press state.
        pressedFolderID = nil
        pressedSelectedTabID = nil
        dragMouseDownKey = nil

        let frame = convert(view.bounds, from: view)
        let pointer = convert(event.locationInWindow, from: nil)
        let grabOffset = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        let image = snapshot(of: view)
        let dragItem = NSDraggingItem(pasteboardWriter: NSPasteboardItem.sidebarItem(uuid: id, link: link(for: key)))
        dragItem.draggingFrame = frame
        dragItem.imageComponentsProvider = { DraggedRow.imageComponents(size: frame.size, image: image) }
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // Let go where nothing takes it, the list puts the row back itself,
        // from where it was let go (`draggingSession(_:endedAt:operation:)`)
        session.animatesToStartingPositionsOnCancelOrFail = false
        draggedRow = DraggedRow(session: session, size: frame.size, grabOffset: grabOffset, image: image,
                                address: link(for: key).map { SidebarDraggedRowView.displayAddress($0.url) },
                                sidebarFrame: sidebarScreenFrame)
        Self.activeDragSource = self
        if let before = selectionBeforePress, before.key == key {
            draggedRow?.selectionToRestore = before.itemID
        }
        selectionBeforePress = nil
        if let index = rowIndexByKey[key], let window {
            makeDraggedRowView(for: rows[index], pointer: window.convertPoint(toScreen: event.locationInWindow))
            // Ready for when it's dragged out of the sidebar
            snapshotPage(for: key)
        }
        liftRow(key, itemID: id, grabOffset: grabOffset)
        NotificationCenter.default.post(name: .sidebarItemDragDidBegin, object: id)
    }

    /// A dragged tab's link, for other apps: its address and title.
    private func link(for key: SidebarRowKey) -> (url: String, title: String)? {
        switch key {
        case .peekTab(let id, _) where regularTabsByID[id] != nil:
            return regularTabsByID[id].map { ($0.url, $0.title) }
        case .tab(let id), .peekTab(let id, _):
            // Where its page is now, not where it was saved
            guard let manager = sidebarManager, let tab = manager.sidebarStructure.tabs[id] else { return nil }
            return (manager.currentURL(ofSavedTab: id) ?? tab.url, tab.displayTitle)
        case .regularTab(let id):
            return regularTabsByID[id].map { ($0.url, $0.title) }
        default:
            return nil
        }
    }

    /// Takes the dragged row out of the list. Its place closes, and opens
    /// again at once as the drop's slot, since the drag starts out over it.
    private func liftRow(_ key: SidebarRowKey, itemID: UUID, grabOffset: CGPoint) {
        guard let index = rowIndexByKey[key] else { return }
        let row = rows[index]
        var originTarget: DropTarget?
        switch key {
        case .folder(let id) where regularGroupsByID[id] != nil:
            // Before what's after its tabs
            originTarget = DropTarget(zone: .regular(beforeTabID: regularTab(after: id), groupID: nil, dropOnGroupID: nil),
                                      gap: DropGap(y: row.frame.minY, depth: 0))
        case .regularTab(let id):
            originTarget = regularOriginTarget(of: id, row: row)
        case .peekTab(let id, _) where regularTabsByID[id] != nil:
            // A regular tab peeking out of its closed group
            originTarget = regularOriginTarget(of: id, row: row)
        case .tab, .folder, .peekTab:
            if let manager = sidebarManager,
               let location = manager.findItemLocation(itemID: itemID, in: manager.sidebarStructure),
               let itemIndex = location.index {
                originTarget = DropTarget(
                    zone: .organized(parentID: location.parentID, index: itemIndex, dropOnFolderID: nil),
                    gap: DropGap(y: row.frame.minY, depth: row.depth)
                )
            }
        default:
            break
        }
        lift = Lift(itemID: itemID, key: key, grabOffset: grabOffset, origin: row.frame, originTarget: originTarget,
                    heldPeekTabID: pressHeldPeekTabID)
        pressHeldPeekTabID = nil
        dropTarget = originTarget
        reload()
    }

    /// The drop that puts a regular tab's row, lifted, back: before the one
    /// after it, in its group, or at the end.
    private func regularOriginTarget(of id: UUID, row: SidebarRow) -> DropTarget {
        let next: UUID?
        if regularTabGroups[id] != nil {
            next = regularTab(followingInGroup: id)
        } else {
            next = regularTabs.firstIndex { $0.id == id }.flatMap { index in
                regularTabs.indices.contains(index + 1) ? regularTabs[index + 1].id : nil
            }
        }
        return DropTarget(zone: .regular(beforeTabID: next, groupID: regularTabGroups[id]?.id, dropOnGroupID: nil),
                          gap: DropGap(y: row.frame.minY, depth: row.depth))
    }

    /// Over the pinned sites, a tab turns into the tile it'd be there,
    /// centered under the pointer.
    @objc private func dragDidEnterPinnedSites(_ note: Notification) {
        guard let view = draggedRowView, let tabRow = view.row as? SidebarTabRowView,
              let size = (note.object as? NSValue)?.sizeValue, let itemID = lift?.itemID else { return }
        let colors = PinnedSiteTileView.draggedTileColors(
            icon: tabRow.dragParts().icon, isSelected: sidebarManager?.selectedItem == itemID,
            appearance: view.effectiveAppearance
        )
        draggedRow?.pinnedTile = .init(size: size, fill: colors.fill, border: colors.border)
        updateDraggedRowShape()
    }

    /// Back from the pinned sites, the tile turns into the row again, held
    /// where it was picked up. So does AppKit's image, should it show: it
    /// keeps the grid's change as the drag moves on within the window.
    @objc private func dragDidLeavePinnedSites() {
        draggedRow?.pinnedTile = nil
        updateDraggedRowShape()
        guard let draggedRow, let window else { return }
        let screenPoint = draggedRow.session.draggingLocation
        let frame = draggedRow.frame(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        let components = DraggedRow.imageComponents(size: draggedRow.size, image: draggedRow.image)
        draggedRow.session.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                                  searchOptions: [:]) { item, _, _ in
            item.draggingFrame = frame
            item.imageComponentsProvider = { components }
        }
    }

    /// The dragged row's shape: over the pinned sites, the tile it'd be
    /// there; out of the sidebar, a tab's link, with its page; else the row.
    private func updateDraggedRowShape() {
        guard let draggedRow, let view = draggedRowView else { return }
        if let tile = draggedRow.pinnedTile {
            view.setShape(.tile(tile))
        } else if draggedRow.isOutsideSidebar, let address = draggedRow.address, let key = lift?.key {
            switch view.shape {
            case .link, .page: break
            case .row, .tile: snapshotPage(for: key)
            }
            view.setShape(draggedRow.isOverPage ? .page : .link(address: address))
        } else {
            view.setShape(.row)
        }
    }

    /// The top of a dragged tab's page, as its link shows it, when it has
    /// a web view to take it from. A page that's still loading (pressing
    /// its row loads a tab that wasn't) may not have drawn anything yet:
    /// it's taken once the page has loaded, the favicon showing till then.
    private func snapshotPage(for key: SidebarRowKey) {
        let browserTabID: UUID?
        switch key {
        case .peekTab(let id, _) where regularTabsByID[id] != nil: browserTabID = id
        case .tab(let id), .peekTab(let id, _): browserTabID = sidebarManager?.sidebarToBrowserTabMapping[id]
        case .regularTab(let id): browserTabID = id
        default: browserTabID = nil
        }
        guard draggedRow != nil, let browserTabID, let webView = TabWebViewCoordinator.coordinator(for: browserTabID)?.webView,
              let view = draggedRowView, webView.bounds.width > 0 else { return }
        guard !webView.isLoading, webView.url != nil else {
            draggedRow?.pageLoad = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                DispatchQueue.main.async { self?.snapshotPage(for: key) }
            }
            return
        }
        draggedRow?.pageLoad = nil
        let bounds = webView.bounds
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: bounds.width,
                                    height: min(bounds.height, bounds.width * SidebarDraggedRowView.thumbnailAspect))
        configuration.snapshotWidth = NSNumber(value: Double(view.bounds.width))
        webView.takeSnapshot(with: configuration) { [weak view] image, _ in
            guard let image else { return }
            view?.thumbnail = image
        }
    }

    /// The dragged row as the list draws it, a row view of its own like
    /// `row`'s, in a window over everything (`dragPanel`), the pointer at
    /// `screenPoint`.
    private func makeDraggedRowView(for row: SidebarRow, pointer screenPoint: CGPoint) {
        guard let draggedRow else { return }
        let panel = dragPanel ?? SidebarDragPanel()
        dragPanel = panel
        let rowView = makeRowView(for: row.key)
        rowView.frame = CGRect(origin: .zero, size: draggedRow.size)
        configure(view: rowView, for: row)
        let view = SidebarDraggedRowView(row: rowView, for: row, grabOffset: draggedRow.grabOffset)
        // The sidebar's look, which the panel's may not be
        view.appearance = effectiveAppearance
        // A pinned site's starts out as its tile, as it was picked up
        if let tile = draggedRow.pinnedTile {
            view.setShape(.tile(tile))
        }
        panel.contentView?.addSubview(view)
        draggedRowView = view
        moveDraggedRowView(to: screenPoint)
        panel.orderFrontRegardless()
    }

    /// Puts the list's view of the dragged row where the drag holds it, the
    /// pointer at `screenPoint`.
    private func moveDraggedRowView(to screenPoint: CGPoint) {
        guard let draggedRow, let view = draggedRowView, let panel = dragPanel, let content = panel.contentView else { return }
        panel.cover(screenAt: screenPoint)
        // The pointer is `grabOffset` in from its top left
        let frame = CGRect(x: screenPoint.x - draggedRow.grabOffset.x,
                           y: screenPoint.y + draggedRow.grabOffset.y - draggedRow.size.height,
                           width: draggedRow.size.width, height: draggedRow.size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = content.convert(panel.convertFromScreen(frame), from: nil)
        CATransaction.commit()
    }

    /// From the drag's first move, the list's view of the dragged row is
    /// all there is, AppKit's image of it hidden; if that can't be hidden,
    /// AppKit's is.
    private func presentDraggedRow() {
        guard let draggedRow, draggedRow.hasLookedForImageWindow else { return }
        let hidesImage = draggedRowView != nil
            && draggedRow.imageWindow.map { SidebarDragImageWindow.setHidden(true, $0) } == true
        draggedRowView?.isHidden = !hidesImage
    }

    private func removeDraggedRowView() {
        guard let view = draggedRowView else { return }
        draggedRowView = nil
        view.removeFromSuperview()
        view.row.autoresizingMask = []
        retire(view.row)
        dragPanel?.orderOut(nil)
    }

    private func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard !bounds.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateDropTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = updateDropTarget(sender)
        handleAutoScroll(sender: sender)
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
        if updateVisitingItem(nil) {
            dropTarget = nil
            reload()
        }
        lift?.hasLeftOrigin = true
        setDropTarget(nil)
        cancelAutoScroll()
        cancelHoverExpand()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragOver = false
        if updateVisitingItem(nil) {
            reload()
        }
        setDropTarget(nil)
        cancelAutoScroll()
        cancelHoverExpand()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            cancelAutoScroll()
            cancelHoverExpand()
        }
        isDragOver = false
        // Where it shows it'll go
        guard acceptsDrops, let target = dropTarget else { return false }
        let (accepted, landingKey) = applyDrop(target: target, sender: sender)
        guard accepted else {
            setDropTarget(nil)
            return false
        }
        // The drop's slot stays until the change comes in (the controller's
        // reload, a turn later): the row then takes its place, coming in from
        // where the drag's image was. A link's new tab just fades in.
        let pointer = convert(sender.draggingLocation, from: nil)
        if let landingKey, !sender.draggedSidebarItemUUIDs.isEmpty {
            // A pinned site shows as a row off its grid, its favicon under
            // the pointer; another window's row is held as it was there
            let grab = lift?.grabOffset ?? Self.activeDragSource?.draggedRow?.grabOffset
                ?? CGPoint(x: SidebarTabRowView.faviconCenterX, y: SidebarLayoutMetrics.standardRowHeight / 2)
            landing = Landing(key: landingKey, origin: CGPoint(x: pointer.x - grab.x, y: pointer.y - grab.y))
        }
        lift = nil
        visitingItemID = nil
        dropTarget = nil
        DispatchQueue.main.async { [weak self] in
            // In case nothing changed
            self?.reload()
        }
        return true
    }

    @discardableResult
    private func updateDropTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !isDragOver {
            isDragOver = true
            applyHoveredKey(nil)
        }
        // Drops are worked out without it, as it would be in its own list
        if updateVisitingItem(sender) {
            dropTarget = nil
            reload()
        }
        let point = convert(sender.draggingLocation, from: nil)
        let target: DropTarget?
        if let lift, !lift.hasLeftOrigin, point.y >= lift.origin.minY, point.y < lift.origin.maxY {
            target = lift.originTarget
        } else {
            lift?.hasLeftOrigin = true
            target = dropTargets(at: point).first { isValidDrop(target: $0, sender: sender) }
        }
        setDropTarget(target)
        handleHoverExpand(folderID: target?.folderID)
        guard let target else { return [] }
        followDropDepth(dropDepth(of: target))
        // A link opens a new tab
        return sender.draggedSidebarItemUUIDs.isEmpty ? .copy : .move
    }

    /// How deep in the folders a drop at `target` puts the row.
    private func dropDepth(of target: DropTarget) -> Int? {
        if let gap = target.gap { return gap.depth }
        if let folderID = target.folderID {
            return rowIndexByKey[.folder(folderID)].map { rows[$0].depth + 1 }
        }
        return nil
    }

    /// The dragged row takes the indent a drop would put it at, on a spring
    /// from wherever it is: dragged from this list, or another window's.
    private func followDropDepth(_ depth: Int?) {
        guard let depth else { return }
        (draggedRowView ?? Self.activeDragSource?.draggedRowView)?.setDepth(depth)
    }

    /// A saved tab or folder dragged here from another window's list is
    /// lifted out of this one too, as it is out of its own, and so is an
    /// open tab's row, this window's page of it. Whether that changed.
    private func updateVisitingItem(_ sender: NSDraggingInfo?) -> Bool {
        var itemID: UUID?
        if let sender, Self.activeDragSource !== self, let manager = sidebarManager,
           let id = sender.draggedSidebarItemUUIDs.first {
            if manager.sidebarStructure.tabs[id] != nil || manager.sidebarStructure.folders[id] != nil
                || OpenTabStore.shared.group(withID: id) != nil {
                // A group of regular tabs is every window's, as its tabs are
                itemID = id
            } else if let openTabID = BrowserWindowSession.allTabs.first(where: { $0.id == id })?.openTabID {
                itemID = tabManager?.tabs.first { $0.openTabID == openTabID }?.id
            }
        }
        guard itemID != visitingItemID else { return false }
        visitingItemID = itemID
        return true
    }

    private func setDropTarget(_ target: DropTarget?) {
        guard target != dropTarget else { return }
        dropTarget = target
        layOutForDrop()
    }

    /// Lays the rows out for the drop target: room made for it, or the
    /// folder it goes into lit up.
    private func layOutForDrop() {
        guard transition?.disclosure == nil else {
            // A folder opening as the drag held over it: once it looks done
            guard !needsDropLayout else { return }
            needsDropLayout = true
            DispatchQueue.main.asyncAfter(deadline: .now() + SidebarMotion.perceptualDuration) { [weak self] in
                guard let self, self.needsDropLayout else { return }
                self.needsDropLayout = false
                self.reload()
            }
            return
        }
        needsDropLayout = false
        reload()
    }

    // MARK: Drop target computation

    private enum DropZone: Equatable {
        case organized(parentID: UUID?, index: Int, dropOnFolderID: UUID?)
        /// Among the regular tabs below the divider: before one, or at
        /// their end with none; in `groupID`'s group, or none. Dropped onto
        /// a group's row (`dropOnGroupID`), at the end of its tabs.
        case regular(beforeTabID: UUID?, groupID: UUID?, dropOnGroupID: UUID?)
    }

    /// Room made among the rows for a drop: a row at `y` (in the drop
    /// layout, `dropLayoutRows`), the slot indented to `depth`.
    private struct DropGap: Equatable {
        let y: CGFloat
        let depth: Int
    }

    private struct DropTarget: Equatable {
        let zone: DropZone
        let gap: DropGap?

        /// The group it drops into, when that's where it goes.
        var folderID: UUID? {
            switch zone {
            case .organized(_, _, let folderID): return folderID
            case .regular(_, _, let groupID): return groupID
            }
        }
    }

    /// A row dragged out of the list.
    private struct Lift {
        let itemID: UUID
        let key: SidebarRowKey
        /// Where the pointer holds it.
        let grabOffset: CGPoint
        /// Its place as it was picked up, and the drop that puts it back
        /// there. The drag starts out over it, and
        /// until it first leaves, that's the target, whatever is around.
        let origin: CGRect
        let originTarget: DropTarget?
        var hasLeftOrigin = false
        /// The tab that peeked as its row was pressed (`pressHeldPeekTabID`),
        /// peeking still until the drag ends
        var heldPeekTabID: UUID? = nil
    }

    private struct Landing {
        let key: SidebarRowKey
        /// Where the drag's image was, its top left.
        let origin: CGPoint

        /// Whether `row` is the one coming in: its row, or, dropped into a
        /// closed folder, the active tab peeking out of it.
        func lands(_ row: SidebarRowKey) -> Bool {
            if row == key { return true }
            guard case .peekTab(let peekID, _) = row else { return false }
            switch key {
            case .tab(let id), .regularTab(let id): return id == peekID
            default: return false
            }
        }
    }

    /// Where a drop at `point` would go, best first. Worked out against the
    /// drop layout, so the room made for a drop never moves it: over a tab,
    /// before it, so the room opens under the pointer; over a folder's
    /// middle, into it (else beside it); over its top or bottom quarter,
    /// before it, or after it — or, opened, before its first child. Below
    /// the divider, among the regular tabs, the same as among saved tabs.
    private func dropTargets(at point: CGPoint) -> [DropTarget] {
        guard let manager = sidebarManager, let dividerIndex = dropLayoutDividerIndex else { return [] }
        let structure = manager.sidebarStructure
        let layout = dropLayoutRows

        // The saved tabs and folders, between the space's header and the
        // divider; the regular tabs below.
        guard laidOutCollectionExpanded, let header = layout.first, case .collectionHeader = header.key else {
            // From the divider's line down
            return point.y >= layout[dividerIndex].frame.midY ? regularDropTargets(at: point, dividerIndex: dividerIndex) : []
        }
        let organized = layout[1..<dividerIndex]
        let endY = organized.last?.frame.maxY ?? header.frame.maxY
        // At their end, down to the middle of the room made there. Below, past
        // the divider either way, the regular tabs.
        if point.y >= endY + SidebarLayoutMetrics.standardRowHeight / 2 {
            return regularDropTargets(at: point, dividerIndex: dividerIndex)
        }
        let atEnd = DropTarget(zone: .organized(parentID: nil, index: structure.rootItems.count, dropOnFolderID: nil),
                               gap: DropGap(y: endY, depth: 0))
        guard point.y < endY, let first = organized.first else { return [atEnd] }

        // Above the first one, as over its top
        let y = max(point.y, first.frame.minY)
        var index = organized.startIndex
        var high = organized.endIndex - 1
        while index < high {
            let mid = (index + high) / 2
            if layout[mid].frame.maxY <= y { index = mid + 1 } else { high = mid }
        }
        let row = layout[index]
        switch row.key {
        case .tab(let id):
            return [insertion(beside: id, after: false, gapY: row.frame.minY, depth: row.depth, in: structure)]
                .compactMap { $0 }
        case .folder(let id):
            let before = insertion(beside: id, after: false, gapY: row.frame.minY, depth: row.depth, in: structure)
            let after: DropTarget?
            if laidOutExpandedFolders.contains(id) {
                after = DropTarget(zone: .organized(parentID: id, index: 0, dropOnFolderID: nil),
                                   gap: DropGap(y: row.frame.maxY, depth: row.depth + 1))
            } else {
                // After the tab peeking out of it, if one does
                var blockEnd = row.frame.maxY
                if index + 1 < dividerIndex, case .peekTab = layout[index + 1].key {
                    blockEnd = layout[index + 1].frame.maxY
                }
                after = insertion(beside: id, after: true, gapY: blockEnd, depth: row.depth, in: structure)
            }
            let offset = y - row.frame.minY
            if offset < row.frame.height * 0.25 { return [before].compactMap { $0 } }
            if offset > row.frame.height * 0.75 { return [after].compactMap { $0 } }
            let childCount = structure.folders[id]?.childrenIds.count ?? 0
            let into = DropTarget(zone: .organized(parentID: id, index: childCount, dropOnFolderID: id), gap: nil)
            return [into, offset < row.frame.height / 2 ? before : after].compactMap { $0 }
        case .peekTab(_, let hostFolderID):
            // After the folder it peeks out of
            return [insertion(beside: hostFolderID, after: true, gapY: row.frame.maxY,
                              depth: max(0, row.depth - 1), in: structure)].compactMap { $0 }
        case .collectionHeader, .divider, .newTabButton, .regularTab, .dropSlot:
            return []
        }
    }

    /// Among the regular tabs, at `point` below the divider, best first: over
    /// one, before it, in its group if it's in one, so the room opens under
    /// the pointer (above the first, over New Tab, before that one); past
    /// the last, after it. With none, where the first would be. Over a
    /// group's row as over a saved group's: its middle into it, at the end
    /// of its tabs, its top quarter before it, its bottom quarter before its
    /// first tab, or after it when it's closed. Before the group comes last
    /// for what can't go in one (a group).
    private func regularDropTargets(at point: CGPoint, dividerIndex: Int) -> [DropTarget] {
        let layout = dropLayoutRows
        var endY = layout[dividerIndex].frame.maxY
        var index = dividerIndex + 1
        while index < layout.count {
            let row = layout[index]
            switch row.key {
            case .regularTab(let id):
                if point.y < row.frame.maxY {
                    let groupID = row.depth > 0 ? regularTabGroups[id]?.id : nil
                    return [DropTarget(zone: .regular(beforeTabID: id, groupID: groupID, dropOnGroupID: nil),
                                       gap: DropGap(y: row.frame.minY, depth: row.depth))]
                }
                endY = row.frame.maxY
            case .folder(let groupID):
                // After its tab peeking out, when it's closed
                var blockEnd = row.frame.maxY
                if index + 1 < layout.count, case .peekTab = layout[index + 1].key {
                    blockEnd = layout[index + 1].frame.maxY
                }
                if point.y < row.frame.maxY {
                    let firstTab = regularGroupMembers[groupID]?.first
                    let before = DropTarget(zone: .regular(beforeTabID: firstTab, groupID: nil, dropOnGroupID: nil),
                                            gap: DropGap(y: row.frame.minY, depth: 0))
                    let after: DropTarget
                    if laidOutExpandedFolders.contains(groupID) {
                        after = DropTarget(zone: .regular(beforeTabID: firstTab, groupID: groupID, dropOnGroupID: nil),
                                           gap: DropGap(y: row.frame.maxY, depth: 1))
                    } else {
                        after = DropTarget(zone: .regular(beforeTabID: regularTab(after: groupID), groupID: nil, dropOnGroupID: nil),
                                           gap: DropGap(y: blockEnd, depth: 0))
                    }
                    let into = DropTarget(zone: .regular(beforeTabID: regularTab(after: groupID), groupID: groupID,
                                                         dropOnGroupID: groupID), gap: nil)
                    let offset = point.y - row.frame.minY
                    if offset < row.frame.height * 0.25 { return [before] }
                    if offset > row.frame.height * 0.75 { return [after, before] }
                    return [into, offset < row.frame.height / 2 ? before : after, before]
                }
                endY = blockEnd
            case .peekTab(_, let groupID):
                if point.y < row.frame.maxY {
                    // After the group it peeks out of
                    return [DropTarget(zone: .regular(beforeTabID: regularTab(after: groupID), groupID: nil, dropOnGroupID: nil),
                                       gap: DropGap(y: row.frame.maxY, depth: 0))]
                }
                endY = row.frame.maxY
            case .newTabButton:
                endY = row.frame.maxY + SidebarLayoutMetrics.regularTabsTopGap
            default:
                break
            }
            index += 1
        }
        return [DropTarget(zone: .regular(beforeTabID: nil, groupID: nil, dropOnGroupID: nil), gap: DropGap(y: endY, depth: 0))]
    }

    /// Before or after `itemID`, where it is among the saved tabs, with room
    /// made at `gapY`.
    private func insertion(beside itemID: UUID, after: Bool, gapY: CGFloat, depth: Int,
                           in structure: SidebarStructure) -> DropTarget? {
        guard let location = sidebarManager?.findItemLocation(itemID: itemID, in: structure),
              let index = location.index else { return nil }
        return DropTarget(
            zone: .organized(parentID: location.parentID, index: after ? index + 1 : index, dropOnFolderID: nil),
            gap: DropGap(y: gapY, depth: depth)
        )
    }

    private static func isPeekKey(_ key: SidebarRowKey) -> Bool {
        if case .peekTab = key { return true }
        return false
    }

    /// The fixed rows are singletons with no pool; they keep their view.
    private static func isFixedRow(_ key: SidebarRowKey) -> Bool {
        switch key {
        case .collectionHeader, .divider, .newTabButton, .dropSlot: return true
        default: return false
        }
    }

    private static func peekKeys(in rows: [SidebarRow]) -> Set<SidebarRowKey> {
        Set(rows.lazy.map(\.key).filter(isPeekKey))
    }

    /// UUID of the tab represented by either a `.tab` or `.peekTab` key.
    /// Used to pair a peek row with the active tab's row in the folder.
    private static func tabUUID(of key: SidebarRowKey) -> UUID? {
        switch key {
        case .tab(let id): return id
        case .peekTab(let id, _): return id
        case .regularTab(let id): return id
        default: return nil
        }
    }

    private static func peekUUID(of key: SidebarRowKey) -> UUID? {
        if case .peekTab(let id, _) = key { return id }
        return nil
    }

    // MARK: Drop validation

    /// Returns true if the drag payload + zone combination is a valid
    /// drop. Validation logic depends on what's on the pasteboard:
    ///   * Sidebar-item UUID for an *organized* tab/folder: full nesting +
    ///     descendant checks; demote (organized → regular) is always OK.
    ///   * Sidebar-item UUID for a *regular* browser tab: promote into
    ///     organized is OK, and so is a move among the regular tabs.
    ///   * URL/string pasteboard with no UUID: any zone is OK — we'll open
    ///     a new tab.
    private func isValidDrop(target: DropTarget, sender: NSDraggingInfo) -> Bool {
        guard let manager = sidebarManager else { return false }

        if let draggedID = sender.draggedSidebarItemUUIDs.first {
            let structure = manager.sidebarStructure
            let isSavedTab = structure.tabs[draggedID] != nil
            let isSavedGroup = structure.folders[draggedID] != nil
            let isOrganized = isSavedTab || isSavedGroup
            let isRegularGroup = !isOrganized && OpenTabStore.shared.group(withID: draggedID) != nil
            // This window's, or another window's, which comes over
            let page = isOrganized || isRegularGroup ? nil
                : tabManager?.tabs.first(where: { $0.id == draggedID }) ?? BrowserWindowSession.allTabs.first { $0.id == draggedID }
            if !isOrganized && !isRegularGroup && page == nil { return false }

            switch target.zone {
            case .organized(let parentID, _, let dropOnFolderID):
                if isOrganized {
                    return validateOrganizedMove(draggedID: draggedID, parentID: parentID, dropOnFolderID: dropOnFolderID, manager: manager)
                }
                if isRegularGroup {
                    // Saved, it's a group in the group it's dropped in
                    return (dropOnFolderID ?? parentID).map {
                        manager.folderManager.calculateNestingDepth(for: $0) < SidebarConfiguration.maxNestingLevel - 1
                    } ?? true
                }
                // Regular browser tab being promoted; no nesting issues
                // because tabs can't have children.
                return true
            case .regular(_, let groupID, _):
                // Groups down here are one level deep, and a saved group
                // needs a tab to be one of regular tabs
                if isRegularGroup { return groupID == nil }
                if isSavedGroup { return groupID == nil && !structure.contents(ofFolder: draggedID).tabIDs.isEmpty }
                // A saved tab demoted, a regular tab moved among them, or
                // come over from another space (whose button sprang this one
                // open) or window. Only an open tab, or one becoming one, is
                // in a group.
                guard groupID != nil, let page else { return true }
                let owner = BrowserWindowSession.owner(ofTab: page.id)?.tabManager ?? tabManager
                return owner.map { OpenTabStore.shared.canGroup(page, in: $0) } ?? false
            }
        }

        // External URL / string pasteboard — accept any zone.
        if sender.hasDraggedLink { return true }

        return false
    }

    /// The same folder rules the move itself applies (SidebarDragDropManager),
    /// so the list never makes room for a drop that would be refused — or
    /// that would put a folder inside its own subfolder.
    private func validateOrganizedMove(draggedID: UUID, parentID: UUID?, dropOnFolderID: UUID?, manager: SidebarManager) -> Bool {
        if let onFolderID = dropOnFolderID {
            if onFolderID == draggedID { return false }
            if manager.sidebarStructure.folders[draggedID] != nil,
               !manager.folderManager.canDropFolder(draggedID, into: onFolderID) {
                return false
            }
        } else if let parentID = parentID {
            if parentID == draggedID { return false }
            if manager.sidebarStructure.folders[draggedID] != nil,
               !manager.folderManager.canDropFolder(draggedID, into: parentID) {
                return false
            }
        }
        return true
    }

    private func extractURLString(_ pasteboard: NSPasteboard) -> String? {
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.absoluteString
        }
        if let s = pasteboard.string(forType: .URL) { return s }
        if let s = pasteboard.string(forType: .string), URL(string: s) != nil { return s }
        return nil
    }

    // MARK: Drop dispatch

    /// Drops it at `target`: whether it was taken, and the row it's now in,
    /// to come in from where the drag's image was.
    private func applyDrop(target: DropTarget, sender: NSDraggingInfo) -> (accepted: Bool, row: SidebarRowKey?) {
        guard let manager = sidebarManager else { return (false, nil) }
        let pasteboard = sender.draggingPasteboard

        if let draggedID = sender.draggedSidebarItemUUIDs.first {
            let isOrganized = manager.sidebarStructure.tabs[draggedID] != nil
                || manager.sidebarStructure.folders[draggedID] != nil
            let isRegularGroup = !isOrganized && OpenTabStore.shared.group(withID: draggedID) != nil
            // Another window's tab comes over first
            let regularBrowserTab = isOrganized || isRegularGroup ? nil : manager.browserTabBroughtHere(draggedID)

            switch target.zone {
            case .organized(let parentID, let index, let dropOnFolderID):
                if isRegularGroup {
                    // Its tabs saved, in a saved group of the same name
                    // (dropped onto a group, `parentID` is that one)
                    guard manager.saveRegularGroup(draggedID, in: parentID, at: index) else { return (false, nil) }
                    return (true, .folder(draggedID))
                }
                if isOrganized {
                    guard validateOrganizedMove(draggedID: draggedID, parentID: parentID, dropOnFolderID: dropOnFolderID, manager: manager) else { return (false, nil) }
                    let oldSpaceID = manager.sidebarStructure.collectionID(ofItem: draggedID)
                    let row: SidebarRowKey = manager.sidebarStructure.folders[draggedID] != nil ? .folder(draggedID) : .tab(draggedID)
                    manager.moveItemToPosition(draggedID, containerID: parentID, index: index)
                    SpaceManager.shared.reopenSavedItemIfProfileChanged(draggedID, from: oldSpaceID)
                    return (true, row)
                } else if let bt = regularBrowserTab, let selection = manager.spaceSelection {
                    let spaces = SpaceManager.shared
                    if !selection.isInActiveSpace(bt), !bt.isPrivate,
                       spaces.profileID(of: bt) != spaces.profileID(ofSpace: selection.currentSpaceID) {
                        // Its page has another profile's data: it opens
                        // anew in this space instead.
                        if let spaceID = selection.currentSpaceID {
                            selection.move(itemID: bt.id, toSpace: spaceID)
                        }
                        return (true, nil)
                    }
                    // Promote: create a sidebar tab linked to the existing
                    // browser tab at the requested position.
                    let tabID = manager.addTabAtPosition(bt, to: parentID, at: index)
                    return (true, .tab(tabID))
                }
            case .regular(let beforeTabID, let groupID, _):
                guard let selection = manager.spaceSelection, let tabManager else { return (false, nil) }
                let group = groupID.flatMap { regularGroupsByID[$0] ?? OpenTabStore.shared.group(withID: $0) }
                if isRegularGroup {
                    // Its tabs together, from another space too
                    manager.moveRegularGroup(draggedID, before: beforeTabID)
                    return (true, .folder(draggedID))
                }
                if manager.sidebarStructure.folders[draggedID] != nil {
                    // Its tabs open, as a group of regular tabs
                    guard manager.moveSavedGroupToRegularTabs(draggedID, before: beforeTabID) else { return (false, nil) }
                    return (true, .folder(draggedID))
                }
                if isOrganized {
                    guard manager.sidebarStructure.tabs[draggedID] != nil else { return (false, nil) }
                    let oldSpaceID = manager.sidebarStructure.collectionID(ofItem: draggedID)
                    let browserTabID = manager.sidebarToBrowserTabMapping[draggedID]
                    // Demote: remove the sidebar tab, mapping cleanup makes
                    // the underlying browser tab fall back into the regular
                    // tabs — of this space, if it came from another.
                    manager.removeTab(withID: draggedID)
                    guard let browserTabID else { return (true, nil) }
                    if oldSpaceID != selection.currentSpaceID, let spaceID = selection.currentSpaceID {
                        selection.move(itemID: browserTabID, toSpace: spaceID)
                    }
                    OpenTabStore.shared.movePages([browserTabID], before: beforeTabID, into: group, in: tabManager)
                    return (true, .regularTab(browserTabID))
                } else if let bt = regularBrowserTab {
                    // From another space, or window, or moved among them
                    if !selection.isInActiveSpace(bt), let spaceID = selection.currentSpaceID {
                        selection.move(itemID: bt.id, toSpace: spaceID)
                    }
                    OpenTabStore.shared.movePages([bt.id], before: beforeTabID, into: group, in: tabManager)
                    return (true, .regularTab(bt.id))
                }
            }
            return (false, nil)
        }

        // External URL drop.
        if let urlString = extractURLString(pasteboard), let tabManager = tabManager {
            switch target.zone {
            case .organized(let parentID, let index, _):
                let newID = tabManager.createNewTab(url: urlString, isExternalURL: true)
                if let bt = tabManager.tabs.first(where: { $0.id == newID }) {
                    _ = manager.addTabAtPosition(bt, to: parentID, at: index)
                }
                return (true, nil)
            case .regular(let beforeTabID, let groupID, _):
                let newID = tabManager.createNewTab(url: urlString, isExternalURL: true)
                let group = groupID.flatMap { regularGroupsByID[$0] ?? OpenTabStore.shared.group(withID: $0) }
                OpenTabStore.shared.movePages([newID], before: beforeTabID, into: group, in: tabManager)
                return (true, nil)
            }
        }
        return (false, nil)
    }

    // MARK: Hover-expand

    /// Held over a closed folder it would drop into, the drag opens it, to
    /// drop among what's in it.
    private func handleHoverExpand(folderID: UUID?) {
        guard hoverExpandFolderID != folderID else { return }
        hoverExpandTimer?.invalidate()
        hoverExpandTimer = nil
        hoverExpandFolderID = folderID

        guard let folderID = folderID,
              let manager = sidebarManager,
              !manager.expandedFolders.contains(folderID) else { return }

        let timer = Timer(timeInterval: Self.hoverExpandDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let manager = self?.sidebarManager else { return }
                manager.expandedFolders.insert(folderID)
            }
        }
        // A drag runs the run loop in the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        hoverExpandTimer = timer
    }

    private func cancelHoverExpand() {
        hoverExpandTimer?.invalidate()
        hoverExpandTimer = nil
        hoverExpandFolderID = nil
    }

    // MARK: Auto-scroll

    private func handleAutoScroll(sender: NSDraggingInfo) {
        guard let scrollView = enclosingScrollView else { return }
        let pointInClip = scrollView.contentView.convert(sender.draggingLocation, from: nil)
        let visible = scrollView.contentView.bounds
        let topDistance = pointInClip.y - visible.minY
        let bottomDistance = visible.maxY - pointInClip.y
        let edge = Self.autoScrollEdgeDistance

        var velocity: CGFloat = 0
        if topDistance < edge {
            // Near top → scroll up (decrease bounds.origin.y in a flipped view).
            let intensity = max(0, min(1, (edge - topDistance) / edge))
            velocity = -intensity * Self.autoScrollMaxSpeed
        } else if bottomDistance < edge {
            let intensity = max(0, min(1, (edge - bottomDistance) / edge))
            velocity = intensity * Self.autoScrollMaxSpeed
        }
        autoScrollVelocity = velocity
        if velocity == 0 {
            cancelAutoScroll()
        } else if autoScrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tickAutoScroll()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoScrollTimer = timer
        }
    }

    private func tickAutoScroll() {
        guard let scrollView = enclosingScrollView, autoScrollVelocity != 0 else { return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        origin.y += autoScrollVelocity
        // Clamp so we don't scroll past the document bounds.
        let maxY = max(0, totalHeight - clipView.bounds.height)
        origin.y = max(0, min(maxY, origin.y))
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func cancelAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollVelocity = 0
    }
}

// MARK: - NSDraggingSource

extension SidebarRowsView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        SidebarPasteboardTypes.dragOperations(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard var draggedRow else { return }
        if !draggedRow.hasLookedForImageWindow, let window {
            // AppKit has put its image up by now
            draggedRow.hasLookedForImageWindow = true
            draggedRow.imageWindow = SidebarDragImageWindow.find(above: window, other: dragPanel)
            self.draggedRow = draggedRow
            presentDraggedRow()
        }
        moveDraggedRowView(to: screenPoint)
        // Over the Klar window in front there, this one or another: a row
        // over its sidebar, a page over its pages, a link anywhere else
        let layout = BrowserWindowSession.session(atScreenPoint: screenPoint)?.layoutView
        let isOutsideSidebar = !(layout?.shownSidebarScreenFrame.map { NSMouseInRect(screenPoint, $0, false) } ?? false)
        let isOverPage = isOutsideSidebar && layout?.contentScreenFrame.map { NSMouseInRect(screenPoint, $0, false) } ?? false
        // A pinned site's is its tile over any window's pinned sites, its
        // own grid included, which tells nobody of its own tile
        let pinnedTile = draggedRow.pinnedSite.map { PinnedSitesView.isOverGrid(atScreenPoint: screenPoint) ? $0.tile : nil }
        let isOverGridChanged = pinnedTile.map { ($0 != nil) != (draggedRow.pinnedTile != nil) } ?? false
        if isOutsideSidebar != draggedRow.isOutsideSidebar || isOverPage != draggedRow.isOverPage || isOverGridChanged {
            self.draggedRow?.isOutsideSidebar = isOutsideSidebar
            self.draggedRow?.isOverPage = isOverPage
            if let pinnedTile {
                self.draggedRow?.pinnedTile = pinnedTile
            }
            updateDraggedRowShape()
        }
        // Out of its own sidebar
        if draggedRow.selectionToRestore != nil,
           draggedRow.sidebarFrame.map({ !NSMouseInRect(screenPoint, $0, false) }) ?? false {
            restoreSelectionBeforePress()
        }
    }

    /// Out of the sidebar, a tab whose row was pressed to drag it gives the
    /// selection back to the one selected before, which shows its page
    /// again: the page to drop it beside, into a split view.
    private func restoreSelectionBeforePress() {
        guard let itemID = draggedRow?.selectionToRestore else { return }
        draggedRow?.selectionToRestore = nil
        sidebarManager?.selectItem(itemID)
        // No longer the selected row, as it'll land
        (draggedRowView?.row as? SidebarTabRowView)?.setSelected(false)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingItem = false
        if Self.activeDragSource === self {
            Self.activeDragSource = nil
        }
        if let pinnedSite = draggedRow?.pinnedSite {
            endPinnedSiteDrag(pinnedSite, operation: operation)
        }
        if let imageWindow = draggedRow?.imageWindow {
            // In case AppKit puts it up again for another drag
            DispatchQueue.main.async {
                _ = SidebarDragImageWindow.setHidden(false, imageWindow)
            }
        }
        if lift != nil && !operation.isEmpty {
            // Taken elsewhere (the pinned sites, a space's button, another
            // app's link), which shows it from here on
            draggedRowView?.isHidden = true
        }
        draggedRow = nil
        dragMouseDownKey = nil
        isDragOver = false
        cancelAutoScroll()
        cancelHoverExpand()
        NotificationCenter.default.post(name: .sidebarItemDragDidEnd, object: nil)

        // Dropped in the list: `performDragOperation` already let go of it
        guard let lift else { return }
        if operation.isEmpty {
            // Put back: from where it was let go, into its place opening again
            if let window {
                let pointer = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                landing = Landing(key: lift.key, origin: CGPoint(x: pointer.x - lift.grabOffset.x,
                                                                 y: pointer.y - lift.grabOffset.y))
            }
            self.lift = nil
            dropTarget = nil
            reload()
        } else {
            // Taken elsewhere (the pinned sites, a space's button): kept out
            // of the list until the change has come in — the controller's
            // reloads, a turn later — so it doesn't show in its place again
            // meanwhile. Its link copied into another app, it comes back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lift?.itemID == lift.itemID else { return }
                self.lift = nil
                self.dropTarget = nil
                self.reload()
            }
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    // MARK: - Pinned sites' drags

    /// The live list of a window's active space, which draws a pinned
    /// site's drag
    static func list(in window: NSWindow?) -> SidebarRowsView? {
        guard let window else { return nil }
        return lists.allObjects.first { $0.window === window && $0.previewedSpace == nil && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// A pinned site dragged off its grid (`PinnedSitesView`), drawn by this
    /// list as it draws a row it drags, from the start as its tile: a tile
    /// over any window's pinned sites, a row over a sidebar, a link out of
    /// it, the page over pages. Its grid keeps the tile's slot until it's
    /// told the drag ended. `tileFrame` is in the grid's coordinates; the
    /// row is held by its favicon, the tile centered under the pointer.
    func beginPinnedSiteDrag(_ id: UUID, link: (url: String, title: String)?, tile: SidebarDraggedRowView.Tile,
                             tileFrame: CGRect, tileImage: [NSDraggingImageComponent], event: NSEvent,
                             restoring selection: UUID?, from grid: PinnedSitesView) -> Bool {
        guard let window, grid.window === window else { return false }
        let size = CGSize(width: bounds.width, height: SidebarLayoutMetrics.standardRowHeight)
        let grabOffset = CGPoint(x: SidebarTabRowView.faviconCenterX, y: size.height / 2)

        let dragItem = NSDraggingItem(pasteboardWriter: NSPasteboardItem.sidebarItem(uuid: id, link: link))
        // AppKit's image, should it show: the tile
        dragItem.draggingFrame = convert(tileFrame, from: grid)
        dragItem.imageComponentsProvider = { tileImage }
        isDraggingItem = true
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // Put back, the tile slides back itself (`endPinnedSiteDrag`)
        session.animatesToStartingPositionsOnCancelOrFail = false
        draggedRow = DraggedRow(session: session, size: size, grabOffset: grabOffset, image: nil,
                                address: link.map { SidebarDraggedRowView.displayAddress($0.url) },
                                sidebarFrame: sidebarScreenFrame)
        draggedRow?.selectionToRestore = selection
        draggedRow?.pinnedTile = tile
        draggedRow?.pinnedSite = .init(tile: tile, grid: grid,
                                       tileScreenFrame: window.convertToScreen(grid.convert(tileFrame, to: nil)))
        Self.activeDragSource = self
        // Not among the rows: nothing to lift out of them, or put back
        lift = Lift(itemID: id, key: .tab(id), grabOffset: grabOffset, origin: .zero, originTarget: nil, hasLeftOrigin: true)
        makeDraggedRowView(for: SidebarRow(key: .tab(id), frame: CGRect(origin: .zero, size: size), depth: 0),
                           pointer: window.convertPoint(toScreen: event.locationInWindow))
        // Ready for when it's dragged out of the sidebar
        snapshotPage(for: .tab(id))
        return true
    }

    /// Dropped, the grid shows the change; put back, the tile slides back
    /// into its slot, which shows it again once it's there.
    private func endPinnedSiteDrag(_ pinnedSite: DraggedRow.PinnedSiteDrag, operation: NSDragOperation) {
        let grid = pinnedSite.grid
        guard operation.isEmpty, let view = draggedRowView, let panel = dragPanel, let content = panel.contentView else {
            grid?.pinnedSiteDragDidEnd(operation: operation)
            return
        }
        isReturningPinnedSite = true
        grid?.pinnedSiteDragWillReturn()
        view.setShape(.tile(pinnedSite.tile))
        // The tile is centered on the point it's held by
        let center = CGPoint(x: pinnedSite.tileScreenFrame.midX, y: pinnedSite.tileScreenFrame.midY)
        let frame = CGRect(x: center.x - view.grabOffset.x, y: center.y + view.grabOffset.y - view.frame.height,
                           width: view.frame.width, height: view.frame.height)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SidebarMotion.perceptualDuration
            context.timingFunction = SidebarMotion.easeOut
            view.animator().frame = content.convert(panel.convertFromScreen(frame), from: nil)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReturningPinnedSite = false
                grid?.pinnedSiteDragDidEnd(operation: operation)
                if self.lift == nil {
                    self.removeDraggedRowView()
                }
            }
        })
    }
}

extension NSView {
    /// The sidebar this view is in, on screen: the view the window's layout
    /// places it in.
    var sidebarScreenFrame: CGRect? {
        guard let window,
              let sidebar = sequence(first: self as NSView, next: \.superview).first(where: { $0.superview is BrowserWindowLayoutView })
        else { return nil }
        return window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
    }
}

/// Flipped container that clips its subviews to its bounds — the cheap,
/// rectangular kind of clipping (no mask layer, no offscreen pass). Its own
/// empty area never takes clicks; only its subviews do.
private final class SidebarClipView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
