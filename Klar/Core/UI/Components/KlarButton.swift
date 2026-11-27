import SwiftUI

/// Unified button component for Klar that can be used as either a title bar button or compact button
/// while maintaining consistent look and feel across the app
struct KlarButton<Content: View>: View {
    enum Style {
        case titleBar
        case compact

        var size: CGFloat {
            switch self {
            case .titleBar: return 28
            case .compact: return 16
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .titleBar: return TitleBarHoverBackground.cornerRadius
            case .compact: return 8
            }
        }
    }

    let style: Style
    let action: () -> Void
    let content: () -> Content
    @State private var isHovering = false
    /// A disabled button doesn't light up on hover
    @Environment(\.isEnabled) private var isEnabled

    init(style: Style, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: style.size, height: style.size)
                .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                .background {
                    switch style {
                    case .titleBar:
                        TitleBarHoverBackground(isHovering: isHovering && isEnabled)
                    case .compact:
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .fill(Color.primary.opacity(isHovering && isEnabled ? 0.1 : 0))
                    }
                }
                .onHover { hovering in
                    // Only animate if state actually changes to reduce CPU usage
                    if isHovering != hovering {
                        withAnimation(TitleBarHoverBackground.animation) {
                            isHovering = hovering
                        }
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience Extensions

extension KlarButton {
    /// Creates a title bar button - a 28px square
    static func titleBar(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) -> KlarButton {
        KlarButton(style: .titleBar, action: action, content: content)
    }

    /// Creates a compact button - smaller 16x16px size perfect for sidebar usage
    static func compact(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) -> KlarButton {
        KlarButton(style: .compact, action: action, content: content)
    }
}

// MARK: - Button Pair

/// Two title bar buttons that belong together, like back and forward: side
/// by side, 1 pt apart, with smaller corners where they meet. Each lights up
/// on its own, the other one with a fainter fill while both can be clicked;
/// a disabled one doesn't light up.
struct TitleBarButtonPair: View {
    struct Segment {
        let systemImage: String
        let label: String
        let help: String
        let isEnabled: Bool
        let action: () -> Void
    }

    private enum Side {
        case leading, trailing
    }

    static let spacing: CGFloat = 1
    static let innerCornerRadius: CGFloat = 3

    let leading: Segment
    let trailing: Segment
    @State private var hovered: Side?

    var body: some View {
        HStack(spacing: Self.spacing) {
            button(leading, side: .leading, partner: trailing)
            button(trailing, side: .trailing, partner: leading)
        }
    }

    private func button(_ segment: Segment, side: Side, partner: Segment) -> some View {
        let outer = TitleBarHoverBackground.cornerRadius
        let inner = Self.innerCornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: side == .leading ? outer : inner,
            bottomLeadingRadius: side == .leading ? outer : inner,
            bottomTrailingRadius: side == .leading ? inner : outer,
            topTrailingRadius: side == .leading ? inner : outer
        )
        let fill: Double
        if segment.isEnabled, hovered == side {
            fill = 0.1
        } else if segment.isEnabled, partner.isEnabled, hovered != nil {
            fill = 0.045
        } else {
            fill = 0
        }

        return Button(action: segment.action) {
            Image(systemName: segment.systemImage)
                .font(.system(size: 14))
                .foregroundColor(segment.isEnabled ? .secondary : .secondary.opacity(0.4))
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                .contentShape(shape)
                .background(shape.fill(Color.primary.opacity(fill)))
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .onHover { hovering in
            // Leaving one and entering the other can come in either order
            let next: Side? = hovering ? side : (hovered == side ? nil : hovered)
            if hovered != next {
                withAnimation(TitleBarHoverBackground.animation) {
                    hovered = next
                }
            }
        }
        .accessibilityLabel(Text(segment.label))
        .help(segment.help)
    }
}

// MARK: - Hover Background

/// The hover background of title bar buttons and groups: a light fill.
/// Not Liquid Glass: glass follows its place in the window, so glass behind
/// the title bar and space bar buttons was worked out again on every frame
/// of the sidebar sliding in or out.
struct TitleBarHoverBackground: View {
    static let cornerRadius: CGFloat = 8
    static let animation = Animation.easeInOut(duration: 0.15)

    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
    }
}
