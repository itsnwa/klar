import Foundation
import SwiftUI
import WebKit
import AppKit

struct SettingsConfig: Codable {
    var defaultSearchEngine: String = "DuckDuckGo"
    /// The Custom engine's search address, with `%s` where the words go.
    var customSearchEngineURL: String = ""
    var tabCloseAction: String = "Never"
    /// Links opened from a tab in a group open in that group.
    var openLinksInGroup: Bool = true
    var downloadLocation: String = ""
    var appearanceMode: String = "System"
    var insetWebView: Bool = false
    /// An `AIProvider`'s raw value; empty for the first one installed.
    var aiProvider: String = ""
    var aiModel: String = "llama3.2:latest"
    var aiBaseURL: String = "http://localhost:11434"
    /// Empty for the CLI's own default.
    var claudeModel: String = ""
    var codexModel: String = ""
    var offerToSavePasswords: Bool = true
    var fillSignIns: Bool = true
    var offerPasskeys: Bool = true
    var useApplePasswords: Bool = true
    var fillContactDetails: Bool = false
    var syncWithICloud: Bool = false
    var historyRetention: String = HistoryRetention.oneYear.rawValue
    var blockTrackers: Bool = true
    var fingerprintingProtection: String = FingerprintingProtection.privateTabs.rawValue
    var lockPrivateTabs: Bool = true
    var webDeveloperTools: Bool = false
    var featureFlags: [String: Bool] = [:]
    /// Nil until the file has a `[site_shortcuts]` section: Klar's defaults.
    var siteShortcuts: [SiteShortcut]? = nil

    static func defaultConfig() -> SettingsConfig {
        let defaultDownloadPath = NSHomeDirectory() + "/Downloads"
        return SettingsConfig(
            defaultSearchEngine: "DuckDuckGo",
            tabCloseAction: "Never",
            downloadLocation: defaultDownloadPath,
            appearanceMode: "System",
            aiModel: "llama3.2:latest",
            aiBaseURL: "http://localhost:11434",
            featureFlags: [:]
        )
    }
}

class TOMLSettingsManager: ObservableObject {
    static let shared = TOMLSettingsManager()
    
    @Published var customSearchEngineURL: String {
        didSet {
            config.customSearchEngineURL = customSearchEngineURL
            saveConfig()
        }
    }

    @Published var defaultSearchEngine: DefaultSearchEngine {
        didSet {
            Logger.shared.info(.settings, "Default search engine changed to: \(defaultSearchEngine.rawValue)")
            config.defaultSearchEngine = defaultSearchEngine.rawValue
            saveConfig()
        }
    }
    
    /// Settings › Search, in the order listed.
    @Published var siteShortcuts: [SiteShortcut] {
        didSet {
            guard siteShortcuts != oldValue else { return }
            // Klar's own list isn't written out, so later changes to it reach this Mac
            config.siteShortcuts = siteShortcuts == SiteShortcutPreset.defaults ? nil : siteShortcuts
            saveConfig()
        }
    }

    @Published var tabCloseAction: TabCloseAction {
        didSet {
            Logger.shared.info(.settings, "Tab close action changed to: \(tabCloseAction.rawValue)")
            config.tabCloseAction = tabCloseAction.rawValue
            saveConfig()
            // Post notification for tab closing behavior change
            NotificationCenter.default.post(name: .tabCloseActionChanged, object: nil)
        }
    }

    /// Settings › General › Tabs: a link opened from a tab in a group (a
    /// ⌘-click, a link that opens a new tab) opens in that group, at its end
    /// (`SidebarManager.groupForLink`).
    @Published var openLinksInGroup: Bool {
        didSet {
            guard openLinksInGroup != oldValue else { return }
            config.openLinksInGroup = openLinksInGroup
            saveConfig()
        }
    }

    @Published var downloadLocation: String {
        didSet {
            config.downloadLocation = downloadLocation
            saveConfig()
        }
    }
    
    @Published var appearanceMode: AppearanceMode {
        didSet {
            Logger.shared.info(.settings, "Appearance mode changed to: \(appearanceMode.rawValue)")
            config.appearanceMode = appearanceMode.rawValue
            saveConfig()
            // Apply the appearance change
            AppearanceManager.shared.setAppearance(appearanceMode)
        }
    }

    /// Settings › Appearance: a frame of window background around the web
    /// view (ContentView's `ContentAreaShape` and `BrowserWindowLayoutView`),
    /// not the sidebar.
    @Published var insetWebView: Bool {
        didSet {
            config.insetWebView = insetWebView
            saveConfig()
        }
    }

    /// Nil until one's chosen: the first one installed (`AIProvider.resolved`).
    @Published var aiProvider: AIProvider? {
        didSet {
            config.aiProvider = aiProvider?.rawValue ?? ""
            saveConfig()
        }
    }

    @Published var claudeModel: String {
        didSet {
            config.claudeModel = claudeModel
            saveConfig()
        }
    }

    @Published var codexModel: String {
        didSet {
            config.codexModel = codexModel
            saveConfig()
        }
    }

    @Published var aiModel: String {
        didSet {
            Logger.shared.info(.settings, "AI model changed to: \(aiModel)")
            config.aiModel = aiModel
            saveConfig()
        }
    }

    @Published var aiBaseURL: String {
        didSet {
            Logger.shared.info(.settings, "AI base URL changed to: \(aiBaseURL)")
            config.aiBaseURL = aiBaseURL
            saveConfig()
        }
    }

    @Published var offerToSavePasswords: Bool {
        didSet {
            config.offerToSavePasswords = offerToSavePasswords
            saveConfig()
        }
    }

    @Published var fillSignIns: Bool {
        didSet {
            config.fillSignIns = fillSignIns
            saveConfig()
        }
    }

    /// Read when a web view is configured, so it applies to tabs opened
    /// afterwards.
    @Published var offerPasskeys: Bool {
        didSet {
            config.offerPasskeys = offerPasskeys
            saveConfig()
        }
    }

    @Published var useApplePasswords: Bool {
        didSet {
            config.useApplePasswords = useApplePasswords
            saveConfig()
        }
    }

    @Published var fillContactDetails: Bool {
        didSet {
            config.fillContactDetails = fillContactDetails
            saveConfig()
        }
    }

    /// Settings › iCloud: CloudSyncManager follows it.
    @Published var syncWithICloud: Bool {
        didSet {
            Logger.shared.info(.settings, "Sync with iCloud turned \(syncWithICloud ? "on" : "off")")
            config.syncWithICloud = syncWithICloud
            saveConfig()
        }
    }

    /// Settings › General › Privacy: how long history is kept. Read by
    /// HistoryManager's cleanup, a minute after launch and once a day, so a
    /// shorter time picked by mistake removes nothing on the spot.
    @Published var historyRetention: HistoryRetention {
        didSet {
            guard historyRetention != oldValue else { return }
            Logger.shared.info(.settings, "History retention changed to: \(historyRetention.rawValue)")
            config.historyRetention = historyRetention.rawValue
            saveConfig()
        }
    }

    /// Settings › General › Privacy: known trackers don't load
    /// (TrackerBlocker). Open tabs follow from their next load.
    @Published var blockTrackers: Bool {
        didSet {
            guard blockTrackers != oldValue else { return }
            Logger.shared.info(.settings, "Block trackers turned \(blockTrackers ? "on" : "off")")
            config.blockTrackers = blockTrackers
            saveConfig()
            TrackerBlocker.shared.settingChanged()
        }
    }

    /// Settings › General › Privacy: whether every tab gets the protections
    /// private tabs have, fingerprinting protection included, while Block
    /// trackers is on (TrackerBlocker.setProtections). Open tabs follow from
    /// their next load.
    @Published var fingerprintingProtection: FingerprintingProtection {
        didSet {
            guard fingerprintingProtection != oldValue else { return }
            Logger.shared.info(.settings, "Fingerprinting protection changed to: \(fingerprintingProtection.rawValue)")
            config.fingerprintingProtection = fingerprintingProtection.rawValue
            saveConfig()
        }
    }

    /// Settings › General › Privacy: private tabs lock while the user is
    /// away (PrivateTabLock). Turning it off doesn't unlock them.
    @Published var lockPrivateTabs: Bool {
        didSet {
            guard lockPrivateTabs != oldValue else { return }
            Logger.shared.info(.settings, "Lock private tabs turned \(lockPrivateTabs ? "on" : "off")")
            config.lockPrivateTabs = lockPrivateTabs
            saveConfig()
        }
    }

    /// Settings › General › Web Developers: Inspect Element and remote
    /// inspection on every page (`WebViewConfiguration.showsDeveloperTools`,
    /// always on in Debug builds). Each Mac's own, not synced.
    @Published var webDeveloperTools: Bool {
        didSet {
            guard webDeveloperTools != oldValue else { return }
            Logger.shared.info(.settings, "Web developer tools turned \(webDeveloperTools ? "on" : "off")")
            config.webDeveloperTools = webDeveloperTools
            saveConfig()
            WebViewConfiguration.developerToolsSettingChanged()
        }
    }

    private var config: SettingsConfig
    private let configURL: URL
    
    private init() {
        // Create config directory if it doesn't exist
        let configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/klar")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        self.configURL = configDir.appendingPathComponent("config.toml")
        
        // Load existing config or create default
        if var loadedConfig = Self.loadConfig(from: configURL) {
            // Earlier versions always wrote Klar's list out; unchanged, it's still Klar's
            if loadedConfig.siteShortcuts == SiteShortcutPreset.defaults {
                loadedConfig.siteShortcuts = nil
            }
            self.config = loadedConfig
            Logger.shared.info(.settings, "Loaded settings from \(configURL.path)")
        } else {
            self.config = SettingsConfig.defaultConfig()
            Logger.shared.info(.settings, "Created default settings at \(configURL.path)")
        }
        
        // Initialize published properties
        self.defaultSearchEngine = DefaultSearchEngine(rawValue: config.defaultSearchEngine) ?? .duckduckgo
        self.customSearchEngineURL = config.customSearchEngineURL
        self.siteShortcuts = config.siteShortcuts ?? SiteShortcutPreset.defaults
        self.tabCloseAction = TabCloseAction(rawValue: config.tabCloseAction) ?? .never
        self.openLinksInGroup = config.openLinksInGroup
        self.downloadLocation = config.downloadLocation
        self.appearanceMode = AppearanceMode(rawValue: config.appearanceMode) ?? .system
        self.insetWebView = config.insetWebView
        self.aiProvider = AIProvider(rawValue: config.aiProvider)
        self.claudeModel = config.claudeModel
        self.codexModel = config.codexModel
        self.aiModel = config.aiModel
        self.aiBaseURL = config.aiBaseURL
        self.offerToSavePasswords = config.offerToSavePasswords
        self.fillSignIns = config.fillSignIns
        self.offerPasskeys = config.offerPasskeys
        self.useApplePasswords = config.useApplePasswords
        self.fillContactDetails = config.fillContactDetails
        self.syncWithICloud = config.syncWithICloud
        self.historyRetention = HistoryRetention(rawValue: config.historyRetention) ?? .oneYear
        self.blockTrackers = config.blockTrackers
        self.fingerprintingProtection = FingerprintingProtection(rawValue: config.fingerprintingProtection) ?? .privateTabs
        self.lockPrivateTabs = config.lockPrivateTabs
        self.webDeveloperTools = config.webDeveloperTools

        // Initialize appearance manager with saved setting
        AppearanceManager.shared.setAppearance(self.appearanceMode)

        // Save initial config if it didn't exist
        if !FileManager.default.fileExists(atPath: configURL.path) {
            saveConfig()
        }
    }
    
    private func saveConfig() {
        let tomlString = generateTOML(from: config)
        do {
            try tomlString.write(to: configURL, atomically: true, encoding: .utf8)
            Logger.shared.info(.settings, "Settings saved to \(configURL.path)")
        } catch {
            Logger.shared.error(.settings, "Failed to save settings: \(error)")
        }
        CloudSyncManager.localDataChanged(.settings)
    }
    
    private static func loadConfig(from url: URL) -> SettingsConfig? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return parseTOML(content)
    }
    
    private func generateTOML(from config: SettingsConfig) -> String {
        let q = Self.tomlString
        var toml = "# Klar Browser Settings\n"
        toml += "# Edit this file to customize your browser settings\n"
        toml += "# Available search engines: \(DefaultSearchEngine.allCases.map(\.rawValue).joined(separator: ", "))\n"
        toml += "# Available tab close actions: Never, End of Day, After 24 hours of inactivity, When Closing App\n"
        toml += "# Available appearance modes: Light, Dark, System\n"
        toml += "# Remove history items: \(HistoryRetention.allCases.map(\.rawValue).joined(separator: ", "))\n"


        
        toml += "[general]\n"
        toml += "default_search_engine = \(q(config.defaultSearchEngine))\n"
        toml += "custom_search_engine = \(q(config.customSearchEngineURL))\n"
        toml += "web_developer_tools = \(config.webDeveloperTools)\n\n"

        // Left out while they're Klar's own: no section means Klar's defaults
        if let siteShortcuts = config.siteShortcuts {
            toml += "[site_shortcuts]\n"
            toml += "# A word before a search sends it to the site: \"yt cats\". %s is where the words go.\n"
            toml += "# Remove this section to use Klar's own list.\n"
            for shortcut in siteShortcuts {
                toml += "\(q(shortcut.keyword)) = \(q(shortcut.url))\n"
            }
            toml += "\n"
        }
        
        toml += "[tabs]\n"
        toml += "close_action = \(q(config.tabCloseAction))\n"
        toml += "open_links_in_group = \(config.openLinksInGroup)\n\n"
        
        toml += "[downloads]\n"
        toml += "location = \(q(config.downloadLocation))\n\n"
        
        toml += "[appearance]\n"
        toml += "mode = \(q(config.appearanceMode))\n"
        toml += "inset_web_view = \(config.insetWebView)\n\n"

        toml += "[ai]\n"
        toml += "# Available providers: \(AIProvider.allCases.map(\.rawValue).joined(separator: ", ")); empty for the first one installed\n"
        toml += "provider = \(q(config.aiProvider))\n"
        toml += "claude_model = \(q(config.claudeModel))\n"
        toml += "codex_model = \(q(config.codexModel))\n"
        toml += "model = \(q(config.aiModel))\n"
        toml += "base_url = \(q(config.aiBaseURL))\n\n"

        toml += "[passwords]\n"
        toml += "offer_to_save = \(config.offerToSavePasswords)\n"
        toml += "fill_sign_ins = \(config.fillSignIns)\n"
        toml += "offer_passkeys = \(config.offerPasskeys)\n"
        toml += "apple_passwords = \(config.useApplePasswords)\n\n"

        toml += "[forms]\n"
        toml += "fill_contact_details = \(config.fillContactDetails)\n\n"

        toml += "[sync]\n"
        toml += "icloud = \(config.syncWithICloud)\n\n"

        toml += "[history]\n"
        toml += "remove_items = \(q(config.historyRetention))\n\n"

        toml += "[privacy]\n"
        toml += "block_trackers = \(config.blockTrackers)\n"
        toml += "fingerprinting_protection = \(q(config.fingerprintingProtection))\n"
        toml += "lock_private_tabs = \(config.lockPrivateTabs)\n\n"

        toml += "[feature_flags]\n"
        toml += "# WebKit feature overrides. Managed by Settings > Feature Flags.\n"
        toml += "# Absent key = use WebKit default. Present key = explicit override.\n"
        for key in config.featureFlags.keys.sorted() {
            let value = config.featureFlags[key] ?? false
            toml += "\(key) = \(value ? "true" : "false")\n"
        }
        toml += "\n"

        return toml
    }

    /// A TOML basic string: quoted, with quotes, backslashes and control
    /// characters escaped, so `parseValue` reads back the same text.
    private static func tomlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// A TOML value or key as text: a basic string unescaped, a literal
    /// string as is, anything else (bools, numbers, bare keys) up to a
    /// `#` comment. Whatever follows a string's closing quote is left out.
    private static func parseValue(_ raw: Substring) -> String {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("'") {
            return String(raw.dropFirst().prefix { $0 != "'" })
        }
        guard raw.hasPrefix("\"") else {
            return (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        var result = ""
        var scalars = raw.unicodeScalars.dropFirst().makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "\"":
                return result
            case "\\":
                guard let escaped = scalars.next() else { return result }
                switch escaped {
                case "n": result += "\n"
                case "r": result += "\r"
                case "t": result += "\t"
                case "b": result += "\u{08}"
                case "f": result += "\u{0C}"
                case "u", "U":
                    var digits = ""
                    for _ in 0..<(escaped == "u" ? 4 : 8) {
                        if let digit = scalars.next() { digits.unicodeScalars.append(digit) }
                    }
                    if let value = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(value) {
                        result.unicodeScalars.append(decoded)
                    }
                default: result.unicodeScalars.append(escaped)
                }
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
    
    private static func parseTOML(_ content: String) -> SettingsConfig? {
        var config = SettingsConfig.defaultConfig()
        var currentSection: String = ""

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Track section header (`[tabs] # comment` too)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                currentSection = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
                    .trimmingCharacters(in: .whitespaces)
                // Present, even if empty: the user's own list
                if currentSection == "site_shortcuts" && config.siteShortcuts == nil {
                    config.siteShortcuts = []
                }
                continue
            }

            // Parse key-value pairs (split on first '=': keys never contain one)
            guard let eqRange = trimmed.range(of: "=") else { continue }
            let key = parseValue(trimmed[..<eqRange.lowerBound])
            let value = parseValue(trimmed[eqRange.upperBound...])

            if currentSection == "site_shortcuts" {
                if SiteShortcut.isValidKeyword(key), SiteShortcut.isValidURL(value),
                   !(config.siteShortcuts ?? []).contains(where: { $0.id == key.lowercased() }) {
                    config.siteShortcuts?.append(SiteShortcut(keyword: key, url: value))
                }
                continue
            }

            if currentSection == "feature_flags" {
                let lowered = value.lowercased()
                if lowered == "true" {
                    config.featureFlags[key] = true
                } else if lowered == "false" {
                    config.featureFlags[key] = false
                }
                continue
            }

            switch (currentSection, key) {
            case ("general", "default_search_engine"):
                config.defaultSearchEngine = value
            case ("general", "custom_search_engine"):
                config.customSearchEngineURL = value
            case ("general", "web_developer_tools"):
                config.webDeveloperTools = value.lowercased() == "true"
            case ("tabs", "close_action"):
                config.tabCloseAction = value
            case ("tabs", "open_links_in_group"):
                config.openLinksInGroup = value.lowercased() == "true"
            case ("downloads", "location"):
                config.downloadLocation = value
            case ("appearance", "mode"):
                config.appearanceMode = value
            case ("appearance", "inset_web_view"):
                config.insetWebView = value.lowercased() == "true"
            case ("ai", "provider"):
                config.aiProvider = value
            case ("ai", "claude_model"):
                config.claudeModel = value
            case ("ai", "codex_model"):
                config.codexModel = value
            case ("ai", "model"):
                config.aiModel = value
            case ("ai", "base_url"):
                config.aiBaseURL = value
            case ("passwords", "offer_to_save"):
                config.offerToSavePasswords = value.lowercased() != "false"
            case ("passwords", "fill_sign_ins"):
                config.fillSignIns = value.lowercased() != "false"
            case ("passwords", "offer_passkeys"):
                config.offerPasskeys = value.lowercased() != "false"
            case ("passwords", "apple_passwords"):
                config.useApplePasswords = value.lowercased() != "false"
            case ("forms", "fill_contact_details"):
                config.fillContactDetails = value.lowercased() == "true"
            case ("sync", "icloud"):
                config.syncWithICloud = value.lowercased() == "true"
            case ("history", "remove_items"):
                config.historyRetention = value
            case ("privacy", "block_trackers"):
                config.blockTrackers = value.lowercased() != "false"
            case ("privacy", "fingerprinting_protection"):
                config.fingerprintingProtection = value
            case ("privacy", "lock_private_tabs"):
                config.lockPrivateTabs = value.lowercased() != "false"
            default:
                break
            }
        }

        return config
    }
    
    func selectDownloadLocation() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Choose Download Location"
        
        if let currentURL = URL(string: "file://" + downloadLocation) {
            openPanel.directoryURL = currentURL
        }
        
        openPanel.begin { response in
            if response == .OK, let selectedURL = openPanel.url {
                DispatchQueue.main.async {
                    self.downloadLocation = selectedURL.path
                }
            }
        }
    }
    
    func clearBrowsingData() {
        // Clear web data: the shared store and every space's separate profile
        let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        for store in SpaceManager.shared.allWebsiteDataStores {
            store.removeData(
                ofTypes: websiteDataTypes,
                modifiedSince: Date.distantPast
            ) {
                Logger.shared.info(.settings, "Cleared browsing data")
            }
        }
        let profileIDs = SpaceManager.shared.spaces.compactMap { $0.usesSeparateProfile ? $0.profileID : nil }
        
        // Clear favicon cache and history on main actor
        Task { @MainActor in
            await FaviconCacheManager.shared.clearAllCachedFavicons()
            HistoryManager.shared.clearHistory()
            for profileID in profileIDs {
                HistoryManager.forProfile(profileID).clearHistory()
            }
            Logger.shared.info(.settings, "Cleared all browsing data")
        }
    }
    
    func shouldCloseTabsAtEndOfDay() -> Bool {
        return tabCloseAction == .endOfDay
    }
    
    func shouldCloseTabsAfter24Hours() -> Bool {
        return tabCloseAction == .after24Hours
    }
    
    func getInactiveTabsOlderThan24Hours(from tabs: [BrowserTab]) -> [BrowserTab] {
        guard tabCloseAction == .after24Hours else { return [] }

        let cutoffTime = Date().addingTimeInterval(-24 * 60 * 60) // 24 hours ago
        return tabs.filter { tab in
            // Use lastActiveAt property from BrowserTab
            return tab.lastActiveAt < cutoffTime
        }
    }

    // MARK: - Feature Flags
    // Persistence backing for FeatureFlagsManager. Absence of a key in the
    // dict means "use WebKit's default"; presence means "explicit override".

    var featureFlagOverrides: [String: Bool] {
        config.featureFlags
    }

    func setFeatureFlag(_ key: String, enabled: Bool?) {
        if let enabled = enabled {
            config.featureFlags[key] = enabled
        } else {
            config.featureFlags.removeValue(forKey: key)
        }
        saveConfig()
    }

    func resetAllFeatureFlags() {
        config.featureFlags.removeAll()
        saveConfig()
    }
}
