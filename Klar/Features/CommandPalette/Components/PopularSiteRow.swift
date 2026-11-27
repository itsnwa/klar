import SwiftUI

/// A popular site the typed text is the start of, not in history yet.
struct PopularSiteRow: View {
    let host: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Not cached yet, as the site hasn't been visited: downloaded.
            FaviconView(url: "https://\(host)", size: 22, fallbackText: host)

            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text("Suggested Site")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
    }
}
