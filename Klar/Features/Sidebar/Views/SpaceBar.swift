import SwiftUI
import AppKit

/// The bar at the bottom of the sidebar: the overview button, a button for
/// each space, and New Space. Clicking the active space again opens the
/// overview. Hosted by `SpaceBarDropView`, which takes drags dropped on it.
struct SpaceBar: View {
    @ObservedObject var dropState: SpaceDropState
    @Environment(SidebarStateManager.self) var sidebarStateManager
    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection
    @ObservedObject private var downloadManager = DownloadManager.shared

    nonisolated private static let coordinateSpace = "spaceBar"

    init(dropState: SpaceDropState) {
        self.dropState = dropState
    }

    var body: some View {
        HStack(spacing: 2) {
            overviewButton

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(spaceManager.spaces) { space in
                        SpaceButton(
                            space: space,
                            isActive: space.id == spaceSelection.currentSpaceID,
                            isDropTarget: dropState.targetedSpaceID == space.id,
                            action: { select(space) }
                        )
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.coordinateSpace))
                        } action: { frame in
                            dropState.spaceFrames[space.id] = frame
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.coordinateSpace))
            } action: { frame in
                dropState.spacesFrame = frame
            }

            newSpaceButton
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.coordinateSpace))
                } action: { frame in
                    dropState.newSpaceFrame = frame
                }
        }
        .frame(height: 32)
        .coordinateSpace(name: Self.coordinateSpace)
        .onChange(of: spaceManager.spaces) { _, spaces in
            let ids = Set(spaces.map(\.id))
            dropState.spaceFrames = dropState.spaceFrames.filter { ids.contains($0.key) }
        }
    }

    // MARK: - Buttons

    private var isZoomedOut: Bool {
        sidebarStateManager.level != .space
    }

    private var overviewButton: some View {
        KlarButton.titleBar(action: {
            sidebarStateManager.toggleOverview()
        }) {
            // A download in progress, to look at in the overview: the icon
            // shrinks inside a ring of its progress
            let isDownloading = downloadManager.isDownloading
            // Resizable, so its frame is the glyph's own and it shrinks
            // about its middle: a symbol sized by its font sits off center
            // in its line's box
            ZStack {
                Image(systemName: "square.grid.2x2")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundColor(isZoomedOut ? .primary : .secondary)
                    .scaleEffect(isDownloading ? 0.6 : 1)
                if isDownloading {
                    // Past the button's 16 pt, not widening the bar
                    DownloadProgressRing(color: .accentColor)
                        .frame(width: 21, height: 21)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .animation(.spring(duration: 0.3), value: isDownloading)
        }
        .background {
            RoundedRectangle(cornerRadius: TitleBarHoverBackground.cornerRadius)
                .fill(Color.primary.opacity(isZoomedOut ? 0.1 : 0))
        }
        .accessibilityLabel(Text(isZoomedOut ? "Back to Space" : "Overview"))
        .help("Overview: Downloads, Reading List, History and all spaces (⇧⌘O)")
    }

    private var newSpaceButton: some View {
        KlarButton.titleBar(action: {
            SpaceManager.shared.createSpace(switchingIn: spaceSelection)
            sidebarStateManager.show(.space)
        }) {
            Image(systemName: "plus")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
        }
        .background {
            TitleBarHoverBackground(isHovering: dropState.isTargetingNewSpace)
        }
        .scaleEffect(dropState.isTargetingNewSpace ? 1.12 : 1)
        .animation(.bouncy(duration: 0.3), value: dropState.isTargetingNewSpace)
        .accessibilityLabel(Text("New Space"))
        .help("New Space")
    }

    /// Another space: switch to it. The active one: the overview, or back
    /// to its tabs from the overview or a library list.
    private func select(_ space: Space) {
        if space.id == spaceSelection.currentSpaceID {
            sidebarStateManager.show(sidebarStateManager.level == .space ? .overview : .space)
        } else {
            spaceSelection.switchTo(space.id)
            sidebarStateManager.show(.space)
        }
    }
}

// MARK: - Tint

/// The active space's color over the window's material: the sidebar and
/// the frame around an inset page take on the space's color.
struct SpaceTint: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection
    @Environment(\.colorScheme) private var colorScheme

    init() {}

    var body: some View {
        (spaceSelection.activeSpace?.color.tintColor ?? .clear)
            .opacity(spaceSelection.activeSpace?.color.tintOpacity(in: colorScheme) ?? 0)
            .animation(.easeInOut(duration: 0.35), value: spaceSelection.activeSpace?.color)
            .allowsHitTesting(false)
    }
}

// MARK: - Space Button

private struct SpaceButton: View {
    let space: Space
    let isActive: Bool
    let isDropTarget: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SpaceIconView(icon: space.icon, name: space.name, size: 14)
                .foregroundStyle(isActive ? space.color.color : Color.secondary)
                .opacity(isActive || !space.icon.isEmoji ? 1 : 0.7)
                .frame(width: 28, height: 28)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: TitleBarHoverBackground.cornerRadius)
                            .fill(space.color.color.opacity(isActive ? 0.2 : 0))
                        TitleBarHoverBackground(isHovering: isHovering || isDropTarget)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: TitleBarHoverBackground.cornerRadius))
        }
        .buttonStyle(.plain)
        .scaleEffect(isDropTarget ? 1.15 : 1)
        .animation(.bouncy(duration: 0.3), value: isDropTarget)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .onHover { hovering in
            if isHovering != hovering {
                withAnimation(TitleBarHoverBackground.animation) {
                    isHovering = hovering
                }
            }
        }
        .contextMenu {
            SpaceContextMenu(spaceID: space.id)
        }
        .help(space.name)
        .accessibilityLabel(Text(space.name))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Context Menu

/// The menu of a space's button and of its card in the overview.
struct SpaceContextMenu: View {
    let spaceID: UUID
    @ObservedObject private var spaceManager = SpaceManager.shared

    init(spaceID: UUID) {
        self.spaceID = spaceID
    }

    var body: some View {
        let index = spaceManager.spaces.firstIndex { $0.id == spaceID }

        Button("Space Settings…") {
            SettingsWindowController.shared.showSettings(category: .spaces, spaceID: spaceID)
        }

        Button("Clean Up Saved Tabs…") {
            BrowserWindowSession.current.sidebarManager.showCleanUp()
        }

        Divider()

        Button("Move Left") {
            spaceManager.moveSpace(spaceID, by: -1)
        }
        .disabled(index == nil || index == 0)

        Button("Move Right") {
            spaceManager.moveSpace(spaceID, by: 1)
        }
        .disabled(index == nil || index == spaceManager.spaces.count - 1)

        Divider()

        Button("Delete Space…", role: .destructive) {
            SpaceActions.confirmDelete(spaceID)
        }
        .disabled(!spaceManager.canDeleteSpace(spaceID))
    }
}

/// Space actions that ask first.
@MainActor
enum SpaceActions {
    /// Deletes a space after asking: its saved tabs and folders go with it.
    static func confirmDelete(_ spaceID: UUID, in window: NSWindow? = nil) {
        let spaceManager = SpaceManager.shared
        guard let space = spaceManager.space(withID: spaceID), spaceManager.canDeleteSpace(spaceID) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        var detail = "Its saved tabs and groups are deleted, and its open tabs close."
        if space.usesSeparateProfile {
            detail += " Its website data and history are deleted too."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let delete = { spaceManager.deleteSpace(spaceID) }
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    delete()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete()
        }
    }
}

/// Around the overview button's icon while something downloads: the
/// downloads' combined progress, or, while no size is known, an arc going
/// round. Follows the progress itself, so its updates (a few a second)
/// don't re-render the space bar.
private struct DownloadProgressRing: View {
    let color: Color
    @State private var progress = DownloadManager.shared.overallProgress.value
    @State private var isSpinning = false

    private static let lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: Self.lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 270 : -90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
            }
        }
        .padding(Self.lineWidth / 2)
        .onReceive(DownloadManager.shared.overallProgress) { value in
            if progress != value {
                progress = value
            }
        }
    }
}
