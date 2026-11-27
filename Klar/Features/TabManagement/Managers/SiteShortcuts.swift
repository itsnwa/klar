import SwiftUI
import Foundation

/// A word typed before a search that sends it to a site: "yt cats" searches
/// YouTube for "cats". Settings › Search, kept in `config.toml`'s
/// `[site_shortcuts]` and synced with the settings.
struct SiteShortcut: Codable, Hashable, Identifiable {
    /// Matched without regard to case; never contains whitespace.
    var keyword: String
    /// The site's search address, with `%s` where the words go.
    var url: String

    var id: String { keyword.lowercased() }

    static let placeholder = "%s"

    /// The address that searches for `query`.
    func searchURL(for query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? query
        return url.replacingOccurrences(of: Self.placeholder, with: encoded)
    }

    /// The site itself, for a shortcut used without words.
    var homeURL: String {
        guard let host = host else { return url }
        return "https://\(host)"
    }

    var host: String? {
        URLComponents(string: url.replacingOccurrences(of: Self.placeholder, with: Self.marker))?.host?.lowercased()
    }

    /// The preset for this shortcut's site: the same address, else the same host.
    var preset: SiteShortcutPreset? {
        if let preset = SiteShortcutPreset.all.first(where: { $0.url == url }) {
            return preset
        }
        guard let host = host.map(Self.bareHost) else { return nil }
        return SiteShortcutPreset.all.first { $0.shortcut.host.map(Self.bareHost) == host }
    }

    /// The preset's name, else the host without "www.".
    var name: String {
        preset?.name ?? host.map(Self.bareHost) ?? keyword
    }

    var color: Color {
        preset?.color ?? .accentColor
    }

    /// The words of a search on this site in `urlString`, if it is one: the
    /// value where `%s` is in the address (a query item, or part of the path).
    func query(in urlString: String) -> String? {
        guard let template = URLComponents(string: url.replacingOccurrences(of: Self.placeholder, with: Self.marker)),
              let components = URLComponents(string: urlString),
              let templateHost = template.host, let host = components.host,
              Self.bareHost(templateHost.lowercased()) == Self.bareHost(host.lowercased()) else { return nil }

        let words: String?
        if let item = template.queryItems?.first(where: { $0.value == Self.marker }) {
            guard Self.trimmedPath(components.path) == Self.trimmedPath(template.path) else { return nil }
            // As written in the address: decoded first, a "+" that was
            // searched for (%2B) is taken for the "+" that stands for a
            // space, and "c++" read back as "c".
            words = components.percentEncodedQueryItems?
                .first { ($0.name.removingPercentEncoding ?? $0.name) == item.name }?.value?
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
        } else if let range = template.path.range(of: Self.marker) {
            let prefix = template.path[..<range.lowerBound]
            let suffix = template.path[range.upperBound...]
            let path = components.path
            guard path.count > prefix.count + suffix.count,
                  path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
            words = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        } else {
            words = nil
        }

        guard let words = words?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        return words
    }

    /// The address up to the words, without the scheme or "www.": what
    /// history is searched for to find this site's searches.
    var searchPrefix: String {
        var prefix = url.components(separatedBy: Self.placeholder).first ?? url
        for scheme in ["https://", "http://"] where prefix.hasPrefix(scheme) {
            prefix.removeFirst(scheme.count)
        }
        if prefix.hasPrefix("www.") {
            prefix.removeFirst(4)
        }
        return prefix
    }

    // MARK: - Validation

    static func isValidKeyword(_ keyword: String) -> Bool {
        !keyword.isEmpty && !keyword.contains { $0.isWhitespace || $0 == "\"" || $0 == "=" }
    }

    static func isValidURL(_ url: String) -> Bool {
        guard url.contains(placeholder), !url.contains("\""), !url.contains(where: \.isWhitespace),
              let components = URLComponents(string: url.replacingOccurrences(of: placeholder, with: marker)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else { return false }
        return true
    }

    // MARK: - Helpers

    /// Stands in for `%s` while the address is parsed (`%s` isn't valid
    /// percent-encoding).
    private static let marker = "KLARSEARCHTERMS"

    /// Unreserved characters only, so "c++ & rust" stays one value.
    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func bareHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func trimmedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A site offered in Settings' Add menu. The first ones are what Klar starts
/// with (`defaults`).
struct SiteShortcutPreset: Identifiable {
    let name: String
    let keyword: String
    let url: String
    /// An image in the asset catalog, else the site's favicon is shown.
    let icon: String?
    let color: Color

    var id: String { url }

    var shortcut: SiteShortcut {
        SiteShortcut(keyword: keyword, url: url)
    }

    static let all: [SiteShortcutPreset] = [
        SiteShortcutPreset(name: "Google", keyword: "g", url: "https://www.google.com/search?q=%s", icon: "google", color: Color(.systemBlue)),
        SiteShortcutPreset(name: "DuckDuckGo", keyword: "ddg", url: "https://duckduckgo.com/?q=%s", icon: "duckduckgo", color: Color(.systemOrange)),
        SiteShortcutPreset(name: "GitHub", keyword: "gh", url: "https://github.com/search?q=%s", icon: "github", color: Color(.labelColor)),
        SiteShortcutPreset(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query=%s", icon: "youtube", color: Color(.systemRed)),
        SiteShortcutPreset(name: "Stack Overflow", keyword: "so", url: "https://stackoverflow.com/search?q=%s", icon: "stackoverflow", color: Color(.systemOrange)),
        SiteShortcutPreset(name: "Reddit", keyword: "rd", url: "https://www.reddit.com/search/?q=%s", icon: "reddit", color: Color(.systemOrange)),
        SiteShortcutPreset(name: "X", keyword: "x", url: "https://x.com/search?q=%s", icon: nil, color: Color(.labelColor)),
        SiteShortcutPreset(name: "Wikipedia", keyword: "w", url: "https://en.wikipedia.org/wiki/Special:Search?search=%s", icon: nil, color: Color(.labelColor)),
        SiteShortcutPreset(name: "Amazon", keyword: "amz", url: "https://www.amazon.com/s?k=%s", icon: nil, color: Color(.systemOrange)),
        SiteShortcutPreset(name: "Apple Maps", keyword: "maps", url: "https://maps.apple.com/?q=%s", icon: nil, color: Color(.systemGreen)),
        SiteShortcutPreset(name: "IMDb", keyword: "imdb", url: "https://www.imdb.com/find/?q=%s", icon: nil, color: Color(.systemYellow)),
        SiteShortcutPreset(name: "MDN", keyword: "mdn", url: "https://developer.mozilla.org/search?q=%s", icon: nil, color: Color(.labelColor)),
        SiteShortcutPreset(name: "npm", keyword: "npm", url: "https://www.npmjs.com/search?q=%s", icon: nil, color: Color(.systemRed)),
        SiteShortcutPreset(name: "Hacker News", keyword: "hn", url: "https://hn.algolia.com/?q=%s", icon: nil, color: Color(.systemOrange)),
        SiteShortcutPreset(name: "ChatGPT", keyword: "chat", url: "https://chatgpt.com/?q=%s", icon: nil, color: Color(.systemGreen)),
        SiteShortcutPreset(name: "Perplexity", keyword: "pplx", url: "https://www.perplexity.ai/search?q=%s", icon: nil, color: Color(.systemTeal)),
    ]

    /// What Klar starts with: the shortcuts it always had.
    static let defaults: [SiteShortcut] = all.prefix(8).map(\.shortcut)
}

/// Finding shortcuts in what's typed, and searches in addresses.
enum SiteShortcuts {
    static var all: [SiteShortcut] {
        TOMLSettingsManager.shared.siteShortcuts
    }

    static func shortcut(forKeyword keyword: String) -> SiteShortcut? {
        let keyword = keyword.lowercased()
        return all.first { $0.id == keyword }
    }

    /// The shortcut `text` starts with and the words after it: "yt cats".
    static func search(in text: String) -> (shortcut: SiteShortcut, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace),
              let shortcut = shortcut(forKeyword: String(trimmed[..<space])) else { return nil }
        let query = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return (shortcut, query)
    }

    /// The words and the site's name of a search in `url` on the default
    /// engine's site or a shortcut's: for titles in typed history.
    static func searchQuery(in url: String) -> (query: String, siteName: String)? {
        for engine in DefaultSearchEngine.allCases {
            if let query = engine.shortcut.query(in: url) {
                return (query, engine.displayName)
            }
        }
        for shortcut in all {
            if let query = shortcut.query(in: url) {
                return (query, shortcut.name)
            }
        }
        return nil
    }
}

extension DefaultSearchEngine {
    /// Its search address, as a shortcut without a keyword.
    var shortcut: SiteShortcut {
        switch self {
        case .duckduckgo: return SiteShortcut(keyword: "", url: "https://duckduckgo.com/?q=%s")
        case .google: return SiteShortcut(keyword: "", url: "https://www.google.com/search?q=%s")
        case .bing: return SiteShortcut(keyword: "", url: "https://www.bing.com/search?q=%s")
        case .yahoo: return SiteShortcut(keyword: "", url: "https://search.yahoo.com/search?p=%s")
        case .custom:
            // DuckDuckGo's until there's a valid address
            let url = TOMLSettingsManager.shared.customSearchEngineURL
            return SiteShortcut.isValidURL(url) ? SiteShortcut(keyword: "", url: url) : DefaultSearchEngine.duckduckgo.shortcut
        }
    }

    /// Its name in the palette ("Kagi Suggestions"): a custom engine's is
    /// its site's.
    var displayName: String {
        switch self {
        case .custom:
            let url = TOMLSettingsManager.shared.customSearchEngineURL
            return SiteShortcut.isValidURL(url) ? SiteShortcut(keyword: "", url: url).name : DefaultSearchEngine.duckduckgo.rawValue
        default:
            return rawValue
        }
    }

    func searchURL(for query: String) -> String {
        shortcut.searchURL(for: query)
    }

    /// Where suggestions for `query` come from: the engine's own service
    /// (OpenSearch suggestions, `[query, [suggestions…]]`), so only the
    /// engine chosen sees what's typed. Google's answers in ISO-8859-1
    /// unless asked for UTF-8 (`ie`, `oe`), which `JSONSerialization`
    /// can't read: "blåbær" got no suggestions.
    func suggestionsURL(for query: String) -> URL? {
        let template: String
        switch self {
        case .duckduckgo: template = "https://duckduckgo.com/ac/?q=%s&type=list"
        case .google: template = "https://suggestqueries.google.com/complete/search?output=toolbar&client=firefox&hl=en&ie=utf-8&oe=utf-8&q=%s"
        case .bing: template = "https://www.bing.com/osjson.aspx?query=%s&form=OSDJAS"
        case .yahoo: template = "https://search.yahoo.com/sugg/ff?output=fxjson&appid=ffd&command=%s"
        case .custom:
            // A site's own suggestion service isn't known: none, unless
            // it's still DuckDuckGo's search
            guard !SiteShortcut.isValidURL(TOMLSettingsManager.shared.customSearchEngineURL) else { return nil }
            return DefaultSearchEngine.duckduckgo.suggestionsURL(for: query)
        }
        return URL(string: SiteShortcut(keyword: "", url: template).searchURL(for: query))
    }
}
