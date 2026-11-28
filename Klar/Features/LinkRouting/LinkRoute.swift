import Foundation

/// A rule for links opened from other apps (Settings › Links): a link it
/// matches opens in its space. Routes are tried in order, the first that
/// matches wins (`LinkRouter`).
nonisolated struct LinkRoute: Codable, Hashable, Identifiable, Sendable {
    enum Match: String, Codable, CaseIterable, Sendable {
        /// The host is the pattern or a subdomain of it, `www.` aside
        case domain
        /// Anywhere in the address, ignoring case
        case contains
        /// The address starts with it, the scheme and `www.` aside
        case startsWith = "starts_with"
        /// The address is it, the scheme, `www.` and a trailing slash aside
        case equals
        /// A regular expression, anywhere in the whole address, ignoring case
        case regex

        var title: String {
            switch self {
            case .domain: "Domain is"
            case .contains: "Address contains"
            case .startsWith: "Address starts with"
            case .equals: "Address is"
            case .regex: "Address matches"
            }
        }

        var placeholder: String {
            switch self {
            case .domain: "github.com"
            case .contains: "figma"
            case .startsWith: "docs.google.com/spreadsheets"
            case .equals: "calendar.google.com"
            case .regex: #"^https://(www\.)?notion\.so/team-"#
            }
        }
    }

    var id: UUID = UUID()
    var match: Match
    /// Empty with an app: any link from it
    var pattern: String
    /// The bundle identifier of the app the link comes from; nil for any app
    var app: String?
    var spaceID: UUID

    /// Without the ID, which is only for lists: the same routes are the
    /// same in iCloud from every Mac.
    private enum CodingKeys: String, CodingKey {
        case match, pattern, app
        case spaceID = "space"
    }

    /// Whether a route can be saved: something to match, a pattern that
    /// makes sense for its kind.
    var isValid: Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return app != nil }
        switch match {
        case .domain: return Self.domain(from: pattern) != nil
        case .regex: return Self.regularExpression(pattern) != nil
        case .contains, .startsWith, .equals: return true
        }
    }

    func matches(_ url: URL, from sourceApp: String?) -> Bool {
        if let app, app.caseInsensitiveCompare(sourceApp ?? "") != .orderedSame {
            return false
        }
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return app != nil }

        switch match {
        case .domain:
            guard let domain = Self.domain(from: pattern),
                  let host = url.host(percentEncoded: false).map(Self.withoutWWW) else { return false }
            return host == domain || host.hasSuffix("." + domain)
        case .contains:
            return url.absoluteString.range(of: pattern, options: .caseInsensitive) != nil
                || (url.absoluteString.removingPercentEncoding?.range(of: pattern, options: .caseInsensitive) != nil)
        case .startsWith:
            return Self.comparable(url.absoluteString).hasPrefix(Self.comparable(pattern))
        case .equals:
            return Self.comparable(url.absoluteString) == Self.comparable(pattern)
        case .regex:
            guard let expression = Self.regularExpression(pattern) else { return false }
            let address = url.absoluteString
            return expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
    }

    // MARK: - Patterns

    /// The domain a `.domain` pattern names, typed as a host or as an
    /// address: lowercased, without `www.`.
    static func domain(from pattern: String) -> String? {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: text), let host = url.host(percentEncoded: false), url.scheme != nil {
            text = host
        } else if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<end])
        }
        // A wildcard written out is what a domain matches anyway
        if text.hasPrefix("*.") {
            text.removeFirst(2)
        }
        text = withoutWWW(text)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        // A port isn't part of the host matched
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        guard !text.isEmpty, !text.hasPrefix("."), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    static func regularExpression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func withoutWWW(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// An address as `startsWith` and `equals` compare it: lowercased,
    /// without its scheme, `www.` or trailing slashes.
    private static func comparable(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        text = withoutWWW(text)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}

/// Links wrapped in another site's redirect (a chat app's or a search
/// engine's link tracking, a mail filter's link check): the address they
/// lead to, which routes are matched against.
nonisolated enum LinkRedirects {
    struct Unwrapped: Equatable {
        /// Where the link leads
        let destination: URL
        /// Whether the redirect only tracks the click, so the tab can open
        /// the destination itself. A security check (a mail filter's
        /// time-of-click scan, a site's warning about unknown links) keeps
        /// loading, as its organization or site wants.
        let opensDirectly: Bool
    }

    private struct Redirector: Sendable {
        let matchesHost: @Sendable (String) -> Bool
        /// Paths it redirects from; nil for any
        let paths: Set<String>?
        /// The query parameters that hold the destination, tried in order
        let parameters: [String]
        let isSecurityCheck: Bool
    }

    private static let redirectors: [Redirector] = [
        // Slack
        Redirector(matchesHost: { $0 == "slack-redir.net" }, paths: ["/link"], parameters: ["url"], isSecurityCheck: false),
        // Google (search results, Gmail, Docs, Calendar)
        Redirector(matchesHost: isGoogle, paths: ["/url"], parameters: ["q", "url"], isSecurityCheck: false),
        // YouTube descriptions and comments
        Redirector(matchesHost: { $0 == "youtube.com" || $0 == "m.youtube.com" }, paths: ["/redirect"], parameters: ["q"], isSecurityCheck: false),
        // Meta's link shim
        Redirector(matchesHost: { ["l.facebook.com", "lm.facebook.com", "l.messenger.com"].contains($0) },
                   paths: ["/l.php"], parameters: ["u"], isSecurityCheck: false),
        Redirector(matchesHost: { ["l.instagram.com", "l.threads.net", "l.threads.com"].contains($0) },
                   paths: nil, parameters: ["u"], isSecurityCheck: false),
        // LinkedIn
        Redirector(matchesHost: { $0 == "linkedin.com" }, paths: ["/redir/redirect"], parameters: ["url"], isSecurityCheck: false),
        // Reddit
        Redirector(matchesHost: { $0 == "out.reddit.com" }, paths: nil, parameters: ["url"], isSecurityCheck: false),
        // Microsoft Safe Links (Outlook, Teams)
        Redirector(matchesHost: { $0.hasSuffix(".safelinks.protection.outlook.com") }, paths: nil, parameters: ["url"], isSecurityCheck: true),
        Redirector(matchesHost: { $0 == "statics.teams.cdn.office.net" }, paths: nil, parameters: ["url"], isSecurityCheck: true),
        // Steam's warning about links leaving it
        Redirector(matchesHost: { $0 == "steamcommunity.com" }, paths: ["/linkfilter", "/linkfilter/"], parameters: ["u", "url"], isSecurityCheck: true),
    ]

    @Sendable private static func isGoogle(_ host: String) -> Bool {
        // google.com, google.co.uk, google.no…
        let labels = host.split(separator: ".")
        return labels.first == "google" && (2...3).contains(labels.count)
    }

    /// The destination behind up to 3 redirects, or nil if `url` isn't one.
    static func unwrap(_ url: URL) -> Unwrapped? {
        var current = url
        var opensDirectly = true
        var found = false
        for _ in 0..<3 {
            guard let (next, isSecurityCheck) = destination(of: current) else { break }
            found = true
            current = next
            if isSecurityCheck {
                opensDirectly = false
            }
        }
        return found ? Unwrapped(destination: current, opensDirectly: opensDirectly) : nil
    }

    private static func destination(of url: URL) -> (URL, isSecurityCheck: Bool)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host(percentEncoded: false)?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let path = components.path.isEmpty ? "/" : components.path
        let items = components.queryItems ?? []

        for redirector in redirectors where redirector.matchesHost(host) {
            if let paths = redirector.paths, !paths.contains(path) { continue }
            for name in redirector.parameters {
                guard let value = items.first(where: { $0.name == name })?.value,
                      let destination = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let destinationScheme = destination.scheme?.lowercased(),
                      destinationScheme == "https" || destinationScheme == "http",
                      destination.host() != nil else { continue }
                return (destination, redirector.isSecurityCheck)
            }
        }
        return nil
    }
}
