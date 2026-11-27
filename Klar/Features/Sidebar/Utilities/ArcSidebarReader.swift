import Foundation
import AppKit

/// Reads Arc's `StorableSidebar.json` into an `ImportedSidebar`. Arc doesn't
/// document it, so it's read loosely: what it doesn't recognize is left out
/// rather than failing.
///
/// The container with `spaces` has `items`, every sidebar item (tabs,
/// folders — `list` — and the containers themselves) with its `parentID`
/// and ordered `childrenIds`. A space names its pinned container in
/// `newContainerIDs` (`containerIDs` in older versions): pairs of a marker
/// (`{"pinned": {}}`, or the string `"pinned"`) and an item ID. The
/// favorites containers, one per profile, are in `topAppsContainerIDs`, as
/// pairs of a profile and an item ID. Arrays of objects with IDs are stored
/// as an ID followed by the object.
nonisolated enum ArcSidebarReader {
    enum ReadError: LocalizedError {
        case notFound
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notFound: return "Arc's sidebar wasn't found on this Mac."
            case .unreadable: return "This file isn't an Arc sidebar Klar can read."
            }
        }
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc/StorableSidebar.json")
    }

    static func read(from url: URL = defaultFileURL) throws -> ImportedSidebar {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReadError.notFound }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.unreadable
        }
        return try parse(root)
    }

    // MARK: - Parsing

    private static func parse(_ root: [String: Any]) throws -> ImportedSidebar {
        let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any] ?? []
        guard let container = containers.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else {
            throw ReadError.unreadable
        }

        var itemsByID: [String: [String: Any]] = [:]
        var itemOrder: [String] = []
        for case let item as [String: Any] in container["items"] as? [Any] ?? [] {
            guard let id = item["id"] as? String else { continue }
            itemsByID[id] = item
            itemOrder.append(id)
        }
        let reader = ItemReader(itemsByID: itemsByID, itemOrder: itemOrder)

        var untitledCount = 0
        var spaces: [ImportedSpace] = []
        for case let space as [String: Any] in container["spaces"] as? [Any] ?? [] {
            guard let id = space["id"] as? String else { continue }
            let title: String
            if let name = (space["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                title = name
            } else {
                untitledCount += 1
                title = "Space \(untitledCount)"
            }
            let containerIDs = (space["newContainerIDs"] as? [Any]) ?? (space["containerIDs"] as? [Any]) ?? []
            let items = containerID(marked: "pinned", in: containerIDs).map(reader.children) ?? []
            let customInfo = space["customInfo"] as? [String: Any]
            spaces.append(ImportedSpace(
                id: id,
                title: title,
                icon: icon(from: customInfo?["iconType"]),
                color: color(fromTheme: customInfo?["windowTheme"]),
                usesSeparateProfile: !isDefaultProfile(space["profile"]),
                items: items
            ))
        }

        // Every profile's favorites, the default profile's first, each URL once
        var favoriteContainers = (container["topAppsContainerIDs"] as? [Any] ?? []).compactMap { $0 as? String }
        if favoriteContainers.isEmpty {
            favoriteContainers = itemOrder.filter { id in
                let containerType = ((itemsByID[id]?["data"] as? [String: Any])?["itemContainer"] as? [String: Any])?["containerType"] as? [String: Any]
                return containerType?["topApps"] != nil
            }
        }
        var seenURLs: Set<String> = []
        var favorites: [ImportedTab] = []
        for containerID in favoriteContainers {
            for case .tab(let tab) in reader.children(of: containerID) where seenURLs.insert(tab.url).inserted {
                favorites.append(tab)
            }
        }

        return ImportedSidebar(source: .arc, spaces: spaces, favorites: favorites)
    }

    /// The item ID after `marker`, a string or the only key of an object.
    private static func containerID(marked marker: String, in pairs: [Any]) -> String? {
        for (index, entry) in pairs.enumerated() where index + 1 < pairs.count {
            let isMarker = (entry as? String) == marker || (entry as? [String: Any])?[marker] != nil
            if isMarker, let id = pairs[index + 1] as? String {
                return id
            }
        }
        return nil
    }

    private static func isDefaultProfile(_ profile: Any?) -> Bool {
        guard let profile = profile as? [String: Any] else { return true }
        return profile["custom"] == nil
    }

    private struct ItemReader {
        let itemsByID: [String: [String: Any]]
        let itemOrder: [String]

        /// The tabs and folders in a folder or container, in order: split
        /// views give their tabs, notes and easels (no address) nothing.
        func children(of parentID: String) -> [ImportedItem] {
            var visited: Set<String> = [parentID]
            return children(of: parentID, visited: &visited)
        }

        private func children(of parentID: String, visited: inout Set<String>) -> [ImportedItem] {
            var childIDs = itemsByID[parentID]?["childrenIds"] as? [String] ?? []
            if childIDs.isEmpty {
                childIDs = itemOrder.filter { itemsByID[$0]?["parentID"] as? String == parentID }
            }
            var result: [ImportedItem] = []
            for id in childIDs where visited.insert(id).inserted {
                guard let item = itemsByID[id] else { continue }
                let data = item["data"] as? [String: Any] ?? [:]
                let customTitle = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }

                if let tab = data["tab"] as? [String: Any] {
                    guard let url = tab["savedURL"] as? String, Self.isImportable(url) else { continue }
                    let savedTitle = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let title = savedTitle ?? customTitle ?? URL(string: url)?.host() ?? url
                    result.append(.tab(ImportedTab(url: url, title: title, customTitle: customTitle == title ? nil : customTitle)))
                } else if data["list"] != nil {
                    let items = children(of: id, visited: &visited)
                    result.append(.folder(title: customTitle ?? "Group", icon: nil, items: items))
                } else {
                    // A split view, or something newer: whatever tabs it holds
                    result.append(contentsOf: children(of: id, visited: &visited))
                }
            }
            return result
        }

        /// Web pages and files; not Arc's own pages.
        private static func isImportable(_ url: String) -> Bool {
            guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
            return ["http", "https", "file"].contains(scheme)
        }
    }

    // MARK: - Appearance

    /// An emoji (`emoji_v2`, or `emoji` as a code point in older versions),
    /// or Arc's icon if it's an SF Symbol's name too. Otherwise the letter.
    private static func icon(from iconType: Any?) -> SpaceIcon {
        guard let iconType = iconType as? [String: Any] else { return .letter }
        if let emoji = iconType["emoji_v2"] as? String, !emoji.isEmpty {
            return .icomoji(.emoji(emoji))
        }
        if let codePoint = (iconType["emoji"] as? NSNumber)?.uint32Value, let scalar = Unicode.Scalar(codePoint) {
            return .icomoji(.emoji(String(Character(scalar))))
        }
        if let name = iconType["icon"] as? String {
            for symbol in [name + ".fill", name] where NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                return .icomoji(.symbol(symbol))
            }
        }
        return .letter
    }

    /// The space color nearest to the theme's mid tone, or to the first
    /// color in it.
    private static func color(fromTheme theme: Any?) -> SpaceColor? {
        guard let theme = theme as? [String: Any] else { return nil }
        let midTone = (theme["primaryColorPalette"] as? [String: Any])?["midTone"]
        guard let rgb = rgbComponents(midTone) ?? firstRGB(in: theme) else { return nil }
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        guard color.saturationComponent > 0.15, color.brightnessComponent > 0.15 else { return .graphite }

        switch color.hueComponent * 360 {
        case 15..<40: return .orange
        case 40..<65: return .yellow
        case 65..<160: return .green
        case 160..<200: return .teal
        case 200..<255: return .blue
        case 255..<300: return .purple
        case 300..<345: return .pink
        default: return .red
        }
    }

    private static func rgbComponents(_ value: Any?) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let value = value as? [String: Any],
              let red = (value["red"] as? NSNumber)?.doubleValue,
              let green = (value["green"] as? NSNumber)?.doubleValue,
              let blue = (value["blue"] as? NSNumber)?.doubleValue else { return nil }
        // Extended sRGB can go past 0…1
        let clamp = { (component: Double) in CGFloat(min(max(component, 0), 1)) }
        return (clamp(red), clamp(green), clamp(blue))
    }

    private static func firstRGB(in value: Any) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        if let rgb = rgbComponents(value) { return rgb }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let rgb = firstRGB(in: dictionary[key]!) { return rgb }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let rgb = firstRGB(in: element) { return rgb }
            }
        }
        return nil
    }
}
