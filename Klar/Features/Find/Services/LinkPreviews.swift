import Foundation
import ImageIO

/// What the link cards under an AI answer show of a page: its title, summary,
/// site name and sharing image, from its head. Only fetched as a card is
/// about to show, since the addresses are a model's (made up, or planted by
/// the page it read): in an ephemeral session without cookies, cache or
/// credentials, nothing kept on disk, and only web addresses on the internet
/// (`ExplorePreviews.isPublicWebAddress`, checked again on every redirect).
nonisolated enum LinkPreviews {
    nonisolated struct Content: Sendable {
        var title: String?
        var summary: String?
        var siteName: String?
        var image: Thumbnail?
    }

    /// A decoded image, made for one card
    nonisolated struct Thumbnail: @unchecked Sendable {
        let image: CGImage
    }

    /// A card's image in pixels, at 2x: what a thumbnail must cover
    static let imagePixelSize = CGSize(width: 2 * 184, height: 2 * 96)

    @concurrent
    static func content(for url: URL) async -> Content? {
        guard ExplorePreviews.isPublicWebAddress(url), let (html, base) = await head(of: url) else { return nil }
        let metadata = metadata(in: html, base: base)
        var content = Content(title: metadata.title, summary: metadata.summary, siteName: metadata.siteName)
        if let imageURL = metadata.imageURL, !Task.isCancelled {
            content.image = await thumbnail(at: imageURL)
        }
        return content
    }

    // MARK: Fetching

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: RedirectCheck(), delegateQueue: nil)
    }()

    /// Follows a redirect only to another public web address
    private nonisolated final class RedirectCheck: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(ExplorePreviews.isPublicWebAddress) == true ? request : nil)
        }
    }

    /// Enough of a page for its head, and no more
    private static let maximumHeadSize = 512 << 10

    private static let maximumImageSize = 8 << 20

    /// Narrower images are icons or tracking pixels
    private static let minimumImageWidth = 120

    /// The page's HTML up to the end of its head, and the address it ended up at
    private static func head(of url: URL) async -> (html: String, base: URL)? {
        var request = URLRequest(url: url)
        request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType.map({ $0.contains("html") }) ?? true else { return nil }

        let endOfHead = Data("</head".utf8)
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maximumHeadSize {
                    break
                }
                if data.count % 4096 == 0,
                   data.range(of: endOfHead, in: max(0, data.count - 4096 - endOfHead.count)..<data.count) != nil {
                    break
                }
            }
        } catch {
            return nil
        }
        return (decode(data, encodingName: response.textEncodingName), response.url ?? url)
    }

    private static func thumbnail(at url: URL) async -> Thumbnail? {
        guard ExplorePreviews.isPublicWebAddress(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count <= maximumImageSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width >= Double(minimumImageWidth), height > 0 else { return nil }

        // Just big enough to fill the card, decoded now rather than as it's drawn
        let scale = min(1, max(imagePixelSize.width / width, imagePixelSize.height / height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * scale).rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Thumbnail(image: image)
    }

    /// In the charset the server or the page names, else UTF-8
    private static func decode(_ data: Data, encodingName: String?) -> String {
        var name = encodingName
        if name == nil {
            let start = String(decoding: data.prefix(2048), as: UTF8.self)
            if let match = start.firstMatch(of: /(?i)<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)/) {
                name = String(match.output.1)
            }
        }
        if let name {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Metadata

    private nonisolated struct Metadata {
        var title: String?
        var summary: String?
        var siteName: String?
        var imageURL: URL?
    }

    /// From the page's meta tags: Open Graph's first, then Twitter's and
    /// plain HTML's.
    private static func metadata(in html: String, base: URL) -> Metadata {
        var tags: [String: String] = [:]
        for match in html.matches(of: /(?i)<meta\b[^>]*>/) {
            let tag = String(match.output)
            guard let key = (attribute("property", in: tag) ?? attribute("name", in: tag))?.lowercased(),
                  let content = attribute("content", in: tag), tags[key] == nil else { continue }
            tags[key] = cleaned(content)
        }
        func first(_ keys: String...) -> String? {
            keys.lazy.compactMap { tags[$0] }.first { !$0.isEmpty }
        }

        var title = first("og:title", "twitter:title")
        if title == nil, let match = html.firstMatch(of: /(?i)<title[^>]*>([^<]*)</) {
            title = cleaned(String(match.output.1))
        }
        let image = first("og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src")
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return Metadata(
            title: title.map { String($0.prefix(200)) },
            summary: first("og:description", "twitter:description", "description").map { String($0.prefix(300)) },
            siteName: first("og:site_name", "application-name"),
            imageURL: image
        )
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
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

    /// Entities decoded and whitespace collapsed
    private static func cleaned(_ text: String) -> String {
        decodingEntities(text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
    ]

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let afterAmpersand = rest.index(after: ampersand)
            if let semicolon = rest[afterAmpersand...].prefix(10).firstIndex(of: ";"),
               let decoded = entity(String(rest[afterAmpersand..<semicolon])) {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest[afterAmpersand...]
            }
        }
        return result + rest
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let number = name.dropFirst()
            let value = number.lowercased().hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name.lowercased()]
    }
}
