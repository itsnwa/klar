import SwiftUI

extension Notification.Name {
    static let openSettingsCategory = Notification.Name("klar.openSettingsCategory")
}

struct SettingsWindow: View {
    /// The sidebar's width, which doesn't change, as the window's doesn't.
    static let sidebarWidth: CGFloat = 180

    @State private var selectedCategory: SettingsCategory = .general
    /// Always `.all`: the sidebar doesn't collapse, as in System Settings.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var canNavigateToPrevious: Bool {
        guard let currentIndex = SettingsCategory.allCases.firstIndex(of: selectedCategory) else { return false }
        return currentIndex > 0
    }

    private var canNavigateToNext: Bool {
        guard let currentIndex = SettingsCategory.allCases.firstIndex(of: selectedCategory) else { return false }
        return currentIndex < SettingsCategory.allCases.count - 1
    }

    private func navigateToPrevious() {
        guard let currentIndex = SettingsCategory.allCases.firstIndex(of: selectedCategory),
              currentIndex > 0 else { return }
        selectedCategory = SettingsCategory.allCases[currentIndex - 1]
    }

    private func navigateToNext() {
        guard let currentIndex = SettingsCategory.allCases.firstIndex(of: selectedCategory),
              currentIndex < SettingsCategory.allCases.count - 1 else { return }
        selectedCategory = SettingsCategory.allCases[currentIndex + 1]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsCategory.allCases, id: \.self, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    Label(category.title, systemImage: category.iconName)
                }
                // On the rows: on the List it leaves the icons accent colored.
                .listItemTint(.monochrome)
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selectedCategory {
                case .general:
                    GeneralSettingsView()
                case .search:
                    SearchSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .spaces:
                    SpacesSettingsView()
                case .iCloud:
                    ICloudSettingsView()
                case .passwords:
                    PasswordSettingsView()
                case .extensions:
                    ExtensionsSettingsView()
                case .ai:
                    AISettingsView()
                case .importing:
                    ImportSettingsView()
                case .featureFlags:
                    FeatureFlagsSettingsView()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: navigateToPrevious) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canNavigateToPrevious)

                Button(action: navigateToNext) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canNavigateToNext)
            }
        }
        .navigationTitle(selectedCategory.title)
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all {
                columnVisibility = .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsCategory)) { notification in
            if let category = notification.object as? SettingsCategory {
                selectedCategory = category
            }
        }
    }
}

enum SettingsCategory: String, CaseIterable {
    case general = "general"
    case search = "search"
    case appearance = "appearance"
    case spaces = "spaces"
    case iCloud = "iCloud"
    case passwords = "passwords"
    case extensions = "extensions"
    case ai = "ai"
    case importing = "import"
    case featureFlags = "featureFlags"

    var title: String {
        switch self {
        case .general:
            return "General"
        case .search:
            return "Search"
        case .appearance:
            return "Appearance"
        case .spaces:
            return "Spaces"
        case .iCloud:
            return "iCloud"
        case .passwords:
            return "Passwords"
        case .extensions:
            return "Extensions"
        case .ai:
            return "AI"
        case .importing:
            return "Import"
        case .featureFlags:
            return "Feature Flags"
        }
    }

    var iconName: String {
        switch self {
        case .general:
            return "gear"
        case .search:
            return "magnifyingglass"
        case .appearance:
            return "paintbrush"
        case .spaces:
            return "square.grid.2x2"
        case .iCloud:
            return "icloud"
        case .passwords:
            return "key"
        case .extensions:
            return "puzzlepiece.extension"
        case .ai:
            return "sparkles"
        case .importing:
            return "square.and.arrow.down"
        case .featureFlags:
            return "flag"
        }
    }
}
