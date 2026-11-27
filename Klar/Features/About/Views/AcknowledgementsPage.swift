import AppKit

/// Klar's acknowledgements as a page in a tab, `klar://acknowledgements` (`KlarSchemeHandler`), opened from About
/// Klar (`AboutView`): Klar's copyright and license, then what it's built on, each with its license (Sparkle,
/// Simple Icons' brand icons, Unicode's emoji data, the Chrome UX Report and Tranco for the popular sites), and a
/// note on trademarks. The licenses whose text has to go with the app (the GPL, Sparkle's, Unicode's) are data
/// assets in the asset catalog's Acknowledgements folder, each shown in a disclosure; the brand icons' credits are
/// written there by scripts/update_brand_icons.py, and only those with a license of their own are listed. Each
/// section has an anchor (`#klar` for Klar's license).
enum AcknowledgementsPage {
    static let host = "acknowledgements"

    static func url(section: String? = nil) -> String {
        "\(KlarSchemeHandler.scheme)://\(host)" + (section.map { "#\($0)" } ?? "")
    }

    static func isPage(_ address: String) -> Bool {
        guard let components = URLComponents(string: address) else { return false }
        return components.scheme == KlarSchemeHandler.scheme && components.host == host
    }

    /// In a new tab in the browser window in front, or its tab there that already shows the page.
    static func show(section: String? = nil) {
        BrowserWindow.perform { session in
            session.tabManager.showKlarPage(url(section: section), where: isPage)
        }
    }

    static func html() -> String {
        let sections = [klar, sparkle, brandIcons, emoji, popularSites, trademarks].compactMap { $0 }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>Acknowledgements</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <header>
        \(KlarPage.logo)
        <div><p class="eyebrow">Klar \(escape(Bundle.main.shortVersion))</p><h1>Acknowledgements</h1></div>
        <p class="lede">Klar is free software, and it’s built on the work of the people and projects below. Thank you.</p>
        </header>
        \(sections.joined(separator: "\n"))
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Sections

    private static var klar: String {
        section("klar", "Klar", """
        <p>\(escape(Bundle.main.copyright))</p>
        <p>Klar is free software: you can redistribute it and change it under the terms of the GNU General Public \
        License, version 3, as published by the Free Software Foundation. It’s distributed in the hope that it will \
        be useful, but without any warranty, not even the implied warranty of merchantability or fitness for a \
        particular purpose. See the license for details.</p>
        <p>The Klar name and app icon aren’t covered by the license: a modified version you distribute needs a name \
        and icon of its own.</p>
        <p class="links">\(link(AboutView.sourceCode, "Source code"))\(link(AboutView.website, "klarbrowser.com"))</p>
        \(licenseText("License-GPL", title: "GNU General Public License v3.0"))
        """)
    }

    private static var sparkle: String {
        section("sparkle", "Sparkle", """
        <p>Klar’s updates are delivered by \(link("https://sparkle-project.org", "Sparkle")), under the MIT License, \
        with the code it includes from bsdiff, sais-lite and Ed25519 under their own licenses.</p>
        \(licenseText("License-Sparkle", title: "Sparkle’s license"))
        """)
    }

    /// Simple Icons is CC0; the icons with a license of their own are listed with it.
    private static var brandIcons: String? {
        guard let data = NSDataAsset(name: "BrandIconCredits")?.data,
              let credits = try? JSONDecoder().decode(BrandIconCredits.self, from: data) else { return nil }
        let rows = credits.icons.filter { $0.license != nil }.map { icon in
            let license = icon.licenseURL.map { link($0, icon.license ?? "") } ?? escape(icon.license ?? "")
            return "<tr><td>\(escape(icon.brand))</td><td>\(license)</td><td>\(link(icon.source, host(of: icon.source)))</td></tr>"
        }
        var content = """
        <p>The brand icons you can give a group or space are from \(link("https://simpleicons.org", "Simple Icons")) \
        \(escape(credits.version)), released under \
        \(link("https://creativecommons.org/publicdomain/zero/1.0/", "CC0 1.0")).
        """
        if !rows.isEmpty {
            content += """
             These are available under a license of their own:</p>
            <table>
            <thead><tr><th>Brand</th><th>License</th><th>Source</th></tr></thead>
            <tbody>\(rows.joined())</tbody>
            </table>
            """
        } else {
            content += "</p>"
        }
        return section("brand-icons", "Brand icons", content)
    }

    private static var emoji: String {
        section("emoji", "Emoji", """
        <p>The emoji picker’s names, groups and order are from \
        \(link("https://unicode.org/emoji/", "Unicode’s emoji data")), under the Unicode License v3.</p>
        \(licenseText("License-Unicode", title: "Unicode License v3"))
        """)
    }

    private static var popularSites: String {
        section("popular-sites", "Popular sites", """
        <p>The sites the command palette suggests as you type their address are the top 50,000 of the \
        \(link("https://developer.chrome.com/docs/crux", "Chrome UX Report")) by Google, licensed under \
        \(link("https://creativecommons.org/licenses/by/4.0/", "CC BY 4.0")), ranked by \
        \(link("https://tranco-list.eu", "Tranco")), with adult sites left out.</p>
        """)
    }

    private static var trademarks: String {
        section("trademarks", "Trademarks", """
        <p>Brand names and logos, including the brand icons and the AI and search providers’ logos in Settings, \
        are trademarks of their owners. Showing them doesn’t imply any affiliation with or endorsement by those \
        owners.</p>
        """)
    }

    // MARK: - Parts

    private static func section(_ id: String, _ title: String, _ content: String) -> String {
        "<section id=\"\(id)\"><h2 class=\"eyebrow\">\(escape(title))</h2>\(content)</section>"
    }

    /// A license's full text, from its data asset, folded away until opened.
    private static func licenseText(_ asset: String, title: String) -> String {
        guard let data = NSDataAsset(name: asset)?.data else { return "" }
        return "<details><summary>\(escape(title))</summary><pre>\(escape(String(decoding: data, as: UTF8.self)))</pre></details>"
    }

    private static func link(_ address: String, _ text: String) -> String {
        "<a href=\"\(escape(address))\">\(escape(text))</a>"
    }

    /// The host a source link is shown as, without "www.".
    private static func host(of address: String) -> String {
        guard let host = URL(string: address)?.host() else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func escape(_ text: String) -> String {
        KlarPage.escape(text)
    }

    /// scripts/update_brand_icons.py's `BrandIconCredits` data asset.
    private struct BrandIconCredits: Decodable {
        struct Icon: Decodable {
            let name: String
            let brand: String
            let license: String?
            let licenseURL: String?
            let source: String
        }

        let version: String
        let icons: [Icon]
    }

    // MARK: - Style

    private static let style = KlarPage.style + "\n" + """
    .lede { margin: 0; max-width: 44ch; font-size: 15px; color: var(--secondary); }
    section { display: grid; gap: 14px; scroll-margin-top: 48px; }
    section + section { margin-top: 44px; }
    p { margin: 0; }
    a {
      color: inherit;
      text-decoration: underline;
      text-decoration-thickness: 1px;
      text-decoration-color: var(--secondary);
      text-underline-offset: 2.5px;
    }
    a:hover { text-decoration-color: currentColor; }
    .links { display: flex; flex-wrap: wrap; gap: 6px 20px; }
    details {
      border-radius: 12px;
      background: var(--tile);
      box-shadow: inset 0 0 0 0.5px var(--edge);
    }
    summary {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 11px 16px;
      list-style: none;
      font-weight: 550;
      cursor: default;
    }
    summary::-webkit-details-marker { display: none; }
    summary::before {
      content: "";
      width: 6px;
      height: 6px;
      margin: 0 1px 0 -1px;
      border-right: 1.5px solid var(--secondary);
      border-bottom: 1.5px solid var(--secondary);
      transform: rotate(-45deg);
      transition: transform 0.15s;
    }
    details[open] summary::before { transform: rotate(45deg); }
    pre {
      margin: 0;
      padding: 2px 16px 16px;
      max-height: 420px;
      overflow: auto;
      white-space: pre-wrap;
      font: 11.5px/1.55 ui-monospace, "SF Mono", Menlo, monospace;
      color: var(--secondary);
    }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th {
      padding: 0 12px 8px 0;
      text-align: left;
      font: 500 11px/1.3 ui-monospace, "SF Mono", Menlo, monospace;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--secondary);
    }
    td { padding: 7px 12px 7px 0; border-top: 0.5px solid var(--edge); vertical-align: top; }
    th:last-child, td:last-child { padding-right: 0; }
    td:nth-child(2), td:nth-child(3) { color: var(--secondary); }
    """
}
