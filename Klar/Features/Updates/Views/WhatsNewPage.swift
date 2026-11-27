import AppKit

/// What's New as a page in a tab, `klar://whats-new` (`KlarSchemeHandler`): opened on the first launch after
/// an update, with every version's notes since the one in `?since=` (the version launched before), and from
/// Klar › What's New…, without it, with the menu's notes (`WhatsNew.menuNotes`: this version's, or in a debug
/// build those still being written). New features get a row each, their symbol on a tile; improvements and
/// fixes are lists. The logo and symbols are template images, drawn as CSS masks, so they take the text's color
/// in light and dark.
enum WhatsNewPage {
    static let host = "whats-new"

    static func url(since previous: String? = nil) -> String {
        var components = URLComponents()
        components.scheme = KlarSchemeHandler.scheme
        components.host = host
        if let previous {
            components.queryItems = [URLQueryItem(name: "since", value: previous)]
        }
        return components.string ?? "\(KlarSchemeHandler.scheme)://\(host)"
    }

    /// Whether `address` is a What's New page, whichever notes it shows.
    static func isPage(_ address: String) -> Bool {
        guard let components = URLComponents(string: address) else { return false }
        return components.scheme == KlarSchemeHandler.scheme && components.host == host
    }

    /// The notes for the page at `url`. One restored after a later update, with nothing newer than `since`
    /// left, shows the menu's.
    static func notes(for url: URL) -> ReleaseNotes? {
        let since = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "since" }?.value
        return since.flatMap { ReleaseNotes.since($0, upTo: Bundle.main.shortVersion) } ?? WhatsNew.menuNotes
    }

    static func html(for notes: ReleaseNotes?) -> String {
        var sections: [String] = []
        if let notes {
            if !notes.new.isEmpty {
                let features = notes.new.map { feature in
                    """
                    <li class="feature"><span class="tile">\(mask(symbol: feature.symbol))</span>\
                    <div><h3>\(escape(feature.title))</h3><p>\(escape(feature.detail))</p></div></li>
                    """
                }
                sections.append(section("New", "<ul class=\"features\">\(features.joined())</ul>"))
            }
            if !notes.improvements.isEmpty {
                sections.append(section("Improvements", bullets(notes.improvements)))
            }
            if !notes.fixes.isEmpty {
                sections.append(section("Fixes", bullets(notes.fixes)))
            }
        }
        if sections.isEmpty {
            sections.append("<p class=\"empty\">There are no notes for this version.</p>")
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>What’s New in Klar</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <header>
        \(KlarPage.logo)
        <div><p class="eyebrow">\(escape(versionLine(for: notes)))</p><h1>What’s New</h1></div>
        </header>
        \(sections.joined(separator: "\n"))
        </main>
        </body>
        </html>
        """
    }

    private static func versionLine(for notes: ReleaseNotes?) -> String {
        guard let notes else { return "Klar \(Bundle.main.shortVersion)" }
        if notes.isUnreleased { return "Not released yet" }
        if let earliest = notes.earliestVersion { return "Klar \(earliest) – \(notes.version)" }
        return "Klar \(notes.version)"
    }

    private static func section(_ title: String, _ content: String) -> String {
        "<section><h2 class=\"eyebrow\">\(escape(title))</h2>\(content)</section>"
    }

    /// Bullets sit in the symbols' column, so every line of text starts at the same edge.
    private static func bullets(_ lines: [String]) -> String {
        "<ul class=\"bullets\">\(lines.map { "<li>\(escape($0))</li>" }.joined())</ul>"
    }

    private static func escape(_ text: String) -> String {
        KlarPage.escape(text)
    }

    // MARK: - Images

    /// An SF Symbol, or nothing for a name macOS doesn't know.
    private static func mask(symbol name: String) -> String {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return "" }
        return "<span class=\"symbol\" style=\"-webkit-mask-image: url(\(KlarPage.maskURL(for: image, key: name, size: 20)))\"></span>"
    }

    // MARK: - Style

    private static let style = KlarPage.style + "\n" + """
    .symbol { display: block; width: 20px; height: 20px; background: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; }
    section { display: grid; gap: 18px; }
    section + section { margin-top: 44px; }
    ul { list-style: none; margin: 0; padding: 0; display: grid; }
    .features { gap: 22px; }
    .feature, .bullets li { display: grid; grid-template-columns: 40px minmax(0, 1fr); column-gap: 16px; }
    .tile {
      width: 40px; height: 40px; border-radius: 11px;
      display: grid; place-items: center;
      background: var(--tile);
      box-shadow: inset 0 0 0 0.5px var(--edge);
    }
    .feature h3 { margin: 0 0 3px; font-size: 15px; font-weight: 600; line-height: 1.35; }
    .feature p { margin: 0; color: var(--secondary); }
    .bullets { gap: 10px; }
    .bullets li::before { content: "•"; text-align: center; color: var(--secondary); }
    .empty { margin: 0; color: var(--secondary); }
    """
}
