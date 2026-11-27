import SwiftUI

struct ReadingListSuggestionRow: View {
    let item: ReadingListItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            FaviconView.commandPalette(url: item.url)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.isUnread {
                        Circle()
                            .fill(isSelected ? Color.white : Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                }

                Text(URLUtilities.cleanURL(item.url))
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            // "Reading List" token, mirroring the breadcrumb token used by saved tabs.
            HStack(spacing: 4) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 9, weight: .medium))
                Text("Reading List")
            }
            .font(.system(size: 10))
            .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
    }
}
