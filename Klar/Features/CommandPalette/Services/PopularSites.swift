import AppKit

/// Popular websites, so the palette can suggest one that isn't in history
/// yet as its address is typed ("wir" → wired.com).
///
/// The list (the `PopularSites` data asset, made by
/// `scripts/update_popular_sites.py`) is one host per line, best first. It's
/// kept as it's stored and searched with `memmem`, which finds a prefix's
/// best-ranked host in well under a millisecond and keeps the 42k hosts at
/// their 700 KB instead of a string each.
nonisolated enum PopularSites {
    /// The list with a newline in front, so every host follows one.
    private static let hosts: Data = {
        var data = Data([newline])
        if let asset = NSDataAsset(name: "PopularSites") {
            data.append(asset.data)
        } else {
            logError(.commandPalette, "Popular sites data asset is missing")
        }
        return data
    }()

    private static let newline = UInt8(ascii: "\n")

    /// The best-ranked site whose host starts with what's typed, with what
    /// was matched (the text without scheme and "www."). Nil for text that
    /// isn't the start of a host name, and for a single character unless it's
    /// a site's whole name (x → x.com).
    static func site(matching text: String) -> (host: String, prefix: String)? {
        guard let prefix = hostPrefix(of: text) else { return nil }
        // A whole host typed is that site, even if a longer one ranks higher.
        if prefix.contains("."), firstHost(after: "\n" + prefix + "\n") != nil {
            return (prefix, prefix)
        }
        guard prefix.count == 1 else {
            return firstHost(after: "\n" + prefix).map { ($0, prefix) }
        }
        // A letter's site is one named just that (x.com, t.me), not a subdomain.
        guard let host = firstHost(after: "\n" + prefix + "."),
              host.filter({ $0 == "." }).count == 1 else { return nil }
        return (host, prefix)
    }

    /// The best-ranked host whose line starts with `needle` (which starts
    /// with the newline before it).
    private static func firstHost(after needle: String) -> String? {
        let needle = Array(needle.utf8)
        return hosts.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress,
                  let found = memmem(base, buffer.count, needle, needle.count) else { return nil }
            let start = UnsafeRawPointer(found) + 1
            let bufferEnd = base + buffer.count
            let end = memchr(start, Int32(newline), bufferEnd - start).map { UnsafeRawPointer($0) } ?? bufferEnd
            return String(decoding: UnsafeRawBufferPointer(start: start, count: end - start), as: UTF8.self)
        }
    }

    /// The text as the start of a host name: lowercased, without scheme and
    /// "www.". Nil if it has anything a host name can't (spaces, a path).
    private static func hostPrefix(of text: String) -> String? {
        var prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where prefix.hasPrefix(scheme) {
            prefix.removeFirst(scheme.count)
        }
        if prefix.hasPrefix("www.") {
            prefix.removeFirst(4)
        }
        guard !prefix.isEmpty, !prefix.hasPrefix("."), !prefix.hasPrefix("-"),
              prefix.utf8.allSatisfy({ isHostCharacter($0) }) else { return nil }
        return prefix
    }

    private static func isHostCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }
}
