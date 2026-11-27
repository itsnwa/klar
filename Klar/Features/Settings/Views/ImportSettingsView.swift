import SwiftUI

/// Settings › Import: Arc's and Dia's spaces and favorites
/// (`SidebarImportSheet`), and
/// Chrome Web Store extensions from Chromium browsers
/// (`ExtensionImportSheet`, also in Settings › Extensions).
struct ImportSettingsView: View {
    @State private var sidebarImport: SidebarImportSource?
    @State private var showsExtensionImport = false

    var body: some View {
        SettingsDetailContainer {
            Section("Arc") {
                SettingsRow(title: "Spaces and favorites", subtitle: "Your spaces with their pinned tabs and folders, and your favorites as pinned sites. Importing again adds only what’s new") {
                    Button("Import…") { sidebarImport = .arc }
                }
            }

            Section("Dia") {
                SettingsRow(title: "Spaces and favorites", subtitle: "Your spaces with their pinned tabs and folders, and their favorites as pinned sites. Importing again adds only what’s new") {
                    Button("Import…") { sidebarImport = .dia }
                }
            }

            Section("Extensions") {
                SettingsRow(title: "From another browser", subtitle: "What you added from the Chrome Web Store in Chrome, Arc, Dia, Brave or Edge, reinstalled fresh from the store. Nothing else is copied") {
                    Button("Choose…") { showsExtensionImport = true }
                }
            }
        }
        .sheet(item: $sidebarImport) { source in
            SidebarImportSheet(source: source) { sidebarImport = nil }
        }
        .sheet(isPresented: $showsExtensionImport) {
            ExtensionImportSheet { showsExtensionImport = false }
        }
    }
}

#Preview {
    ImportSettingsView()
        .frame(width: 570, height: 400)
}
