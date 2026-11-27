import Foundation
import WebKit

/// Explore with AI (⌘K): questions about the page on screen that the AI in Settings › AI answers by searching
/// the web (sites like it, where it's discussed, other sources on it), each a page of cards in a new tab,
/// `klar://explore?q=…&url=…&title=…&id=…` (`KlarSchemeHandler`). It shows at once, searching
/// (`ExploreLibrary` asks); once the answer is in, the tabs showing it reload. Each card has the site's
/// sharing image (`ExplorePreviews`), or its icon on a color of its own. Answers are kept and synced
/// (`ExploreLibrary`), so a page restored later, or opened from the overview's Explore list, shows its
/// own; one without an answer (it failed, or Klar quit first) asks again. Only the page's address and title
/// go along, to Claude or Codex (Ollama can't search the web), and never a private tab's.
enum ExplorePage {
    nonisolated static let host = "explore"

    // MARK: - Addresses

    /// A new page asking `question` about the page at `source`. Only addresses made here ask: a website
    /// can link to a `klar://explore` page, but not make it search.
    static func url(for question: Question, source: String, title: String, siteName: String?) -> String {
        let id = UUID()
        ExploreLibrary.shared.allowAsking(id)
        return url(for: question, source: source, title: title, siteName: siteName, id: id)
    }

    nonisolated static func url(for question: Question, source: String, title: String, siteName: String?, id: UUID) -> String {
        var components = URLComponents()
        components.scheme = KlarSchemeHandler.scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "q", value: question.rawValue),
            URLQueryItem(name: "url", value: source),
            URLQueryItem(name: "title", value: title),
        ] + (siteName.map { [URLQueryItem(name: "site", value: $0)] } ?? []) + [
            URLQueryItem(name: "id", value: id.uuidString),
        ]
        return components.string ?? "\(KlarSchemeHandler.scheme)://\(host)"
    }

    /// Whether a page can be asked about: a web page, not a private tab's
    static func canAsk(about tab: BrowserTab?) -> Bool {
        guard let tab, !tab.isPrivate else { return false }
        return isWebAddress(tab.url)
    }

    /// http or https: the only addresses a page links to or asks about
    nonisolated static func isWebAddress(_ address: String) -> Bool {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The site's own name, from the page's head: `og:site_name`, `application-name`, else the end of its
    /// title after a separator ("Pull requests · GitHub"). Read in a content world of Klar's, apart from the
    /// page's scripts. Only a name that's plainly the address's own (`isName(_:of:)`): a blog on Tumblr or
    /// Substack names the platform, which the AI's answer corrects (`ExploreLibrary.ask`). Nil for none.
    static func siteName(in webView: WKWebView?) async -> String? {
        guard let webView, let host = webView.url?.host() else { return nil }
        let script = """
        const meta = (name) => document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.content?.trim();
        const named = meta('og:site_name') || meta('application-name') || meta('apple-mobile-web-app-title');
        if (named) return named;
        const parts = document.title.split(/\\s+[|·•–—-]\\s+/);
        return parts.length > 1 ? parts[parts.length - 1].trim() : '';
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        guard let name = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 60, isName(name, of: host) else { return nil }
        return name
    }

    /// Whether a name is the site at `host` itself: one its domain spells ("The Verge", theverge.com; "X",
    /// x.com), on the domain itself or `www.`. Not a platform's name on a site it hosts: "Tumblr" on
    /// staff.tumblr.com or a blog's own domain. Names that don't spell the domain (nytimes.com's) fail too,
    /// and the AI's name takes over.
    nonisolated static func isName(_ name: String, of host: String) -> Bool {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" || labels.first == "m" { labels.removeFirst() }
        guard labels.count >= 2 else { return false }
        // The label before the public suffix: "tumblr" in tumblr.com, "bbc" in bbc.co.uk
        let suffixes: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        var domainIndex = labels.count - 2
        if domainIndex > 0, suffixes.contains(labels[domainIndex]), labels.last?.count == 2 {
            domainIndex -= 1
        }
        // A subdomain is a site of its own (a blog, a shop, docs): its name isn't the domain's
        guard domainIndex == 0 else { return false }
        let spelled = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let domain = labels[domainIndex].filter { $0.isLetter || $0.isNumber }
        guard !spelled.isEmpty, !domain.isEmpty else { return false }
        return spelled == domain || spelled.contains(domain) || domain.contains(spelled) && spelled.count >= 2
    }

    /// "arc.net"
    nonisolated static func displayHost(of address: String) -> String {
        guard var host = URL(string: address)?.host?.lowercased() else { return address }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - The page

    /// The page for `url`: the answer, or that it's being looked for (asking, if no one is yet).
    static func html(for url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let question = value("q").flatMap(Question.init(rawValue:)),
              let source = value("url"), isWebAddress(source),
              let id = value("id").flatMap(UUID.init(uuidString:)) else {
            return document(title: "Explore", body: "<p class=\"note\">This page can’t be shown.</p>")
        }
        let title = value("title").flatMap { $0.isEmpty ? nil : $0 } ?? displayHost(of: source)
        let siteName = value("site").flatMap { $0.isEmpty ? nil : $0 }
        let library = ExploreLibrary.shared

        if let answer = library.answer(id) {
            return html(for: answer)
        }
        let again = askAgainLink(question: question, source: source, title: title, siteName: siteName, label: "Search again")
        let heading = question.heading(source: source, title: title, siteName: siteName)
        if library.isDeleted(id) {
            return document(
                title: heading,
                body: header(question: question, heading: heading, source: source, title: title, meta: "Deleted")
                    + "<p class=\"note\">This page was deleted from Explore. \(again)</p>"
            )
        }
        // Only a search Klar started (not a link from a website), which hasn't finished: Klar quit first
        guard library.ask(question, about: source, title: title, siteName: siteName, id: id) else {
            return document(
                title: heading,
                body: header(question: question, heading: heading, source: source, title: title, meta: "Not searched")
                    + "<p class=\"note\">This search didn’t finish. \(again)</p>"
            )
        }
        return searchingHTML(question: question, heading: heading, source: source, title: title)
    }

    private static func html(for answer: Answer) -> String {
        let again = askAgainLink(
            question: answer.question, source: answer.source, title: answer.sourceTitle, siteName: answer.siteName,
            label: answer.error == nil ? "Search again" : "Try again"
        )
        if let error = answer.error {
            return document(title: answer.heading, body: header(for: answer, meta: "Couldn’t search")
                + "<p class=\"note\">\(escape(error)). \(again)</p>")
        }
        guard !answer.sites.isEmpty else {
            return document(title: answer.heading, body: header(for: answer, meta: "Nothing found by \(answer.provider)")
                + "<p class=\"note\">\(again)</p>")
        }

        let cards = answer.sites.enumerated().map { index, site in
            card(for: site, isFeatured: index == 0 && answer.sites.count >= 3)
        }
        let count = answer.sites.count == 1 ? "1 site" : "\(answer.sites.count) sites"
        let date = answer.date.formatted(date: .abbreviated, time: .omitted)
        return document(title: answer.heading, body: header(for: answer, meta: "\(count) · found by \(answer.provider) · \(date)") + """
        <ul class="cards">\(cards.joined())</ul>
        <p class="note footer">Found by searching the web. \(escape(answer.provider)) can be wrong, so check what you open. \(again)</p>
        """)
    }

    private static func searchingHTML(question: Question, heading: String, source: String, title: String) -> String {
        let placeholders = (0..<6).map { index in
            "<li class=\"card placeholder\(index == 0 ? " featured" : "")\"><div class=\"art\"></div><div class=\"text\"><span></span><span></span><span></span></div></li>"
        }
        return document(
            title: heading,
            body: header(question: question, heading: heading, source: source, title: title, meta: "Searching the web…", isSearching: true)
                + "<ul class=\"cards\">\(placeholders.joined())</ul>"
                + "<p class=\"note footer\">This takes up to a minute. The page’s address and title went to the AI in Settings › AI, which searches the web for the rest.</p>"
        )
    }

    // MARK: - Parts

    private static func header(for answer: Answer, meta: String) -> String {
        header(question: answer.question, heading: answer.heading, source: answer.source, title: answer.sourceTitle, meta: meta)
    }

    /// The question, the heading, and a link back to the page asked about, by its title
    private static func header(question: Question, heading: String, source: String, title: String, meta: String, isSearching: Bool = false) -> String {
        """
        <header>
        <p class="eyebrow">\(escape(question.eyebrow))</p>
        <h1>\(escape(heading))</h1>
        <a class="source" href="\(escape(source))" title="\(escape(source))">\
        <img src="\(escape(ExplorePreviews.url("icon", for: source)))" alt="">\
        <span class="title">\(escape(title))</span></a>
        <p class="meta\(isSearching ? " searching" : "")">\(escape(meta))</p>
        </header>
        """
    }

    /// A site's card: its sharing image, else its icon on a color of its own, over its name and why it's here
    private static func card(for site: Site, isFeatured: Bool) -> String {
        let icon = escape(ExplorePreviews.url("icon", for: site.url))
        return """
        <li class="card\(isFeatured ? " featured" : "")" style="--hue: \(hue(for: site.url))">\
        <a href="\(escape(site.url))">\
        <div class="art"><span class="badge"><img src="\(icon)" alt=""></span>\
        <img class="preview" src="\(escape(ExplorePreviews.url("preview", for: site.url)))" alt="" loading="lazy"></div>\
        <div class="text">\
        <p class="site"><img src="\(icon)" alt="">\(escape(displayAddress(of: site.url)))</p>\
        <h3>\(escape(site.name))</h3>\
        <p class="description">\(escape(site.description))</p>\
        </div></a></li>
        """
    }

    private static func askAgainLink(question: Question, source: String, title: String, siteName: String?, label: String) -> String {
        "<a href=\"\(escape(url(for: question, source: source, title: title, siteName: siteName)))\">\(escape(label))</a>"
    }

    /// The same color for a site every time
    private static func hue(for address: String) -> Int {
        let host = displayHost(of: address)
        var hash: UInt32 = 2166136261
        for byte in host.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return Int(hash % 360)
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src klar:; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        \(body)
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        KlarPage.escape(text)
    }

    /// "news.ycombinator.com/item?id=1", without the scheme or `www.`
    private static func displayAddress(of address: String) -> String {
        guard let components = URLComponents(string: address) else { return address }
        var text = displayHost(of: address)
        if components.path != "/" { text += components.path }
        if let query = components.query, !query.isEmpty { text += "?" + query }
        return text
    }

    // MARK: - Style

    private static let style = KlarPage.style + "\n" + """
    .source img, .badge img, .site img { border-radius: \(Int(FaviconStyle.cornerRadius))px; }
    main { max-width: 920px; padding-top: 72px; }
    a { color: inherit; }
    header { gap: 14px; margin-bottom: 36px; }
    h1 { margin: 0; font-size: 46px; line-height: 1.08; letter-spacing: -0.025em; }
    .source {
      justify-self: start; display: inline-flex; align-items: center; gap: 8px; max-width: 100%;
      padding: 6px 12px 6px 8px; border-radius: 999px; text-decoration: none;
      background: var(--tile); box-shadow: inset 0 0 0 0.5px var(--edge);
    }
    .source img { width: 16px; height: 16px; }
    .source .title { font-weight: 550; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .meta { margin: 0; color: var(--secondary); font-size: 13px; }
    .meta.searching { animation: pulse 1.6s ease-in-out infinite; }
    .note { margin: 0; color: var(--secondary); }
    .note a { color: var(--text); text-underline-offset: 3px; }
    .footer { margin-top: 36px; font-size: 12px; }

    .cards { list-style: none; margin: 0; padding: 0; display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
    .card > a {
      display: flex; flex-direction: column; height: 100%; overflow: hidden; text-decoration: none;
      border-radius: 16px; background: var(--tile); box-shadow: inset 0 0 0 0.5px var(--edge);
      transition: transform 0.18s ease, box-shadow 0.18s ease;
    }
    .card > a:hover { transform: translateY(-2px); box-shadow: inset 0 0 0 0.5px var(--edge), 0 10px 28px rgba(0, 0, 0, 0.12); }
    .art {
      position: relative; aspect-ratio: 1.91 / 1; overflow: hidden;
      display: grid; place-items: center;
      background:
        radial-gradient(circle at 25% 20%, hsl(var(--hue) 85% 70% / 0.55), transparent 60%),
        radial-gradient(circle at 80% 90%, hsl(calc(var(--hue) + 50) 80% 55% / 0.45), transparent 55%),
        hsl(var(--hue) 40% 50% / 0.18);
    }
    .badge {
      width: 56px; height: 56px; border-radius: 16px; display: grid; place-items: center;
      background: var(--background); box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12);
    }
    .badge img { width: 32px; height: 32px; }
    .preview { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
    .text { display: grid; gap: 4px; padding: 14px 16px 16px; }
    .site {
      display: flex; align-items: center; gap: 6px; margin: 0; color: var(--secondary);
      font: 11px/1.4 ui-monospace, "SF Mono", Menlo, monospace;
      overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
    }
    .site img { width: 14px; height: 14px; flex: none; }
    .card h3 { margin: 0; font-size: 15px; font-weight: 600; line-height: 1.35; }
    .description {
      margin: 0; color: var(--secondary);
      display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;
    }

    @media (min-width: 640px) {
      .card.featured { grid-column: 1 / -1; }
      .card.featured > a { flex-direction: row; }
      .card.featured .art { flex: 0 0 55%; aspect-ratio: auto; min-height: 240px; }
      .card.featured .text { align-content: center; padding: 24px 28px; gap: 6px; }
      .card.featured h3 { font-size: 21px; letter-spacing: -0.01em; }
      .card.featured .description { -webkit-line-clamp: 5; font-size: 15px; }
    }

    .placeholder { list-style: none; }
    .placeholder .art, .placeholder .text span {
      background: linear-gradient(90deg, var(--tile) 0%, var(--edge) 50%, var(--tile) 100%);
      background-size: 200% 100%; animation: shimmer 1.4s linear infinite;
    }
    .placeholder { border-radius: 16px; overflow: hidden; box-shadow: inset 0 0 0 0.5px var(--edge); }
    .placeholder .text span { display: block; height: 10px; border-radius: 5px; }
    .placeholder .text span:nth-child(1) { width: 40%; }
    .placeholder .text span:nth-child(2) { width: 75%; height: 14px; }
    .placeholder .text span:nth-child(3) { width: 90%; }
    @media (min-width: 640px) {
      .placeholder.featured { display: flex; }
      .placeholder.featured .art { flex: 0 0 55%; min-height: 240px; aspect-ratio: auto; }
      .placeholder.featured .text { flex: 1; align-content: center; }
    }
    @keyframes shimmer { to { background-position: -200% 0; } }
    @keyframes pulse { 50% { opacity: 0.45; } }
    """
}
