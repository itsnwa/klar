import SwiftUI
import AppKit

struct DirectURLRow: View {
    let url: String
    let isSelected: Bool
    /// A popular site's URL (see `PopularSites`), shown with its icon.
    var isPopularSite = false

    var body: some View {
        let deepLinkApp = DeepLinkApp.forURL(url)

        HStack(spacing: 12) {
            // Icon based on URL type
            if isPopularSite {
                FaviconView(url: url, size: 22)
            } else if let appIcon = deepLinkApp?.icon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22, alignment: .center)
            } else {
                Image(systemName: deepLinkApp != nil ? "arrow.up.right.square" : "globe")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .primary.opacity(0.8))
                    .frame(width: 22, height: 22, alignment: .center)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(deepLinkApp.map { "Open in \($0.name)" } ?? "Go to URL")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                
                Text(url)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .primary.opacity(0.6))
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
}

/// The app a deep link opens. LaunchServices lookups are too slow to repeat
/// on every render, so they're made once per URL scheme.
private struct DeepLinkApp {
    let name: String
    let icon: NSImage?

    @MainActor private static var appsByScheme: [String: DeepLinkApp] = [:]

    /// Nil for URLs that aren't deep links.
    @MainActor static func forURL(_ url: String) -> DeepLinkApp? {
        guard DeepLinkHandler.shared.shouldHandleAsDeepLink(url),
              let urlObj = URL(string: url),
              let scheme = urlObj.scheme else {
            return nil
        }

        let key = scheme.lowercased()
        if let app = appsByScheme[key] {
            return app
        }
        let app = lookUp(urlObj, scheme: scheme)
        appsByScheme[key] = app
        return app
    }

    private static func lookUp(_ url: URL, scheme: String) -> DeepLinkApp {
        // Try to get the default app for this URL scheme
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            // Get the app icon from the app bundle
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            let appName = appURL.deletingPathExtension().lastPathComponent
            return DeepLinkApp(
                name: !appName.isEmpty && appName != "Unknown" ? appName : nameFromScheme(scheme),
                icon: icon.size.width > 0 ? icon : nil // If no specific app icon found, use the fallback
            )
        }
        return DeepLinkApp(name: nameFromScheme(scheme), icon: nil)
    }

    /// Fallback to a name derived from the scheme (DeepLinkHandler's own is private)
    private static func nameFromScheme(_ scheme: String) -> String {
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
