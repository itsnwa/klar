import SwiftUI
import AppKit

// MARK: - Zoom levels

/// The sidebar's content at its three zoom levels: the active space's tabs;
/// the overview of the library and every space; and one of the library's
/// full lists.
///
/// Pinching zooms out to the overview and back in, following the fingers:
/// as far as the pinch has gone, what's going out zooms away, blurs and
/// fades, and what's coming in zooms in from blurred to sharp; let go, it
/// goes to whichever end is nearer, or where it was heading. Swiping
/// sideways moves between pages laid out left to right, the overview and
/// then each space, following the fingers too. The overview button, the
/// menu and the shortcuts cross-fade. The tabs zoom on their AppKit layer (`SidebarTabsViewController.setZoomedOut`):
/// scaled by SwiftUI, their rows were laid out again on every frame and
/// their text jumped, and SwiftUI's blur doesn't reach AppKit views. The
/// lists, AppKit tables under a SwiftUI header, only fade.
///
/// The pinned sites are the space's and the lists', above them, not the
/// overview's: they zoom out and fade with the tabs, and slide away with
/// them to the overview, which has all of the sidebar under the URL bar.
struct SidebarZoomContent: View {
    @Environment(SidebarStateManager.self) var sidebarStateManager
    /// Not observed for its changes: read when a swipe starts or ends
    @EnvironmentObject private var spaceSelection: SpaceSelection

    @State private var pinch: Pinch?
    @State private var swipe: Swipe?
    /// What a gesture let go of does once it has settled. Done at once if
    /// another gesture starts first.
    @State private var settling: Settling?
    @State private var width: CGFloat = 0
    @StateObject private var pinnedSites = PinnedSitesState()

    /// How far the fingers close (in total magnification) to zoom all the way out.
    private static let pinchDistance: CGFloat = 0.35
    /// How blurred the overview is when it starts to come in, in points.
    private static let pinchBlur: CGFloat = 12
    /// How far ahead a gesture is projected when let go, in seconds of its speed.
    private static let projection: CGFloat = 0.15
    /// How much the pinned sites shrink zoomed all the way out, as the tabs do.
    private static let pinnedSitesShrink: CGFloat = 0.1

    var body: some View {
        let level = sidebarStateManager.level
        ZStack {
            VStack(spacing: 0) {
                PinnedSitesSpace(count: pinnedSites.count) {}
                ZStack {
                    // Kept at every level: building the rows of hundreds of saved
                    // tabs again on each zoom would cost more than hiding them.
                    ZoomingTabs(zoomedOut: pinch.map { $0.base == .space ? $0.progress : 0 } ?? 0,
                                acceptsDrops: level == .space)
                        .opacity(tabsOpacity)
                        .offset(x: swipe.flatMap { $0.offset(of: .space($0.activeSpaceID), width: width) } ?? 0)
                        .allowsHitTesting(level == .space && pinch == nil && swipe == nil)

                    // The space beside the active one, while swiping to it
                    if let spaceID = swipe?.previewedSpaceID {
                        SidebarTabsAppKitBridge(previewedSpaceID: spaceID)
                            .id(spaceID)
                            .offset(x: swipe?.offset(of: .space(spaceID), width: width) ?? 0)
                            .allowsHitTesting(false)
                    }
                }
            }

            if level == .overview || pinch != nil || swipe?.offset(of: .overview, width: width) != nil {
                SidebarOverview()
                    .scaleEffect(pinch.map { 1.1 - 0.1 * $0.progress } ?? 1)
                    .blur(radius: pinch.map { Self.pinchBlur * (1 - $0.progress) } ?? 0)
                    .opacity(pinch.map { Double($0.progress) } ?? 1)
                    .offset(x: swipe?.offset(of: .overview, width: width) ?? 0)
                    .allowsHitTesting(pinch == nil && swipe == nil)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if case .list(let list) = level {
                VStack(spacing: 0) {
                    PinnedSitesSpace(count: pinnedSites.count) {}
                    SidebarLibraryListView(list: list)
                }
                .id(list)
                .opacity(pinch.map { 1 - $0.progress } ?? 1)
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .overlay {
            let opacity = pinnedSitesOpacity
            PinnedSitesSection(state: pinnedSites, isShown: opacity > 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // About the middle, as the tabs zoom
                .scaleEffect(1 - Self.pinnedSitesShrink * (pinch?.progress ?? 0))
                .opacity(opacity)
                .offset(x: swipe.flatMap { pinnedSitesOffset(in: $0) } ?? 0)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .background(SidebarGestureMonitor(
            canSwipe: { pinch == nil && [SidebarLevel.space, .overview].contains(sidebarStateManager.level) },
            onPinch: handlePinch,
            onSwipe: handleSwipe,
            onStep: handleStep
        ))
    }

    private var tabsOpacity: Double {
        if let swipe {
            return swipe.offset(of: .space(swipe.activeSpaceID), width: width) == nil ? 0 : 1
        }
        if let pinch {
            return pinch.base == .space ? 1 - pinch.progress : 0
        }
        return sidebarStateManager.level == .space ? 1 : 0
    }

    // MARK: Pinned sites

    /// The pinned sites fade as a pinch zooms out to the overview, which
    /// has none, and back in; a swipe moves them instead.
    private var pinnedSitesOpacity: Double {
        if let pinch {
            return 1 - pinch.progress
        }
        if let swipe {
            return pinnedSitesOffset(in: swipe) == nil ? 0 : 1
        }
        return sidebarStateManager.level == .overview ? 0 : 1
    }

    /// Where a swipe has moved the pinned sites across: with the space's
    /// page as it goes to or from the overview, not between spaces, which
    /// share them. Nil while only the overview shows.
    private func pinnedSitesOffset(in swipe: Swipe) -> CGFloat? {
        let pages = [swipe.current, swipe.neighbor].compactMap { $0 }
        guard pages.contains(.overview) else { return 0 }
        guard let spacePage = pages.first(where: { $0 != .overview }) else { return nil }
        return swipe.offset(of: spacePage, width: width)
    }

    // MARK: Pinch

    /// The tabs, zoomed out and blurred as the overview comes in, and in
    /// as it goes. Animatable, so a settling pinch reaches the AppKit view
    /// on every frame: a plain value would get there in one step.
    private struct ZoomingTabs: View, Animatable {
        var zoomedOut: CGFloat
        var acceptsDrops: Bool

        var animatableData: CGFloat {
            get { zoomedOut }
            set { zoomedOut = newValue }
        }

        var body: some View {
            SidebarTabsAppKitBridge(zoomedOut: zoomedOut, acceptsDrops: acceptsDrops)
        }
    }

    private struct Pinch {
        /// The level it began at.
        let from: SidebarLevel
        /// How far toward the overview: 0 at `base`, 1 at the overview.
        var progress: CGFloat

        /// Where zooming in from the overview goes: the space.
        var base: SidebarLevel { from == .overview ? .space : from }
    }

    private func handlePinch(_ phase: SidebarGesturePhase) {
        switch phase {
        case .began:
            finishSettling()
            guard swipe == nil else { return }
            let level = sidebarStateManager.level
            pinch = Pinch(from: level, progress: level == .overview ? 1 : 0)

        case .changed(let magnification):
            guard var pinch else { return }
            // Closing the fingers zooms out
            let zoomedOut = -magnification / Self.pinchDistance
            pinch.progress = min(max(pinch.from == .overview ? 1 + zoomedOut : zoomedOut, 0), 1)
            self.pinch = pinch

        case .ended(_, let velocity):
            guard let pinch else { return }
            let projected = pinch.progress - velocity / Self.pinchDistance * Self.projection
            let zoomsOut = projected > 0.5
            let destination: SidebarLevel = zoomsOut ? .overview : pinch.base
            settle(.spring(duration: 0.3, bounce: 0)) {
                self.pinch?.progress = zoomsOut ? 1 : 0
            } then: {
                self.pinch = nil
                sidebarStateManager.show(destination, animated: false)
            }
        }
    }

    // MARK: Swipe

    /// The pages swiping moves between, left to right: the overview, then
    /// each space.
    private enum Page: Equatable {
        case overview
        case space(UUID)
    }

    private struct Swipe {
        let id = UUID()
        /// The space the tabs view shows.
        let activeSpaceID: UUID
        let current: Page
        let previous: Page?
        let next: Page?
        /// How far the pages have moved right, in points: positive brings in
        /// `previous`, negative `next`.
        var offset: CGFloat = 0

        var neighbor: Page? {
            offset > 0 ? previous : offset < 0 ? next : nil
        }

        /// Another space than the active one, coming in.
        var previewedSpaceID: UUID? {
            guard case .space(let id) = neighbor, id != activeSpaceID else { return nil }
            return id
        }

        /// Where `page` is, if it's on screen.
        func offset(of page: Page, width: CGFloat) -> CGFloat? {
            if page == current { return offset }
            if page == neighbor { return offset > 0 ? offset - width : offset + width }
            return nil
        }

        /// The fingers' total movement as the pages' offset: one to one
        /// toward a page, resisting past the first or the last.
        func pagesOffset(forScroll scroll: CGFloat, width: CGFloat) -> CGFloat {
            let hasPage = scroll > 0 ? previous != nil : next != nil
            if hasPage {
                return min(max(scroll, -width), width)
            }
            let limit = width * 0.25
            let resisted = (1 - 1 / (abs(scroll) * 0.55 / limit + 1)) * limit
            return scroll < 0 ? -resisted : resisted
        }
    }

    private func handleSwipe(_ phase: SidebarGesturePhase) {
        switch phase {
        case .began:
            finishSettling()
            guard pinch == nil, let activeSpaceID = spaceSelection.currentSpaceID else { return }
            let pages = [Page.overview] + SpaceManager.shared.spaces.map { Page.space($0.id) }
            let current: Page = sidebarStateManager.level == .overview ? .overview : .space(activeSpaceID)
            guard let index = pages.firstIndex(of: current) else { return }
            swipe = Swipe(
                activeSpaceID: activeSpaceID,
                current: current,
                previous: index > 0 ? pages[index - 1] : nil,
                next: index + 1 < pages.count ? pages[index + 1] : nil
            )

        case .changed(let scroll):
            guard var swipe else { return }
            swipe.offset = swipe.pagesOffset(forScroll: scroll, width: width)
            self.swipe = swipe

        case .ended(_, let velocity):
            guard let swipe, width > 0 else {
                self.swipe = nil
                return
            }
            let projected = swipe.offset + velocity * Self.projection
            let turnsPage = swipe.neighbor != nil
                && abs(projected) > width / 2
                && (projected > 0) == (swipe.offset > 0)
            settleSwipe(turningPage: turnsPage, velocity: velocity)
        }
    }

    /// A mouse's sideways wheel turns a page at a time: the pages start
    /// moving toward the next one (positive: `previous`), then settle on it.
    private func handleStep(_ direction: CGFloat) {
        handleSwipe(.began)
        guard var swipe, width > 0, (direction > 0 ? swipe.previous : swipe.next) != nil else {
            self.swipe = nil
            return
        }
        swipe.offset = direction > 0 ? 1 : -1
        self.swipe = swipe
        // Once that's on screen, so the page coming in slides in rather
        // than showing up where it lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) {
            guard self.swipe?.id == swipe.id else { return }
            settleSwipe(turningPage: true, velocity: 0)
        }
    }

    /// Springs the pages to the neighbor, or back, then goes there.
    private func settleSwipe(turningPage turnsPage: Bool, velocity: CGFloat) {
        guard let swipe else { return }
        let target: CGFloat = turnsPage ? (swipe.offset > 0 ? width : -width) : 0
        // The spring starts at the speed the fingers left off at.
        let distance = target - swipe.offset
        let initialVelocity = distance != 0 ? min(max(velocity / distance, 0), 10) : 0
        settle(.interpolatingSpring(duration: 0.35, bounce: 0, initialVelocity: initialVelocity)) {
            self.swipe?.offset = target
        } then: {
            if turnsPage, let neighbor = swipe.neighbor {
                turn(to: neighbor, endingSwipe: swipe.id)
            } else {
                self.swipe = nil
            }
        }
    }

    /// Goes to the page a swipe has moved to.
    private func turn(to page: Page, endingSwipe swipeID: UUID) {
        switch page {
        case .overview:
            swipe = nil
            sidebarStateManager.show(.overview, animated: false)
        case .space(let spaceID):
            if spaceID != spaceSelection.currentSpaceID {
                spaceSelection.switchTo(spaceID)
            }
            sidebarStateManager.show(.space, animated: false)
            // The tabs view shows the new space once it has reloaded, which
            // it does next on the main queue; until then, the preview stays.
            DispatchQueue.main.async {
                guard swipe?.id == swipeID else { return }
                withTransaction(Transaction(animation: nil)) {
                    swipe = nil
                }
            }
        }
    }

    // MARK: Settling

    private struct Settling {
        let id = UUID()
        let commit: () -> Void
    }

    /// Animates what's on screen to where a gesture was let go toward, then
    /// goes there for good.
    private func settle(_ animation: Animation, _ change: () -> Void, then commit: @escaping () -> Void) {
        let settling = Settling(commit: commit)
        self.settling = settling
        withAnimation(animation) {
            change()
        } completion: {
            if self.settling?.id == settling.id {
                finishSettling()
            }
        }
    }

    private func finishSettling() {
        guard let settling else { return }
        self.settling = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            settling.commit()
        }
    }
}

// MARK: - Gestures

/// A pinch or a sideways swipe over the sidebar's content, as it goes.
enum SidebarGesturePhase {
    case began
    /// How far it has gone: a pinch's total magnification (negative as the
    /// fingers close), a swipe's total sideways scroll in points (positive
    /// as the fingers move right).
    case changed(CGFloat)
    /// How far it went, and how fast it was going when let go, per second.
    case ended(CGFloat, velocity: CGFloat)
}

struct SidebarGestureMonitor: NSViewRepresentable {
    /// Asked as a scroll starts: whether one going sideways is a swipe.
    let canSwipe: () -> Bool
    let onPinch: (SidebarGesturePhase) -> Void
    let onSwipe: (SidebarGesturePhase) -> Void
    /// A mouse's sideways wheel flicked: which way (positive: right, as a swipe).
    let onStep: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarGestureMonitorView {
        let view = SidebarGestureMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SidebarGestureMonitorView, context: Context) {
        view.canSwipe = canSwipe
        view.onPinch = onPinch
        view.onSwipe = onSwipe
        view.onStep = onStep
    }
}

/// Watches the window's pinches and trackpad scrolls that start over its
/// bounds; it takes no clicks. A scroll that starts out clearly sideways is
/// a swipe: the views under it get none of it, nor its momentum. Other
/// scrolls go on to them, once it's clear they aren't swipes: up and down
/// wins anything in between, since scrolling the list is what's done most.
/// Until then, a scroll's events are held back, from its very first (the
/// fingers touching), so the list doesn't move under a swipe as it starts.
/// A scroll view under it mustn't use responsive scrolling
/// (`SidebarTabsScrollView`): that sends a scroll's events after its first
/// straight to the scroll view, past this monitor.
///
/// A mouse's wheel scrolling sideways (a thumb wheel, or Shift with the
/// wheel) has no motion to follow, only steps: each flick of it turns a page, and the
/// views under it get none of it.
final class SidebarGestureMonitorView: NSView {
    var canSwipe: (() -> Bool)?
    var onPinch: ((SidebarGesturePhase) -> Void)?
    var onSwipe: ((SidebarGesturePhase) -> Void)?
    var onStep: ((CGFloat) -> Void)?

    private var monitors: [Any] = []
    private var pinch: Motion?
    private var scroll: ScrollState = .idle
    /// Set while handing held-back events on, so they aren't held again.
    private var isPassingHeldEvents = false
    /// The sideways wheel flick going on.
    private var flick: Flick?

    private enum ScrollState {
        case idle
        /// Too little movement yet to tell which way it goes.
        case deciding(Pending)
        case swiping(Motion)
        /// A swipe let go: its momentum is ours too.
        case coasting
        /// A scroll for the views under it.
        case passing
    }

    /// How far a scroll moves sideways, in points, to be a swipe, and how
    /// many times further than up or down.
    private static let swipeDistance: CGFloat = 10
    private static let swipeRatio: CGFloat = 2
    /// How far a scroll going more up or down than sideways moves before
    /// it's a scroll, and how far one that's neither clearly does.
    private static let scrollDistance: CGFloat = 4
    private static let decisionLimit: CGFloat = 16
    /// How long a sideways wheel rests before its next flick turns another page.
    private static let stepPause: TimeInterval = 0.2
    /// How far a flick goes sideways, in the wheel's lines, to turn a page.
    private static let stepDistance: CGFloat = 6

    /// A mouse wheel's sideways flick: how far it has gone, when it last
    /// moved, and whether it has turned its page.
    private struct Flick {
        var total: CGFloat = 0
        var lastMoved: TimeInterval
        var hasStepped = false
    }

    /// A scroll not yet known to be a swipe or not: its movement so far,
    /// and its events, held back.
    private struct Pending {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var events: [NSEvent] = []
        /// Whether the fingers have started moving, or only touched.
        var hasBegun = false
    }

    /// A gesture's total so far, and its recent speed.
    private struct Motion {
        var total: CGFloat = 0
        private(set) var velocity: CGFloat = 0
        private var lastMoved: TimeInterval

        init(at time: TimeInterval) {
            lastMoved = time
        }

        mutating func add(_ delta: CGFloat, at time: TimeInterval) {
            total += delta
            guard delta != 0 else { return }
            let interval = time - lastMoved
            if interval > 0 {
                // Smoothed: one event's speed is noisy.
                velocity = velocity * 0.4 + delta / CGFloat(interval) * 0.6
            }
            lastMoved = time
        }

        /// The speed at `time`: none if the fingers had stopped by then.
        func velocity(at time: TimeInterval) -> CGFloat {
            time - lastMoved > 0.08 ? 0 : velocity
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard window != nil else { return }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                self?.handleMagnify(event)
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            }
        ].compactMap { $0 }
    }

    isolated deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func isOver(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    // MARK: Pinch

    private func handleMagnify(_ event: NSEvent) {
        guard event.window === window else { return }
        switch event.phase {
        case .began:
            guard isOver(event) else {
                pinch = nil
                return
            }
            pinch = Motion(at: event.timestamp)
            onPinch?(.began)
            fallthrough
        case .changed:
            guard var pinch else { return }
            pinch.add(event.magnification, at: event.timestamp)
            self.pinch = pinch
            onPinch?(.changed(pinch.total))
        case .ended, .cancelled:
            guard var pinch else { return }
            pinch.add(event.magnification, at: event.timestamp)
            self.pinch = nil
            onPinch?(.ended(pinch.total, velocity: pinch.velocity(at: event.timestamp)))
        default:
            break
        }
    }

    // MARK: Swipe

    /// The event, or nil when it's held back or a swipe's.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !isPassingHeldEvents else { return event }

        if !event.momentumPhase.isEmpty {
            guard case .coasting = scroll else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                scroll = .idle
            }
            return nil
        }

        // A mouse's wheel: no phases, or (with Logitech's software, say)
        // phases but deltas in lines
        guard !event.phase.isEmpty, event.hasPreciseScrollingDeltas else { return handleWheel(event) }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            if case .deciding(let pending) = scroll, !pending.hasBegun, event.phase.contains(.began) {
                // The fingers that touched start moving
            } else {
                if case .swiping = scroll {
                    endSwipe(at: event.timestamp)
                }
                let canSwipe = event.hasPreciseScrollingDeltas && isOver(event) && (canSwipe?() ?? false)
                scroll = canSwipe ? .deciding(Pending()) : .passing
            }
        }

        let isEnd = event.phase.contains(.ended) || event.phase.contains(.cancelled)

        switch scroll {
        case .deciding(var pending):
            pending.dx += event.scrollingDeltaX
            pending.dy += event.scrollingDeltaY
            if event.phase.contains(.began) {
                pending.hasBegun = true
            }
            if isEnd {
                scroll = .idle
                // Too short to tell: a scroll, if the fingers moved at all
                guard pending.hasBegun else { return nil }
                pass(pending.events)
                return event
            }
            let sideways = abs(pending.dx), upright = abs(pending.dy)
            if sideways >= Self.swipeDistance && sideways >= upright * Self.swipeRatio {
                var motion = Motion(at: event.timestamp)
                motion.add(pending.dx, at: event.timestamp)
                scroll = .swiping(motion)
                onSwipe?(.began)
                onSwipe?(.changed(motion.total))
                return nil
            }
            if (upright > sideways && sideways + upright >= Self.scrollDistance)
                || sideways + upright >= Self.decisionLimit {
                scroll = .passing
                pass(pending.events)
                return event
            }
            pending.events.append(event)
            scroll = .deciding(pending)
            return nil

        case .swiping(var motion):
            motion.add(event.scrollingDeltaX, at: event.timestamp)
            scroll = .swiping(motion)
            if isEnd {
                endSwipe(at: event.timestamp)
            } else {
                onSwipe?(.changed(motion.total))
            }
            return nil

        case .idle, .coasting, .passing:
            if isEnd, case .passing = scroll {
                scroll = .idle
            }
            return event
        }
    }

    /// A mouse wheel's event: sideways ones over the sidebar are swallowed,
    /// and a flick of them that goes far enough turns a page.
    private func handleWheel(_ event: NSEvent) -> NSEvent? {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx != 0, abs(dx) > abs(dy), isOver(event) else { return event }
        // A wheel with phases begins each flick; one without, after a rest
        if event.phase.contains(.began) || flick.map({ event.timestamp - $0.lastMoved >= Self.stepPause }) ?? true {
            guard case .idle = scroll, canSwipe?() ?? false else {
                flick = nil
                return event
            }
            flick = Flick(lastMoved: event.timestamp)
        }
        guard var flick else { return event }
        flick.total += dx
        flick.lastMoved = event.timestamp
        if !flick.hasStepped && abs(flick.total) >= Self.stepDistance {
            flick.hasStepped = true
            onStep?(flick.total)
        }
        self.flick = flick
        return nil
    }

    /// Hands a scroll's held-back events on to the views under them, before
    /// the event that showed it isn't a swipe.
    private func pass(_ events: [NSEvent]) {
        isPassingHeldEvents = true
        defer { isPassingHeldEvents = false }
        events.forEach { NSApp.sendEvent($0) }
    }

    private func endSwipe(at time: TimeInterval) {
        guard case .swiping(let motion) = scroll else { return }
        scroll = .coasting
        onSwipe?(.ended(motion.total, velocity: motion.velocity(at: time)))
    }
}

// MARK: - Edge separators

extension View {
    /// A separator line at a sidebar scroll view's top and bottom edges,
    /// toward the URL bar and the space bar, each shown while there's more
    /// past it: `SidebarScrollView`'s, for SwiftUI's `ScrollView`. Each line
    /// is its inset in from its edge, where the scroll view is cut off.
    func sidebarScrollEdgeSeparators(
        topInset: CGFloat = SidebarLayoutMetrics.topSeparatorInset,
        bottomInset: CGFloat = SidebarLayoutMetrics.bottomSeparatorInset
    ) -> some View {
        modifier(SidebarScrollEdgeSeparators(topInset: topInset, bottomInset: bottomInset))
    }
}

private struct SidebarScrollEdgeSeparators: ViewModifier {
    nonisolated private struct Overflow: Equatable {
        var top = false
        var bottom = false
    }

    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var overflow = Overflow()
    @Environment(\.pixelLength) private var pixelLength

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Overflow.self) { geometry in
                // Half a point of slack, for fractional scroll positions
                Overflow(top: geometry.visibleRect.minY > 0.5,
                         bottom: geometry.visibleRect.maxY < geometry.contentSize.height - 0.5)
            } action: { _, newValue in
                withAnimation(.easeInOut(duration: 0.15)) {
                    overflow = newValue
                }
            }
            // Over its first and last pixel rows
            .overlay(alignment: .top) { separator.opacity(overflow.top ? 1 : 0) }
            .overlay(alignment: .bottom) { separator.opacity(overflow.bottom ? 1 : 0) }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: pixelLength)
            .padding(.horizontal, SidebarLayoutMetrics.outerHorizontalPadding)
            .allowsHitTesting(false)
    }
}
