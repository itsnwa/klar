import Foundation

nonisolated struct URLUtilities {
    // MARK: - Domain Extraction
    static func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }

    /// The registered domain, for telling a saved tab's site from another:
    /// the last two labels (`deel.com` for both `www.deel.com` and
    /// `app.deel.com`), or three when the last two are a multi-label public
    /// suffix like `co.uk`. An address without a host (`file:`) is its
    /// scheme, so local files count as one site.
    static func baseDomain(of urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return url.scheme.map { "\($0.lowercased()):" }
        }

        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }

        let lastTwo = parts.suffix(2).joined(separator: ".")
        if parts.count >= 3 && multiLabelPublicSuffixes.contains(lastTwo) {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "ac.uk", "gov.uk", "org.uk", "net.uk",
        "co.jp", "co.kr", "co.nz", "co.za", "co.in", "co.il",
        "com.au", "com.br", "com.cn", "com.mx", "com.tr", "com.tw", "com.sg", "com.hk"
    ]

    /// Both addresses are on the same base domain (`baseDomain(of:)`).
    static func isSameSite(_ url1: String, _ url2: String) -> Bool {
        guard let domain1 = baseDomain(of: url1),
              let domain2 = baseDomain(of: url2) else { return false }
        return domain1 == domain2
    }

    // MARK: - URL Formatting for Navigation
    @MainActor static func formatURLForNavigation(_ text: String) -> String {
        var formattedURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Don't format if URL is empty
        guard !formattedURL.isEmpty else { 
            return formattedURL
        }
        
        // Already an address: `chrome-extension://…/options.html` and
        // `blob:…` became `file:///chrome-extension://…` and
        // `https://blob:…` when read as a path or a host
        if addressScheme(of: formattedURL) != nil {
            return formattedURL
        }
        
        // Handle file paths that look like local paths (start with / or contain common file extensions)
        if formattedURL.hasPrefix("/") || (formattedURL.contains("/") &&
           (formattedURL.hasSuffix(".html") || formattedURL.hasSuffix(".htm") || 
            formattedURL.hasSuffix(".txt") || formattedURL.hasSuffix(".pdf") || 
            formattedURL.hasSuffix(".md") || formattedURL.hasSuffix(".js") || 
            formattedURL.hasSuffix(".css") || formattedURL.hasSuffix(".json"))) {
            return "file://" + (formattedURL.hasPrefix("/") ? "" : "/") + formattedURL
        }
        
        // Add protocol if missing
        if let search = SiteShortcuts.search(in: formattedURL) {
            // A site shortcut: "yt cats"
            formattedURL = search.shortcut.searchURL(for: search.query)
        } else if shouldAddProtocol(to: formattedURL) {
            // Looks like a URL (contains dots, IP patterns, or localhost).
            // This Mac and a device by its address (a dev server, a
            // router) rarely have a certificate: over HTTPS they only
            // gave the "Secure Connection Failed" page.
            let isLocal = isLocalhostPattern(formattedURL) || isIPAddressPattern(formattedURL)
            formattedURL = (isLocal ? "http://" : "https://") + formattedURL
        } else {
            // A search on the default search engine
            formattedURL = TOMLSettingsManager.shared.defaultSearchEngine.searchURL(for: formattedURL)
        }
        
        return formattedURL
    }

    /// The scheme of typed text that's an address already
    /// (`https://…`, `chrome-extension://…`, `data:…`, `mailto:…`), else
    /// nil. Not anything with a colon in it, which is all a URL needs to
    /// have a scheme: `localhost:3000` and `example.com:8080` are a host
    /// and its port, and `site:reddit.com klar` or a pasted `TypeError: …`
    /// a search (spaces are only in an address after `://`, pasted). Nor
    /// `javascript:`, which would run in the page.
    static func addressScheme(of text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: text)?.scheme else { return nil }
        let lowercased = scheme.lowercased()
        guard lowercased != "javascript" else { return nil }
        guard text.dropFirst(scheme.count + 1).hasPrefix("//") || !text.contains(where: \.isWhitespace) else { return nil }
        // A host and its port: what's read as the scheme is a host's name,
        // and after it come digits
        if lowercased == "localhost" || scheme.contains(".") {
            let port = text.dropFirst(scheme.count + 1).prefix { !"/?#".contains($0) }
            if !port.isEmpty, port.count <= 5, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) {
                return nil
            }
        }
        return lowercased
    }
    
    // MARK: - URL Display Cleaning
    /// Clean URL for display - removes protocol and www prefix
    static func cleanURL(_ url: String) -> String {
        var cleanedURL = url
        if cleanedURL.hasPrefix("https://") {
            cleanedURL = String(cleanedURL.dropFirst(8))
        } else if cleanedURL.hasPrefix("http://") {
            cleanedURL = String(cleanedURL.dropFirst(7))
        }
        if cleanedURL.hasPrefix("www.") {
            cleanedURL = String(cleanedURL.dropFirst(4))
        }
        
        // Remove trailing slash from domain-only URLs (but keep for actual paths)
        if cleanedURL.hasSuffix("/") && !cleanedURL.dropLast().contains("/") {
            cleanedURL = String(cleanedURL.dropLast())
        }
        
        return cleanedURL
    }
    
    // MARK: - Tracking Parameter Removal
    /// Remove tracking parameters and return both the clean URL and whether trackers were detected
    static func removeTrackingParameters(from urlString: String) -> (cleanURL: String, trackersDetected: Bool) {
        // The parameters as they're written in the address: `queryItems`
        // decodes them, and written back a `%2B` came out as a `+`, which
        // servers read as a space.
        guard let url = URL(string: urlString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.percentEncodedQueryItems, !queryItems.isEmpty else {
            return (urlString, false)
        }

        let siteParameters = siteTrackingParameters(forHost: components.host)
        let cleanQueryItems = queryItems.filter { queryItem in
            let name = (queryItem.name.removingPercentEncoding ?? queryItem.name).lowercased()
            return !trackingParameters.contains(name) && !siteParameters.contains(name)
        }

        // Nothing to remove: the address as it is, not as written out again.
        guard cleanQueryItems.count < queryItems.count else {
            return (urlString, false)
        }

        components.percentEncodedQueryItems = cleanQueryItems.isEmpty ? nil : cleanQueryItems
        return (components.url?.absoluteString ?? urlString, true)
    }

    /// Lowercase names of parameters that only ever track, on any site.
    /// Built once: the check runs for every query parameter of every saved
    /// tab on each save. This runs on every address Klar keeps (the session,
    /// saved tabs, iCloud), so a name that's part of the address on some
    /// sites isn't here: `list` (a YouTube playlist), `t` (where a video
    /// starts, a forum's topic), `s` (a WordPress search), `cid` (a place
    /// on Google Maps) and the like were, and saved tabs lost them.
    private static let trackingParameters: Set<String> = [
            // Google Analytics & Google Ads
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "srsltid",
            "gclid", "gclsrc", "dclid", "wbraid", "gbraid",

            // Facebook/Meta
            "fbclid", "fb_action_ids", "fb_action_types", "fb_ref", "fb_source",

            // Amazon
            "ascsubtag",

            // General tracking
            "click_id", "clickid", "tracking_id", "trackingid", "affiliate_id",
            "campaign_id", "campaignid",

            // Social media
            "ig_rid", "igshid", "twclid",

            // Email marketing
            "mc_cid", "mc_eid", "mlid", "email_source", "email_campaign",

            // Microsoft/Bing
            "msclkid", "msclkid2",

            // Adobe
            "s_cid", "s_tnt", "s_kwcid",

            // Other common tracking
            "icid", "ncid", "sr_share", "at_medium", "at_campaign",
            "spm", "vn_medium", "vn_source", "vn_campaign", "vn_term", "vn_content",

            // Reddit
            "rdt_cid", "ref_source", "ref_campaign",

            // LinkedIn
            "trk", "trkinfo", "li_source", "li_medium",

            // Twitter/X
            "refsrc",

            // TikTok
            "is_copy_url", "is_from_webapp", "sender_device", "sender_web_id",

            // General session tracking
            "_ga", "_gl", "_gd"
        ]

    /// Names that track on one site and mean something else on others,
    /// removed only on the site that tracks with them.
    private static func siteTrackingParameters(forHost host: String?) -> Set<String> {
        guard var host = host?.lowercased() else { return [] }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        if host.hasPrefix("amazon.") || host.contains(".amazon.") {
            return ["ref", "ref_", "tag", "linkcode", "creative", "creativeasin"]
        }
        switch host {
        case "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be":
            return ["si", "feature"]
        case "twitter.com", "mobile.twitter.com", "x.com":
            return ["s", "t", "cn", "ref_src"]
        case "open.spotify.com":
            return ["si"]
        default:
            return []
        }
    }
    
    // MARK: - URL Validation
    static func isValidURL(_ string: String) -> Bool {
        if let url = URL(string: string) {
            // Allow file:// URLs even without a host
            if url.scheme == "file" {
                return true
            }
            return url.scheme != nil && url.host != nil
        }
        return false
    }
    
    /// Check if we should add a protocol to the given text
    private static func shouldAddProtocol(to text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // No spaces allowed in URLs
        guard !trimmed.contains(" ") else { return false }
        
        // Check for localhost patterns
        if isLocalhostPattern(trimmed) {
            return true
        }
        
        // Check for IP address patterns
        if isIPAddressPattern(trimmed) {
            return true
        }
        
        // Check for domain patterns (contains dots)
        if trimmed.contains(".") {
            return true
        }
        
        return false
    }
    
    /// Check if text is a localhost pattern (with optional port/path)
    private static func isLocalhostPattern(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased == "localhost" || 
               lowercased.hasPrefix("localhost:") || 
               lowercased.hasPrefix("localhost/")
    }
    
    /// Check if text is an IP address pattern (with optional port/path)
    private static func isIPAddressPattern(_ text: String) -> Bool {
        // Extract the host part (before any path)
        let pathComponents = text.components(separatedBy: "/")
        let hostPart = pathComponents.first ?? ""
        
        // Extract the IP part (before any port)
        let hostComponents = hostPart.components(separatedBy: ":")
        let ipPart = hostComponents.first ?? ""
        
        // Simple IPv4 validation
        let components = ipPart.components(separatedBy: ".")
        guard components.count == 4 else { return false }
        
        for component in components {
            guard let number = Int(component),
                  number >= 0 && number <= 255,
                  (component == "0" || !component.hasPrefix("0")) else {
                return false
            }
        }
        
        // If there's a port, validate it
        if hostComponents.count == 2 {
            let portPart = hostComponents[1]
            guard let port = Int(portPart), port >= 1 && port <= 65535 else {
                return false
            }
        }
        
        return true
    }
} 
