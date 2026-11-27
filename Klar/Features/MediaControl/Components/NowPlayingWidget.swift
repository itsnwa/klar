import SwiftUI
import WebKit

// MARK: - Video Rect Tracking

/// Finds where a tab's playing <video> is on its page, for the Now Playing
/// preview, which shows that part of the tab's own web view live
/// (`MiniPlayerHostView`).
///
/// Nothing is drawn or copied here: the page is only asked for a rect,
/// which rarely changes while its tab is in the background.
@MainActor
private class VideoRectTracker: ObservableObject {
    /// The video's picture, in the web view's coordinates. Nil while the
    /// page shows no video (an audio-only player, or one scrolled away).
    @Published private(set) var videoRect: CGRect?

    private static let pollInterval: TimeInterval = 1
    /// After this many polls in a row without a video, the page is only
    /// asked every `emptyProbeInterval` ticks, in case it starts showing one.
    private static let maxEmptyPolls = 3
    private static let emptyProbeInterval = 5

    private var timer: Timer?
    private var isPolling = false
    private var tabId: UUID?
    /// Whether the sidebar showing the preview is on screen.
    private var isShown = true
    private var emptyPolls = 0
    private var skippedProbeTicks = 0

    /// The largest playing video's picture (the part of the element it
    /// fills, per object-fit), clipped to the viewport, in CSS pixels. A
    /// video in Picture in Picture is shown there, not previewed: 0 if
    /// that's the only one.
    private static let rectScript = """
    (function(){
        var v=null,r=null,maxA=0,pip=false;
        document.querySelectorAll('video').forEach(function(el){
            if(el.webkitPresentationMode==='picture-in-picture'||el===document.pictureInPictureElement){pip=true;return;}
            if(el.readyState<2||!el.videoWidth)return;
            var b=el.getBoundingClientRect(),a=b.width*b.height;
            if(a>maxA){maxA=a;v=el;r=b;}
        });
        if(!v)return pip?0:null;
        var fit=getComputedStyle(v).objectFit==='cover'?Math.max:Math.min;
        var s=fit(r.width/v.videoWidth,r.height/v.videoHeight);
        var w=Math.min(v.videoWidth*s,r.width),h=Math.min(v.videoHeight*s,r.height);
        var x=Math.max(r.left+(r.width-w)/2,0),y=Math.max(r.top+(r.height-h)/2,0);
        var x2=Math.min(r.left+(r.width+w)/2,innerWidth),y2=Math.min(r.top+(r.height+h)/2,innerHeight);
        if(x2-x<16||y2-y<16)return null;
        return [x,y,x2-x,y2-y];
    })();
    """

    func start(tabId: UUID) {
        stop()
        self.tabId = tabId
        resumeIfNeeded()
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            resumeIfNeeded()
        } else {
            pause()
        }
    }

    func stop() {
        pause()
        tabId = nil
        emptyPolls = 0
        skippedProbeTicks = 0
        // A video-less successor tab (e.g. a music site) must not get the
        // previous tab's preview.
        if videoRect != nil {
            videoRect = nil
        }
    }

    private func resumeIfNeeded() {
        guard timer == nil, isShown, tabId != nil else { return }
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        // Let the system batch these wakeups with others.
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !isPolling,
              let currentTabId = tabId,
              let coordinator = TabWebViewCoordinator.coordinator(for: currentTabId),
              // An occluded window shows no preview.
              coordinator.webView.presentationWindow?.occlusionState.contains(.visible) == true else { return }

        if emptyPolls >= Self.maxEmptyPolls {
            skippedProbeTicks += 1
            guard skippedProbeTicks >= Self.emptyProbeInterval else { return }
            skippedProbeTicks = 0
        }

        isPolling = true
        let webView = coordinator.webView

        webView.evaluateJavaScript(Self.rectScript) { [weak self, weak webView, currentTabId] result, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPolling = false

                // Discard a rect from a tab we are no longer tracking — an
                // in-flight poll from the previous tab after a switch.
                guard self.tabId == currentTabId else { return }

                var rect: CGRect?
                if let webView, let values = result as? [NSNumber], values.count == 4 {
                    // CSS pixels to the web view's points.
                    let zoom = webView.pageZoom
                    rect = CGRect(
                        x: values[0].doubleValue * zoom,
                        y: values[1].doubleValue * zoom,
                        width: values[2].doubleValue * zoom,
                        height: values[3].doubleValue * zoom
                    ).integral
                }

                // Back in the page soon after Picture in Picture closes
                let isInPictureInPicture = result is NSNumber
                if rect == nil, !isInPictureInPicture {
                    self.emptyPolls += 1
                } else {
                    self.emptyPolls = 0
                    self.skippedProbeTicks = 0
                }
                if self.videoRect != rect {
                    self.videoRect = rect
                }
            }
        }
    }

    isolated deinit {
        timer?.invalidate()
    }
}

// MARK: - Live Preview

/// The preview of a background tab's video: the video's own layer, cropped
/// and scaled down. The tab's web view is lent by its `WebViewContainerView`,
/// so the page stays visible to WebKit and keeps rendering the video. The
/// web view keeps its size, so the page doesn't lay out again, and Core
/// Animation composites the video as it plays — at its own frame rate,
/// with no frames copied out of the page.
private struct MiniPlayerView: NSViewRepresentable {
    let tabId: UUID
    let videoRect: CGRect
    /// Whether the preview is on screen. Off it, the web view is given back,
    /// so the page doesn't keep rendering for nobody.
    let isLive: Bool

    func makeNSView(context: Context) -> MiniPlayerHostView {
        MiniPlayerHostView()
    }

    func updateNSView(_ view: MiniPlayerHostView, context: Context) {
        view.videoRect = videoRect
        view.show(tabId: isLive ? tabId : nil)
    }

    static func dismantleNSView(_ view: MiniPlayerHostView, coordinator: ()) {
        view.show(tabId: nil)
    }
}

private final class MiniPlayerHostView: NSView {
    /// Its bounds are the crop, so AppKit scales that part of the page to
    /// fill this view.
    private let scalingView = FlippedView()
    /// Clips the page to the crop and draws it into a bitmap that's then
    /// scaled down with mipmaps. Scaled straight from the page's layers
    /// (about 5×), the video sampled too few of its pixels and looked
    /// jagged. The bitmap is redrawn on every video frame, so it covers
    /// only the crop.
    private let smoothingView = FlippedView()
    /// Holds the borrowed web view at its own size. Not drawn while
    /// `videoView` shows the video, but it has to stay in the window and
    /// not hidden: for a hidden page, WebKit's GPU process takes down the
    /// video's layer.
    private let pageView = FlippedView()
    /// The video alone, from its own render context (`videoHost`), where
    /// the page has it.
    private let videoView = FlippedView()
    /// WebKit's layer for the video hosts a render context of its GPU
    /// process (`CALayerHost`, private), and this hosts it again. Only the
    /// video is rasterized then, not the page's layers around and over it:
    /// about a third less GPU time in WindowServer. Nil while there's no
    /// such layer; the web view itself shows then.
    private var videoHost: CALayer?
    /// Looks for the video's layer again: WebKit replaces it when the page
    /// is hidden and shown again, as when the window is covered.
    private var videoHostTimer: Timer?
    private var tabId: UUID?
    private weak var webView: WKWebView?

    private static let layerHostClass = NSClassFromString("CALayerHost") as? CALayer.Type

    /// The video's picture, in the web view's coordinates.
    var videoRect: CGRect = .zero {
        didSet {
            if videoRect != oldValue {
                updateCrop()
                updateVideoHost()
            }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()
        scalingView.frame = bounds
        addSubview(scalingView)
        smoothingView.wantsLayer = true
        smoothingView.layer?.masksToBounds = true
        smoothingView.layer?.shouldRasterize = true
        smoothingView.layer?.minificationFilter = .trilinear
        scalingView.addSubview(smoothingView)
        for view in [pageView, videoView] {
            view.wantsLayer = true
            smoothingView.addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows this tab's web view, or gives it back for nil.
    func show(tabId: UUID?) {
        guard tabId != self.tabId else { return }
        giveBack()
        self.tabId = tabId
        borrowIfNeeded()
    }

    private func borrowIfNeeded() {
        // Only a tab of this window: another window's page stays in it
        guard let window, webView == nil, let tabId,
              let coordinator = TabWebViewCoordinator.coordinator(for: tabId),
              let container = WebViewContainerView.container(of: coordinator.webView),
              container.window === window,
              let webView = container.lendWebView(to: self) else { return }
        // The page doesn't react to the cursor over the preview: no hover
        // controls, no cursor changes. Restored when its tab is shown.
        coordinator.setPointerEventsEnabled(false)
        updateRasterizationScale()
        pageView.frame = CGRect(origin: .zero, size: webView.frame.size)
        videoView.frame = pageView.frame
        webView.setFrameOrigin(.zero)
        pageView.addSubview(webView)
        self.webView = webView
        updateVideoHost()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoHost()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        videoHostTimer = timer
    }

    private func giveBack() {
        videoHostTimer?.invalidate()
        videoHostTimer = nil
        removeVideoHost()
        guard let webView else { return }
        self.webView = nil
        // Already gone if its tab was shown meanwhile.
        if webView.superview === pageView {
            WebViewContainerView.container(of: webView)?.reclaimWebView(from: self)
        }
    }

    /// Hosts the render context of WebKit's layer for the video, where the
    /// page draws it, or shows the web view if there's no such layer.
    private func updateVideoHost() {
        guard let webView, let root = webView.layer, let hostClass = Self.layerHostClass,
              let source = Self.videoHostLayer(in: root, over: videoRect),
              let contextId = source.value(forKey: "contextId") as? NSNumber else {
            removeVideoHost()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if (videoHost?.value(forKey: "contextId") as? NSNumber) != contextId {
            videoHost?.removeFromSuperlayer()
            let host = hostClass.init()
            host.setValue(contextId, forKey: "contextId")
            if let preservesFlip = source.value(forKey: "preservesFlip") {
                host.setValue(preservesFlip, forKey: "preservesFlip")
            }
            videoView.layer?.addSublayer(host)
            videoHost = host
        }
        if let videoHost {
            // Where the page has it, at its size there
            let frame = root.convert(source.bounds, from: source)
            let position = CGPoint(x: frame.midX, y: frame.midY)
            let transform = CATransform3DMakeScale(
                frame.width / source.bounds.width,
                frame.height / source.bounds.height,
                1
            )
            if videoHost.bounds != source.bounds {
                videoHost.bounds = source.bounds
            }
            if videoHost.position != position {
                videoHost.position = position
            }
            if !CATransform3DEqualToTransform(videoHost.transform, transform) {
                videoHost.transform = transform
            }
        }
        CATransaction.commit()
        if pageView.alphaValue != 0 {
            pageView.alphaValue = 0
        }
    }

    private func removeVideoHost() {
        videoHost?.removeFromSuperlayer()
        videoHost = nil
        if pageView.alphaValue != 1 {
            pageView.alphaValue = 1
        }
    }

    /// WebKit's host layer for the video over `rect`, in `root`'s
    /// coordinates: the one that covers most of it.
    private static func videoHostLayer(in root: CALayer, over rect: CGRect) -> CALayer? {
        guard let hostClass = layerHostClass, !rect.isEmpty else { return nil }
        var best: (layer: CALayer, area: CGFloat)?
        func visit(_ layer: CALayer) {
            if layer.isKind(of: hostClass), !layer.bounds.isEmpty {
                let overlap = root.convert(layer.bounds, from: layer).intersection(rect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.area ?? 0) {
                    best = (layer, area)
                }
            }
            layer.sublayers?.forEach(visit)
        }
        visit(root)
        // Most of the video, not some other layer beside it
        guard let best, best.area >= rect.width * rect.height / 2 else { return nil }
        return best.layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            giveBack()
        } else {
            borrowIfNeeded()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRasterizationScale()
    }

    private func updateRasterizationScale() {
        smoothingView.layer?.rasterizationScale = window?.backingScaleFactor ?? 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scalingView.frame = bounds
        updateCrop()
    }

    /// Shows the largest part of the video with this view's shape (aspect
    /// fill), scaled to fit.
    private func updateCrop() {
        let size = bounds.size
        guard size.width > 0, size.height > 0, !videoRect.isEmpty else { return }
        var crop = videoRect
        let aspect = size.width / size.height
        if crop.width / crop.height > aspect {
            let width = crop.height * aspect
            crop.origin.x += (crop.width - width) / 2
            crop.size.width = width
        } else {
            let height = crop.width / aspect
            crop.origin.y += (crop.height - height) / 2
            crop.size.height = height
        }
        if scalingView.bounds != crop {
            scalingView.bounds = crop
            // Its frame and bounds are both the crop, so it shows the page
            // (at its origin) through a window the crop's size.
            smoothingView.frame = crop
            smoothingView.bounds = crop
        }
    }

    // Clicks go to the row, which switches to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
        }
    }

    private final class FlippedView: NSView {
        // Top-left origin, like the page's coordinates.
        override var isFlipped: Bool { true }
    }
}

// MARK: - Now Playing Widget

struct NowPlayingWidget: View {
    /// Whether the sidebar is on screen; the preview only updates while it is.
    let isShown: Bool
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var mediaManager = MediaControlManager.shared
    @StateObject private var videoTracker = VideoRectTracker()

    /// All tabs with active media, except those on screen (the active one,
    /// or its split view's panes). Sorted with playing tabs first, then by
    /// most recent activity.
    private var mediaTabs: [(BrowserTab, TabMediaState)] {
        mediaManager.tabMediaStates
            .compactMap { (tabId, state) -> (BrowserTab, TabMediaState)? in
                guard state.hasActiveMedia,
                      !tabManager.splitViews.isVisible(tabId),
                      let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
                return (tab, state)
            }
            .sorted { lhs, rhs in
                if lhs.1.isPlayingMedia != rhs.1.isPlayingMedia {
                    return lhs.1.isPlayingMedia
                }
                return lhs.1.lastDetectionTime > rhs.1.lastDetectionTime
            }
    }

    var body: some View {
        let tabs = mediaTabs
        if !tabs.isEmpty {
            stackContent(tabs: tabs)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func stackContent(tabs: [(BrowserTab, TabMediaState)]) -> some View {
        let topTabId = tabs[0].0.id
        VStack(spacing: 2) {
            NowPlayingItem(
                tab: tabs[0].0,
                state: tabs[0].1,
                preview: videoTracker.videoRect,
                isPreviewLive: isShown,
                style: .preview
            )
            ForEach(Array(tabs.dropFirst()), id: \.0.id) { entry in
                NowPlayingItem(
                    tab: entry.0,
                    state: entry.1,
                    preview: nil,
                    isPreviewLive: false,
                    style: .compact
                )
            }
        }
        // With the items' hover background inset 4, it's 6 from the
        // sidebar's edges, like the tabs
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
        .onAppear {
            videoTracker.setShown(isShown)
            videoTracker.start(tabId: topTabId)
        }
        .onDisappear { videoTracker.stop() }
        .onChange(of: topTabId) { _, newId in
            videoTracker.start(tabId: newId)
        }
        .onChange(of: isShown) { _, shown in
            videoTracker.setShown(shown)
        }
    }
}

// MARK: - Item Row

private enum NowPlayingItemStyle {
    case preview
    case compact
}

private struct NowPlayingItem: View {
    let tab: BrowserTab
    @ObservedObject var state: TabMediaState
    /// Where the tab's video is on its page, for a live preview of it.
    let preview: CGRect?
    let isPreviewLive: Bool
    let style: NowPlayingItemStyle

    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var mediaManager = MediaControlManager.shared
    @State private var isHovering = false

    var body: some View {
        Group {
            switch style {
            case .preview:
                VStack(spacing: 8) {
                    if let preview {
                        MiniPlayerView(tabId: tab.id, videoRect: preview, isLive: isPreviewLive)
                            .frame(maxWidth: .infinity)
                            .frame(height: 120)
                            .overlay(alignment: .topTrailing) {
                                pictureInPictureButton
                            }
                    }
                    rowContent
                }
                .padding(.horizontal, 8)
                // The hover background is inset 4 at the sides but 2 at
                // the top, so this leaves the preview 4 from its edge
                // all round.
                .padding(.top, 6)
                .padding(.bottom, 12)
            case .compact:
                rowContent
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tabManager.switchToTab(tab) }
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .background(
            RoundedRectangle(cornerRadius: style == .preview ? 16 : 10)
                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .clipShape(FaviconStyle.clipShape)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Playing" : tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if style == .preview, let host = URL(string: tab.url)?.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                controlButton(
                    icon: state.isMediaPaused ? "play.fill" : "pause.fill",
                    help: state.isMediaPaused ? "Resume" : "Pause"
                ) {
                    mediaManager.togglePause(for: tab.id)
                }

                controlButton(
                    icon: state.isMediaMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: state.isMediaMuted ? "Unmute" : "Mute"
                ) {
                    mediaManager.toggleMute(for: tab.id)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Pops the video out to Picture in Picture; shown while the pointer is
    /// over the row. The preview then gives way to the row alone until it's
    /// back in the page.
    /// Only there while hovered: glass follows its place in the window, and
    /// a hidden button's was worked out again on every frame of the sidebar
    /// sliding in or out.
    private var pictureInPictureButton: some View {
        ZStack {
            if isHovering {
                Button {
                    mediaManager.enterPictureInPicture(for: tab.id)
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .glassEffectTransition(.identity)
                .padding(6)
                .help("Picture in Picture")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private func controlButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        KlarButton(style: .compact, action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}
