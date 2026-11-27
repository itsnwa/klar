import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The corners of a split view's panes: the page's own (see ContentAreaShape)
    @Entry var splitPaneCornerRadius: CGFloat = 0
}

/// The pages: each live tab's web view, filling the content area, or at its
/// pane while it's in a split view, and the empty state for a tab on screen
/// with no page; and, for the split view on screen, the gaps that resize its
/// panes, a ring around the active one, and where a tab dragged onto a page
/// would go.
///
/// Observes the split views itself, so a gap being dragged updates this and
/// nothing above it. Observes TabManager too, as BrowserView does: a tab
/// suspended, or getting a page, changes which tabs have a web view.
struct SplitPanesView: View {
    @EnvironmentObject var tabManager: TabManager
    /// No web views until the window is up and extensions have started (see BrowserView)
    let canLoadPages: Bool
    let isInteractionEnabled: Bool
    @Environment(\.splitPaneCornerRadius) private var cornerRadius
    @State private var layoutState = SplitPanesLayoutState()

    private var activeTabID: UUID? { tabManager.activeTabId }

    var body: some View {
        let splitViews = tabManager.splitViews
        let shownSplit = splitViews.shownSplit
        let shownTabIDs = splitViews.shownTabIDs
        let dropTarget = splitViews.dropTarget
        // Closing as the panes beside them take their place
        let leavingPanes = splitViews.leavingPanes
        let onScreen = shownTabIDs.union(leavingPanes.keys)

        SplitPaneLayout(
            splits: splitViews.splits,
            shownSplitID: shownSplit?.id,
            activeTabID: activeTabID,
            leavingTabIDs: Set(leavingPanes.keys),
            dropTarget: dropTarget,
            animationGeneration: splitViews.paneAnimationGeneration,
            state: layoutState
        ) {
            ForEach(liveTabs(onScreen: onScreen), id: \.id) { tab in
                TabWebView(
                    tab: tab,
                    tabManager: tabManager,
                    isVisible: tab.id == activeTabID || onScreen.contains(tab.id),
                    isInteractionEnabled: isInteractionEnabled,
                    cornerRadius: splitViews.contains(tab.id) || leavingPanes[tab.id] != nil ? cornerRadius : 0,
                    showsPaneControls: shownTabIDs.contains(tab.id),
                    shouldForceArrowCursor: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutValue(key: SplitPaneRole.self, value: .tab(tab.id))
                // The layout moves the panes; nothing fades over that
                .transition(.identity)
            }

            // A new pane (⌘D, ⇧⌘D) until something opens in it
            ForEach(emptyTabs(onScreen: onScreen), id: \.id) { tab in
                EmptyPane(
                    tabID: tab.id,
                    tabManager: tabManager,
                    cornerRadius: splitViews.contains(tab.id) || leavingPanes[tab.id] != nil ? cornerRadius : 0,
                    showsPaneControls: shownTabIDs.contains(tab.id)
                )
                .layoutValue(key: SplitPaneRole.self, value: .tab(tab.id))
                .transition(.identity)
            }

            // A closed tab's pane, until it has closed
            ForEach(closedPaneTabIDs(leavingPanes), id: \.self) { tabID in
                ClosedPane(look: leavingPanes[tabID] ?? .empty, cornerRadius: cornerRadius)
                    .layoutValue(key: SplitPaneRole.self, value: .tab(tabID))
                    .transition(.identity)
            }

            if let shownSplit {
                ForEach(shownSplit.dividerIDs, id: \.self) { divider in
                    SplitDividerHandle(divider: divider, splitViews: splitViews, layoutState: layoutState)
                        .layoutValue(key: SplitPaneRole.self, value: .divider(divider))
                }
                // Where the ring around the active pane goes, which is drawn
                // outside the content area's clip (`SplitFocusRing`)
                Color.clear
                    .anchorPreference(key: SplitFocusedPaneKey.self, value: .bounds) { $0 }
                    .layoutValue(key: SplitPaneRole.self, value: .focusRing)
            }

            if dropTarget != nil {
                SplitDropPreview(cornerRadius: max(cornerRadius, SplitDropPreview.minimumCornerRadius))
                    .layoutValue(key: SplitPaneRole.self, value: .dropPreview)
                    .transition(.opacity)
            }
        }
        .coordinateSpace(.named(SplitDividerHandle.coordinateSpace))
    }

    /// Tabs that get a web view: those with content that aren't suspended,
    /// plus those on screen — showing a suspended tab is what resumes it.
    private func liveTabs(onScreen: Set<UUID>) -> [BrowserTab] {
        guard canLoadPages else { return [] }
        return tabManager.tabs.filter {
            !$0.isEmpty && (!$0.isSuspended || $0.id == activeTabID || onScreen.contains($0.id))
        }
    }

    /// Tabs on screen with no page, which show the empty state
    private func emptyTabs(onScreen: Set<UUID>) -> [BrowserTab] {
        tabManager.tabs.filter { $0.isEmpty && ($0.id == activeTabID || onScreen.contains($0.id)) }
    }

    /// The panes leaving whose tabs have closed
    private func closedPaneTabIDs(_ leavingPanes: [UUID: SplitViewManager.LeavingPane]) -> [UUID] {
        leavingPanes.keys.filter { id in !tabManager.tabs.contains { $0.id == id } }
    }
}

// MARK: - Layout

/// What a view among the panes is, for `SplitPaneLayout` to place it
nonisolated private enum SplitPaneRole: LayoutValueKey {
    static let defaultValue: Role? = nil

    enum Role {
        case tab(UUID)
        case divider(SplitDividerID)
        case focusRing
        case dropPreview
    }
}

/// What the panes' layout hands its views: the size it last laid them out
/// in, for a gap being dragged, and where the drop preview was, for it to
/// fade out there; and what it keeps to move the panes: where it last placed
/// them. A class, so passing it on isn't a view update.
nonisolated private final class SplitPanesLayoutState: @unchecked Sendable {
    var size: CGSize = .zero
    var dropPreviewFrame: CGRect = .zero
    /// Each tab's frame as last placed, which tabs were on screen then, and
    /// the split views they were in
    var placedFrames: [UUID: CGRect] = [:]
    var placedShownTabIDs: Set<UUID> = []
    var placedSplits: [SplitView] = []
    /// The split views' change last placed (`SplitViewManager.paneAnimationGeneration`)
    var generation: Int?
    var animation: SplitPaneAnimation?
}

/// The panes moving to their places after a change of the split views
nonisolated private struct SplitPaneAnimation {
    /// The layout's animated generation as it started, which goes to the
    /// change's own
    let startValue: Double
    /// Where the tabs were on screen as it started, which were, and the
    /// split views they were in
    let fromFrames: [UUID: CGRect]
    let fromShownTabIDs: Set<UUID>
    let fromSplits: [SplitView]
}

/// Places each page at its pane, or over the whole area when its tab is in
/// no split view (hidden then, unless it's the active one), and the split
/// view on screen's gap handles, focus ring and drop preview. A Layout, so
/// a new size (every frame of the sidebar sliding) places them again
/// without re-running any view's body.
///
/// A change that moves the panes (a split, a pane closed or moved) is a new
/// generation, animated: SwiftUI hands each frame's value in between to
/// `animatableData`, and the panes go from where they were on screen to
/// their new places, a pane coming on screen opening from no width at its
/// place in the row as the others make room, and one leaving closing to
/// none as the others take its place. The pages lay out at each size as
/// they go, as they do while the sidebar slides.
nonisolated private struct SplitPaneLayout: Layout {
    let splits: [SplitView]
    let shownSplitID: UUID?
    let activeTabID: UUID?
    /// Shown until they've closed (`SplitViewManager.leavingPanes`)
    let leavingTabIDs: Set<UUID>
    let dropTarget: SplitDropTarget?
    let generation: Int
    let state: SplitPanesLayoutState
    /// On its way to `generation`
    var animatedGeneration: Double

    init(
        splits: [SplitView],
        shownSplitID: UUID?,
        activeTabID: UUID?,
        leavingTabIDs: Set<UUID>,
        dropTarget: SplitDropTarget?,
        animationGeneration: Int,
        state: SplitPanesLayoutState
    ) {
        self.splits = splits
        self.shownSplitID = shownSplitID
        self.activeTabID = activeTabID
        self.leavingTabIDs = leavingTabIDs
        self.dropTarget = dropTarget
        self.generation = animationGeneration
        self.state = state
        animatedGeneration = Double(animationGeneration)
    }

    var animatableData: Double {
        get { animatedGeneration }
        set { animatedGeneration = newValue }
    }

    /// How far a gap's handle reaches into the panes beside it, so it's
    /// easier to grab than the gap itself
    private static let handleOverhang: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        state.size = bounds.size
        let fullFrame = CGRect(origin: .zero, size: bounds.size)
        let geometry = SplitViewManager.geometry(of: splits, in: bounds.size, shownSplitID: shownSplitID)
        if let preview = SplitViewManager.dropPreviewFrame(for: dropTarget, in: geometry, fullFrame: fullFrame) {
            state.dropPreviewFrame = preview
        }

        var shownTabIDs = Set(splits.first { $0.id == shownSplitID }?.root.tabIDs ?? [])
        if let activeTabID {
            shownTabIDs.insert(activeTabID)
        }
        var tabFrames: [UUID: CGRect] = [:]
        for subview in subviews {
            if case .tab(let id)? = subview[SplitPaneRole.self] {
                tabFrames[id] = geometry.paneFrames[id] ?? fullFrame
            }
        }
        if let animation = currentAnimation(), let fraction = progress(of: animation) {
            let size = bounds.size
            tabFrames = Self.frames(
                tabFrames,
                movingFrom: animation,
                progress: fraction,
                shownTabIDs: shownTabIDs,
                openingGeometry: {
                    Self.geometry(of: splits, collapsing: shownTabIDs.subtracting(animation.fromShownTabIDs), in: size)
                },
                closingGeometry: {
                    Self.geometry(of: animation.fromSplits, collapsing: animation.fromShownTabIDs.subtracting(shownTabIDs), in: size)
                }
            )
        } else {
            // Closed, until they're gone
            for id in leavingTabIDs where !shownTabIDs.contains(id) {
                tabFrames[id] = state.placedFrames[id] ?? tabFrames[id]
            }
        }
        state.placedFrames = tabFrames
        state.placedShownTabIDs = shownTabIDs
        state.placedSplits = splits

        for subview in subviews {
            let frame: CGRect
            switch subview[SplitPaneRole.self] {
            case .tab(let id)?:
                frame = tabFrames[id] ?? fullFrame
            case .divider(let id)?:
                let overhang = Self.handleOverhang
                frame = geometry.gaps[id].map {
                    id.axis == .horizontal ? $0.insetBy(dx: -overhang, dy: 0) : $0.insetBy(dx: 0, dy: -overhang)
                } ?? .zero
            case .focusRing?:
                // Around the active pane as it moves
                frame = activeTabID.flatMap { tabFrames[$0] } ?? .zero
            case .dropPreview?:
                // Fading out once the drag has left: where it was
                frame = state.dropPreviewFrame
            case nil:
                frame = fullFrame
            }
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// The panes' animation under way, a new one if the split views have
    /// changed since the last placement (none the first time, or when the
    /// change wasn't animated)
    private func currentAnimation() -> SplitPaneAnimation? {
        if state.generation != generation {
            let isAnimated = state.generation != nil && animatedGeneration != Double(generation)
            state.animation = isAnimated
                ? SplitPaneAnimation(
                    startValue: animatedGeneration,
                    fromFrames: state.placedFrames,
                    fromShownTabIDs: state.placedShownTabIDs,
                    fromSplits: state.placedSplits
                )
                : nil
            state.generation = generation
        }
        return state.animation
    }

    /// How far the panes are, 0 to 1, without overshooting; nil once
    /// they're there
    private func progress(of animation: SplitPaneAnimation) -> CGFloat? {
        let span = Double(generation) - animation.startValue
        guard span > 0, animatedGeneration < Double(generation) else {
            state.animation = nil
            return nil
        }
        return CGFloat(min(max((animatedGeneration - animation.startValue) / span, 0), 1))
    }

    /// Each tab's frame on the way to `targets`: a pane on screen before and
    /// after from where it was; one coming on screen from no width at its
    /// place in the row (`openingGeometry`, its share 0); one leaving to no
    /// width at its place in the row it was in (`closingGeometry`)
    private static func frames(
        _ targets: [UUID: CGRect],
        movingFrom animation: SplitPaneAnimation,
        progress: CGFloat,
        shownTabIDs: Set<UUID>,
        openingGeometry: () -> SplitGeometry,
        closingGeometry: () -> SplitGeometry
    ) -> [UUID: CGRect] {
        var opening: SplitGeometry?
        var closing: SplitGeometry?
        var frames = targets
        for (id, target) in targets {
            let wasShown = animation.fromShownTabIDs.contains(id)
            if shownTabIDs.contains(id) {
                let from: CGRect?
                if wasShown {
                    from = animation.fromFrames[id]
                } else {
                    if opening == nil {
                        opening = openingGeometry()
                    }
                    from = opening?.paneFrames[id]
                }
                if let from {
                    frames[id] = interpolate(from, target, progress)
                }
            } else if wasShown, let from = animation.fromFrames[id] {
                if closing == nil {
                    closing = closingGeometry()
                }
                frames[id] = interpolate(from, closing?.paneFrames[id] ?? from, progress)
            }
        }
        return frames
    }

    /// The split views laid out with the panes of `ids` at no share
    private static func geometry(of splits: [SplitView], collapsing ids: Set<UUID>, in size: CGSize) -> SplitGeometry {
        guard !ids.isEmpty else { return SplitGeometry() }
        var collapsed = splits
        for index in collapsed.indices {
            collapsed[index].root = collapsed[index].root.collapsing(ids)
        }
        return SplitViewManager.geometry(of: collapsed, in: size, shownSplitID: nil)
    }

    /// On whole points, as the pages' frames always are
    private static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            (a + (b - a) * progress).rounded()
        }
        let minX = mix(from.minX, to.minX)
        let minY = mix(from.minY, to.minY)
        return CGRect(x: minX, y: minY, width: mix(from.maxX, to.maxX) - minX, height: mix(from.maxY, to.maxY) - minY)
    }
}

// MARK: - Empty pane

/// A tab with no page, on screen: the empty state, as the window shows with
/// no tab open, on the empty state's color. A click makes it the active tab, and a
/// tab dragged from the sidebar onto it (or another pane) takes its place.
private struct EmptyPane: View {
    let tabID: UUID
    let tabManager: TabManager
    let cornerRadius: CGFloat
    let showsPaneControls: Bool

    var body: some View {
        EmptyPaneContent(cornerRadius: cornerRadius)
            .overlay {
                EmptyPaneTarget(tabID: tabID, tabManager: tabManager, showsPaneControls: showsPaneControls)
            }
    }
}

private struct EmptyPaneContent: View {
    let cornerRadius: CGFloat

    var body: some View {
        EmptyStateView()
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(EmptyStateView.backgroundColor)
            }
    }
}

/// A closed tab's pane as it closes: an empty pane as it was, a page's in
/// the page's color (its web view is gone with the tab)
private struct ClosedPane: View {
    let look: SplitViewManager.LeavingPane
    let cornerRadius: CGFloat

    var body: some View {
        switch look {
        case .empty:
            EmptyPaneContent(cornerRadius: cornerRadius)
        case .page(let color):
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color)
        }
    }
}

private struct EmptyPaneTarget: NSViewRepresentable {
    let tabID: UUID
    let tabManager: TabManager
    let showsPaneControls: Bool

    func makeNSView(context: Context) -> EmptyPaneTargetView {
        EmptyPaneTargetView()
    }

    func updateNSView(_ view: EmptyPaneTargetView, context: Context) {
        view.tabID = tabID
        view.tabManager = tabManager
        view.setPaneControls(showsPaneControls)
    }
}

/// Over an empty pane, taking its clicks and the tabs and panes dropped on
/// it, with the pane's controls along its top
final class EmptyPaneTargetView: NSView {
    var tabID: UUID?
    weak var tabManager: TabManager?
    private var paneControls: SplitPaneControlsView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([SidebarPasteboardTypes.sidebarItem, SplitPaneControlsView.pasteboardType])
    }

    func setPaneControls(_ isShown: Bool) {
        guard isShown, let tabID, let tabManager else {
            paneControls?.removeFromSuperview()
            paneControls = nil
            return
        }
        let controls = paneControls ?? SplitPaneControlsView()
        if paneControls == nil {
            addSubview(controls)
            paneControls = controls
        }
        controls.tabID = tabID
        controls.tabManager = tabManager
        controls.placeAtTop(of: self)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        paneControls?.placeAtTop(of: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Keys no longer go to the page that had them
        window?.makeFirstResponder(nil)
        guard let tabID else { return }
        tabManager?.focusPane(tabID)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrop()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tabID, let tabManager else { return false }
        return tabManager.performSplitDrop(sender, over: tabID, on: nil)
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let tabID, let tabManager else { return [] }
        return tabManager.updateSplitDrop(sender, over: tabID, on: nil)
    }

    private func endDrop() {
        guard let tabID else { return }
        tabManager?.endSplitDrop(over: tabID)
    }
}

// MARK: - Gaps, focus and drop preview

/// The gap between two panes: dragged, it resizes them; double-clicked, the
/// panes of its row share it evenly.
private struct SplitDividerHandle: View {
    static let coordinateSpace = "SplitPanes"

    let divider: SplitDividerID
    let splitViews: SplitViewManager
    let layoutState: SplitPanesLayoutState

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(divider.axis == .horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { value in
                        splitViews.moveDivider(divider, to: value.location, in: layoutState.size)
                    }
            )
            .onTapGesture(count: 2) {
                splitViews.equalize(divider)
            }
    }
}

/// The active pane of the split view on screen, for its ring
struct SplitFocusedPaneKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Around the active tab's pane, so it's clear which page the keyboard,
/// the URL bar and ⌘W act on: outside the page, a 1 pt shadow against
/// it and a 1.5 pt highlight around that, monochrome as the sidebar's
/// selection is (the accent is for where a dragged tab would go). Drawn
/// over the content area rather than in it, whose shape would clip it
/// along the window's edges.
struct SplitFocusRing: View {
    static let highlightWidth: CGFloat = 1.5
    static let shadowWidth: CGFloat = 1

    /// The pane's own, which the ring's corners are concentric with
    let cornerRadius: CGFloat

    var body: some View {
        let outset = Self.highlightWidth + Self.shadowWidth
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.6), lineWidth: Self.highlightWidth)
            RoundedRectangle(cornerRadius: cornerRadius + Self.shadowWidth, style: .continuous)
                .strokeBorder(Color.black.opacity(0.6), lineWidth: Self.shadowWidth)
                .padding(Self.highlightWidth)
        }
        .padding(-outset)
        .allowsHitTesting(false)
    }
}

/// Where a tab dragged from the sidebar would go
private struct SplitDropPreview: View {
    static let minimumCornerRadius: CGFloat = 8

    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(0.18))
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
            }
            .allowsHitTesting(false)
    }
}
