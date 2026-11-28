import Foundation

private let settingRecordType = "Setting"
private let settingRecordPrefix = "setting-"

/// The settings that sync, by record name (`setting-<raw value>`).
private enum SyncedSetting: String, CaseIterable {
    case searchEngine = "default_search_engine"
    /// The Custom engine's address.
    case customSearchEngine = "custom_search_engine"
    /// One "keyword address" per line, in order.
    case siteShortcuts = "site_shortcuts"
    case tabCloseAction = "close_action"
    case openLinksInGroup = "open_links_in_group"
    case appearance = "appearance_mode"
    case insetWebView = "inset_web_view"
    case offerToSavePasswords = "offer_to_save_passwords"
    case fillSignIns = "fill_sign_ins"
    case offerPasskeys = "offer_passkeys"
    case applePasswords = "apple_passwords"
    case fillContactDetails = "fill_contact_details"
    /// AutofillCoordinator's, one host per line.
    case neverSavePasswordSites = "never_save_password_sites"
    /// DeepLinkHandler's, one URL scheme per line.
    case alwaysOpenApps = "always_open_apps"
    case blockTrackers = "block_trackers"
    /// TrackerBlocker's sites whose trackers load, one host per line.
    case trackersAllowedSites = "trackers_allowed_sites"
    case fingerprintingProtection = "fingerprinting_protection"
    case lockPrivateTabs = "lock_private_tabs"
}

/// Settings in iCloud (CloudSyncManager), one record per setting, so
/// changing different ones on two Macs merges.
///
/// What depends on the Mac stays on it: the download folder, the AI
/// provider, models and server (tools installed on this Mac, a local Ollama),
/// WebKit feature flags, web developer tools, and whether this Mac syncs at all. So does how long
/// history is kept: history is each Mac's own, and a shorter time arriving
/// from another Mac would remove it here unasked.
@MainActor
extension TOMLSettingsManager: CloudSyncSource {
    var syncRecordTypes: Set<String> {
        [settingRecordType]
    }

    var isReadyForSync: Bool {
        true
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        var records: [String: CloudSyncRecord] = [:]
        for setting in SyncedSetting.allCases {
            records[settingRecordPrefix + setting.rawValue] = CloudSyncRecord(
                type: settingRecordType,
                fields: ["value": .string(syncedValue(of: setting))]
            )
        }
        return records
    }

    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        // A new Mac takes the settings iCloud has; settings are never deleted.
        for (name, record) in saved {
            guard name.hasPrefix(settingRecordPrefix),
                  let setting = SyncedSetting(rawValue: String(name.dropFirst(settingRecordPrefix.count))),
                  let value = record["value"]?.stringValue,
                  value != syncedValue(of: setting) else { continue }
            apply(value, to: setting)
        }
    }

    private func syncedValue(of setting: SyncedSetting) -> String {
        switch setting {
        case .searchEngine: return defaultSearchEngine.rawValue
        case .customSearchEngine: return customSearchEngineURL
        case .siteShortcuts: return siteShortcuts.map { "\($0.keyword) \($0.url)" }.joined(separator: "\n")
        case .tabCloseAction: return tabCloseAction.rawValue
        case .openLinksInGroup: return String(openLinksInGroup)
        case .appearance: return appearanceMode.rawValue
        case .insetWebView: return String(insetWebView)
        case .offerToSavePasswords: return String(offerToSavePasswords)
        case .fillSignIns: return String(fillSignIns)
        case .offerPasskeys: return String(offerPasskeys)
        case .applePasswords: return String(useApplePasswords)
        case .fillContactDetails: return String(fillContactDetails)
        case .neverSavePasswordSites: return AutofillCoordinator.neverSaveHosts.sorted().joined(separator: "\n")
        case .alwaysOpenApps: return DeepLinkHandler.shared.alwaysOpenSchemes.sorted().joined(separator: "\n")
        case .blockTrackers: return String(blockTrackers)
        case .trackersAllowedSites: return TrackerBlocker.shared.allowedHosts.sorted().joined(separator: "\n")
        case .fingerprintingProtection: return fingerprintingProtection.rawValue
        case .lockPrivateTabs: return String(lockPrivateTabs)
        }
    }

    /// Sets it as if the user had: the setter saves and applies it. A value
    /// this version doesn't know is ignored.
    private func apply(_ value: String, to setting: SyncedSetting) {
        logInfo(.sync, "Setting \(setting.rawValue) from iCloud")
        switch setting {
        case .searchEngine:
            if let engine = DefaultSearchEngine(rawValue: value) { defaultSearchEngine = engine }
        case .customSearchEngine:
            if value.isEmpty || SiteShortcut.isValidURL(value) { customSearchEngineURL = value }
        case .siteShortcuts:
            siteShortcuts = value.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, SiteShortcut.isValidKeyword(parts[0]), SiteShortcut.isValidURL(parts[1]) else { return nil }
                return SiteShortcut(keyword: parts[0], url: parts[1])
            }
        case .tabCloseAction:
            if let action = TabCloseAction(rawValue: value) { tabCloseAction = action }
        case .openLinksInGroup:
            if let enabled = Bool(value) { openLinksInGroup = enabled }
        case .appearance:
            if let mode = AppearanceMode(rawValue: value) { appearanceMode = mode }
        case .insetWebView:
            if let enabled = Bool(value) { insetWebView = enabled }
        case .offerToSavePasswords:
            if let enabled = Bool(value) { offerToSavePasswords = enabled }
        case .fillSignIns:
            if let enabled = Bool(value) { fillSignIns = enabled }
        case .offerPasskeys:
            if let enabled = Bool(value) { offerPasskeys = enabled }
        case .applePasswords:
            if let enabled = Bool(value) { useApplePasswords = enabled }
        case .fillContactDetails:
            if let enabled = Bool(value) { fillContactDetails = enabled }
        case .neverSavePasswordSites:
            AutofillCoordinator.neverSaveHosts = Self.lines(value)
        case .alwaysOpenApps:
            DeepLinkHandler.shared.alwaysOpenSchemes = Self.lines(value)
        case .blockTrackers:
            if let enabled = Bool(value) { blockTrackers = enabled }
        case .trackersAllowedSites:
            TrackerBlocker.shared.setAllowedHosts(Self.lines(value))
        case .fingerprintingProtection:
            if let protection = FingerprintingProtection(rawValue: value) { fingerprintingProtection = protection }
        case .lockPrivateTabs:
            if let enabled = Bool(value) { lockPrivateTabs = enabled }
        }
    }

    private static func lines(_ value: String) -> Set<String> {
        Set(value.split(separator: "\n").map(String.init))
    }
}
