import SwiftUI

/// First launch's setup over the browser, in the window showing it
/// (Onboarding). Observes the setup on its own, so ContentView's body
/// doesn't run again for it.
struct OnboardingOverlay: View {
    let session: BrowserWindowSession

    var body: some View {
        let onboarding = Onboarding.shared
        if onboarding.isShowing(in: session) {
            OnboardingView(onboarding: onboarding)
                // Asks for no size of its own: SwiftUI would grow the window
                // for it, by the title bar's height too
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }
}

/// The setup's screens, one at a time, on the window's glass: the mist
/// behind the window shows through it. Its content sharpens as the window
/// comes out of the mist, and drops away as the window grows into the
/// browser.
struct OnboardingView: View {
    let onboarding: Onboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let setup = onboarding.setup
        let hasEmerged = onboarding.phase != .preparing
        let isFinishing = onboarding.phase == .finishing

        ZStack {
            Group {
                switch setup.step {
                case .welcome: OnboardingWelcomeStep(setup: setup)
                case .iCloud: OnboardingICloudStep(setup: setup)
                case .importing: OnboardingImportStep(setup: setup)
                case .look: OnboardingLookStep(setup: setup)
                case .ready: OnboardingReadyStep(setup: setup)
                }
            }
            .id(setup.step)
            .transition(reduceMotion ? .opacity : .onboardingStep(forward: !setup.wentBack))
        }
        .animation(.smooth(duration: 0.42), value: setup.step)
        .frame(width: Onboarding.windowSize.width, height: Onboarding.windowSize.height)
        // Out of the mist
        .blur(radius: hasEmerged ? 0 : 16)
        .scaleEffect(hasEmerged ? 1 : 0.95)
        .offset(y: hasEmerged ? 0 : 20)
        .animation(reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.2, 0.75, 0.2, 1, duration: 2.2).delay(0.8), value: hasEmerged)
        // Into the browser: the screen drifts toward you and dissolves as the
        // window fades into its stand-in, which grows (`Onboarding.finish`)
        .blur(radius: isFinishing ? 10 : 0)
        .scaleEffect(isFinishing ? 1.06 : 1)
        .opacity(isFinishing ? 0 : 1)
        .animation(.easeIn(duration: 0.2), value: isFinishing)
        // Centered in the window
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window's glass, all of it; gone by the time the window comes
        // back as the browser
        .background {
            VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow, state: .active)
                .opacity(isFinishing ? 0 : 1)
                .animation(.easeIn(duration: 0.25), value: isFinishing)
        }
        // Nothing of the browser under it takes a click
        .contentShape(Rectangle())
    }
}

private struct Blurred: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// A screen coming in from the side it's going, sharpening
    static func onboardingStep(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: forward ? 14 : -14))
                .combined(with: .modifier(active: Blurred(radius: 3), identity: Blurred(radius: 0))),
            removal: .opacity
        )
    }
}

// MARK: - Parts

/// A screen's title and what it's about
struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 310)
    }
}

/// Back, where the setup is, and the way on. Return and Escape are the
/// setup's own (`Onboarding`), whatever has the focus.
struct OnboardingFooter: View {
    let setup: OnboardingSetup
    let primary: String
    var isPrimaryEnabled = true

    var body: some View {
        HStack(spacing: 0) {
            Button("Back", action: setup.back)
                .buttonStyle(OnboardingTextButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
            OnboardingPageDots(setup: setup)
            Button(primary, action: setup.primaryAction)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!isPrimaryEnabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }
}

/// A dot per screen, the one showing lit like the icon's LEDs
struct OnboardingPageDots: View {
    let setup: OnboardingSetup
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let steps = setup.steps
        let current = steps.firstIndex(of: setup.step) ?? 0
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                let isCurrent = index == current
                Circle()
                    .fill(isCurrent ? Color.primary : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .shadow(color: isCurrent && colorScheme == .dark ? .white.opacity(0.85) : .clear, radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(steps.count)")
    }
}

/// Filled with the text's color, glowing a little in the dark, like a lit dot
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    var width: CGFloat?
    var height: CGFloat = 36
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isDark ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .frame(width: width, height: height)
            .background(Capsule().fill(isDark ? Color(white: 0.96) : Color(white: 0.1)))
            .shadow(color: isDark && isEnabled ? .white.opacity(0.16) : .clear, radius: 11)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A rounded box for a screen's rows
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A symbol on a dark tile, like the icon's
struct OnboardingSymbolTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.6), radius: 4)
            .frame(width: 48, height: 48)
            .background(KlarIconTile(cornerRadius: 14))
    }
}

/// The icon's black glass
struct KlarIconTile: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.17), Color(white: 0.045), Color(white: 0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }
}

/// Klar's icon in its LED dots, lighting up into its glyph: a dim bar
/// sliding in from each side and a bright one lit from the middle out,
/// after a faint sweep across
struct KlarDotIcon: View {
    var size: CGFloat = 120
    /// How long after it appears the dots start
    var delay: TimeInterval = 0.4
    /// Lit from the start, without the dots coming on
    var isStill = false

    @State private var start = Date()
    @State private var isLit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let rows = 10
    /// Each step of the dots coming on
    private static let tick: TimeInterval = 0.055
    private static let fade: TimeInterval = 0.3

    var body: some View {
        let still = isStill || reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 60, paused: still || isLit)) { timeline in
            let elapsed = still ? .infinity : timeline.date.timeIntervalSince(start) - delay
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize, elapsed: elapsed)
            }
        }
        .frame(width: size, height: size)
        .background(KlarIconTile(cornerRadius: size * 0.233))
        .shadow(color: .white.opacity(colorScheme == .dark && (isLit || still) ? 0.14 : 0), radius: size * 0.2)
        .animation(.easeOut(duration: 0.8), value: isLit)
        .task {
            guard !still else { return }
            try? await Task.sleep(for: .seconds(delay + 26 * Self.tick + Self.fade))
            isLit = true
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let rows = CGFloat(Self.rows)
        let dot = size.width * 0.05
        let gap = size.width * 0.0383
        let inset = (size.width - rows * dot - (rows - 1) * gap) / 2
        let sweep = elapsed / Self.tick
        var bright = Path()

        for row in 0..<Self.rows {
            for column in 0..<Self.rows {
                let rect = CGRect(x: inset + CGFloat(column) * (dot + gap), y: inset + CGFloat(row) * (dot + gap), width: dot, height: dot)
                let circle = Path(ellipseIn: rect)
                context.fill(circle, with: .color(Color(white: 0.01)))
                let (level, step) = Self.level(row: row, column: column)
                let shown = level * min(max((elapsed - Double(step) * Self.tick) / Self.fade, 0), 1)
                if level == 1 {
                    if shown > 0 {
                        context.fill(circle, with: .color(.white.opacity(shown)))
                        if shown == 1 { bright.addPath(circle) }
                    }
                } else if shown > 0 {
                    context.fill(circle, with: .color(Color(white: 0.55).opacity(shown * 2)))
                } else if sweep >= 0, sweep <= 12, abs(Double(column) - sweep) < 1.5 {
                    context.fill(circle, with: .color(Color(white: 0.24)))
                }
            }
        }
        // The lit dots glow
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .white.opacity(0.85), radius: dot * 0.9))
            layer.fill(bright, with: .color(.white))
        }
    }

    /// How bright a dot ends up (0, ½ or 1), and at which step it comes on
    private static func level(row: Int, column: Int) -> (Double, Int) {
        if (2...3).contains(row), column <= 5 {
            return (0.5, 4 + column + row - 2)
        }
        if (4...5).contains(row), (2...7).contains(column) {
            return (1, 12 + Int((abs(Double(column) - 4.5) * 2).rounded()))
        }
        if (6...7).contains(row), column >= 4 {
            return (0.5, 4 + 9 - column + row - 6)
        }
        return (0, 0)
    }
}

/// Lights up dot by dot over `duration`: an import under way
struct OnboardingDotProgress: View {
    var count = 16
    var duration: TimeInterval = 1.3
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let lit = Int(timeline.date.timeIntervalSince(start) / duration * Double(count))
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index < lit ? Color.primary : Color.primary.opacity(0.14))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .accessibilityLabel("Importing")
    }
}

/// A key, as on the keyboard; pressed, it goes down and lights up
struct OnboardingKeycap: View {
    let key: String
    var isPressed = false

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .frame(minWidth: 24, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(isPressed ? 0.24 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(isPressed ? 0.3 : 0.16), lineWidth: 0.5))
            .offset(y: isPressed ? 1 : 0)
            .scaleEffect(isPressed ? 0.96 : 1)
    }
}
