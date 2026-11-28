import SwiftUI

struct GeneralSettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    @ObservedObject private var updater = AppUpdater.shared
    @State private var browsers: [DefaultBrowser.Browser] = []
    /// The bundle identifier of the default browser
    @State private var defaultBrowserID: String?

    var body: some View {
        SettingsDetailContainer {
            SettingsPageHeader(
                title: "Klar \(Bundle.main.shortVersion)",
                summary: updatesSubtitle
            ) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            } accessory: {
                if updater.readyUpdate != nil {
                    Button("Restart to Update") { updater.installUpdate() }
                        .buttonStyle(.borderedProminent)
                } else {
                    // The answer shows here, so the browser window stays behind
                    Button("Check for Updates") { updater.checkForUpdates(showingSidebar: false) }
                        .disabled(!updater.canCheckForUpdates || updater.isBusy)
                }
            }

            Section("Default Browser") {
                Picker(selection: defaultBrowserSelection) {
                    ForEach(browsers) { browser in
                        Label {
                            Text(browser.name)
                        } icon: {
                            Image(nsImage: browser.icon)
                        }
                        .tag(Optional(browser.bundleIdentifier))
                    }
                    // One macOS names that isn't a browser it lists
                    if let defaultBrowserID, !browsers.contains(where: { $0.bundleIdentifier == defaultBrowserID }) {
                        Text(defaultBrowserID).tag(Optional(defaultBrowserID))
                    }
                } label: {
                    Text("Default web browser")
                    Text(defaultBrowserID == Bundle.main.bundleIdentifier
                        ? "Links you open in other apps open in Klar"
                        : "Links you open in other apps open in this browser. macOS asks before it changes")
                }
            }

            Section("Tabs") {
                Picker(selection: $settingsManager.tabCloseAction) {
                    ForEach(TabCloseAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                } label: {
                    Text("Close tabs")
                    Text("Automatically close tabs based on your preference")
                }

                Toggle(isOn: $settingsManager.openLinksInGroup) {
                    Text("Open links in the tab’s group")
                    Text("A link you open from a tab in a group opens as a new tab in that group")
                }
            }

            Section("Downloads") {
                SettingsRow(title: "Download location", subtitle: "Choose where downloaded files are saved") {
                    HStack {
                        Text(settingsManager.downloadLocation.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            settingsManager.selectDownloadLocation()
                        }
                    }
                }
            }

            Section("Privacy") {
                Toggle(isOn: $settingsManager.blockTrackers) {
                    Text("Block trackers")
                    Text("Known trackers don’t load, and links lose their tracking parameters. To allow a site’s trackers, use the gear in its address bar")
                }

                Picker(selection: $settingsManager.fingerprintingProtection) {
                    ForEach(FingerprintingProtection.allCases, id: \.self) { protection in
                        Text(protection.rawValue).tag(protection)
                    }
                } label: {
                    Text("Fingerprinting protection")
                    Text("Safari’s protection: sites can’t tell your Mac apart by how it draws, plays audio or sizes its screen. If a site doesn’t work right, allow its trackers with the gear in its address bar")
                }
                .disabled(!settingsManager.blockTrackers)

                Toggle(isOn: $settingsManager.lockPrivateTabs) {
                    Text("Lock private tabs when you’re away")
                    Text("When your Mac locks or sleeps, or Klar has been in the background for 5 minutes, private tabs hide until you unlock them with Touch ID or your password")
                }

                Picker(selection: $settingsManager.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.rawValue).tag(retention)
                    }
                } label: {
                    Text("Remove history items")
                    Text("Older pages are removed when Klar opens and once a day")
                }

                SettingsRow(title: "Clear browsing data", subtitle: "Remove all browsing history, cookies, and cached data") {
                    Button("Clear Data") {
                        TOMLSettingsManager.shared.clearBrowsingData()
                    }
                }
            }

            Section("Web Developers") {
                Toggle(isOn: webDeveloperTools) {
                    Text("Web developer tools")
                    Text(webDeveloperToolsSubtitle)
                }
                .disabled(isDebugBuild)
            }
        }
        .onAppear {
            checkDefaultBrowserStatus()
        }
        // The default can also change in System Settings while Klar is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkDefaultBrowserStatus()
        }
    }

    #if DEBUG
    private let isDebugBuild = true
    #else
    private let isDebugBuild = false
    #endif

    /// Always on in Debug builds, which share config.toml with Release ones,
    /// so the setting isn't written from them.
    private var webDeveloperTools: Binding<Bool> {
        Binding(
            get: { isDebugBuild || settingsManager.webDeveloperTools },
            set: { settingsManager.webDeveloperTools = $0 }
        )
    }

    private var webDeveloperToolsSubtitle: String {
        if isDebugBuild { return "Always on in Debug builds" }
        return "Inspect Element in a page’s menu, and Safari’s Develop menu can inspect Klar’s pages. Pages keep their recent console messages while it’s on. ⌥⌘I opens the Web Inspector either way"
    }

    /// Picking one asks macOS to make it the default; the picker shows what
    /// the default is once the user has answered.
    private var defaultBrowserSelection: Binding<String?> {
        Binding(
            get: { defaultBrowserID },
            set: { bundleIdentifier in
                guard bundleIdentifier != defaultBrowserID,
                      let browser = browsers.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
                DefaultBrowser.makeDefault(appAt: browser.url) { _ in
                    checkDefaultBrowserStatus()
                }
            }
        )
    }

    private func checkDefaultBrowserStatus() {
        let current = DefaultBrowser.currentBundleIdentifier
        if defaultBrowserID != current {
            defaultBrowserID = current
        }
        let installed = DefaultBrowser.installedBrowsers
        if browsers != installed {
            browsers = installed
        }
    }

    /// Where the update is, as the sidebar's card says it
    private var updatesSubtitle: String {
        guard updater.isAvailable else { return "This build doesn’t update itself" }
        switch updater.state {
        case .idle:
            return "Klar checks for updates and downloads them by itself. They install when you restart or quit Klar"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Klar is up to date"
        case .failed(_, let message):
            return message
        case .downloading(let update, _, _), .preparing(let update):
            return "Downloading \(update.name)…"
        case .ready(let update):
            return "\(update.name) is ready. It installs when you restart or quit Klar"
        case .installing(let update):
            return "Restarting to install \(update.name)…"
        }
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 700, height: 500)
}
