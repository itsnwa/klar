import AppKit

/// The pictures on Explore's pages, served by `KlarSchemeHandler` as the page loads them:
/// `klar://explore/preview?url=…`, the image a site gives for sharing a page (`og:image`, else
/// `twitter:image`), and `klar://explore/icon?url=…`, its icon from the favicon cache. Fetched as the
/// favicon cache fetches a front page: without cookies. Only web addresses on the internet: not
/// this Mac or the local network (`isPublicWebAddress`, checked again on every redirect), whatever the AI or
/// a page names. Images (and pages, when their headers allow) are cached in `Caches/Klar/ExplorePreviews`;
/// which image a page has is remembered for the launch. Images under 120 pixels wide (a tracking pixel,
/// an icon) are left out, as none is: a transparent pixel.
enum ExplorePreviews {
    static func isResource(_ url: URL) -> Bool {
        url.host == ExplorePage.host && (url.path == "/preview" || url.path == "/icon")
    }

    static func url(_ kind: String, for page: String) -> String {
        var components = URLComponents()
        components.scheme = KlarSchemeHandler.scheme
        components.host = ExplorePage.host
        components.path = "/\(kind)"
        components.queryItems = [URLQueryItem(name: "url", value: page)]
        return components.string ?? ""
    }

    /// What's served for a picture there's none of
    static let transparentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=") ?? Data()

    /// The picture at a resource address, or nil when there's none
    static func resource(at url: URL) async -> (data: Data, mimeType: String)? {
        guard let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        switch url.path {
        case "/icon": return await iconPNG(for: page).map { ($0, "image/png") }
        case "/preview": return await previewImage(forPage: page)
        default: return nil
        }
    }

    // MARK: - Icons

    private static func iconPNG(for page: String) async -> Data? {
        guard ExplorePage.isWebAddress(page), let image = await FaviconCacheManager.shared.getFavicon(for: page),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Previews

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klar/ExplorePreviews", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: directory)
        return URLSession(configuration: configuration, delegate: RedirectCheck(), delegateQueue: nil)
    }()

    /// Follows a redirect only to another public web address
    private nonisolated final class RedirectCheck: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(ExplorePreviews.isPublicWebAddress) == true ? request : nil)
        }
    }

    /// http or https, and not this Mac or the local network: no `localhost` or `.local` name, nor a loopback,
    /// private, link-local or shared address. A public name that resolves to one isn't caught.
    nonisolated static func isPublicWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")),
              !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || !host.contains(".") && !host.contains(":") {
            return false
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        if host.contains(":") {
            // IPv6: loopback, unspecified, unique local (fc00::/7), link-local (fe80::/10), mapped IPv4
            if host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
                || host.hasPrefix("::ffff:") {
                return false
            }
        }
        return true
    }

    /// Each page's image, nil for one with none
    private static var imageAddresses: [String: URL?] = [:]

    private static let maximumImageSize = 8 << 20

    private static let minimumImageWidth = 120

    private static func previewImage(forPage page: String) async -> (data: Data, mimeType: String)? {
        guard let address = await imageAddress(forPage: page), isPublicWebAddress(address) else { return nil }
        var request = URLRequest(url: address, cachePolicy: .returnCacheDataElseLoad)
        request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let mimeType = response.mimeType, mimeType.hasPrefix("image/"),
              data.count <= maximumImageSize,
              let width = NSBitmapImageRep(data: data)?.pixelsWide ?? NSImage(data: data).map({ Int($0.size.width) }),
              width >= minimumImageWidth else { return nil }
        return (data, mimeType)
    }

    private static func imageAddress(forPage page: String) async -> URL? {
        if let known = imageAddresses[page] { return known }
        guard let url = URL(string: page), isPublicWebAddress(url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let address: URL?
        if let (data, response) = try? await session.data(for: request),
           response.mimeType?.contains("html") ?? true {
            // The head is all it needs
            let html = String(decoding: data.prefix(400_000), as: UTF8.self)
            address = imageAddress(in: html, base: response.url ?? url)
        } else {
            address = nil
        }
        imageAddresses[page] = address
        return address
    }

    /// The page's sharing image, from its meta tags: Open Graph's first, then Twitter's.
    private nonisolated static func imageAddress(in html: String, base: URL) -> URL? {
        let wanted = ["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"]
        var found: [String: String] = [:]
        let tag = /<meta\b[^>]*>/.ignoresCase()
        for match in html.matches(of: tag) {
            let text = String(match.output)
            guard let key = attribute("property", in: text) ?? attribute("name", in: text),
                  wanted.contains(key.lowercased()),
                  let content = attribute("content", in: text), !content.isEmpty else { continue }
            if found[key.lowercased()] == nil {
                found[key.lowercased()] = content
            }
        }
        for key in wanted {
            guard let content = found[key] else { continue }
            let decoded = content
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: decoded, relativeTo: base)?.absoluteURL,
               let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                return url
            }
        }
        return nil
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }
}
