import Foundation
import AppKit
import WebKit
import os

class DeepLinkHandler {
    static let shared = DeepLinkHandler()
    
    private init() {}
    
    /// UserDefaults key for storing always-open preferences
    private let alwaysOpenKey = "DeepLinkAlwaysOpen"
    
    /// Get stored always-open preferences
    private var alwaysOpenPreferences: [String: Bool] {
        get {
            return UserDefaults.standard.dictionary(forKey: alwaysOpenKey) as? [String: Bool] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: alwaysOpenKey)
            CloudSyncManager.localDataChanged(.settings)
        }
    }

    /// URL schemes whose apps open without asking. Synced with the settings
    /// (TOMLSettingsManager+CloudSync).
    var alwaysOpenSchemes: Set<String> {
        get {
            Set(alwaysOpenPreferences.filter { $0.value }.keys)
        }
        set {
            guard newValue != alwaysOpenSchemes else { return }
            alwaysOpenPreferences = Dictionary(uniqueKeysWithValues: newValue.map { ($0, true) })
        }
    }
    
    /// Check if a URL should be handled as a deep link
    func shouldHandleAsDeepLink(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        
        // Skip standard web protocols and internal browser schemes
        let webProtocols = ["http", "https", "file", "data", "javascript", "about", "blob", "ftp",
                            "chrome-extension", "webkit-extension", KlarSchemeHandler.scheme]
        if webProtocols.contains(scheme) {
            return false
        }
        
        // Handle ANY custom URL scheme that's not a web protocol
        return true
    }
    
    /// Handle a deep link URL by showing user confirmation and potentially opening external app
    func handleDeepLink(_ urlString: String, from webView: WKWebView) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased() else {
            return
        }
        
        // Nothing in the address opens an app without asking: one with
        // "callback" in it used to, as an app's sign-in coming back to it
        // does, but any page can write that into a link to any app. Such a
        // sign-in asks once, and Always Open covers the next ones.
        // Check if user has set always-open preference for this scheme
        if alwaysOpenPreferences[scheme] == true {
            openExternalApp(url: url)
            return
        }
        
        // Get the app name for the scheme
        let appName = getAppName(for: scheme)
        let domain = webView.url?.host ?? "this website"
        
        DispatchQueue.main.async {
            self.showDeepLinkDialog(
                url: url,
                appName: appName,
                domain: domain,
                from: webView
            )
        }
    }
    
    /// Show native dialog asking user permission to open external app
    private func showDeepLinkDialog(url: URL, appName: String, domain: String, from webView: WKWebView) {
        let alert = NSAlert()
        alert.messageText = "Open \"\(appName)\"?"
        alert.informativeText = "\"\(domain)\" wants to open \"\(appName)\"."
        alert.alertStyle = .informational
        
        // Get the actual app icon from the system
        let appIcon = getActualAppIcon(for: url)
        alert.icon = appIcon
        
        // Add buttons in the correct order (primary action first)
        alert.addButton(withTitle: "Open \"\(appName)\"")
        alert.addButton(withTitle: "Always open \"\(appName)\"")
        alert.addButton(withTitle: "Cancel")
        
        // Show as sheet if window is available, otherwise as modal
        if let window = webView.presentationWindow {
            alert.beginSheetModal(for: window) { response in
                self.handleDialogResponse(response, url: url)
            }
        } else {
            let response = alert.runModal()
            handleDialogResponse(response, url: url)
        }
    }
    
    /// Handle the user's response to the deep link dialog
    private func handleDialogResponse(_ response: NSApplication.ModalResponse, url: URL) {
        switch response {
        case .alertFirstButtonReturn: // Open [App Name]
            openExternalApp(url: url)
            
        case .alertSecondButtonReturn: // Always open [App Name]
            if let scheme = url.scheme?.lowercased() {
                // Save the always-open preference
                var prefs = alwaysOpenPreferences
                prefs[scheme] = true
                alwaysOpenPreferences = prefs
            }
            openExternalApp(url: url)
            
        case .alertThirdButtonReturn: // Cancel
            break
            
        default:
            break
        }
    }
    
    /// Open the external application
    private func openExternalApp(url: URL) {
        let success = NSWorkspace.shared.open(url)
        
        if !success {
            // Show error dialog on main thread
            DispatchQueue.main.async {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Unable to Open App"
                errorAlert.informativeText = "The requested application could not be opened. It may not be installed on your system."
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            }
        }
    }
    
    // MARK: - Public Utilities
    
    /// Get user-friendly app name for a URL scheme
    private func getAppName(for scheme: String) -> String {
        // First, try to get the actual app name from the system
        let testURL = URL(string: "\(scheme)://")!
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: testURL) {
            let appName = appURL.deletingPathExtension().lastPathComponent
            if !appName.isEmpty && appName != "Unknown" {
                return appName
            }
        }
        
        // Fallback to known scheme mappings for common apps
        switch scheme.lowercased() {
        case "macappstores", "macappstore", "itms-apps", "itms":
            return "App Store"
        case "zoom", "zoommtg", "zoomus":
            return "Zoom"
        case "skype":
            return "Skype"
        case "teams":
            return "Microsoft Teams"
        case "slack":
            return "Slack"
        case "discord":
            return "Discord"
        case "whatsapp":
            return "WhatsApp"
        case "telegram":
            return "Telegram"
        case "signal":
            return "Signal"
        case "facetime", "facetime-audio":
            return "FaceTime"
        case "xcode":
            return "Xcode"
        case "github-desktop":
            return "GitHub Desktop"
        case "sourcetree":
            return "Sourcetree"
        case "tower":
            return "Tower"
        case "fork":
            return "Fork"
        case "vscode", "code":
            return "Visual Studio Code"
        case "sublime":
            return "Sublime Text"
        case "atom":
            return "Atom"
        case "intellij":
            return "IntelliJ IDEA"
        case "spotify":
            return "Spotify"
        case "music", "apple-music":
            return "Music"
        case "youtube":
            return "YouTube"
        case "netflix":
            return "Netflix"
        case "vlc":
            return "VLC"
        case "notion":
            return "Notion"
        case "obsidian":
            return "Obsidian"
        case "bear":
            return "Bear"
        case "ulysses":
            return "Ulysses"
        case "things":
            return "Things"
        case "omnifocus":
            return "OmniFocus"
        case "evernote":
            return "Evernote"
        case "onenote":
            return "OneNote"
        case "drafts":
            return "Drafts"
        case "raycast":
            return "Raycast"
        case "firefox":
            return "Firefox"
        case "chrome":
            return "Chrome"
        case "safari":
            return "Safari"
        case "edge":
            return "Microsoft Edge"
        case "opera":
            return "Opera"
        case "mailto":
            return "Mail"
        case "tel":
            return "Phone"
        case "sms":
            return "Messages"
        case "maps":
            return "Maps"
        case "calendar":
            return "Calendar"
        case "contacts":
            return "Contacts"
        case "prefs", "app-prefs", "x-apple-systempreferences":
            return "System Preferences"
        case "steam":
            return "Steam"
        case "epic":
            return "Epic Games"
        case "battle":
            return "Battle.net"
        case "origin":
            return "Origin"
        case "uplay":
            return "Uplay"
        default:
            // For unknown schemes, try to extract a readable name from the scheme
            if scheme.contains(".") {
                // Handle reverse domain schemes like com.raycast-x.internal
                let components = scheme.components(separatedBy: ".")
                if let lastComponent = components.last, !lastComponent.isEmpty {
                    return lastComponent.capitalized
                }
                if components.count >= 2, let appPart = components.dropFirst().first {
                    return appPart.replacingOccurrences(of: "-", with: " ").capitalized
                }
            }
            return scheme.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    
    /// Get the actual app icon from the system for the URL scheme
    private func getActualAppIcon(for url: URL) -> NSImage {
        // Try to get the default app for this URL scheme
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            // Get the app icon from the app bundle
            let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            if appIcon.size.width > 0 { // Valid icon found
                return appIcon
            }
        }
        
        // Fallback to system icons if no specific app is found
        return getSystemIcon(for: url.scheme?.lowercased() ?? "")
    }
    
    /// Get system icon for common URL schemes (fallback when app not installed)
    private func getSystemIcon(for scheme: String) -> NSImage {
        switch scheme.lowercased() {
        case "macappstores", "macappstore", "itms-apps", "itms":
            return NSImage(systemSymbolName: "appstore", accessibilityDescription: "App Store") ?? NSImage(named: NSImage.applicationIconName)!
        case "mailto":
            return NSImage(systemSymbolName: "envelope", accessibilityDescription: "Mail") ?? NSImage(named: NSImage.applicationIconName)!
        case "tel":
            return NSImage(systemSymbolName: "phone", accessibilityDescription: "Phone") ?? NSImage(named: NSImage.applicationIconName)!
        case "sms":
            return NSImage(systemSymbolName: "message", accessibilityDescription: "Messages") ?? NSImage(named: NSImage.applicationIconName)!
        case "maps":
            return NSImage(systemSymbolName: "map", accessibilityDescription: "Maps") ?? NSImage(named: NSImage.applicationIconName)!
        case "calendar":
            return NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") ?? NSImage(named: NSImage.applicationIconName)!
        case "contacts":
            return NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Contacts") ?? NSImage(named: NSImage.applicationIconName)!
        case "zoom", "zoommtg", "zoomus":
            return NSImage(systemSymbolName: "video", accessibilityDescription: "Zoom") ?? NSImage(named: NSImage.applicationIconName)!
        case "facetime", "facetime-audio":
            return NSImage(systemSymbolName: "video", accessibilityDescription: "FaceTime") ?? NSImage(named: NSImage.applicationIconName)!
        case "music", "apple-music", "spotify":
            return NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music") ?? NSImage(named: NSImage.applicationIconName)!
        case "prefs", "app-prefs", "x-apple-systempreferences":
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: "System Preferences") ?? NSImage(named: NSImage.applicationIconName)!
        default:
            return NSImage(systemSymbolName: "app.badge", accessibilityDescription: "App") ?? NSImage(named: NSImage.applicationIconName)!
        }
    }
} 