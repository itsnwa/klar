import AppKit
import WebKit

/// A web view's icon loading delegate (WebKit's private
/// `_WKIconLoadingDelegate`): the icons a page lists, loaded by WebKit
/// itself, with the page's own cookies and website data. Klar's own lookup
/// fetches the site's front page without them,
/// and a site behind a browser check ("Checking your browser…") answers
/// that with the check's page, or a 403 for every icon.
///
/// WebKit offers the icons of each main-frame document as it finishes
/// loading (its `<link rel=icon>`s and touch icons, or `/favicon.ico`),
/// and loads only those it's told to. A page's offers are gathered, ranked
/// and, if the site wants an icon (`FaviconCacheManager.wantsPageIcon`),
/// loaded one at a time until one is an image; the rest are declined.
final class PageIconLoader: NSObject {
    /// The handler WebKit gives each offered icon: called with a block for
    /// the icon's data to load it, or with nil to leave it.
    typealias Answer = (((NSData?) -> Void)?) -> Void

    /// The icon found for a page, kept by `FaviconCacheManager` (and posted
    /// as `.faviconCached`), with the address of that page.
    var onIcon: ((NSImage, String) -> Void)?

    private let persist: Bool
    /// The page whose icons are being gathered or loaded.
    private var round: Round?

    /// How long WebKit gets for an icon's data before the next one is tried.
    private static let loadTimeout: Duration = .seconds(15)
    /// WebKit sends a page's offers one message each, in a burst.
    private static let gatherDelay: Duration = .milliseconds(50)

    /// `isPrivate`: a private tab's page, whose icons aren't kept on disk.
    init(isPrivate: Bool) {
        persist = !isPrivate
        super.init()
    }

    func attach(to webView: WKWebView) {
        let selector = NSSelectorFromString("_setIconLoadingDelegate:")
        guard webView.responds(to: selector) else { return }
        webView.perform(selector, with: self)
    }

    func detach(from webView: WKWebView) {
        let selector = NSSelectorFromString("_setIconLoadingDelegate:")
        if webView.responds(to: selector) {
            webView.perform(selector, with: nil)
        }
        round?.cancel()
        round = nil
    }

    isolated deinit {
        round?.cancel()
    }

    @objc(webView:shouldLoadIconWithParameters:completionHandler:)
    func webView(_ webView: WKWebView, shouldLoadIconWithParameters parameters: NSObject, completionHandler: @escaping Answer) {
        guard let iconURL = parameters.value(forKey: "url") as? URL,
              let pageURL = webView.url?.absoluteString else {
            completionHandler(nil)
            return
        }
        // Another page's icons, or the same page's again: the earlier
        // round's icons not loaded yet are left.
        if round == nil || round?.pageURL != pageURL || round?.isLoading == true {
            round?.cancel()
            let newRound = Round(pageURL: pageURL)
            round = newRound
            Task { [weak self] in
                try? await Task.sleep(for: Self.gatherDelay)
                await self?.load(newRound)
            }
        }
        round?.offers.append(Offer(
            url: iconURL,
            isTouchIcon: (parameters.value(forKey: "iconType") as? Int ?? 0) != 0,
            size: (parameters.value(forKey: "size") as? NSNumber)?.intValue,
            mimeType: (parameters.value(forKey: "mimeType") as? String)?.lowercased(),
            answer: completionHandler
        ))
    }

    private func load(_ round: Round) async {
        guard round === self.round, !round.isCancelled else { return }
        round.isLoading = true
        round.rankOffers()
        let image = await FaviconCacheManager.shared.cachePageIcon(for: round.pageURL, persist: persist) {
            await round.loadNext()
        }
        round.cancel()
        if self.round === round {
            self.round = nil
        }
        if let image {
            onIcon?(image, round.pageURL)
        }
    }

    // MARK: - Appearance-aware links

    static func installAppearanceObserver(on configuration: WKWebViewConfiguration) {
        let world = WKContentWorld.world(name: "KlarFavicon")
        let controller = configuration.userContentController
        controller.add(AppearanceIconHandler.shared, contentWorld: world, name: "klarFavicon")
        controller.addUserScript(WKUserScript(source: appearanceScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
    }

    private final class AppearanceIconHandler: NSObject, WKScriptMessageHandler {
        static let shared = AppearanceIconHandler()

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let webView = message.webView,
                  let page = message.frameInfo.request.url,
                  let scheme = page.scheme, ["https", "http"].contains(scheme),
                  let body = message.body as? [String: String],
                  let href = body["href"], let source = URL(string: href),
                  let appearance = body["scheme"].flatMap(FaviconColorScheme.init(rawValue:)) else { return }

            let githubVariants = FaviconCacheManager.githubIconVariants(for: source, on: page)
            guard !githubVariants.isEmpty || body["kind"] == "variant" else { return }
            let variants = githubVariants.isEmpty ? [appearance: source] : githubVariants
            let persist = webView.configuration.websiteDataStore.isPersistent
            Task {
                let current = FaviconColorScheme.current
                for scheme in [current, current == .dark ? .light : .dark] {
                    guard let icon = variants[scheme] else { continue }
                    await FaviconCacheManager.shared.cacheVariant(from: icon, for: page.absoluteString,
                                                                 scheme: scheme, persist: persist)
                }
            }
        }
    }

    /// Ordinary icons still use the WebKit delegate. This reports links
    /// matching an appearance query, or a script replacing the icon as the
    /// appearance changes. Observe only the head, where favicon links live.
    private static let appearanceScript = #"""
    (() => {
        if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
        const handler = window.webkit.messageHandlers.klarFavicon;
        const dark = matchMedia('(prefers-color-scheme: dark)');
        let previousAppearance = dark.matches;
        let previousURL;
        let urlBeforeSwitch;
        let sent = false;

        function update() {
            if (previousAppearance !== dark.matches) {
                previousAppearance = dark.matches;
                urlBeforeSwitch = previousURL;
                sent = false;
            }

            const links = Array.from(document.head.querySelectorAll('link[rel~="icon" i][href]'));
            const matching = links.filter(link => !link.media || matchMedia(link.media).matches);
            const themed = matching.findLast(link => /prefers-color-scheme/i.test(link.media));
            const icon = themed || matching.findLast(link => !link.relList.contains('alternate')) || matching.at(-1);
            if (!icon) return;
            previousURL = icon.href;
            const variant = themed || (urlBeforeSwitch && icon.href !== urlBeforeSwitch);
            const githubIcon = location.hostname === 'github.com' &&
                /^https:\/\/github\.githubassets\.com\/favicons\/favicon(?:-dark)?\.svg(?:[?#]|$)/.test(icon.href);
            if (sent || (!variant && !githubIcon)) return;

            sent = true;
            handler.postMessage({ href: icon.href, scheme: dark.matches ? 'dark' : 'light',
                                  kind: variant ? 'variant' : 'standard' });
        }

        function watchHead() {
            if (!document.head) return false;
            new MutationObserver(records => {
                if (records.some(record => record.target instanceof HTMLLinkElement ||
                    [...record.addedNodes, ...record.removedNodes].some(node => node instanceof HTMLLinkElement))) {
                    update();
                }
            }).observe(document.head, {
                childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'media', 'rel']
            });
            dark.addEventListener('change', update);
            window.addEventListener('pageshow', update);
            update();
            return true;
        }

        if (!watchHead()) {
            const observer = new MutationObserver(() => {
                if (watchHead()) observer.disconnect();
            });
            observer.observe(document, { childList: true, subtree: true });
        }
    })();
    """#

    // MARK: - Offers

    /// An icon WebKit offers, and the answer it waits for. Every offer is
    /// answered once: loaded, or declined (`Round.cancel`).
    private struct Offer {
        let url: URL
        let isTouchIcon: Bool
        /// From its `sizes`, in pixels; nil when it doesn't say.
        let size: Int?
        let mimeType: String?
        let answer: Answer

        var isVector: Bool {
            mimeType?.contains("svg") == true || url.pathExtension.lowercased() == "svg"
        }

        /// Best first: the smallest of at least 64 px (icons are kept at
        /// 64 px), a vector one, a touch icon (180 px, mostly), the largest
        /// smaller one, then the rest in the page's order.
        var rank: (tier: Int, size: Int) {
            if let size, size >= 64 { return (0, size) }
            if isVector { return (1, 0) }
            if isTouchIcon, size == nil { return (2, 0) }
            if let size { return (3, -size) }
            return (4, 0)
        }
    }

    /// One page's offered icons, loaded one at a time.
    private final class Round {
        let pageURL: String
        var offers: [Offer] = []
        /// Whether its offers are being loaded: any more are another round's.
        var isLoading = false
        private(set) var isCancelled = false
        /// The icon being loaded, finished by WebKit's answer or the timeout,
        /// whichever comes first (`loadCount` tells the two apart).
        private var pendingLoad: CheckedContinuation<Data?, Never>?
        private var loadCount = 0

        init(pageURL: String) {
            self.pageURL = pageURL
        }

        func rankOffers() {
            offers = offers.enumerated()
                .sorted { ($0.element.rank.tier, $0.element.rank.size, $0.offset) < ($1.element.rank.tier, $1.element.rank.size, $1.offset) }
                .map(\.element)
        }

        /// The best icon left, loaded by WebKit: its data (nil when it
        /// couldn't be loaded), or nil when none are left.
        func loadNext() async -> Data? {
            while !isCancelled, !offers.isEmpty {
                let offer = offers.removeFirst()
                loadCount += 1
                let thisLoad = loadCount
                let data = await withCheckedContinuation { continuation in
                    pendingLoad = continuation
                    offer.answer { [weak self] data in
                        self?.finishLoad(thisLoad, data: data as Data?)
                    }
                    Task { [weak self] in
                        try? await Task.sleep(for: PageIconLoader.loadTimeout)
                        self?.finishLoad(thisLoad, data: nil)
                    }
                }
                if let data, !data.isEmpty { return data }
            }
            return nil
        }

        private func finishLoad(_ thisLoad: Int, data: Data?) {
            guard thisLoad == loadCount, let continuation = pendingLoad else { return }
            pendingLoad = nil
            continuation.resume(returning: data)
        }

        /// Declines the icons not loaded, and gives up on one loading.
        func cancel() {
            isCancelled = true
            let declined = offers
            offers.removeAll()
            for offer in declined {
                offer.answer(nil)
            }
            finishLoad(loadCount, data: nil)
        }
    }
}
