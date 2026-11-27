import SwiftUI

struct ICloudSettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    @ObservedObject private var syncManager = CloudSyncManager.shared

    var body: some View {
        SettingsDetailContainer {
            Section {
                Toggle(isOn: $settingsManager.syncWithICloud) {
                    Text("Sync with iCloud")
                    Text("The same open and saved tabs, Explore pages, settings, extensions, website permissions and passwords on all your Macs, kept in iCloud as a backup")
                }
                if settingsManager.syncWithICloud {
                    SettingsRow(title: statusTitle, subtitle: statusDescription) {
                        if syncManager.status == .syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Sync Now") { syncManager.syncNow() }
                                .disabled(!canSyncNow)
                        }
                    }
                }
                if let problem = syncManager.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.secondary)
                }
            }

            Section("What Syncs") {
                syncedItem(
                    "Saved tabs and groups",
                    systemImage: "sidebar.left",
                    description: "Their order, names and icons. Which tabs are loaded and which groups are open stay on each Mac"
                )
                syncedItem(
                    "Settings",
                    systemImage: "gearshape",
                    description: "Search engine, closing tabs, appearance, passwords and forms, sites never to save passwords for and apps that always open. The download folder, loaded tab limit, AI and feature flags stay on each Mac"
                )
                syncedItem(
                    "Extensions",
                    systemImage: "puzzlepiece.extension",
                    description: "Chrome Web Store extensions, on or off and pinned; other Macs install them from the store. Unpacked extensions stay on their Mac"
                )
                syncedItem(
                    "Passwords",
                    systemImage: "key",
                    description: passwordsDescription
                )
            }
        }
    }

    private func syncedItem(_ title: String, systemImage: String, description: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private var passwordsDescription: String {
        if settingsManager.syncWithICloud, let problem = syncManager.passwordsProblem {
            return "Klar's own passwords stay on this Mac: \(problem)"
        }
        return "Klar's own passwords, in iCloud Keychain. Apple's Passwords app syncs on its own"
    }

    private var statusTitle: String {
        switch syncManager.status {
        case .off, .unavailable: return "Not syncing"
        case .syncing: return "Syncing…"
        case .idle: return syncManager.problem == nil ? "Up to date" : "Couldn't sync"
        }
    }

    private var statusDescription: String? {
        switch syncManager.status {
        case .unavailable(let reason):
            return reason
        case .idle:
            guard let date = syncManager.lastSyncDate else { return nil }
            return "Last synced \(date.formatted(date: .omitted, time: .shortened))"
        case .off, .syncing:
            return nil
        }
    }

    private var canSyncNow: Bool {
        if case .idle = syncManager.status { return true }
        return false
    }
}

#Preview {
    ICloudSettingsView()
        .frame(width: 700, height: 500)
}
