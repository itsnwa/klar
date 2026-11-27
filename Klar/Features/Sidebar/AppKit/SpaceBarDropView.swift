import AppKit
import SwiftUI
import Combine

/// Where the space bar's buttons are, and which one a drag is over. The bar
/// (SwiftUI) reports the frames; the drop view (AppKit) hit-tests drags
/// against them.
final class SpaceDropState: ObservableObject {
    /// The space whose button a tab is being dragged over.
    @Published var targetedSpaceID: UUID?
    /// Whether the drag is over the New Space button.
    @Published var isTargetingNewSpace = false

    /// In the bar's coordinates (top-left origin). Not published: they're
    /// only read while a drag is on.
    var spaceFrames: [UUID: CGRect] = [:]
    var newSpaceFrame: CGRect = .zero
    /// The scrolling row of space buttons: those scrolled out of it don't count.
    var spacesFrame: CGRect = .zero
}

/// Hosts the space bar and takes the drags dropped on it: a saved tab,
/// folder or regular tab dragged onto a space's button moves to that space,
/// and onto New Space to a new one; a link opens there. Held over a space's
/// button for a moment, the drag springs that space open, so it can be
/// dropped into one of its folders.
///
/// The drop target is this view, around the bar's hosting view: SwiftUI
/// buttons aren't views of their own, and AppKit looks for a drag's
/// destination from the view under the pointer up through its superviews.
final class SpaceBarDropView: NSView {
    let dropState: SpaceDropState
    private let hostingView: NSHostingView<AnyView>
    private var springTimer: Timer?
    private static let springDelay: TimeInterval = 0.6

    var tabManager: TabManager?

    override var isFlipped: Bool { true }

    init(rootView: AnyView, dropState: SpaceDropState) {
        self.dropState = dropState
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        // Sized by this view, which SwiftUI sizes.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        registerForDraggedTypes([SidebarPasteboardTypes.sidebarItem, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(rootView: AnyView) {
        hostingView.rootView = rootView
    }

    // MARK: - Targets

    private enum Target: Equatable {
        case space(UUID)
        case newSpace
    }

    private func target(at point: CGPoint) -> Target? {
        if dropState.newSpaceFrame.contains(point) {
            return .newSpace
        }
        guard dropState.spacesFrame.contains(point) else { return nil }
        if let space = dropState.spaceFrames.first(where: { $0.value.contains(point) }) {
            return .space(space.key)
        }
        return nil
    }

    private func setTarget(_ target: Target?) {
        let spaceID: UUID? = {
            if case .space(let id) = target { return id }
            return nil
        }()
        if dropState.targetedSpaceID != spaceID {
            dropState.targetedSpaceID = spaceID
            scheduleSpring(for: spaceID)
        }
        let isNewSpace = target == .newSpace
        if dropState.isTargetingNewSpace != isNewSpace {
            dropState.isTargetingNewSpace = isNewSpace
        }
    }

    /// Held over another space's button, the drag opens that space.
    private func scheduleSpring(for spaceID: UUID?) {
        springTimer?.invalidate()
        springTimer = nil
        guard let spaceID, let selection = tabManager?.spaceSelection, spaceID != selection.currentSpaceID else { return }
        let timer = Timer(timeInterval: Self.springDelay, repeats: false) { [weak selection] _ in
            MainActor.assumeIsolated {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                selection?.switchTo(spaceID)
            }
        }
        // A drag runs the run loop in the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func clearTarget() {
        springTimer?.invalidate()
        springTimer = nil
        if dropState.targetedSpaceID != nil {
            dropState.targetedSpaceID = nil
        }
        if dropState.isTargetingNewSpace {
            dropState.isTargetingNewSpace = false
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearTarget()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearTarget()
    }

    private func updateTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = target(at: point), acceptsDrag(sender) else {
            clearTarget()
            return []
        }
        setTarget(target)
        return sender.draggedSidebarItemUUIDs.isEmpty ? .copy : .move
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        !sender.draggedSidebarItemUUIDs.isEmpty || sender.draggedWebURL != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearTarget() }
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = target(at: point) else { return false }

        let selection = tabManager?.spaceSelection
        let spaceID: UUID
        switch target {
        case .space(let id):
            spaceID = id
        case .newSpace:
            guard let id = SpaceManager.shared.createSpace(switchingIn: selection) else { return false }
            spaceID = id
        }

        if let itemID = sender.draggedSidebarItemUUIDs.first {
            selection?.move(itemID: itemID, toSpace: spaceID)
            return true
        }
        if let url = sender.draggedWebURL, let tabManager {
            tabManager.createNewTab(url: url, inSpace: spaceID)
            return true
        }
        return false
    }
}

/// The space bar, wrapped in its drop target.
struct SpaceBarDropContainer: NSViewRepresentable {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var spaceSelection: SpaceSelection
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @StateObject private var dropState = SpaceDropState()

    func makeNSView(context: Context) -> SpaceBarDropView {
        let view = SpaceBarDropView(rootView: rootView, dropState: dropState)
        view.tabManager = tabManager
        return view
    }

    func updateNSView(_ view: SpaceBarDropView, context: Context) {
        view.tabManager = tabManager
    }

    private var rootView: AnyView {
        AnyView(
            SpaceBar(dropState: dropState)
                .environmentObject(tabManager)
                .environmentObject(spaceSelection)
                .environment(sidebarStateManager)
        )
    }
}
