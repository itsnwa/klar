import SwiftUI

/// Liquid Glass in the active space's color, as the window's frame has it
/// (`SpaceTint`): the command palette, the Find panel, the loading bar,
/// toasts and the split view's pane controls. Dark glass in dark mode, milky in light, each with a little of the
/// space's color. Regular glass has no dark style of its own, so in dark mode
/// a near-black tint does the darkening.
///
/// Glass draws what it's applied to on top of itself: put it on the content,
/// or on `Color.clear` behind it, never on a filled shape, whose fill (the
/// foreground color) would cover the glass.
struct SpaceGlass<S: Shape>: ViewModifier {
    let shape: S

    @ObservedObject private var spaceManager = SpaceManager.shared
    @EnvironmentObject private var spaceSelection: SpaceSelection
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tint = SpaceGlassTint.color(spaceSelection.activeSpace?.color, in: colorScheme)
        return content.glassEffect(.regular.tint(tint), in: shape)
    }
}

/// `SpaceGlass`'s tint, for SwiftUI's glass and AppKit's alike: the split
/// view's pane controls are `NSGlassEffectView`s.
enum SpaceGlassTint {
    /// The space's own color rather than `tintColor`: graphite's is black in
    /// dark mode, which would leave its glass black instead of charcoal.
    static func color(_ spaceColor: SpaceColor?, in colorScheme: ColorScheme) -> Color {
        let color = spaceColor?.color
        if colorScheme == .dark {
            return (color ?? .black).mix(with: Color(white: 0.08), by: 0.8).opacity(0.85)
        }
        return (color ?? .gray).mix(with: Color(white: 0.65), by: 0.85).opacity(0.45)
    }

    /// The same tint resolved for `appearance`, for `NSGlassEffectView`'s
    /// `tintColor`: SwiftUI's own mix, so it's the same color.
    static func nsColor(_ spaceColor: SpaceColor?, in appearance: NSAppearance) -> NSColor {
        var environment = EnvironmentValues()
        environment.colorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let resolved = color(spaceColor, in: environment.colorScheme).resolve(in: environment)
        return NSColor(cgColor: resolved.cgColor) ?? .clear
    }
}

extension View {
    /// Glass in the active space's color, in `shape` (see `SpaceGlass`).
    func spaceGlass(in shape: some Shape) -> some View {
        modifier(SpaceGlass(shape: shape))
    }
}
