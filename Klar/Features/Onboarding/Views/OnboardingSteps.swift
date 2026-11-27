import AppKit
import SwiftUI

// MARK: - Welcome

/// The icon's dots light up as the window comes out of the mist, then the
/// welcome
struct OnboardingWelcomeStep: View {
    let setup: OnboardingSetup
    @State private var showsTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Back from the next screen: as it was
        let isStill = setup.wentBack || reduceMotion
        VStack(spacing: 0) {
            KlarDotIcon(size: 120, delay: 1.8, isStill: isStill)
                .padding(.top, 92)
            VStack(spacing: 10) {
                Text("Welcome to Klar")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.5)
                Text("A calm, private browser made for the Mac. Let’s get you set up.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(.top, 28)
            .opacity(showsTitle || isStill ? 1 : 0)
            .offset(y: showsTitle || isStill ? 0 : 8)

            Spacer()

            Button("Get Started", action: setup.primaryAction)
                .buttonStyle(OnboardingPrimaryButtonStyle(width: 220, height: 40))
            OnboardingPageDots(setup: setup)
                .padding(.top, 22)
                .padding(.bottom, 26)
        }
        .task {
            guard !isStill else { return }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.smooth(duration: 0.6)) { showsTitle = true }
        }
    }
}

// MARK: - iCloud

/// Sync with iCloud, or with Klar on another Mac already, Welcome Back
struct OnboardingICloudStep: View {
    @Bindable var setup: OnboardingSetup

    var body: some View {
        let welcomesBack = setup.welcomesBack
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                OnboardingSymbolTile(systemName: "icloud")
                if welcomesBack {
                    OnboardingHeader(
                        title: "Welcome back",
                        subtitle: "Klar on another Mac already keeps your browsing in iCloud. Bring it here?"
                    )
                    OnboardingCard {
                        syncedRows
                    }
                    Button("Set Up Without iCloud", action: setup.setUpWithoutICloud)
                        .buttonStyle(.link)
                        .font(.system(size: 13))
                } else if setup.iCloud == .unavailable {
                    OnboardingHeader(
                        title: "Klar on every Mac",
                        subtitle: "Sign in to iCloud in System Settings to keep your spaces, tabs and settings in step on every Mac. Turn it on later in Settings › iCloud."
                    )
                } else {
                    OnboardingHeader(
                        title: "Klar on every Mac",
                        subtitle: "Your spaces, tabs and settings stay in step on every Mac you use, in your own iCloud."
                    )
                    OnboardingCard {
                        HStack {
                            Text("Sync with iCloud")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Toggle("Sync with iCloud", isOn: $setup.syncWithICloud)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        Divider().opacity(0.6)
                        syncedRows
                            .opacity(setup.syncWithICloud ? 1 : 0.4)
                            .animation(.easeOut(duration: 0.2), value: setup.syncWithICloud)
                    }
                }
            }
            .padding(.top, 52)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            OnboardingFooter(setup: setup, primary: welcomesBack ? "Restore" : "Continue")
        }
    }

    private var syncedRows: some View {
        VStack(spacing: 0) {
            SyncedRow(symbol: "square.grid.2x2", text: "Spaces, groups and saved tabs")
            SyncedRow(symbol: "square.on.square", text: "Open tabs, to pick up on another Mac")
            SyncedRow(symbol: "slider.horizontal.3", text: "Settings, extensions and site permissions")
            SyncedRow(symbol: "key", text: "Passwords, in iCloud Keychain")
        }
        .padding(.vertical, 4)
    }

    private struct SyncedRow: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
    }
}

// MARK: - Import

/// Arc's and Dia's spaces and favorites, and extensions from Chromium
/// browsers: what was found on this Mac, chosen and brought in
struct OnboardingImportStep: View {
    @Bindable var setup: OnboardingSetup

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                OnboardingHeader(title: "Bring your browsing along", subtitle: subtitle)
                VStack(spacing: 8) {
                    if let sidebar = setup.arcSidebar {
                        ImportRow(
                            title: "Arc",
                            detail: setup.importState == .done ? setup.arcSummary ?? "" : Self.details(of: sidebar),
                            isOn: $setup.importsArc,
                            state: setup.importState
                        ) {
                            AppIcon(bundleIdentifier: "company.thebrowser.Browser", fallback: "globe")
                        } options: {
                            HStack(spacing: 6) {
                                if setup.hasArcSpaces {
                                    OptionChip(title: "Spaces and pinned tabs", isOn: $setup.importsArcSpaces)
                                }
                                if setup.hasArcFavorites {
                                    OptionChip(title: "Favorites", isOn: $setup.importsArcFavorites)
                                }
                            }
                        }
                    }
                    if setup.hasDiaSidebar {
                        ImportRow(
                            title: "Dia",
                            detail: setup.importState == .done ? setup.diaSummary ?? "" : "Spaces, pinned tabs and favorites",
                            isOn: $setup.importsDia,
                            state: setup.importState
                        ) {
                            AppIcon(bundleIdentifier: "company.thebrowser.dia", fallback: "globe")
                        } options: {
                            Text("macOS asks first whether Klar may use Dia’s key, since Dia keeps its sidebar encrypted.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !setup.foreignExtensions.isEmpty {
                        ImportRow(
                            title: "Extensions",
                            detail: setup.importState == .done ? "Added when you start browsing" : Self.details(of: setup.foreignExtensions),
                            isOn: $setup.importsExtensions,
                            state: setup.importState
                        ) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(KlarIconTile(cornerRadius: 9))
                        } options: {
                            Text("Fresh from the Chrome Web Store once you start browsing, each asking for your OK.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !setup.hasLookedForImports {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 20)
                    }
                }
            }
            .padding(.top, 56)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            OnboardingFooter(setup: setup, primary: primaryTitle, isPrimaryEnabled: setup.importState != .importing)
        }
    }

    private var subtitle: String {
        if setup.importState == .done {
            return setup.arcSummary == nil && setup.diaSummary == nil
                ? "All set. Your extensions come once you start browsing."
                : "All set. It’s in your sidebar now."
        }
        if setup.hasLookedForImports && !setup.hasSomethingToImport {
            return "There’s nothing to bring over from other browsers on this Mac."
        }
        return "Klar found these on this Mac."
    }

    private var primaryTitle: String {
        switch setup.importState {
        case .done: return "Continue"
        case .importing: return "Importing…"
        case .choosing: return setup.choosesNothingToImport ? "Skip" : "Import"
        }
    }

    private static func details(of sidebar: ImportedSidebar) -> String {
        let spaces = sidebar.spaces.filter { $0.tabCount > 0 }
        var parts: [String] = []
        if !spaces.isEmpty {
            parts.append(OnboardingSetup.count(spaces.count, "space"))
            parts.append(OnboardingSetup.count(spaces.reduce(0) { $0 + $1.tabCount }, "tab"))
        }
        if !sidebar.favorites.isEmpty {
            parts.append(OnboardingSetup.count(sidebar.favorites.count, "favorite"))
        }
        return parts.joined(separator: " · ")
    }

    /// "uBlock Origin Lite, 1Password and 3 more, from Chrome and Arc"
    private static func details(of extensions: [ExtensionInstaller.ForeignExtension]) -> String {
        let names = extensions.prefix(2).map(\.name)
        let more = extensions.count - names.count
        let listed = more > 0
            ? names.joined(separator: ", ") + " and \(more) more"
            : ListFormatter.localizedString(byJoining: names)
        var browsers: [String] = []
        for browser in extensions.flatMap(\.browsers) where !browsers.contains(browser) {
            browsers.append(browser)
        }
        return listed + ", from " + ListFormatter.localizedString(byJoining: browsers)
    }

    /// A browser found, chosen as a whole, with what it brings
    private struct ImportRow<Icon: View, Options: View>: View {
        let title: String
        let detail: String
        @Binding var isOn: Bool
        let state: OnboardingSetup.ImportState
        @ViewBuilder let icon: Icon
        @ViewBuilder let options: Options

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isOn.toggle()
                } label: {
                    HStack(spacing: 12) {
                        icon
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        CheckCircle(isOn: isOn, isDone: state == .done)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state != .choosing)
                .accessibilityAddTraits(isOn ? .isSelected : [])

                if isOn && state == .choosing {
                    options
                        .padding(.leading, 58)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
                if isOn && state == .importing {
                    OnboardingDotProgress()
                        .padding(.leading, 58)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(isOn ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(isOn ? 0.13 : 0.06)))
            .animation(.smooth(duration: 0.25), value: isOn)
            .animation(.smooth(duration: 0.25), value: state)
        }
    }

    private struct CheckCircle: View {
        let isOn: Bool
        let isDone: Bool

        var body: some View {
            ZStack {
                if isOn {
                    Circle()
                        .fill(isDone ? Color.green : Color.accentColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                }
            }
            .frame(width: 20, height: 20)
        }
    }

    private struct OptionChip: View {
        let title: String
        @Binding var isOn: Bool

        var body: some View {
            Button(title) { isOn.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.16) : .clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.14)))
                .contentShape(Capsule())
                .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }

    /// An installed app's own icon
    private struct AppIcon: View {
        let bundleIdentifier: String
        let fallback: String

        var body: some View {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 16))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

// MARK: - Make It Yours

/// Appearance, the page's frame and the search engine, applied as they're
/// picked
struct OnboardingLookStep: View {
    let setup: OnboardingSetup
    @ObservedObject private var settings = TOMLSettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingHeader(title: "Make it yours", subtitle: "All of this is in Settings later too.")
                    .frame(maxWidth: .infinity)

                section("Appearance") {
                    HStack(spacing: 12) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            AppearanceChoice(mode: mode, isSelected: settings.appearanceMode == mode) {
                                settings.appearanceMode = mode
                            }
                        }
                    }
                }

                section("Web pages") {
                    HStack(spacing: 12) {
                        PageFrameChoice(isInset: true, isSelected: settings.insetWebView) {
                            settings.insetWebView = true
                        }
                        PageFrameChoice(isInset: false, isSelected: !settings.insetWebView) {
                            settings.insetWebView = false
                        }
                    }
                }

                // A menu, as the engines' names don't fit side by side. A
                // custom engine's address is set in Settings › Search.
                HStack {
                    Text("Search with")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("Search with", selection: $settings.defaultSearchEngine) {
                        ForEach(DefaultSearchEngine.allCases.filter { $0 != .custom }, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
            .padding(.top, 54)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            OnboardingFooter(setup: setup, primary: "Continue")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// A window in miniature, light, dark or half of each
    private struct AppearanceChoice: View {
        let mode: AppearanceMode
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    thumbnail
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                    Text(mode == .system ? "Auto" : mode.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        @ViewBuilder private var thumbnail: some View {
            switch mode {
            case .light: MiniWindow(isDark: false)
            case .dark: MiniWindow(isDark: true)
            case .system:
                MiniWindow(isDark: false)
                    .overlay(alignment: .trailing) {
                        MiniWindow(isDark: true)
                            .mask(alignment: .trailing) { Rectangle().frame(width: 48) }
                    }
            }
        }
    }

    private struct PageFrameChoice: View {
        let isInset: Bool
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    MiniWindow(isDark: colorScheme == .dark, isInset: isInset, size: CGSize(width: 54, height: 38))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isInset ? "Framed" : "Edge to edge")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(isInset ? "A small frame around the page" : "The page fills the window")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// Klar's window, drawn small: the sidebar's lines and the page
    private struct MiniWindow: View {
        let isDark: Bool
        var isInset = true
        var size = CGSize(width: 96, height: 58)

        var body: some View {
            let scale = size.width / 96
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(isDark ? Color(white: 0.14) : Color(white: 0.91))
                VStack(alignment: .leading, spacing: 4 * scale) {
                    ForEach([18.0, 14, 16], id: \.self) { width in
                        Capsule()
                            .fill(isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.22))
                            .frame(width: width * scale, height: 3 * scale)
                    }
                }
                .padding(.leading, 7 * scale)
                .padding(.top, 9 * scale)
                RoundedRectangle(cornerRadius: isInset ? 4 * scale : 0, style: .continuous)
                    .fill(isDark ? Color(white: 0.05) : .white)
                    .padding(.leading, 30 * scale)
                    .padding([.top, .bottom, .trailing], isInset ? 4 * scale : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        }
    }
}

// MARK: - Ready

/// The shortcuts worth knowing first. Pressed here, a row lights up a
/// moment, unannounced (`Onboarding` takes the keys, which do nothing else
/// here).
struct OnboardingReadyStep: View {
    let setup: OnboardingSetup

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                OnboardingSymbolTile(systemName: "command")
                OnboardingHeader(
                    title: "A few keys to know",
                    subtitle: "Most of Klar is a key or two away."
                )
            }
            .padding(.top, 52)
            .padding(.horizontal, 24)

            OnboardingCard {
                VStack(spacing: 0) {
                    ForEach(OnboardingSetup.Shortcut.all, id: \.self) { shortcut in
                        ShortcutRow(shortcut: shortcut, isPressed: setup.pressedShortcut == shortcut)
                    }
                }
                .padding(5)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            OnboardingFooter(setup: setup, primary: "Start Browsing")
        }
    }

    private struct ShortcutRow: View {
        let shortcut: OnboardingSetup.Shortcut
        let isPressed: Bool

        var body: some View {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(shortcut.keys, id: \.self) { OnboardingKeycap(key: $0, isPressed: isPressed) }
                }
                .frame(width: 86, alignment: .leading)
                Text(shortcut.text)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(isPressed ? 0.12 : 0)))
            .animation(.easeOut(duration: isPressed ? 0.08 : 0.35), value: isPressed)
        }
    }
}
