import AppKit
import WebKit

/// The approvals Klar asks for, worded like Chrome's: adding an extension,
/// an update that wants more, an extension asking for more while it runs,
/// and removing one. Shown as a sheet on the frontmost window.
@MainActor
enum ExtensionPermissionPrompt {
    /// Chrome's warning for each permission that has one; the rest (storage,
    /// alarms, contextMenus, scripting, activeTab, …) don't warrant a line.
    private static let permissionWarnings: [String: String] = [
        "bookmarks": "Read and change your bookmarks",
        "clipboardRead": "Read data you copy and paste",
        "clipboardWrite": "Modify data you copy and paste",
        "contentSettings": "Change your settings that control websites' access to features such as cookies, JavaScript, location, microphone and camera",
        "debugger": "Access the page debugger backend",
        "declarativeNetRequest": "Block content on any page",
        "declarativeNetRequestFeedback": "Read your browsing history",
        "desktopCapture": "Capture content of your screen",
        "downloads": "Manage your downloads",
        "favicon": "Read the icons of the websites you visit",
        "geolocation": "Detect your physical location",
        "history": "Read and change your browsing history",
        "management": "Manage your apps, extensions, and themes",
        "nativeMessaging": "Communicate with cooperating native applications",
        "notifications": "Display notifications",
        "privacy": "Change your privacy-related settings",
        "proxy": "Read and change all your data on all websites",
        "readingList": "Read and change entries in the reading list",
        "sessions": "Read your browsing history",
        "tabs": "Read your browsing history",
        "topSites": "Read a list of your most frequently visited websites",
        "webNavigation": "Read your browsing history"
    ]

    private static let allSitesWarning = "Read and change all your data on all websites"

    /// Chrome's warnings for these permissions and sites, in the order it
    /// lists them: sites first.
    static func warnings(permissions: Set<String>, matchPatterns: Set<WKWebExtension.MatchPattern>) -> [String] {
        var lines: [String] = []
        if let siteWarning = siteWarning(for: matchPatterns) {
            lines.append(siteWarning)
        }
        for permission in permissions.sorted() {
            guard let warning = permissionWarnings[permission], !lines.contains(warning) else { continue }
            // Access to every site already covers what proxy implies.
            if warning == allSitesWarning, lines.first == allSitesWarning { continue }
            lines.append(warning)
        }
        return lines
    }

    /// What the manifest asks for at install time, as Chrome would list it.
    static func installWarnings(for webExtension: WKWebExtension) -> [String] {
        warnings(permissions: manifestPermissions(of: webExtension), matchPatterns: webExtension.allRequestedMatchPatterns)
    }

    /// The manifest's `permissions`, as written: WebKit leaves the ones it
    /// doesn't support out of `requestedPermissions`, but the user should
    /// still hear what the extension asks for.
    static func manifestPermissions(of webExtension: WKWebExtension) -> Set<String> {
        let listed = webExtension.manifest["permissions"] as? [Any] ?? []
        return Set(listed.compactMap { $0 as? String }.filter { !$0.contains("://") && $0 != "<all_urls>" })
    }

    /// Requested permissions this version of WebKit doesn't implement, less
    /// the ones store extensions get Klar's stand-ins for.
    static func unsupportedPermissions(of webExtension: WKWebExtension, source: ExtensionRecord.Source) -> [String] {
        var supported = Set(webExtension.requestedPermissions.map(\.rawValue))
        if source == .webStore {
            supported.formUnion(ExtensionCompatibility.standInPermissions)
        }
        return manifestPermissions(of: webExtension).subtracting(supported).sorted()
    }

    private static func siteWarning(for patterns: Set<WKWebExtension.MatchPattern>) -> String? {
        guard !patterns.isEmpty else { return nil }
        if patterns.contains(where: { $0.matchesAllURLs || $0.matchesAllHosts }) {
            return allSitesWarning
        }
        var hosts: [String] = []
        for pattern in patterns {
            guard let host = pattern.host, !host.isEmpty else { continue }
            let name = host.hasPrefix("*.") ? "all \(host.dropFirst(2)) sites" : host
            if !hosts.contains(name) { hosts.append(name) }
        }
        hosts.sort()
        switch hosts.count {
        case 0: return nil
        case 1: return "Read and change your data on \(hosts[0])"
        case 2: return "Read and change your data on \(hosts[0]) and \(hosts[1])"
        case 3: return "Read and change your data on \(hosts[0]), \(hosts[1]), and \(hosts[2])"
        default: return "Read and change your data on a number of websites"
        }
    }

    // MARK: - Prompts

    /// Asks before an extension is added. True to add it.
    static func confirmInstall(_ webExtension: WKWebExtension) async -> Bool {
        let name = webExtension.displayName ?? "this extension"
        var details = bulletList("It can:", installWarnings(for: webExtension))
        let unsupported = unsupportedPermissions(of: webExtension, source: .webStore)
        if !unsupported.isEmpty {
            details += (details.isEmpty ? "" : "\n\n")
                + "Klar doesn't support everything it uses yet (\(unsupported.joined(separator: ", "))), so parts of it may not work."
        }
        return await confirm(
            title: "Add “\(name)”?",
            details: details,
            confirmTitle: "Add Extension",
            icon: webExtension.icon(for: NSSize(width: 64, height: 64))
        )
    }

    /// Asks before installing an update that wants more than the user
    /// allowed so far.
    static func confirmUpdate(_ webExtension: WKWebExtension, newPermissions: Set<String>,
                              newMatchPatterns: Set<WKWebExtension.MatchPattern>) async -> Bool {
        let name = webExtension.displayName ?? "This extension"
        let lines = warnings(permissions: newPermissions, matchPatterns: newMatchPatterns)
        return await confirm(
            title: "Update “\(name)”?",
            details: bulletList("The new version also wants to:", lines.isEmpty ? ["Use more of Klar's features"] : lines),
            confirmTitle: "Update",
            icon: webExtension.icon(for: NSSize(width: 64, height: 64))
        )
    }

    /// Asks when a running extension requests more (permissions.request,
    /// or access to sites). True to allow.
    static func confirmRequest(from context: WKWebExtensionContext, permissions: Set<String>,
                               matchPatterns: Set<WKWebExtension.MatchPattern>) async -> Bool {
        let webExtension = context.webExtension
        let name = webExtension.displayName ?? "An extension"
        let lines = warnings(permissions: permissions, matchPatterns: matchPatterns)
        return await confirm(
            title: "“\(name)” wants more access",
            details: bulletList("It's asking to:", lines.isEmpty ? Array(permissions).sorted() : lines),
            confirmTitle: "Allow",
            cancelTitle: "Don't Allow",
            icon: webExtension.icon(for: NSSize(width: 64, height: 64))
        )
    }

    static func confirmRemoval(name: String, icon: NSImage?) async -> Bool {
        await confirm(
            title: "Remove “\(name)”?",
            details: "Its settings and data in Klar are removed too.",
            confirmTitle: "Remove",
            icon: icon,
            isDestructive: true
        )
    }

    static func showError(_ message: String, title: String = "Couldn't add the extension") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private static func bulletList(_ heading: String, _ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return heading + "\n" + lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private static func confirm(title: String, details: String, confirmTitle: String, cancelTitle: String = "Cancel",
                                icon: NSImage?, isDestructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        if let icon { alert.icon = icon }
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = isDestructive
        alert.addButton(withTitle: cancelTitle)
        return await withCheckedContinuation { continuation in
            present(alert) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// As a sheet on the frontmost titled window (Klar's window, or Settings
    /// when that's where the user is), else as a modal alert.
    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        if let window = candidates.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.attachedSheet == nil }) {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            NSApp.activate()
            completion(alert.runModal())
        }
    }
}
