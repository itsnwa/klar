import SwiftUI

/// Offers My Card from Contacts under a name, email, phone or address box,
/// saying which parts of it would go into the form.
struct ContactCardPopoverView: View {
    let card: ContactCard
    /// e.g. ["name", "email"]
    let categories: [String]
    let onFill: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onFill) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text(card.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text("Fills your \(ListFormatter.localizedString(byJoining: categories))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .frame(width: 260)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }
}
