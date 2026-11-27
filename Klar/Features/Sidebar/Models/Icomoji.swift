import SwiftUI
import AppKit

/// An icon from the icomoji picker, used by folders and spaces: an SF
/// Symbol, one of Klar's own icons (the `brand-…` images in the asset
/// catalog), or an emoji. Stored as a plain string, as folder icons always
/// have been: the symbol's or image's name, or the emoji itself.
nonisolated enum Icomoji: Hashable {
    case symbol(String)
    case custom(String)
    case emoji(String)

    init(_ stored: String) {
        let stored = CuratedFolderIcons.renamedBrandIcons[stored] ?? stored
        // A retired brand icon stays one, with no image: a group shows its
        // favicons, a space its letter (`SpaceIcon`)
        if CuratedFolderIcons.isBrandIcon(stored) || stored.hasPrefix("brand-") {
            self = .custom(stored)
        } else if stored.unicodeScalars.contains(where: { !$0.isASCII }) {
            // Symbol and image names are ASCII; anything else is an emoji.
            self = .emoji(stored)
        } else {
            self = .symbol(stored)
        }
    }

    var stored: String {
        switch self {
        case .symbol(let value), .custom(let value), .emoji(let value): return value
        }
    }

    /// For AppKit: a symbol or Klar icon as a template image, an emoji in color.
    func image(pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        switch self {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        case .custom(let name):
            guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
            image.size = NSSize(width: pointSize + 2, height: pointSize + 2)
            image.isTemplate = true
            return image
        case .emoji(let emoji):
            return Self.textImage(emoji, pointSize: pointSize)
        }
    }

    /// Text drawn into an image: an emoji, or a space's letter.
    static func textImage(_ text: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, isTemplate: Bool = false) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pointSize, weight: weight)
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { rect in
            string.draw(in: rect, withAttributes: attributes)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    var kind: Kind {
        switch self {
        case .symbol: return .symbol
        case .custom: return .custom
        case .emoji: return .emoji
        }
    }

    enum Kind: CaseIterable {
        case symbol
        case emoji
        case custom
    }
}

// MARK: - Catalog

/// One of the icomoji picker's choices, with the name it's shown and
/// searched by.
nonisolated struct IcomojiItem: Hashable {
    let icomoji: Icomoji
    /// "Newspaper", "Grinning face", "Swift".
    let name: String
    /// The name, its group's title and the symbol's own name, lowercased.
    let searchText: String
}

/// A group of the picker's: Work & Money, Smileys, Languages…
nonisolated struct IcomojiCategory: Identifiable {
    let title: String
    /// The symbol of its button in the picker's bar.
    let symbol: String
    let items: [IcomojiItem]
    var id: String { title }
}

nonisolated extension Icomoji {
    static func categories(of kind: Kind) -> [IcomojiCategory] {
        switch kind {
        case .symbol: return symbolCategories
        case .emoji: return emojiCategories
        case .custom: return customCategories
        }
    }

    /// The curated SF Symbols, by group. Not the plain folder: on a folder it
    /// means no icon, which looks like nothing was picked.
    static let symbolCategories: [IcomojiCategory] = CuratedFolderIcons.symbolGroups.map { group in
        IcomojiCategory(title: group.title, symbol: group.symbol, items: group.names.map { name in
            let words = name.split(separator: ".").filter { $0 != "fill" && $0 != "inverse" }.joined(separator: " ")
            return IcomojiItem(icomoji: .symbol(name), name: words.capitalizingFirstLetter,
                               searchText: "\(words) \(group.title) \(name)".lowercased())
        })
    }

    /// Klar's own icons, by group.
    static let customCategories: [IcomojiCategory] = CuratedFolderIcons.brandGroups.map { group in
        IcomojiCategory(title: group.title, symbol: group.symbol, items: group.names.map { name in
            let brand = String(name.dropFirst("brand-".count))
            return IcomojiItem(icomoji: .custom(name), name: brand.capitalizingFirstLetter,
                               searchText: "\(brand) \(group.title)".lowercased())
        })
    }

    /// Emoji in Unicode's groups and order (the `EmojiCatalog` data asset,
    /// made by `scripts/update_emoji_catalog.py`: a "# Group" line, then
    /// "emoji<tab>name" lines), without skin tones, which can still be typed
    /// into the search.
    static let emojiCategories: [IcomojiCategory] = {
        guard let asset = NSDataAsset(name: "EmojiCatalog"),
              let text = String(data: asset.data, encoding: .utf8) else {
            logError(.sidebar, "Emoji catalog data asset is missing")
            return []
        }
        var categories: [IcomojiCategory] = []
        var title: String?
        var items: [IcomojiItem] = []
        func close() {
            if let title, !items.isEmpty {
                categories.append(IcomojiCategory(title: title, symbol: emojiGroupSymbols[title] ?? "face.smiling", items: items))
            }
            items = []
        }
        for line in text.split(separator: "\n") {
            // The keycap "#️⃣" starts with "#" too, but every emoji has a tab.
            if let tab = line.firstIndex(of: "\t") {
                let name = String(line[line.index(after: tab)...])
                items.append(IcomojiItem(icomoji: .emoji(String(line[..<tab])), name: name.capitalizingFirstLetter,
                                         searchText: "\(name) \(title ?? "")".lowercased()))
            } else if line.hasPrefix("# ") {
                close()
                title = String(line.dropFirst(2))
            }
        }
        close()
        return categories
    }()

    private static let emojiGroupSymbols: [String: String] = [
        "Smileys": "face.smiling",
        "People": "hand.wave.fill",
        "Animals & Nature": "pawprint.fill",
        "Food & Drink": "fork.knife",
        "Travel & Places": "car.fill",
        "Activities": "soccerball",
        "Objects": "lightbulb.fill",
        "Symbols": "heart.fill",
        "Flags": "flag.fill"
    ]

    /// Every choice by its stored value, for the names of recent ones.
    private static let itemsByStored: [String: IcomojiItem] = {
        var items: [String: IcomojiItem] = [:]
        for kind in Kind.allCases {
            for category in categories(of: kind) {
                for item in category.items where items[item.icomoji.stored] == nil {
                    items[item.icomoji.stored] = item
                }
            }
        }
        return items
    }()

    /// This icomoji's place in the catalog; an emoji typed into the search
    /// that isn't in it gets one of its own.
    var item: IcomojiItem {
        if let item = Self.itemsByStored[stored] { return item }
        let name = stored.unicodeScalars.first?.properties.name?.lowercased() ?? stored
        return IcomojiItem(icomoji: self, name: name.capitalizingFirstLetter, searchText: name)
    }

    // MARK: - Recents

    private static let recentsKey = "IcomojiRecents"
    private static let recentsLimit = 32

    /// The icomoji picked last, most recent first.
    static var recents: [Icomoji] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .filter { !CuratedFolderIcons.isRetiredBrandIcon($0) }
            .map(Icomoji.init)
    }

    static func addRecent(_ icomoji: Icomoji) {
        var stored = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        stored.removeAll { $0 == icomoji.stored }
        stored.insert(icomoji.stored, at: 0)
        UserDefaults.standard.set(Array(stored.prefix(recentsLimit)), forKey: recentsKey)
    }
}

private extension String {
    nonisolated var capitalizingFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// An icomoji in SwiftUI at `size` points.
struct IcomojiView: View {
    let icomoji: Icomoji
    var size: CGFloat = 15

    var body: some View {
        switch icomoji {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
        case .custom(let name):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size + 1, height: size + 1)
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size + 1))
        }
    }
}
