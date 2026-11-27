import SwiftUI

/// Settings › Search: the default search engine, as tiles with its icon
/// (Custom's is its site's), and the site shortcuts
/// (`SiteShortcutsSettingsView`).
struct SearchSettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    /// The Custom engine's address as typed: saved once it's a valid one.
    @State private var customURLDraft = ""
    @FocusState private var isCustomURLFocused: Bool

    var body: some View {
        SettingsDetailContainer {
            Section {
                SearchEnginePicker(
                    selection: $settingsManager.defaultSearchEngine,
                    customURL: settingsManager.customSearchEngineURL
                ) {
                    if settingsManager.defaultSearchEngine == .custom && customURLDraft.isEmpty {
                        isCustomURLFocused = true
                    }
                }

                if settingsManager.defaultSearchEngine == .custom {
                    TextField(text: $customURLDraft, prompt: Text(verbatim: "https://kagi.com/search?q=%s")) {
                        Text("Search address")
                        Text(customURLProblem ?? "The address of a search on the site, with %s where the words go")
                    }
                    .focused($isCustomURLFocused)
                    .onSubmit(commitCustomURL)
                    .onChange(of: isCustomURLFocused) { _, isFocused in
                        if !isFocused { commitCustomURL() }
                    }
                }
            } header: {
                Text("Search Engine")
            } footer: {
                Text(settingsManager.defaultSearchEngine == .custom
                    ? "What you type in the command palette that isn’t an address is searched with it. Until its address is set, DuckDuckGo searches instead. A custom engine has no suggestions as you type"
                    : "What you type in the command palette that isn’t an address is searched with it, and its suggestions show as you type")
            }

            Section("Site Shortcuts") {
                SiteShortcutsSettingsView(settingsManager: settingsManager)
            }
        }
        .onAppear {
            customURLDraft = settingsManager.customSearchEngineURL
        }
        .onChange(of: settingsManager.customSearchEngineURL) { _, url in
            if !isCustomURLFocused { customURLDraft = url }
        }
    }

    private var trimmedCustomURL: String {
        customURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What's keeping the address from being saved, once something's typed.
    private var customURLProblem: String? {
        guard !trimmedCustomURL.isEmpty, !SiteShortcut.isValidURL(trimmedCustomURL) else { return nil }
        return trimmedCustomURL.contains(SiteShortcut.placeholder)
            ? "Enter the site’s whole address, starting with https://"
            : "Put %s in the address where the words go"
    }

    private func commitCustomURL() {
        if trimmedCustomURL.isEmpty || SiteShortcut.isValidURL(trimmedCustomURL),
           trimmedCustomURL != settingsManager.customSearchEngineURL {
            settingsManager.customSearchEngineURL = trimmedCustomURL
        }
    }
}

/// The engines side by side, each a tile with its icon and name.
private struct SearchEnginePicker: View {
    @Binding var selection: DefaultSearchEngine
    /// The Custom engine's address, for its tile's icon and name.
    let customURL: String
    let onSelect: () -> Void

    private var customShortcut: SiteShortcut? {
        SiteShortcut.isValidURL(customURL) ? SiteShortcut(keyword: "", url: customURL) : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DefaultSearchEngine.allCases, id: \.self) { engine in
                let isSelected = engine == selection
                Button {
                    selection = engine
                    onSelect()
                } label: {
                    VStack(spacing: 8) {
                        icon(for: engine)
                            .frame(width: 28, height: 28)
                        Text(title(for: engine))
                            .lineLimit(1)
                            .font(.callout)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(engine.rawValue))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func icon(for engine: DefaultSearchEngine) -> some View {
        if engine != .custom {
            FaviconView(url: engine.shortcut.homeURL, size: 28, fallbackIcon: "magnifyingglass")
        } else if let customShortcut {
            // The site's own icon, looked up again as the address changes
            FaviconView(url: customShortcut.homeURL, size: 28, fallbackIcon: "magnifyingglass")
                .id(customShortcut.homeURL)
        } else {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    private func title(for engine: DefaultSearchEngine) -> String {
        guard engine == .custom else { return engine.rawValue }
        return customShortcut?.name ?? "Custom"
    }
}

#Preview {
    SearchSettingsView()
        .frame(width: 570, height: 600)
}
