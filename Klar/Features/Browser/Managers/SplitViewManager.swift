import Foundation
import Observation
import SwiftUI

/// How the panes of a split view sit: side by side (horizontal) or one
/// above the other (vertical)
nonisolated enum SplitAxis {
    case horizontal
    case vertical
}

/// The side of a pane another tab goes on
nonisolated enum SplitEdge {
    case left, right, top, bottom

    var axis: SplitAxis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// Right of the pane, or below it
    var isAfter: Bool { self == .right || self == .bottom }
}

/// A split view's panes: a tab, or a row (or column) of further panes, each
/// with its share of the row's length. A row always has two panes or more.
nonisolated enum SplitNode: Equatable {
    case tab(UUID)
    case group(SplitAxis, [SplitNode], [CGFloat])

    /// Left to right, top to bottom
    var tabIDs: [UUID] {
        switch self {
        case .tab(let id): return [id]
        case .group(_, let children, _): return children.flatMap(\.tabIDs)
        }
    }

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .tab(let tabID): return tabID == id
        case .group(_, let children, _): return children.contains { $0.contains(id) }
        }
    }

    /// With `newID` on `edge` of `targetID`'s pane, taking half its share:
    /// beside it in its row, or in a new row in its place
    func inserting(_ newID: UUID, beside targetID: UUID, on edge: SplitEdge) -> SplitNode {
        switch self {
        case .tab(let id):
            guard id == targetID else { return self }
            let pair: [SplitNode] = edge.isAfter ? [self, .tab(newID)] : [.tab(newID), self]
            return .group(edge.axis, pair, [0.5, 0.5])
        case .group(let axis, var children, var fractions):
            if axis == edge.axis, let index = children.firstIndex(of: .tab(targetID)) {
                let half = fractions[index] / 2
                fractions[index] = half
                let newIndex = edge.isAfter ? index + 1 : index
                children.insert(.tab(newID), at: newIndex)
                fractions.insert(half, at: newIndex)
                return .group(axis, children, fractions)
            }
            return .group(axis, children.map { $0.inserting(newID, beside: targetID, on: edge) }, fractions)
        }
    }

    /// Without `id`'s pane, whose share goes to the pane before it (after
    /// it, if it was first). Nil if nothing's left.
    func removing(_ id: UUID) -> SplitNode? {
        switch self {
        case .tab(let tabID):
            return tabID == id ? nil : self
        case .group(let axis, let children, let fractions):
            var kept: [SplitNode] = []
            var keptFractions: [CGFloat] = []
            var leftOver: CGFloat = 0
            for (child, fraction) in zip(children, fractions) {
                guard let remaining = child.removing(id) else {
                    if keptFractions.isEmpty {
                        leftOver += fraction
                    } else {
                        keptFractions[keptFractions.count - 1] += fraction
                    }
                    continue
                }
                kept.append(remaining)
                keptFractions.append(fraction + leftOver)
                leftOver = 0
            }
            return Self.row(axis, kept, keptFractions)
        }
    }

    func replacing(_ oldID: UUID, with newID: UUID) -> SplitNode {
        switch self {
        case .tab(let id):
            return id == oldID ? .tab(newID) : self
        case .group(let axis, let children, let fractions):
            return .group(axis, children.map { $0.replacing(oldID, with: newID) }, fractions)
        }
    }

    /// The pane that takes over from `id`'s when it closes: the one before
    /// it in its row, else the one after it
    func neighbor(of id: UUID) -> UUID? {
        guard case .group(_, let children, _) = self else { return nil }
        if let index = children.firstIndex(of: .tab(id)) {
            return index > 0 ? children[index - 1].tabIDs.last : children[index + 1].tabIDs.first
        }
        return children.lazy.compactMap { $0.neighbor(of: id) }.first
    }

    func node(at path: ArraySlice<Int>) -> SplitNode? {
        guard let first = path.first else { return self }
        guard case .group(_, let children, _) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: path.dropFirst())
    }

    func settingFractions(_ newFractions: [CGFloat], at path: ArraySlice<Int>) -> SplitNode {
        guard case .group(let axis, var children, let fractions) = self else { return self }
        guard let first = path.first else {
            return newFractions.count == children.count ? .group(axis, children, newFractions) : self
        }
        guard children.indices.contains(first) else { return self }
        children[first] = children[first].settingFractions(newFractions, at: path.dropFirst())
        return .group(axis, children, fractions)
    }

    /// With the panes of `ids` at no share of their rows, the others sharing
    /// them as they did: where those panes open from
    func collapsing(_ ids: Set<UUID>) -> SplitNode {
        guard case .group(let axis, let children, var fractions) = self else { return self }
        for (index, child) in children.enumerated() {
            if case .tab(let id) = child, ids.contains(id) {
                fractions[index] = 0
            }
        }
        let total = fractions.reduce(0, +)
        guard total > 0 else { return self }
        return .group(axis, children.map { $0.collapsing(ids) }, fractions.map { $0 / total })
    }

    /// A row of one is that one, and a row in a row of the same axis joins it
    private static func row(_ axis: SplitAxis, _ children: [SplitNode], _ fractions: [CGFloat]) -> SplitNode? {
        var flatChildren: [SplitNode] = []
        var flatFractions: [CGFloat] = []
        for (child, fraction) in zip(children, fractions) {
            if case .group(let childAxis, let grandchildren, let childFractions) = child, childAxis == axis {
                flatChildren += grandchildren
                flatFractions += childFractions.map { $0 * fraction }
            } else {
                flatChildren.append(child)
                flatFractions.append(fraction)
            }
        }
        switch flatChildren.count {
        case 0: return nil
        case 1: return flatChildren[0]
        default:
            let total = flatFractions.reduce(0, +)
            return .group(axis, flatChildren, flatFractions.map { total > 0 ? $0 / total : 1 / CGFloat(flatFractions.count) })
        }
    }

    // MARK: - Geometry

    /// Each pane's frame within `rect` (top-left origin), the panes `gap`
    /// apart, and the gaps between them. Edges are on whole points, as the
    /// page's own frame is (see `BrowserWindowLayoutView.layoutHosts`).
    func layout(in rect: CGRect, gap: CGFloat, splitID: UUID, path: [Int] = [], into geometry: inout SplitGeometry) {
        switch self {
        case .tab(let id):
            geometry.paneFrames[id] = rect
        case .group(let axis, let children, _):
            let rects = childRects(in: rect, gap: gap)
            for (index, child) in children.enumerated() {
                child.layout(in: rects[index], gap: gap, splitID: splitID, path: path + [index], into: &geometry)
                guard index < children.count - 1 else { continue }
                let next = rects[index + 1]
                let gapRect = axis == .horizontal
                    ? CGRect(x: rects[index].maxX, y: rect.minY, width: next.minX - rects[index].maxX, height: rect.height)
                    : CGRect(x: rect.minX, y: rects[index].maxY, width: rect.width, height: next.minY - rects[index].maxY)
                geometry.gaps[SplitDividerID(splitID: splitID, path: path, index: index, axis: axis)] = gapRect
            }
        }
    }

    /// The frame of the row at `path`
    func rect(ofNodeAt path: ArraySlice<Int>, in rect: CGRect, gap: CGFloat) -> CGRect? {
        guard let first = path.first else { return rect }
        guard case .group(_, let children, _) = self, children.indices.contains(first) else { return nil }
        return children[first].rect(ofNodeAt: path.dropFirst(), in: childRects(in: rect, gap: gap)[first], gap: gap)
    }

    private func childRects(in rect: CGRect, gap: CGFloat) -> [CGRect] {
        guard case .group(let axis, let children, let fractions) = self else { return [rect] }
        let isHorizontal = axis == .horizontal
        let start = isHorizontal ? rect.minX : rect.minY
        let length = isHorizontal ? rect.width : rect.height
        let available = max(length - gap * CGFloat(children.count - 1), 0)
        var rects: [CGRect] = []
        var paneStart = start
        var share: CGFloat = 0
        for index in children.indices {
            share += fractions[index]
            let paneEnd = index == children.count - 1
                ? start + length
                : max((start + available * share + gap * CGFloat(index)).rounded(), paneStart)
            rects.append(isHorizontal
                ? CGRect(x: paneStart, y: rect.minY, width: paneEnd - paneStart, height: rect.height)
                : CGRect(x: rect.minX, y: paneStart, width: rect.width, height: paneEnd - paneStart))
            paneStart = paneEnd + gap
        }
        return rects
    }
}

/// A row of panes and the gap after one of them, which resizes the two
/// panes beside it
nonisolated struct SplitDividerID: Hashable {
    let splitID: UUID
    let path: [Int]
    let index: Int
    let axis: SplitAxis
}

/// Where the panes are, and the gaps between those of the split on screen
nonisolated struct SplitGeometry {
    var paneFrames: [UUID: CGRect] = [:]
    var gaps: [SplitDividerID: CGRect] = [:]
}

/// Tabs shown side by side or one above the other
nonisolated struct SplitView: Identifiable, Equatable {
    let id: UUID
    var root: SplitNode

    init(id: UUID = UUID(), root: SplitNode) {
        self.id = id
        self.root = root
    }

    /// The gaps between its panes, which resize them
    var dividerIDs: [SplitDividerID] {
        var geometry = SplitGeometry()
        root.layout(in: .zero, gap: 0, splitID: id, into: &geometry)
        return geometry.gaps.keys.sorted { ($0.path.count, $0.index) < ($1.path.count, $1.index) }
    }
}

/// The pane a tab dragged over a page would go beside, and on which side;
/// no side for an empty pane, whose place it'd take
nonisolated struct SplitDropTarget: Equatable {
    let paneTabID: UUID
    let edge: SplitEdge?
}

/// The window's split views. A tab is in one at most; selecting it shows
/// its split view's panes, each its own tab, and selecting a tab in none
/// shows that tab alone. Only for this session: splits aren't restored.
///
/// Observable, so dragging a gap re-runs only the panes' layout, not every
/// view that observes TabManager.
@Observable
final class SplitViewManager {
    static let maximumPanes = 4
    /// Between panes: the frame around an inset page
    nonisolated static let gap = BrowserWindowLayoutView.pageInset
    nonisolated private static let minimumPaneLength: CGFloat = 200
    /// How the panes move to their new places when a split view changes:
    /// off at full speed and easing into place (ease-out cubic), quick
    static let paneAnimation = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.24)

    private(set) var splits: [SplitView] = []
    /// The active tab's split view, on screen, and its tabs. Kept apart from
    /// `splits`, so what only asks which tabs are on screen isn't updated
    /// for every step of a gap being dragged.
    private(set) var shownSplitID: UUID?
    private(set) var shownTabIDs: Set<UUID> = []
    /// Where a tab dragged over a page would go
    private(set) var dropTarget: SplitDropTarget?
    /// One more for each change that moves the panes, made in
    /// `paneAnimation`, which the panes' layout follows (`SplitPaneLayout`)
    private(set) var paneAnimationGeneration = 0
    /// While the panes move: until then, the content area shows the window
    /// around them, as between panes, rather than the page's color
    private(set) var isMovingPanes = false
    /// The panes leaving the split view on screen, shown as they close until
    /// the panes have moved, and what one shows once its tab has closed
    private(set) var leavingPanes: [UUID: LeavingPane] = [:]

    /// What a pane leaving shows once its tab has closed
    enum LeavingPane: Equatable {
        case empty
        /// The page's color
        case page(Color)
    }

    /// Kept up to date by TabManager
    @ObservationIgnored var activeTabID: UUID? {
        didSet {
            if activeTabID != oldValue {
                updateShownSplit()
            }
        }
    }

    var shownSplit: SplitView? {
        guard let shownSplitID else { return nil }
        return splits.first { $0.id == shownSplitID }
    }

    /// On screen: the active tab, or a pane of its split view
    func isVisible(_ tabID: UUID) -> Bool {
        tabID == activeTabID || shownTabIDs.contains(tabID)
    }

    func split(containing tabID: UUID?) -> SplitView? {
        guard let tabID else { return nil }
        return splits.first { $0.root.contains(tabID) }
    }

    func contains(_ tabID: UUID) -> Bool {
        split(containing: tabID) != nil
    }

    /// Whether `tabID` can go beside `targetID`: another tab, and no more
    /// than `maximumPanes` there. A tab already in that split moves.
    func canAdd(_ tabID: UUID, beside targetID: UUID) -> Bool {
        guard tabID != targetID else { return false }
        let panes = split(containing: targetID)?.root.tabIDs ?? [targetID]
        return panes.count + (panes.contains(tabID) ? 0 : 1) <= Self.maximumPanes
    }

    /// Puts `tabID` on `edge` of `targetID`'s pane, out of any split it was in
    func add(_ tabID: UUID, beside targetID: UUID, on edge: SplitEdge) {
        guard canAdd(tabID, beside: targetID) else { return }
        var splits = splits
        Self.remove(tabID, from: &splits)
        if let index = splits.firstIndex(where: { $0.root.contains(targetID) }) {
            splits[index].root = splits[index].root.inserting(tabID, beside: targetID, on: edge)
        } else {
            splits.append(SplitView(root: SplitNode.tab(targetID).inserting(tabID, beside: targetID, on: edge)))
        }
        movePanes {
            self.splits = splits
        }
    }

    /// Takes the tab's pane out; a split left with one pane is no more.
    /// It closes as the others take its place, as `closedLook` once its
    /// tab has closed.
    func remove(_ tabID: UUID, closedLook: LeavingPane = .empty) {
        guard contains(tabID) else { return }
        movePanes(closedLooks: [tabID: closedLook]) {
            Self.remove(tabID, from: &splits)
        }
    }

    /// The split the tab is in goes, leaving its tabs as they are
    func separate(splitContaining tabID: UUID) {
        guard let split = split(containing: tabID) else { return }
        movePanes {
            splits.removeAll { $0.id == split.id }
        }
    }

    /// A tab reopened in another (in or out of private browsing) keeps its pane
    func replace(_ oldID: UUID, with newID: UUID) {
        guard contains(oldID) else { return }
        var splits = splits
        Self.remove(newID, from: &splits)
        guard let index = splits.firstIndex(where: { $0.root.contains(oldID) }) else { return }
        splits[index].root = splits[index].root.replacing(oldID, with: newID)
        self.splits = splits
        didChange()
    }

    /// Closed tabs' panes go
    func removeTabs(notIn openTabIDs: Set<UUID>) {
        let closed = splits.flatMap(\.root.tabIDs).filter { !openTabIDs.contains($0) }
        guard !closed.isEmpty else { return }
        var splits = splits
        for id in closed {
            Self.remove(id, from: &splits)
        }
        self.splits = splits
        didChange()
    }

    /// The pane that takes over from the tab's when it closes
    func neighbor(of tabID: UUID) -> UUID? {
        split(containing: tabID)?.root.neighbor(of: tabID)
    }

    /// The pane past `edge` of the tab's in its split view: the nearest
    /// one that way, and of those, the one most in line with it
    func pane(beside tabID: UUID, toward edge: SplitEdge) -> UUID? {
        guard let split = split(containing: tabID) else { return nil }
        var geometry = SplitGeometry()
        split.root.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), gap: 0, splitID: split.id, into: &geometry)
        guard let from = geometry.paneFrames[tabID] else { return nil }
        let tolerance: CGFloat = 0.5
        let candidates = geometry.paneFrames.compactMap { (id, frame) -> (id: UUID, distance: CGFloat, offset: CGFloat)? in
            guard id != tabID else { return nil }
            switch edge {
            case .left:
                guard frame.maxX <= from.minX + tolerance else { return nil }
                return (id, from.minX - frame.maxX, abs(frame.midY - from.midY))
            case .right:
                guard frame.minX >= from.maxX - tolerance else { return nil }
                return (id, frame.minX - from.maxX, abs(frame.midY - from.midY))
            case .top:
                guard frame.maxY <= from.minY + tolerance else { return nil }
                return (id, from.minY - frame.maxY, abs(frame.midX - from.midX))
            case .bottom:
                guard frame.minY >= from.maxY - tolerance else { return nil }
                return (id, frame.minY - from.maxY, abs(frame.midX - from.midX))
            }
        }
        return candidates.min { ($0.distance, $0.offset) < ($1.distance, $1.offset) }?.id
    }

    private static func remove(_ tabID: UUID, from splits: inout [SplitView]) {
        guard let index = splits.firstIndex(where: { $0.root.contains(tabID) }) else { return }
        if let root = splits[index].root.removing(tabID), case .group = root {
            splits[index].root = root
        } else {
            splits.remove(at: index)
        }
    }

    /// A change of the split views that moves the panes
    private func movePanes(closedLooks: [UUID: LeavingPane] = [:], _ change: () -> Void) {
        animatePanes(closedLooks: closedLooks) {
            change()
            updateShownSplit()
        }
        didChange()
    }

    /// The panes go to their new places on a spring, from wherever they are
    /// on screen, and those leaving the split view on screen close
    private func animatePanes(closedLooks: [UUID: LeavingPane] = [:], _ change: () -> Void) {
        let generation = paneAnimationGeneration + 1
        let shownBefore = shownTabIDs
        withAnimation(Self.paneAnimation, completionCriteria: .removed) {
            change()
            for id in shownBefore.subtracting(splits.flatMap(\.root.tabIDs)) {
                leavingPanes[id] = closedLooks[id] ?? .empty
            }
            paneAnimationGeneration = generation
            isMovingPanes = true
        } completion: { [weak self] in
            guard let self, self.paneAnimationGeneration == generation else { return }
            self.isMovingPanes = false
            self.leavingPanes = [:]
        }
    }

    private func didChange() {
        updateShownSplit()
        NotificationCenter.default.post(name: .splitViewsDidChange, object: nil)
    }

    private func updateShownSplit() {
        let split = split(containing: activeTabID)
        if shownSplitID != split?.id {
            shownSplitID = split?.id
        }
        let tabIDs = Set(split?.root.tabIDs ?? [])
        if shownTabIDs != tabIDs {
            shownTabIDs = tabIDs
        }
    }

    // MARK: - Dropping a tab

    /// The preview moves from one side to another on a spring, and fades
    /// out when the drag leaves; it's gone at once once dropped, as the new
    /// pane takes its place.
    func setDropTarget(_ target: SplitDropTarget?, animated: Bool = true) {
        guard dropTarget != target else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                dropTarget = target
            }
        } else {
            dropTarget = target
        }
    }

    /// Where the dropped tab's pane would be: the half of the pane on the
    /// drop's side, as `add` would lay it out, or the empty pane it fills
    nonisolated static func dropPreviewFrame(for dropTarget: SplitDropTarget?, in geometry: SplitGeometry, fullFrame: CGRect) -> CGRect? {
        guard let dropTarget else { return nil }
        let pane = geometry.paneFrames[dropTarget.paneTabID] ?? fullFrame
        guard let edge = dropTarget.edge else { return pane }
        var preview = SplitGeometry()
        SplitNode.tab(dropTarget.paneTabID)
            .inserting(droppedTabID, beside: dropTarget.paneTabID, on: edge)
            .layout(in: pane, gap: gap, splitID: droppedTabID, into: &preview)
        return preview.paneFrames[droppedTabID]
    }

    /// Stands in for the dropped tab in the drop preview's layout
    nonisolated private static let droppedTabID = UUID()

    // MARK: - Geometry

    /// Every split's panes laid out in `size`, so a split's tabs keep their
    /// size while another is shown, and the gaps of the one on screen
    nonisolated static func geometry(of splits: [SplitView], in size: CGSize, shownSplitID: UUID?) -> SplitGeometry {
        var geometry = SplitGeometry()
        let bounds = CGRect(origin: .zero, size: size)
        for split in splits {
            var splitGeometry = SplitGeometry()
            split.root.layout(in: bounds, gap: gap, splitID: split.id, into: &splitGeometry)
            geometry.paneFrames.merge(splitGeometry.paneFrames) { first, _ in first }
            if split.id == shownSplitID {
                geometry.gaps = splitGeometry.gaps
            }
        }
        return geometry
    }

    /// Dragging a gap: the panes beside it share their length so the gap
    /// is under the pointer, neither narrower than `minimumPaneLength`.
    func moveDivider(_ divider: SplitDividerID, to location: CGPoint, in size: CGSize) {
        guard let splitIndex = splits.firstIndex(where: { $0.id == divider.splitID }) else { return }
        let root = splits[splitIndex].root
        guard case .group(let axis, let children, var fractions)? = root.node(at: divider.path[...]),
              divider.index + 1 < children.count,
              let rect = root.rect(ofNodeAt: divider.path[...], in: CGRect(origin: .zero, size: size), gap: Self.gap)
        else { return }

        let isHorizontal = axis == .horizontal
        let start = isHorizontal ? rect.minX : rect.minY
        let available = (isHorizontal ? rect.width : rect.height) - Self.gap * CGFloat(children.count - 1)
        guard available > 0 else { return }
        let index = divider.index
        let paneStart = start + available * fractions[..<index].reduce(0, +) + Self.gap * CGFloat(index)
        let pointer = isHorizontal ? location.x : location.y
        let pair = fractions[index] + fractions[index + 1]
        let minimumShare = min(Self.minimumPaneLength / available, pair / 2)
        let share = min(max((pointer - Self.gap / 2 - paneStart) / available, minimumShare), pair - minimumShare)
        guard abs(share - fractions[index]) > 0.0001 else { return }
        fractions[index] = share
        fractions[index + 1] = pair - share
        splits[splitIndex].root = root.settingFractions(fractions, at: divider.path[...])
    }

    /// Double-clicking a gap: the panes of its row share it evenly
    func equalize(_ divider: SplitDividerID) {
        guard let splitIndex = splits.firstIndex(where: { $0.id == divider.splitID }),
              case .group(_, let children, _)? = splits[splitIndex].root.node(at: divider.path[...])
        else { return }
        let even = Array(repeating: 1 / CGFloat(children.count), count: children.count)
        animatePanes {
            splits[splitIndex].root = splits[splitIndex].root.settingFractions(even, at: divider.path[...])
        }
    }
}

extension Notification.Name {
    /// A tab went into or out of a split view
    static let splitViewsDidChange = Notification.Name("klar.splitViewsDidChange")
}
