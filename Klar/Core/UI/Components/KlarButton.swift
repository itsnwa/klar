import SwiftUI

/// Unified button component for Klar that can be used as either a title bar button or compact button
/// while maintaining consistent look and feel across the app
struct KlarButton<Content: View>: View {
    enum Style {
        case titleBar
        /// A title bar button inside a `KlarButtonGroup`, which draws the hover background for the whole group
        case titleBarSegment
        case compact

        var size: CGFloat {
            switch self {
            case .titleBar, .titleBarSegment: return 28
            case .compact: return 16
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .titleBar, .titleBarSegment: return TitleBarHoverBackground.cornerRadius
            case .compact: return 8
            }
        }
    }

    let style: Style
    let action: () -> Void
    let content: () -> Content
    @State private var isHovering = false

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
                        TitleBarHoverBackground(isHovering: isHovering)
                    case .titleBarSegment:
                        EmptyView()
                    case .compact:
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                    }
                }
                .onHover { hovering in
                    // Only animate if state actually changes to reduce CPU usage
                    if style != .titleBarSegment, isHovering != hovering {
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

    /// Creates a title bar button for a `KlarButtonGroup`
    static func titleBarSegment(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) -> KlarButton {
        KlarButton(style: .titleBarSegment, action: action, content: content)
    }

    /// Creates a compact button - smaller 16x16px size perfect for sidebar usage
    static func compact(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) -> KlarButton {
        KlarButton(style: .compact, action: action, content: content)
    }
}

// MARK: - Button Group

/// Title bar buttons that hover as one item, like back and forward
struct KlarButtonGroup<Content: View>: View {
    let content: Content
    @State private var isHovering = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .contentShape(Rectangle())
        .background {
            TitleBarHoverBackground(isHovering: isHovering)
        }
        .onHover { hovering in
            if isHovering != hovering {
                withAnimation(TitleBarHoverBackground.animation) {
                    isHovering = hovering
                }
            }
        }
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
