import SwiftUI
import AppKit

// MARK: - Icon

/// What a space's button shows: the first letter of its name, or an
/// icomoji (a symbol, an emoji or one of Klar's own icons).
nonisolated enum SpaceIcon: Codable, Hashable {
    case letter
    case icomoji(Icomoji)

    /// The letter a space named `name` shows.
    static func firstLetter(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "S"
    }

    var isEmoji: Bool {
        if case .icomoji(.emoji) = self { return true }
        return false
    }

    var pickerChoice: IcomojiChoice {
        switch self {
        case .letter: return .letter
        case .icomoji(let icomoji): return .icomoji(icomoji)
        }
    }

    init(_ choice: IcomojiChoice) {
        switch choice {
        case .letter: self = .letter
        case .icomoji(let icomoji): self = .icomoji(icomoji)
        }
    }

    /// For menus: the icon, or the letter of `name`.
    func image(name: String, pointSize: CGFloat) -> NSImage? {
        switch self {
        case .letter:
            return Icomoji.textImage(Self.firstLetter(of: name), pointSize: pointSize, weight: .semibold, isTemplate: true)
        case .icomoji(let icomoji):
            return icomoji.image(pointSize: pointSize)
        }
    }

    // Stored as "letter", or as an icomoji is (also the iCloud field).
    var storageString: String {
        switch self {
        case .letter: return "letter"
        case .icomoji(let icomoji): return icomoji.stored
        }
    }

    init?(storageString: String) {
        guard !storageString.isEmpty else { return nil }
        if storageString == "letter" || storageString.hasPrefix("letter:") {
            self = .letter
        } else if storageString.hasPrefix("symbol:") {
            self = .icomoji(.symbol(String(storageString.dropFirst("symbol:".count))))
        } else if storageString.hasPrefix("emoji:") {
            self = .icomoji(.emoji(String(storageString.dropFirst("emoji:".count))))
        } else if CuratedFolderIcons.isRetiredBrandIcon(storageString) {
            // A brand icon Klar no longer has
            self = .letter
        } else {
            self = .icomoji(Icomoji(storageString))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let icon = SpaceIcon(storageString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown space icon \(string)")
        }
        self = icon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageString)
    }
}

// MARK: - Color

/// A space's color, from the system palette so it adapts to light and dark.
nonisolated enum SpaceColor: String, Codable, CaseIterable, Identifiable {
    case graphite, blue, teal, green, yellow, orange, red, pink, purple

    var id: String { rawValue }

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .teal: return .systemTeal
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .graphite: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// What `SpaceTint` lays over the window's material. Graphite darkens it
    /// in dark mode: system gray is lighter than the dark material there.
    var tintColor: Color {
        guard self == .graphite else { return color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .systemGray
        })
    }

    /// How strongly `SpaceTint` lays `tintColor` over the material. Graphite
    /// in dark mode goes further, to a charcoal sidebar.
    func tintOpacity(in colorScheme: ColorScheme) -> Double {
        guard colorScheme == .dark else { return 0.09 }
        return self == .graphite ? 0.38 : 0.12
    }

    /// The color's swatch in Settings: graphite shows the charcoal its tint
    /// gives the sidebar in dark mode, rather than system gray.
    var swatchColor: Color {
        guard self == .graphite else { return color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.21, alpha: 1) : .systemGray
        })
    }

    // Unknown colors (from a newer Klar on another Mac) fall back to blue.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpaceColor(rawValue: raw) ?? .blue
    }
}

// MARK: - Space

/// A space as the UI shows it: a snapshot of its collection.
struct Space: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var icon: SpaceIcon
    var color: SpaceColor
    var usesSeparateProfile: Bool
    var profileID: UUID?

    init(_ collection: SidebarCollection) {
        id = collection.id
        name = collection.displayTitle
        icon = collection.icon
        color = collection.color
        usesSeparateProfile = collection.usesSeparateProfile
        profileID = collection.profileID
    }
}

/// How a space's icon is drawn at `size`: its icomoji, or the first letter
/// of `name` (a name being typed, in Settings, so the letter follows it).
struct SpaceIconView: View {
    let icon: SpaceIcon
    let name: String
    var size: CGFloat = 15

    var body: some View {
        switch icon {
        case .letter:
            Text(SpaceIcon.firstLetter(of: name))
                .font(.system(size: size, weight: .semibold, design: .rounded))
        case .icomoji(let icomoji):
            IcomojiView(icomoji: icomoji, size: size)
        }
    }
}

// MARK: - Structure

nonisolated extension SidebarCollection {
    /// The space a new install starts with, and what the first collection
    /// of earlier versions becomes.
    static func makeDefaultSpace() -> SidebarCollection {
        SidebarCollection(title: "Personal", order: 0, icon: .icomoji(.symbol("house.fill")), color: .graphite)
    }
}

nonisolated extension SidebarStructure {
    /// The spaces in the order of their buttons.
    var orderedCollections: [SidebarCollection] {
        collections.values.sorted { ($0.order, $0.createdAt, $0.id.uuidString) < ($1.order, $1.createdAt, $1.id.uuidString) }
    }

    /// The space of a saved tab or folder.
    func collectionID(ofItem itemID: UUID) -> UUID? {
        tabs[itemID]?.collectionID ?? folders[itemID]?.collectionID
    }

    /// Puts a saved tab or folder, and everything in the folder, in `collectionID`.
    mutating func assignCollection(_ collectionID: UUID, toItemAndDescendants itemID: UUID) {
        var pending = [itemID]
        var seen: Set<UUID> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            if tabs[id] != nil {
                tabs[id]?.collectionID = collectionID
            } else if let folder = folders[id] {
                folders[id]?.collectionID = collectionID
                pending.append(contentsOf: folder.childrenIds)
            }
        }
    }

    /// Structures from before spaces (version 3): the "Saved Tabs"
    /// collection becomes the first space. Returns whether anything changed.
    mutating func migrateToSpaces() -> Bool {
        guard version < 4 else { return false }
        version = 4
        let defaultID = ensureDefaultCollection()
        if var first = collections[defaultID], first.title == "Saved Tabs", first.customTitle == nil {
            first.title = "Personal"
            first.icon = .icomoji(.symbol("house.fill"))
            collections[defaultID] = first
        }
        // Items that point at no collection were shown in the first one.
        for (id, tab) in tabs where tab.collectionID.flatMap({ collections[$0] }) == nil {
            tabs[id]?.collectionID = defaultID
        }
        for (id, folder) in folders where folder.collectionID.flatMap({ collections[$0] }) == nil {
            folders[id]?.collectionID = defaultID
        }
        lastUpdated = Date()
        return true
    }
}
