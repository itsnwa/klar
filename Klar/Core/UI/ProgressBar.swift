import SwiftUI

struct FloatingProgressBar: View {
    let progress: Double
    let isVisible: Bool
    let barHeight: CGFloat = 4
    let barWidth: CGFloat = 50
    /// Whether the bar is up. Down out of sight, it would sit flush below the
    /// page's bottom edge, kept out only by the content area's clip: its
    /// shadow reached over that edge, and while the inset setting animated
    /// the clip, a pixel of its glass showed through. And glass follows its
    /// place in the window, so with the sidebar sliding, the bar's was worked
    /// out again on every frame. So once it has slid down, it's gone.
    @State private var isShown = false
    @EnvironmentObject private var spaceSelection: SpaceSelection
    @Environment(\.colorScheme) private var colorScheme

    private static let slide = Animation.spring(response: 0.4, dampingFraction: 0.8)

    var body: some View {
        ZStack {
            if isShown {
                bar
                    .offset(y: -24)
                    .transition(.offset(y: 24))
            }
        }
        .frame(width: barWidth + 12, height: barHeight + 12)
        .onAppear {
            withAnimation(Self.slide) {
                isShown = isVisible
            }
        }
        .onChange(of: isVisible) { _, newValue in
            withAnimation(Self.slide) {
                isShown = newValue
            }
        }
    }

    /// White on dark glass; on milky glass, where white doesn't show, the
    /// space's color. Not `.primary`: content on glass is drawn vibrant,
    /// which turns it light gray there.
    private var fill: Color {
        guard colorScheme == .light else { return .white }
        return spaceSelection.activeSpace?.color.color ?? Color(white: 0.25)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            // Progress fill
            Rectangle()
                .fill(fill)
                .frame(width: max(0, barWidth * progress), height: barHeight)
                .cornerRadius(barHeight / 2)

            // Remaining space
            Rectangle()
              .fill(fill.opacity(0.12))
              .frame(width: max(0, barWidth * (1 - progress)), height: barHeight)
              .cornerRadius(barHeight / 2)
        }
        .frame(width: barWidth + 12, height: barHeight + 12)
        .spaceGlass(in: RoundedRectangle(cornerRadius: (barHeight / 2) + 6))
        .glassEffectTransition(.identity)
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}
