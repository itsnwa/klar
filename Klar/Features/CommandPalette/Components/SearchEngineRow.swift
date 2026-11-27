import SwiftUI

/// "Search YouTube for cats": text starting with a site shortcut's keyword.
struct SearchEngineRow: View {
    let shortcut: SiteShortcut
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            SiteShortcutIcon(shortcut: shortcut, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Search \(shortcut.name)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(shortcut.keyword)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? .white : shortcut.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background((isSelected ? Color.white : shortcut.color).opacity(0.15))
                        .cornerRadius(3)
                }

                Text("for \"\(SiteShortcuts.search(in: query)?.query ?? query)\"")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}

/// A site shortcut's icon: its preset's image, else the site's favicon.
struct SiteShortcutIcon: View {
    let shortcut: SiteShortcut
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = shortcut.preset?.icon {
                Image(icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                FaviconView(url: shortcut.homeURL, size: size, fallbackIcon: "magnifyingglass")
            }
        }
        .frame(width: size, height: size)
    }
}
