import AppKit
import SwiftUI
import Combine

nonisolated enum FaviconStyle {
    static let cornerRadius: CGFloat = 4

    static var clipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
    }

    @MainActor static func clip(_ layer: CALayer?) {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }

    static func draggingContents(_ contents: Any, size: CGSize) -> Any {
        guard let image = contents as? NSImage else { return contents }
        return NSImage(size: size, flipped: false) { @Sendable rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.addPath(FaviconStyle.clipShape.path(in: rect).cgPath)
            context.clip()
            image.draw(in: rect)
            return true
        }
    }
}

final class FaviconImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        FaviconStyle.clip(layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Unified favicon view component that handles all favicon display logic consistently across the app
struct FaviconView: View {
    let url: String
    let size: CGFloat
    let fallbackIcon: String
    let fallbackText: String?
    let forceRefresh: Bool
    let cacheOnly: Bool

    @State private var favicon: NSImage? = nil
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>? = nil

    private let cacheManager = FaviconCacheManager.shared

    // MARK: - Initializers

    /// Standard favicon view with default settings
    init(url: String, size: CGFloat = 16, forceRefresh: Bool = false, cacheOnly: Bool = false) {
        self.url = url
        self.size = size
        self.fallbackIcon = "globe"
        self.fallbackText = nil
        self.forceRefresh = forceRefresh
        self.cacheOnly = cacheOnly
    }

    /// Favicon view with custom fallback icon
    init(url: String, size: CGFloat = 16, fallbackIcon: String, forceRefresh: Bool = false, cacheOnly: Bool = false) {
        self.url = url
        self.size = size
        self.fallbackIcon = fallbackIcon
        self.fallbackText = nil
        self.forceRefresh = forceRefresh
        self.cacheOnly = cacheOnly
    }

    /// Favicon view with a per-item text fallback (e.g. first letter of the domain).
    /// When the favicon is unavailable, the first character of `fallbackText` is rendered
    /// centered inside the size frame instead of an SF symbol.
    init(url: String, size: CGFloat = 16, fallbackText: String, forceRefresh: Bool = false, cacheOnly: Bool = false) {
        self.url = url
        self.size = size
        self.fallbackIcon = "globe"
        self.fallbackText = fallbackText
        self.forceRefresh = forceRefresh
        self.cacheOnly = cacheOnly
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let favicon = favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(FaviconStyle.clipShape)
            } else if let letter = fallbackLetter {
                Text(letter)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: fallbackIcon)
                    .foregroundColor(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            loadFavicon()
        }
        .onChange(of: url) { _, newURL in
            loadFavicon(for: newURL)
        }
        .onDisappear {
            cancelLoading()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faviconRefreshRequested)) { notification in
            // Check if this notification is for our URL
            if let refreshURL = notification.object as? String,
               refreshURL == self.url {
                loadFavicon(forceRefresh: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .faviconCached)) { notification in
            updateCachedFavicon(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .faviconAppearanceChanged)) { notification in
            updateCachedFavicon(notification)
        }
    }
    
    // MARK: - Private Computed Properties

    /// The single uppercased character to display when the favicon is unavailable
    /// and a `fallbackText` was supplied. Strips a leading "www." and skips any
    /// non-letter/digit prefix (e.g. punctuation) so an obvious initial wins.
    private var fallbackLetter: String? {
        guard let text = fallbackText, !text.isEmpty else { return nil }
        let trimmed = text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
        guard let scalar = trimmed.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return String(scalar).uppercased()
    }

    // MARK: - Private Methods

    private func updateCachedFavicon(_ notification: Notification) {
        if notification.userInfo?["private"] as? Bool == true { return }
        if let changedURL = notification.object as? String,
           cacheManager.generateCacheKey(for: changedURL) != cacheManager.generateCacheKey(for: url) { return }
        if let image = cacheManager.cachedFavicon(for: url) {
            cancelLoading()
            favicon = image
        }
    }
    
    private func loadFavicon(for targetURL: String? = nil, forceRefresh: Bool? = nil) {
        let urlToLoad = targetURL ?? url
        let shouldForceRefresh = forceRefresh ?? self.forceRefresh
        
        // Cancel any existing load task
        cancelLoading()
        
        // Skip if URL is empty
        guard !urlToLoad.isEmpty else {
            favicon = nil
            return
        }
        
        isLoading = true
        
        loadTask = Task { @MainActor in
            var loadedFavicon: NSImage?
            
            if shouldForceRefresh && !cacheOnly {
                // Force refresh: invalidate cache and re-download (only if not cache-only mode)
                loadedFavicon = await cacheManager.refreshFavicon(for: urlToLoad)
                
                // Post notification to other FaviconViews that this URL was refreshed
                if loadedFavicon != nil {
                    NotificationCenter.default.post(
                        name: .faviconCached,
                        object: urlToLoad,
                        userInfo: ["image": loadedFavicon!]
                    )
                }
            } else {
                loadedFavicon = cacheManager.cachedFavicon(for: urlToLoad)
                if loadedFavicon == nil, !cacheOnly {
                    let shouldThrottle = size == 22 && cacheManager.hasTooManyActiveRequests()
                    if !shouldThrottle {
                        loadedFavicon = await cacheManager.getFavicon(for: urlToLoad)
                    }
                }
            }
            
            // Only update if this is still the current load: cancelling
            // doesn't stop the lookup, and `self.url` here is the one this
            // load started with, so it can't tell.
            if !Task.isCancelled, urlToLoad == self.url {
                self.favicon = loadedFavicon
                self.isLoading = false
            }
        }
    }
    
    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }
}

// MARK: - Convenience Extensions

extension FaviconView {
    
    /// Title bar favicon (16x16)
    static func titleBar(url: String) -> FaviconView {
        FaviconView(url: url, size: 16)
    }
    
    /// Command palette favicon (22x22) - cache only to prevent excessive downloads
    static func commandPalette(url: String) -> FaviconView {
        FaviconView(url: url, size: 22, cacheOnly: true)
    }
    
    /// Sidebar favicon (16x16)
    static func sidebar(url: String) -> FaviconView {
        FaviconView(url: url, size: 16)
    }
    
    /// Custom size favicon
    static func custom(url: String, size: CGFloat, fallbackIcon: String = "globe", forceRefresh: Bool = false, cacheOnly: Bool = false) -> FaviconView {
        FaviconView(url: url, size: size, fallbackIcon: fallbackIcon, forceRefresh: forceRefresh, cacheOnly: cacheOnly)
    }
}

// MARK: - Preview

#if DEBUG
struct FaviconView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                FaviconView.titleBar(url: "https://apple.com")
                FaviconView.commandPalette(url: "https://github.com")
                FaviconView.sidebar(url: "https://swift.org")
            }
            
            HStack(spacing: 16) {
                FaviconView.custom(url: "https://google.com", size: 32)
                FaviconView.custom(url: "", size: 24, fallbackIcon: "star.fill")
            }
        }
        .padding()
    }
}
#endif 
