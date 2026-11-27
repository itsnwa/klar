import AppKit

/// Checks and changes the system's default web browser: Klar, or any other
/// browser installed (Settings › General › Default Browser).
enum DefaultBrowser {
    private static let schemes = ["http", "https"]

    /// A browser installed on this Mac.
    struct Browser: Identifiable, Hashable {
        let bundleIdentifier: String
        let name: String
        let url: URL

        var id: String { bundleIdentifier }

        /// Its icon at menu size: a copy, so the workspace's own isn't resized.
        var icon: NSImage {
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
    }

    /// Whether Klar opens both http and https links. Compares bundle identifiers, not
    /// paths: the default is stored per bundle ID, and with several Klar copies installed
    /// (e.g. /Applications and a debug build) macOS may report another copy than this one.
    static var isDefault: Bool {
        isDefault(Bundle.main.bundleIdentifier)
    }

    private static func isDefault(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return schemes.allSatisfy { handler(for: $0) == bundleIdentifier }
    }

    /// The bundle identifier of the app that opens https links.
    static var currentBundleIdentifier: String? {
        handler(for: "https")
    }

    private static func handler(for scheme: String) -> String? {
        guard let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://example.com")!) else {
            return nil
        }
        return Bundle(url: handlerURL)?.bundleIdentifier
    }

    /// Every app that opens https links, by name, one copy each: this Klar
    /// for Klar's bundle identifier, the first macOS lists for the others.
    static var installedBrowsers: [Browser] {
        let link = URL(string: "https://example.com")!
        var browsers: [String: Browser] = [:]
        for url in NSWorkspace.shared.urlsForApplications(toOpen: link) {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { continue }
            let isThisKlar = url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            guard browsers[bundleIdentifier] == nil || isThisKlar else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            browsers[bundleIdentifier] = Browser(bundleIdentifier: bundleIdentifier, name: name, url: url)
        }
        return browsers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Asks macOS to make Klar the default browser.
    static func makeDefault(completion: (@MainActor (Bool) -> Void)? = nil) {
        makeDefault(appAt: Bundle.main.bundleURL) { _ in
            completion?(isDefault)
        }
    }

    /// Asks macOS to make the app at `appURL` the default browser. The
    /// system shows its own confirmation, and setting http changes https
    /// along with it; https is set on its own only if it didn't follow.
    /// `completion` runs on the main actor once the user has answered, with
    /// whether that app is the default now.
    static func makeDefault(appAt appURL: URL, completion: (@MainActor (Bool) -> Void)? = nil) {
        let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in
                if let error {
                    logWarning(.general, "Setting default browser for http failed: \(error.localizedDescription)")
                    completion?(isDefault(bundleIdentifier))
                    return
                }
                guard !isDefault(bundleIdentifier) else {
                    completion?(true)
                    return
                }
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
                    Task { @MainActor in
                        if let error {
                            logWarning(.general, "Setting default browser for https failed: \(error.localizedDescription)")
                        }
                        completion?(isDefault(bundleIdentifier))
                    }
                }
            }
        }
    }
}
