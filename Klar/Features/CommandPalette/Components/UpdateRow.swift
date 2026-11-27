import SwiftUI

/// Restart to Update, leading the palette once an update is ready (`AppUpdater`): Return or a click quits
/// Klar, installs the update and opens Klar again.
struct UpdateRow: View {
    let update: AppUpdater.Update
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image("logo")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(isSelected ? .white : .primary.opacity(0.85))
                .frame(width: 18, height: 18)
                .frame(width: 22, height: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Restart to Update")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    /// "Klar 1.3.6 · New: The same tabs everywhere"
    private var subtitle: String {
        guard let headline = update.headline else { return "\(update.name) is ready to install" }
        return "\(update.name) · New: \(headline)"
    }
}
