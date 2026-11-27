import SwiftUI

struct CommandPaletteBreadcrumb: View {
    let frames: [PaletteSubviewFrame]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.4))
                }

                Text(frame.title)
                    .font(.system(size: 11, weight: index == frames.count - 1 ? .semibold : .medium))
                    .foregroundColor(index == frames.count - 1 ? .primary.opacity(0.85) : .primary.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
