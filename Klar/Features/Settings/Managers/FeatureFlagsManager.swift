import Foundation
import SwiftUI

// User-controlled WebKit feature flag overrides.
//
// Backed by `~/.config/klar/config.toml`'s `[feature_flags]` section, written
// through TOMLSettingsManager. Absence of a key in `overrides` means "use
// WebKit's default"; presence means "explicit override".
//
// Read at WKWebView creation time by WebViewConfiguration. Changes do not
// apply to live WebViews — WebKit bakes feature flags into prefs at init.
final class FeatureFlagsManager: ObservableObject {
    static let shared = FeatureFlagsManager()

    @Published private(set) var overrides: [String: Bool] = [:]

    private init() {
        self.overrides = TOMLSettingsManager.shared.featureFlagOverrides
    }

    // Set or clear an override. Pass `enabled: nil` to clear the override
    // (returning the flag to its WebKit default).
    func setOverride(_ key: String, enabled: Bool?) {
        TOMLSettingsManager.shared.setFeatureFlag(key, enabled: enabled)
        if let enabled = enabled {
            overrides[key] = enabled
        } else {
            overrides.removeValue(forKey: key)
        }
        Logger.shared.info(.settings, "Feature flag override \(key) = \(enabled.map { String($0) } ?? "default")")
    }

    func resetAll() {
        TOMLSettingsManager.shared.resetAllFeatureFlags()
        overrides.removeAll()
        Logger.shared.info(.settings, "All WebKit feature flag overrides reset")
    }

    func isOverridden(_ key: String) -> Bool {
        overrides[key] != nil
    }

    func effectiveValue(for feature: WebKitFeature) -> Bool {
        overrides[feature.key] ?? feature.defaultValue
    }

    // Keys present in the override dict that don't match any known WebKit
    // feature — surfaces stale TOML entries (renamed/removed flags) so the
    // UI can offer to clean them up.
    func unknownOverrideKeys() -> [String] {
        let known = Set(WebKitFeatureRegistry.allFeatures.map(\.key))
        return overrides.keys.filter { !known.contains($0) }.sorted()
    }
}
