import SwiftUI
import AppKit

struct ContentView: View {
    /// The window's models, handed to the sidebar's and the page's hosting views
    let session: BrowserWindowSession

    // Only what `body` reads: every observed object re-runs the whole
    // window's body on each change it publishes. Everything else reaches the
    // subviews through the environment set up in KlarApp. The sidebar's
    // state isn't read here at all: the sidebar and the page are laid out by
    // `BrowserWindowLayout`.
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject var downloadManager = DownloadManager.shared

    // Track overlay state separately to ensure proper cleanup
    @State private var showOverlay: Bool = false

    // The command palette's state, with its index of tabs, outlives each
    // open. Created on first open and held in @State, which doesn't observe
    // it: observing it here would re-run this whole body on every keystroke.
    @State private var paletteState: CommandPaletteState?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The sidebar and the page
            BrowserWindowLayout(session: session)

            // Command palette - only render when overlay is active to prevent ghost views
            if showOverlay, let paletteState = paletteState {
                // Transparent click-capture layer for click-outside-to-close functionality
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Close command palette on background click
                        tabManager.showCommandPalette = false
                    }
                    .zIndex(1500)

                VStack {
                    HStack {
                        Spacer()
                        CommandPalette(state: paletteState)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 120) // Top padding for breathing room

                    Spacer() // Push content to top
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(showOverlay) // Immediately disable hit testing when closing
                // A new palette for each request, also one made while it's
                // open (⌘K, ⌘T, ⌘L): it opens again in the mode asked for.
                .id(tabManager.commandPaletteRequest)
                .zIndex(2000)
            }

            // Download animation overlay, in the window in front
            if downloadManager.shouldShowDownloadAnimation,
               downloadManager.downloadAnimationWindowNumber == nil
                || downloadManager.downloadAnimationWindowNumber == session.window?.windowNumber {
                downloadAnimationOverlay
            }

            // First launch's setup, over the browser until it's done
            OnboardingOverlay(session: session)
                .zIndex(3000)
        }
        // The window itself is sidebar material, tinted with the active
        // space's color; the page's background color lives inside the
        // rounded content area (see `BrowserContentArea`).
        .background {
            ZStack {
                SidebarMaterial()
                SpaceTint()
            }
        }
        .ignoresSafeArea(edges: .all)
        .onAppear {
            // Keys go to the restored page from the start
            tabManager.focusActiveWebView()

            // Check for empty state and auto-show command palette if needed.
            // After the setup instead, while it shows (Onboarding).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard !Onboarding.shared.isShowing(in: session) else { return }
                tabManager.checkAndAutoShowCommandPalette()
            }
        }
        .onChange(of: tabManager.showCommandPalette) { oldValue, isShowing in
            if isShowing {
                // Command palette is opening - show overlay immediately
                if paletteState == nil {
                    paletteState = CommandPaletteState(tabManager: tabManager)
                }
                showOverlay = true
            } else {
                // Command palette is closing - remove overlay immediately (synchronously)
                // This ensures CommandPalette view is removed from hierarchy right away
                showOverlay = false
                // Typing goes back to the page
                tabManager.focusActiveWebView()
            }
        }
    }

    // MARK: - Download Animation Overlay

    @ViewBuilder
    private var downloadAnimationOverlay: some View {
        DownloadAnimationOverlay(
            icon: downloadManager.downloadAnimationIcon,
            startPoint: downloadManager.downloadAnimationStartPoint
        )
        .zIndex(1500)
    }
}

/// The sidebar, in a hosting view of its own that `BrowserWindowLayoutView`
/// slides in and out.
///
/// Edge-to-edge (macOS 27 style): flush with the window's left, top and
/// bottom edges — no inset, no glass, no rounded panel. Docked, it has no
/// background of its own: it's the window's material, one surface with the
/// frame around the page.
struct SidebarArea: View {
    @Environment(SidebarStateManager.self) var sidebarStateManager

    var body: some View {
        let isFloating = sidebarStateManager.isFloating

        SidebarView()
            .frame(width: sidebarStateManager.customSidebarWidth)
            .frame(maxHeight: .infinity)
            .background {
                ZStack {
                    // Shadow caster. Only the hover-revealed sidebar overlaps
                    // web content, so only it gets a shadow. Drawn by a plain
                    // shape because a behind-window material has no opaque
                    // pixels of its own to cast one from.
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: Color.black.opacity(0.15), radius: 16, x: 2, y: 0)

                    // Own material (on top of the window-wide one) so the
                    // sidebar stays opaque while it floats over web content.
                    SidebarMaterial()
                    SpaceTint()
                }
                .opacity(isFloating ? 1 : 0)
                .allowsHitTesting(false) // Allow interactions to pass through
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(sidebarStateManager.floatingAnimation, value: isFloating)
    }
}

/// The page, in a hosting view of its own that `BrowserWindowLayoutView`
/// gives a frame per display frame while the sidebar slides.
struct BrowserContentArea: View {
    let windowState: WindowState
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) var sidebarStateManager

    var body: some View {
        // A split view's panes have the window between them, each rounded
        // on its own, instead of a page's color all around, also while they
        // move as one opens or closes. The empty state
        // (when BrowserView shows it) has a color of its own, following the
        // appearance: no page's color, which starts out black
        let showsEmptyState = tabManager.activeTabId == nil
            || !tabManager.tabs.contains(where: { !$0.isEmpty })
        let splitViews = tabManager.splitViews
        let pageColor = splitViews.shownSplitID != nil || splitViews.isMovingPanes
            ? Color.clear
            : showsEmptyState
                ? EmptyStateView.backgroundColor
                : tabManager.activeTab?.backgroundColor ?? EmptyStateView.backgroundColor
        BrowserView(isSidebarFloating: sidebarStateManager.isFloating)
            .modifier(ContentAreaShape(
                pageColor: pageColor,
                windowCornerRadius: windowState.cornerRadius,
                isFullScreen: windowState.isFullScreen
            ))
            .animation(.easeInOut(duration: 0.15), value: pageColor)
    }
}

/// Standard system sidebar material: the window's surface — the docked
/// sidebar, the frame around an inset page and what shows behind the
/// content area's rounded corners.
private struct SidebarMaterial: View {
    var body: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow, state: .followsWindowActiveState)
    }
}

/// Rounds the content area to the window's own corner shape and, with
/// Settings › Appearance › Inset web pages, pulls it in from the window's
/// top, bottom and trailing edges so the window background frames the
/// page. The leading inset is `BrowserWindowLayoutView`'s, which moves the
/// page's leading edge with the sidebar: the page meets the docked sidebar
/// without an inset of its own.
///
/// The page's hosting view isn't the window's own, so SwiftUI doesn't know
/// the window's corners there: they're given as the container shape, the
/// window's radius (16pt on macOS 27, 0 in fullscreen; read by
/// `BrowserWindowLayoutView`) around the hosting view, whose right-hand
/// corners are the window's. The page's corners resolve to that radius
/// less the inset, which keeps them concentric; `isUniform` carries it over
/// to the left-hand corners next to the sidebar. Inset, the radius is a
/// little more than concentric would give (8pt), which looked tight.
///
/// Full screen leaves out the inset: the page goes edge to edge, square.
///
/// A split view's panes are rounded each on their own (`WebViewContainerView`),
/// with the radius the page's corners come to. The active one's ring is
/// outside it, so it's drawn over the clip, not in it.
///
/// SwiftUI applies this as a plain layer `cornerRadius` on the web views'
/// container — no mask layer over the web content.
///
/// Behind the page, its own color fills in where the web view hasn't drawn
/// (`BackgroundColorExtractor`). It stops a point short of the page's edge:
/// SwiftUI rounds it and the web view each on their own, and where the
/// curve only partly covers a pixel, a light page color showed through
/// around a darker top of the page as a hairline.
///
/// Observes the settings here rather than in ContentView, whose whole body
/// would re-run on every settings change.
private struct ContentAreaShape: ViewModifier {
    /// The active page's background color
    let pageColor: Color
    let windowCornerRadius: CGFloat
    let isFullScreen: Bool
    @ObservedObject private var settings = TOMLSettingsManager.shared

    private static let inset = BrowserWindowLayoutView.pageInset
    private static let minimumInsetCornerRadius: CGFloat = 10
    private static let insets = EdgeInsets(top: inset, leading: 0, bottom: inset, trailing: inset)

    func body(content: Content) -> some View {
        let isInset = settings.insetWebView && !isFullScreen
        let shape = ConcentricRectangle(
            corners: isInset ? .concentric(minimum: .fixed(Self.minimumInsetCornerRadius)) : .concentric,
            isUniform: true
        )
        // What the shape's corners come to
        let cornerRadius = isInset
            ? max(windowCornerRadius - Self.inset, Self.minimumInsetCornerRadius)
            : windowCornerRadius
        content
            .environment(\.splitPaneCornerRadius, cornerRadius)
            .background {
                shape
                    .fill(pageColor)
                    .padding(1)
            }
            .clipShape(shape)
            .overlayPreferenceValue(SplitFocusedPaneKey.self) { pane in
                if let pane {
                    GeometryReader { proxy in
                        let frame = proxy[pane]
                        SplitFocusRing(cornerRadius: cornerRadius)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    .allowsHitTesting(false)
                    // On the pane that's active now at once, moving with it
                    .transition(.identity)
                }
            }
            .padding(isInset ? Self.insets : EdgeInsets())
            .animation(.easeInOut(duration: 0.15), value: isInset)
            .containerShape(RoundedRectangle(cornerRadius: windowCornerRadius))
    }
}
