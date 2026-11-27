import AppKit
import WebKit

/// Klar's own pages, `klar://…` (What's New, `WhatsNewPage`; Explore with AI, `ExplorePage`; Acknowledgements,
/// `AcknowledgementsPage`), made on the spot for every web view
/// (`WebViewConfiguration.createConfiguration`). Only as the page itself: a website loading one as an image,
/// a frame or a fetch gets an error, as for an address nothing answers. Such a page isn't a deep link, isn't
/// kept in history and isn't an open tab, so it stays in its window and off other Macs, whose Klar may not
/// know it.
final class KlarSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "klar"
    static let shared = KlarSchemeHandler()

    nonisolated static func isPage(_ url: String) -> Bool {
        url.hasPrefix("\(scheme):")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        // The document asking: the page itself for its own load, a website for anything it loads
        let document = request.mainDocumentURL ?? webView.url
        guard let url = request.url, document?.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // An Explore page's pictures, as they're fetched, for Explore's pages alone
        if ExplorePreviews.isResource(url) {
            guard document?.host == ExplorePage.host else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let key = ObjectIdentifier(urlSchemeTask)
            loadingPictures.insert(key)
            Task {
                let picture = await ExplorePreviews.resource(at: url)
                // Stopped meanwhile: the task mustn't be answered
                guard loadingPictures.remove(key) != nil else { return }
                // None is a transparent pixel, so the card's own art shows (the page runs no script to hide it)
                let shown = picture ?? (ExplorePreviews.transparentPNG, "image/png")
                respond(to: urlSchemeTask, url: url, mimeType: shown.mimeType, data: shown.data)
            }
            return
        }
        guard let html = page(at: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        respond(to: urlSchemeTask, url: url, mimeType: "text/html", data: Data(html.utf8))
    }

    /// Pictures still being fetched, by their tasks
    private var loadingPictures: Set<ObjectIdentifier> = []

    // Pages are answered at once; only a picture can still be loading.
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        loadingPictures.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func respond(to urlSchemeTask: any WKURLSchemeTask, url: URL, mimeType: String, data: Data) {
        let encoding = mimeType == "text/html" ? "utf-8" : nil
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: encoding))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    private func page(at url: URL) -> String? {
        switch url.host {
        case WhatsNewPage.host: WhatsNewPage.html(for: WhatsNewPage.notes(for: url))
        case ExplorePage.host: ExplorePage.html(for: url)
        case AcknowledgementsPage.host: AcknowledgementsPage.html()
        default: nil
        }
    }
}

extension TabManager {
    /// Switches to the window's tab showing one of Klar's pages (`isPage`), taking it to `url` if it shows another
    /// address of it, or opens `url` in a new tab.
    func showKlarPage(_ url: String, where isPage: (String) -> Bool) {
        guard let tab = tabs.first(where: { isPage($0.url) }) else {
            createNewTab(url: url)
            return
        }
        if tab.url != url {
            tab.navigateToURL(url)
        }
        if activeTabId != tab.id {
            switchToTab(tab)
        }
    }
}

/// What Klar's pages share: their colors, type and header (`.eyebrow`, `h1`, Klar's `logo`), and escaping text
/// into HTML.
enum KlarPage {
    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let style = """
    :root {
      color-scheme: light dark;
      --background: #ffffff;
      --text: #1d1d1f;
      --secondary: rgba(29, 29, 31, 0.56);
      --tile: rgba(0, 0, 0, 0.045);
      --edge: rgba(0, 0, 0, 0.07);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: #1c1c1e;
        --text: #f5f5f7;
        --secondary: rgba(245, 245, 247, 0.58);
        --tile: rgba(255, 255, 255, 0.07);
        --edge: rgba(255, 255, 255, 0.09);
      }
    }
    html { background: var(--background); }
    body {
      margin: 0;
      color: var(--text);
      font: 14px/1.5 -apple-system, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    main { max-width: 580px; margin: 0 auto; padding: 88px 40px 120px; }
    header { display: grid; gap: 22px; margin-bottom: 48px; }
    h1 { margin: 4px 0 0; font-size: 34px; line-height: 1.15; font-weight: 650; letter-spacing: -0.02em; }
    .logo { display: block; width: 44px; height: 44px; background: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; }
    .eyebrow {
      margin: 0;
      font: 500 11px/1.3 ui-monospace, "SF Mono", Menlo, monospace;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--secondary);
    }
    """

    // MARK: - Images

    /// Klar's logo, in the text's color.
    static var logo: String {
        guard let image = NSImage(named: "logo") else { return "" }
        return "<span class=\"logo\" style=\"-webkit-mask-image: url(\(maskURL(for: image, key: "logo", size: 44)))\"></span>"
    }

    private static var maskURLs: [String: String] = [:]

    /// A template image as a PNG data URL at twice its size, for a CSS mask (only its shape, its alpha, counts
    /// in one), so it takes the text's color in light and dark.
    static func maskURL(for image: NSImage, key: String, size: CGFloat) -> String {
        if let cached = maskURLs[key] { return cached }
        let pixels = Int(size * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return "" }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Fit, centered, keeping its proportions
        let scale = min(size / image.size.width, size / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        let url = "data:image/png;base64,\(png.base64EncodedString())"
        maskURLs[key] = url
        return url
    }
}
