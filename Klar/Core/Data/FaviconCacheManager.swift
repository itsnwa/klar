import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import Combine

nonisolated enum FaviconColorScheme: String, CaseIterable, Sendable {
    case light, dark

    @MainActor static var current: Self {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// High-performance favicon cache manager with LRU eviction and automatic optimization
@MainActor
class FaviconCacheManager: ObservableObject {
    static let shared = FaviconCacheManager()
    
    // MARK: - Store

    /// The icons kept on disk, opened on the first lookup. Used on the main
    /// actor: a lookup by key takes microseconds, less than a hop to a queue
    /// and back. Nil if it couldn't be opened (logged): icons are then kept
    /// in memory only, until the next launch.
    private lazy var database: SQLiteDatabase? = Self.openDatabase()

    /// A site's icon (by cache key, `generateCacheKey`), already made small
    /// (`optimizeFaviconData`). Eviction and cleanup go by last use.
    private nonisolated static let schema = """
        CREATE TABLE icons (
            cache_key TEXT PRIMARY KEY NOT NULL,
            data BLOB NOT NULL,
            created_at REAL NOT NULL,
            last_accessed_at REAL NOT NULL
        );
        CREATE INDEX icons_by_last_access ON icons (last_accessed_at);
        """

    private struct StoredIcon {
        let data: Data
        let createdAt: Date
        let lastAccessedAt: Date
    }

    /// Opens (or creates) `Application Support/Klar/Favicons.sqlite`,
    /// bringing in the icons the Core Data store there had.
    private nonisolated static func openDatabase() -> SQLiteDatabase? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try SQLiteDatabase(url: directory.appendingPathComponent("Favicons.sqlite"))
            if try database.userVersion() < 1 {
                try database.transaction {
                    try database.execute(schema)
                    try database.setUserVersion(1)
                }
            }
            importCoreDataIcons(in: directory, into: database)
            return database
        } catch {
            logError(.persistence, "Failed to open the favicon cache: \(error)")
            return nil
        }
    }

    /// Brings in the icons Klar kept with Core Data (`FaviconCache.sqlite`),
    /// then deletes that store, and the one before it. Core Data put a byte
    /// before each icon: 1 when the icon follows, 2 when it's in a file of
    /// its own (never for an icon this small; left out). If the import
    /// fails, the old store stays, and is tried again next launch.
    private nonisolated static func importCoreDataIcons(in directory: URL, into database: SQLiteDatabase) {
        let fileManager = FileManager.default
        func remove(_ names: [String]) {
            for name in names {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        // The store used before Core Data's history tracking was turned off.
        remove([
            "FaviconCacheDataModel.sqlite", "FaviconCacheDataModel.sqlite-shm",
            "FaviconCacheDataModel.sqlite-wal", ".FaviconCacheDataModel_SUPPORT"
        ])

        let legacyURL = directory.appendingPathComponent("FaviconCache.sqlite")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        do {
            try database.run("ATTACH DATABASE ? AS legacy", legacyURL.path)
            let imported: Int
            do {
                let hasEntries = try !database.query(
                    "SELECT 1 FROM legacy.sqlite_master WHERE name = 'ZFAVICONCACHEENTITY'"
                ) { _ in true }.isEmpty
                let now = Date()
                // Most recently used first, so that one is kept of any two
                // for the same site.
                imported = try !hasEntries ? 0 : database.transaction {
                    try database.run("""
                        INSERT OR IGNORE INTO icons (cache_key, data, created_at, last_accessed_at)
                        SELECT ZCACHEKEY, substr(ZFAVICONDATA, 2),
                               COALESCE(ZCREATEDAT, ?1), COALESCE(ZLASTACCESSEDAT, ZCREATEDAT, ?1)
                        FROM legacy.ZFAVICONCACHEENTITY
                        WHERE ZCACHEKEY IS NOT NULL
                          AND substr(ZFAVICONDATA, 1, 1) = x'01' AND length(ZFAVICONDATA) > 1
                        ORDER BY ZLASTACCESSEDAT DESC
                        """, now)
                }
            } catch {
                _ = try? database.run("DETACH DATABASE legacy")
                throw error
            }
            try database.run("DETACH DATABASE legacy")

            remove(["FaviconCache.sqlite", "FaviconCache.sqlite-shm", "FaviconCache.sqlite-wal", ".FaviconCache_SUPPORT"])
            logInfo(.persistence, "Imported \(imported) favicons from Core Data")
        } catch {
            logError(.persistence, "Failed to import Core Data favicons: \(error)")
        }
    }

    private func storedIcon(cacheKey: String) -> StoredIcon? {
        do {
            return try database?.query(
                "SELECT data, created_at, last_accessed_at FROM icons WHERE cache_key = ?", cacheKey
            ) { (row: SQLiteRow) -> StoredIcon? in
                guard let data = row.data(0), let createdAt = row.date(1), let lastAccessedAt = row.date(2) else { return nil }
                return StoredIcon(data: data, createdAt: createdAt, lastAccessedAt: lastAccessedAt)
            }.first
        } catch {
            Logger.shared.error(.persistence, "Failed to fetch cached favicon: \(error)")
            return nil
        }
    }
    
    // MARK: - Configuration
    
    nonisolated private struct CacheConfig {
        static let maxCacheSize: Int = 500 // Maximum number of cached favicons
        static let maxUnusedDays: Int = 30 // Days before cleanup
        static let maxFaviconSize: Int = 1200 * 1024 // 1.2MB max per favicon
        static let maxHTMLSize: Int = 1024 * 1024 // Read of a page, for its head
        static let iconPixelSize: Int = 64 // Stored icons: 32 pt at 2x
        static let launchCleanupDelay: TimeInterval = 60 // First cleanup after launch
        static let backgroundCleanupInterval: TimeInterval = 24 * 60 * 60 // 24 hours
        static let missRetryInterval: TimeInterval = 10 * 60 // Before a site with no icon is asked again
        static let revalidateAfter: TimeInterval = 7 * 24 * 60 * 60 // Before a stored icon is looked up again
        static let saveDelay: TimeInterval = 30 // Last-use stamps and shrunk icons, saved together
    }
    
    // MARK: - Memory Cache for Performance
    
    private var memoryCache = NSCache<NSString, NSImage>()
    private let missingVariants = NSCache<NSString, NSNumber>()
    /// When `lastAccessedAt` was last brought up to date per cache key, this
    /// session (see `markAccessed`).
    private var accessNotedAt: [String: Date] = [:]
    /// Last uses not written yet, by cache key: saved together by `saveSoon`.
    private var pendingAccess: [String: Date] = [:]
    /// Stored icons shrunk (`loadStoredFavicon`), not written yet: saved
    /// with the last uses.
    private var pendingData: [String: Data] = [:]
    private var saveTask: Task<Void, Never>?
    /// Sites whose stored icon was checked for its age this launch.
    private var revalidatedKeys: Set<String> = []
    private var cleanupTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var observedAppearance = FaviconColorScheme.current
    /// Lookups under way, by cache key (the front page's, or a page's own
    /// icons): another ask for the same site's icon (its tab's row while
    /// the page fetches it) waits for that one.
    private var activeDownloads: [String: Task<NSImage?, Never>] = [:]
    private struct VariantDownload {
        let source: URL
        let task: Task<NSImage?, Never>
    }
    private var variantDownloads: [String: VariantDownload] = [:]
    private var variantSources: [String: URL] = [:]
    /// When each site's icon was last looked for and not found, this launch
    /// (by cache key): it isn't asked for again until `missRetryInterval`
    /// has passed, or the page is reloaded.
    private var missedAt: [String: Date] = [:]
    private let maxConcurrentDownloads = 5 // Limit for command palette efficiency

    /// Custom URLSession that respects SSL bypass settings for sites with
    /// certificate issues. No cookies or HTTP cache: those would be kept
    /// apart from the pages' website data, where Clear Data doesn't reach.
    private lazy var faviconURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: SSLBypassSessionDelegate(), delegateQueue: nil)
    }()

    /// For private tabs' icons: no cookies or cache kept on disk.
    private lazy var ephemeralFaviconURLSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        return URLSession(configuration: config, delegate: SSLBypassSessionDelegate(), delegateQueue: nil)
    }()
    
    // MARK: - Initialization
    
    private init() {
        setupMemoryCache()
        scheduleBackgroundCleanup()
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let current = FaviconColorScheme.current
                guard self.observedAppearance != current else { return }
                self.observedAppearance = current
                NotificationCenter.default.post(name: .faviconAppearanceChanged, object: nil)
            }
        }
    }
    
    private func setupMemoryCache() {
        // Cost is each image's decoded size (see `decodedCost`). Icons are
        // stored at most 64 px (16 KB decoded), so the count fits a big
        // sidebar's sites: opening a folder shows its rows' icons from here
        // in the first frame, rather than the globe until the store answers.
        memoryCache.countLimit = 400
        memoryCache.totalCostLimit = 8 * 1024 * 1024 // 8MB decoded
        missingVariants.countLimit = CacheConfig.maxCacheSize * 2
    }
    
    private func scheduleBackgroundCleanup() {
        // First a minute after launch: Klar is rarely open for the 24 hours
        // the interval alone takes, and the cleanup then never ran.
        let timer = Timer(
            fire: Date().addingTimeInterval(CacheConfig.launchCleanupDelay),
            interval: CacheConfig.backgroundCleanupInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performBackgroundCleanup()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }
    
    // MARK: - Public API
    
    /// `persist: false` (a private tab's page) fetches a missing icon
    /// without keeping it, or anything of the fetch, on disk: it's only in
    /// the memory cache, for this launch. `retryingMiss` asks a site again
    /// that had no icon a moment ago (a reload).
    func getFavicon(for url: String, persist: Bool = true, retryingMiss: Bool = false) async -> NSImage? {
        // An extension's own pages show its icon, Klar's its own.
        if let image = cachedFavicon(for: url, persist: persist) {
            return image
        }
        if url.hasPrefix("\(ExtensionManager.urlScheme)://") || KlarSchemeHandler.isPage(url) { return nil }

        _ = await downloadAndCacheFavicon(for: url, persist: persist, retryingMiss: retryingMiss)
        return cachedFavicon(for: url, persist: persist)
    }

    /// After a page of the site has loaded (not a private one's): an icon
    /// stored over a week ago is looked up again, once a launch, so a site
    /// that changed its icon (or another project on the same localhost
    /// port) shows the new one. The old icon stays until a new one is
    /// found. Returns the new icon, also posted as `.faviconCached`.
    func revalidateIfStale(for url: String) async -> NSImage? {
        guard URL(string: url)?.host != nil else { return nil }
        let cacheKey = generateCacheKey(for: url)
        guard revalidatedKeys.insert(cacheKey).inserted,
              let stored = storedIcon(cacheKey: cacheKey),
              Date().timeIntervalSince(stored.createdAt) > CacheConfig.revalidateAfter,
              await downloadAndCacheFavicon(for: url, persist: true, retryingMiss: true) != nil,
              let image = cachedFavicon(for: url) else {
            return nil
        }
        NotificationCenter.default.post(name: .faviconCached, object: url, userInfo: ["image": image])
        return image
    }

    /// Whether a page of the site should hand over the icons it lists
    /// (`cachePageIcon`): a web page's site with no icon kept yet, or one
    /// stored over a week ago and not looked up again this launch (not for
    /// a private tab's page, whose icon isn't kept).
    func wantsPageIcon(for url: String, persist: Bool) -> Bool {
        guard let siteURL = URL(string: url), siteURL.host != nil,
              let scheme = siteURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let cacheKey = generateCacheKey(for: url)
        if let stored = storedIcon(cacheKey: cacheKey) {
            return persist && !revalidatedKeys.contains(cacheKey)
                && Date().timeIntervalSince(stored.createdAt) > CacheConfig.revalidateAfter
        }
        return memoryCache.object(forKey: cacheKey as NSString) == nil
    }

    /// The site's icon from the icons a page of it lists, loaded by WebKit
    /// with the page's own cookies (`PageIconLoader`; `nextIcon` loads the
    /// next best, nil when none are left): a site behind a browser check
    /// answers the front-page lookup with the check's page, or a 403. Kept
    /// as any other, and posted as `.faviconCached`. If none of them is an
    /// image, the front page is looked up instead, unless it had no icon a
    /// moment ago. Nil when the site needs no icon (`wantsPageIcon`), or
    /// none was found.
    func cachePageIcon(for url: String, persist: Bool, nextIcon: @escaping @MainActor () async -> Data?) async -> NSImage? {
        let cacheKey = generateCacheKey(for: url)
        let lookupKey = persist ? cacheKey : "\(cacheKey)|private"
        // The tab's own lookup, started as the page did: its icon will do.
        if let lookup = activeDownloads[lookupKey], await lookup.value != nil { return nil }
        guard wantsPageIcon(for: url, persist: persist), let siteURL = URL(string: url) else { return nil }
        if persist { revalidatedKeys.insert(cacheKey) }
        let triesFrontPage = missedAt[lookupKey].map { Date().timeIntervalSince($0) >= CacheConfig.missRetryInterval } ?? true

        let lookup = Task { () -> NSImage? in
            while !Task.isCancelled, let data = await nextIcon() {
                if let smaller = await Self.optimizeFaviconData(data), !Task.isCancelled,
                   let image = self.storeFavicon(smaller, for: url, persist: persist) {
                    return image
                }
            }
            guard !Task.isCancelled, triesFrontPage else { return nil }
            return await self.download(siteURL: siteURL, for: url, persist: persist)
        }
        activeDownloads[lookupKey] = lookup
        let loadedImage = await lookup.value
        guard activeDownloads[lookupKey] == lookup else { return nil }
        activeDownloads[lookupKey] = nil
        let image = loadedImage.flatMap { _ in cachedFavicon(for: url, persist: persist) }
        if let image {
            missedAt[lookupKey] = nil
            NotificationCenter.default.post(name: .faviconCached, object: url, userInfo: ["image": image, "private": !persist])
        } else if triesFrontPage {
            missedAt[lookupKey] = Date()
        }
        return image
    }

    private func removeFavicon(cacheKey: String) {
        memoryCache.removeObject(forKey: cacheKey as NSString)
        pendingData[cacheKey] = nil
        
        do {
            try database?.run("DELETE FROM icons WHERE cache_key = ?", cacheKey)
        } catch {
            Logger.shared.error(.persistence, "Failed to remove favicon from cache: \(error)")
        }
    }
    
    func refreshFavicon(for url: String) async -> NSImage? {
        let cacheKey = generateCacheKey(for: url)
        for scheme in FaviconColorScheme.allCases {
            let key = variantKey(cacheKey, scheme: scheme, persist: true)
            variantDownloads.removeValue(forKey: key)?.task.cancel()
            variantSources[key] = nil
            removeFavicon(cacheKey: key)
        }
        removeFavicon(cacheKey: cacheKey)
        return await getFavicon(for: url, retryingMiss: true)
    }

    /// Writes what `saveSoon` holds now, at quit.
    func saveNow() {
        guard let task = saveTask else { return }
        task.cancel()
        writePendingChanges()
    }
    
    // MARK: - Public Cache Access Methods (for Command Palette efficiency)
  
    func generateCacheKey(for url: String) -> String {
        if let urlObj = URL(string: url),
           let host = urlObj.host {
            let hostKey = host.lowercased()
            
            if let port = urlObj.port {
                return "\(hostKey):\(port)"
            } else {
                let scheme = urlObj.scheme?.lowercased() ?? "http"
                let defaultPort = (scheme == "https") ? 443 : 80
                return "\(hostKey):\(defaultPort)"
            }
        }
        
        return String(url.hash)
    }
    
    private func variantKey(_ siteKey: String, scheme: FaviconColorScheme, persist: Bool) -> String {
        "\(siteKey)|\(persist ? "" : "private-")\(scheme.rawValue)"
    }

    /// Only github.com's standard icon uses this pairing. Its site theme can
    /// be fixed to light even while Klar is dark (or the other way round).
    nonisolated static func githubIconVariants(for icon: URL, on page: URL) -> [FaviconColorScheme: URL] {
        guard page.host?.lowercased() == "github.com",
              icon.scheme == "https", icon.host == "github.githubassets.com",
              ["/favicons/favicon.svg", "/favicons/favicon-dark.svg"].contains(icon.path) else { return [:] }
        return [
            .light: URL(string: "https://github.githubassets.com/favicons/favicon.svg")!,
            .dark: URL(string: "https://github.githubassets.com/favicons/favicon-dark.svg")!
        ]
    }

    /// Shares concurrent requests for the same variant. If a page swaps its
    /// link again while an older icon is loading, only the new one is kept.
    @discardableResult
    func cacheVariant(from source: URL, for url: String, scheme: FaviconColorScheme, persist: Bool) async -> NSImage? {
        guard let sourceScheme = source.scheme?.lowercased(), ["https", "http"].contains(sourceScheme),
              source.host != nil, source.user == nil, source.password == nil else { return nil }
        let key = variantKey(generateCacheKey(for: url), scheme: scheme, persist: persist)
        if variantSources[key] == source, let image = memoryCache.object(forKey: key as NSString) {
            return image
        }
        if let existing = variantDownloads[key] {
            if existing.source == source { return await existing.task.value }
            existing.task.cancel()
        }

        let session = persist ? faviconURLSession : ephemeralFaviconURLSession
        let task = Task { () -> NSImage? in
            guard let data = await Self.downloadFavicon(from: source, session: session), !Task.isCancelled,
                  let image = self.storeFavicon(data, cacheKey: key, persist: persist) else { return nil }
            self.missingVariants.removeObject(forKey: key as NSString)
            self.variantSources[key] = source
            if FaviconColorScheme.current == scheme {
                NotificationCenter.default.post(name: .faviconAppearanceChanged, object: url,
                                                userInfo: ["private": !persist])
            }
            return image
        }
        variantDownloads[key] = VariantDownload(source: source, task: task)
        let image = await task.value
        if variantDownloads[key]?.task == task { variantDownloads[key] = nil }
        return image
    }

    /// The icon for `url` when it's at hand without a fetch (in memory, or an
    /// extension's own), so a row can show it in the frame it appears.
    /// `persist: false` (a private tab's row) leaves the stored icon's last
    /// use as it was.
    func memoryCachedFavicon(for url: String, persist: Bool = true) -> NSImage? {
        cachedFavicon(for: url, persist: persist, memoryOnly: true)
    }

    func cachedFavicon(for url: String, persist: Bool = true, memoryOnly: Bool = false) -> NSImage? {
        if url.hasPrefix("\(ExtensionManager.urlScheme)://") {
            return ExtensionManager.shared.icon(forExtensionURL: url)
        }
        if KlarSchemeHandler.isPage(url) {
            return Self.klarPageIcon
        }
        let siteKey = generateCacheKey(for: url)
        let scheme = FaviconColorScheme.current
        if !persist, let image = memoryCache.object(forKey: variantKey(siteKey, scheme: scheme, persist: false) as NSString) {
            return image
        }

        let key = variantKey(siteKey, scheme: scheme, persist: true)
        if missingVariants.object(forKey: key as NSString) == nil {
            if let image = cachedIcon(key, persist: persist, memoryOnly: memoryOnly) { return image }
            if !memoryOnly { missingVariants.setObject(NSNumber(value: true), forKey: key as NSString) }
        }
        return cachedIcon(siteKey, persist: persist, memoryOnly: memoryOnly)
    }

    /// Klar's own pages' icon: the app icon cropped to its visible edges.
    /// The app icon keeps the icon grid's margin and shadow around its
    /// shape, which drew it smaller than other sites' icons.
    private static let klarPageIcon: NSImage = {
        let appIcon = NSApp.applicationIconImage ?? NSImage()
        let pixels = 128
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return appIcon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appIcon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(), let data = context.data else { return appIcon }

        // The shape's bounds: pixels at least half opaque, leaving out the shadow.
        let bytes = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        var minX = pixels, minY = pixels, maxX = -1, maxY = -1
        for y in 0..<pixels {
            for x in 0..<pixels where bytes[(y * pixels + x) * 4 + 3] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return appIcon }
        // Square, so the icon isn't stretched.
        let side = max(maxX - minX, maxY - minY) + 1
        let crop = CGRect(x: (minX + maxX + 1 - side) / 2, y: (minY + maxY + 1 - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: crop) else { return appIcon }
        return NSImage(cgImage: cropped, size: NSSize(width: side / 2, height: side / 2))
    }()

    private func cachedIcon(_ key: String, persist: Bool, memoryOnly: Bool) -> NSImage? {
        if let image = memoryCache.object(forKey: key as NSString) {
            if persist { markAccessed(cacheKey: key) }
            return image
        }
        guard !memoryOnly, let stored = storedIcon(cacheKey: key),
              let image = loadStoredFavicon(stored.data, cacheKey: key) else { return nil }
        if persist { markAccessed(cacheKey: key, storedAccess: stored.lastAccessedAt) }
        return image
    }
    
    func hasTooManyActiveRequests() -> Bool {
        activeDownloads.count + variantDownloads.count >= maxConcurrentDownloads
    }
    
    func clearAllCachedFavicons() async {
        memoryCache.removeAllObjects()
        missingVariants.removeAllObjects()
        saveTask?.cancel()
        saveTask = nil
        pendingAccess.removeAll()
        pendingData.removeAll()
        accessNotedAt.removeAll()
        revalidatedKeys.removeAll()
        for download in activeDownloads.values { download.cancel() }
        activeDownloads.removeAll()
        missedAt.removeAll()
        for download in variantDownloads.values { download.task.cancel() }
        variantDownloads.removeAll()
        variantSources.removeAll()
        
        do {
            try database?.run("DELETE FROM icons")
            try database?.execute("PRAGMA incremental_vacuum")
            Logger.shared.info(.persistence, "Successfully cleared all cached favicons")
        } catch {
            Logger.shared.error(.persistence, "Failed to clear favicon cache: \(error)")
        }
    }
    
    // MARK: - Private Implementation

    /// A stored icon, now in the memory cache too. One kept at full size by
    /// an earlier build (a 180–512 px touch icon, an SVG) is shown as it is
    /// and shrunk in the background for next time.
    private func loadStoredFavicon(_ data: Data, cacheKey: String) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: Self.decodedCost(of: image))
        if !Self.isSmallBitmap(image) {
            Task { [weak self] in
                guard let smaller = await Self.optimizeFaviconData(data), smaller != data,
                      let smallerImage = NSImage(data: smaller),
                      let self else { return }
                // Not if the icon was replaced or removed meanwhile.
                guard self.memoryCache.object(forKey: cacheKey as NSString) === image else { return }
                self.pendingData[cacheKey] = smaller
                self.memoryCache.setObject(smallerImage, forKey: cacheKey as NSString, cost: Self.decodedCost(of: smallerImage))
                self.saveSoon()
            }
        }
        return image
    }

    /// Keeps `last_accessed_at` current enough for eviction, which drops the
    /// least recently used icons first: at most once per icon per day,
    /// memory hits included (the busiest icons live in the memory cache).
    /// `storedAccess` is the stored one, when the icon was just read.
    /// Stamped in memory and saved with the others by `saveSoon`, not with
    /// a write of its own on the main thread for each row's icon.
    private func markAccessed(cacheKey: String, storedAccess: Date? = nil) {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        if let noted = accessNotedAt[cacheKey], now.timeIntervalSince(noted) < day { return }
        accessNotedAt[cacheKey] = now
        if let storedAccess, now.timeIntervalSince(storedAccess) < day { return }
        pendingAccess[cacheKey] = now
        saveSoon()
    }

    /// One save for what's changed over the next `saveDelay` seconds.
    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CacheConfig.saveDelay))
            guard !Task.isCancelled else { return }
            self?.writePendingChanges()
        }
    }

    private func writePendingChanges() {
        saveTask = nil
        guard !pendingAccess.isEmpty || !pendingData.isEmpty else { return }
        let stamps = pendingAccess
        let shrunk = pendingData
        pendingAccess.removeAll()
        pendingData.removeAll()
        guard let database else { return }
        do {
            try database.transaction {
                for (cacheKey, stamp) in stamps {
                    try database.run(
                        "UPDATE icons SET last_accessed_at = ?1 WHERE cache_key = ?2 AND last_accessed_at < ?1",
                        stamp, cacheKey
                    )
                }
                for (cacheKey, data) in shrunk {
                    try database.run("UPDATE icons SET data = ? WHERE cache_key = ?", data, cacheKey)
                }
            }
        } catch {
            Logger.shared.error(.persistence, "Failed to save favicon cache: \(error)")
        }
    }
    
    private func downloadAndCacheFavicon(for url: String, persist: Bool, retryingMiss: Bool = false) async -> NSImage? {
        guard let siteURL = URL(string: url) else { return nil }

        let siteKey = generateCacheKey(for: url)
        let lookupKey = persist ? siteKey : "\(siteKey)|private"
        if let download = activeDownloads[lookupKey] {
            return await download.value
        }
        // A site with no icon was asked again for every row of it that
        // came on screen and every page opened on it: five requests each.
        if !retryingMiss, let missed = missedAt[lookupKey],
           Date().timeIntervalSince(missed) < CacheConfig.missRetryInterval {
            return nil
        }
        let download = Task { await self.download(siteURL: siteURL, for: url, persist: persist) }
        activeDownloads[lookupKey] = download
        let image = await download.value
        // Not another lookup started since (a page's icons, `cachePageIcon`).
        if activeDownloads[lookupKey] == download {
            activeDownloads[lookupKey] = nil
            missedAt[lookupKey] = image == nil ? Date() : nil
        }
        return image
    }

    /// The site's front page, where its icons are looked up. Not the tab's
    /// own address: fetched a second time here, without the page's cookies
    /// and before the page itself, a link that only works once (a sign-in or
    /// verification link) could be used up by the icon lookup. Icons are
    /// kept by host anyway.
    nonisolated private static func frontPage(of siteURL: URL) -> URL {
        guard let scheme = siteURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else { return siteURL }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url ?? siteURL
    }

    /// The network reads, HTML parsing and image work run off the main actor.
    private func download(siteURL: URL, for url: String, persist: Bool) async -> NSImage? {
        let siteURL = Self.frontPage(of: siteURL)
        let session = persist ? faviconURLSession : ephemeralFaviconURLSession
        let links = await Self.extractFaviconLinksFromHTML(siteURL: siteURL, session: session, isPrivate: !persist)
        let current = FaviconColorScheme.current
        var variants: [FaviconColorScheme: NSImage] = [:]
        for scheme in [current, current == .dark ? .light : .dark] {
            for link in links where link.scheme == scheme {
                guard !Task.isCancelled else { return nil }
                if let image = await cacheVariant(from: link.url, for: url, scheme: scheme, persist: persist) {
                    variants[scheme] = image
                    break
                }
            }
        }
        if variants.count == FaviconColorScheme.allCases.count, let image = variants[FaviconColorScheme.current] {
            return image
        }

        let fallbackPaths = [
            "/apple-touch-icon.png",
            "/apple-touch-icon-precomposed.png",
            "/favicon.png",
            "/favicon.ico"
        ]
        let fallbackURLs = fallbackPaths.compactMap { URL(string: $0, relativeTo: siteURL) }
        
        for faviconURL in links.filter({ $0.scheme == nil }).map(\.url) + fallbackURLs {
            guard !Task.isCancelled else { return nil }
            if let faviconData = await Self.downloadFavicon(from: faviconURL, session: session),
               !Task.isCancelled,
               let image = storeFavicon(faviconData, for: url, persist: persist) {
                return image
            }
        }
        return variants[FaviconColorScheme.current]
    }

    /// Keeps an icon already made small (`optimizeFaviconData`): in the
    /// store unless `persist` is off, and in the memory cache.
    private func storeFavicon(_ data: Data, for url: String, persist: Bool) -> NSImage? {
        storeFavicon(data, cacheKey: generateCacheKey(for: url), persist: persist)
    }

    private func storeFavicon(_ data: Data, cacheKey: String, persist: Bool) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        if persist {
            guard saveFaviconToCache(data: data, cacheKey: cacheKey) else {
                Logger.shared.error(.persistence, "Failed to save favicon for \(cacheKey)")
                return nil
            }
        }
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: Self.decodedCost(of: image))
        return image
    }
    
    nonisolated private struct IconLink: Sendable {
        let url: URL
        let scheme: FaviconColorScheme?
    }

    @concurrent private static func extractFaviconLinksFromHTML(siteURL: URL, session: URLSession, isPrivate: Bool) async -> [IconLink] {
        do {
            var request = URLRequest(url: siteURL)
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("1", forHTTPHeaderField: "DNT")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.timeoutInterval = 10.0

            // Only the head is needed, and only from a page: a tab on a
            // download's address isn't one (a 700 MB disk image, read whole
            // and decoded as text on the main thread, hung Klar for a minute).
            guard let data = try await fetchPrefix(
                request,
                session: session,
                limit: CacheConfig.maxHTMLSize,
                isWanted: { response in
                    guard let mimeType = response.mimeType?.lowercased() else { return true }
                    return mimeType.contains("html") || mimeType.contains("xml")
                },
                endMarkers: ["</head>", "</HEAD>"]
            ) else {
                return []
            }

            var fullHtmlString: String?
            
            fullHtmlString = String(data: data, encoding: .utf8)
            
            if fullHtmlString == nil {
                fullHtmlString = String(data: data, encoding: .isoLatin1)
            }
            
            if fullHtmlString == nil {
                fullHtmlString = String(data: data, encoding: .windowsCP1252)
            }
            
            if fullHtmlString == nil {
                fullHtmlString = String(data: data, encoding: .ascii)
            }
            
            guard let htmlString = fullHtmlString else { 
                return [] 
            }
            
            let headEndRange = htmlString.range(of: "</head>", options: [.caseInsensitive])
            let htmlToProcess: String
            
            if let endRange = headEndRange {
                htmlToProcess = String(htmlString[..<endRange.upperBound])
            } else {
                htmlToProcess = String(htmlString.prefix(65536))
            }
            
            return parseFaviconLinksFromHTML(htmlToProcess, baseURL: siteURL)
        } catch {
            if !Task.isCancelled {
                Logger.shared.error(.persistence, "Failed to fetch HTML for favicon extraction from \(siteURL.absoluteString): \(error.localizedDescription)", isPrivate: isPrivate)
            }
            return []
        }
    }
    
    /// Parse HTML string to extract favicon link tags
    nonisolated private static func parseFaviconLinksFromHTML(_ html: String, baseURL: URL) -> [IconLink] {
        guard !html.isEmpty else { return [] }
        
        var faviconLinks: [IconLink] = []
        
        // Regular expression to match any link tag
        let linkPattern = #"<link[^>]*>"#
        // Updated patterns to handle both quoted and unquoted attributes
        let relPattern = #"rel\s*=\s*(?:["\']([^"\']+)["\']|([^\s>]+))"#
        let hrefPattern = #"href\s*=\s*(?:["\']([^"\']+)["\']|([^\s>]+))"#
        let sizePattern = #"sizes\s*=\s*(?:["\']([^"\']+)["\']|([^\s>]+))"#
        let mediaPattern = #"\smedia\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        let colorSchemePattern = #"^\s*\(\s*prefers-color-scheme\s*:\s*(light|dark)\s*\)\s*$"#
        
        do {
            let linkRegex = try NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive])
            let relRegex = try NSRegularExpression(pattern: relPattern, options: [.caseInsensitive])
            let hrefRegex = try NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive])
            let sizeRegex = try NSRegularExpression(pattern: sizePattern, options: [.caseInsensitive])
            let mediaRegex = try NSRegularExpression(pattern: mediaPattern, options: [.caseInsensitive])
            let colorSchemeRegex = try NSRegularExpression(pattern: colorSchemePattern, options: [.caseInsensitive])
            
            let nsString = html as NSString
            let linkMatches = linkRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            var faviconCandidates: [(link: IconLink, priority: Int)] = []
            
            for linkMatch in linkMatches {
                // Safety check for valid range
                guard linkMatch.range.location != NSNotFound,
                      linkMatch.range.location + linkMatch.range.length <= nsString.length else {
                    continue
                }
                
                let linkTag = nsString.substring(with: linkMatch.range)
                let tag = linkTag as NSString
                
                // Safety check for valid link tag
                guard tag.length > 0, tag.length < 10000 else { continue }
                
                // Check if this is a favicon-related link
                let relMatches = relRegex.matches(in: linkTag, options: [], range: NSRange(location: 0, length: tag.length))
                guard let relMatch = relMatches.first,
                      relMatch.numberOfRanges > 1 else { continue }
                
                // Extract rel value from either quoted (group 1) or unquoted (group 2) capture
                let relValue: String
                if relMatch.numberOfRanges > 2 && relMatch.range(at: 2).location != NSNotFound {
                    // Unquoted attribute - add safety check
                    let range = relMatch.range(at: 2)
                    guard range.location != NSNotFound,
                          range.location + range.length <= tag.length else { continue }
                    relValue = tag.substring(with: range).lowercased()
                } else {
                    // Quoted attribute - add safety check
                    let range = relMatch.range(at: 1)
                    guard range.location != NSNotFound,
                          range.location + range.length <= tag.length else { continue }
                    relValue = tag.substring(with: range).lowercased()
                }
                
                // Filter for icon-related rel attributes
                guard relValue.contains("icon") || relValue.contains("shortcut") else { continue }
                
                // Extract href attribute
                let hrefMatches = hrefRegex.matches(in: linkTag, options: [], range: NSRange(location: 0, length: tag.length))
                guard let hrefMatch = hrefMatches.first,
                      hrefMatch.numberOfRanges > 1 else { continue }
                
                // Extract href value from either quoted (group 1) or unquoted (group 2) capture
                let hrefValue: String
                if hrefMatch.numberOfRanges > 2 && hrefMatch.range(at: 2).location != NSNotFound {
                    // Unquoted attribute - add safety check
                    let range = hrefMatch.range(at: 2)
                    guard range.location != NSNotFound,
                          range.location + range.length <= tag.length else { continue }
                    hrefValue = tag.substring(with: range)
                } else {
                    // Quoted attribute - add safety check
                    let range = hrefMatch.range(at: 1)
                    guard range.location != NSNotFound,
                          range.location + range.length <= tag.length else { continue }
                    hrefValue = tag.substring(with: range)
                }
                
                // Decode HTML entities (e.g., &amp; -> &)
                let decodedHrefValue = decodeHTMLEntities(hrefValue)
                
                // Convert relative URLs to absolute
                let faviconURL: URL?
                if decodedHrefValue.hasPrefix("http") {
                    faviconURL = URL(string: decodedHrefValue)
                } else if decodedHrefValue.hasPrefix("//") {
                    faviconURL = URL(string: "\(baseURL.scheme ?? "https"):\(decodedHrefValue)")
                } else {
                    faviconURL = URL(string: decodedHrefValue, relativeTo: baseURL)
                }
                
                guard let url = faviconURL?.absoluteURL else { continue }
                let githubVariants = githubIconVariants(for: url, on: baseURL)
                if !githubVariants.isEmpty {
                    for (scheme, asset) in githubVariants {
                        faviconCandidates.append((IconLink(url: asset, scheme: scheme), Int.max))
                    }
                }

                var scheme: FaviconColorScheme?
                if let match = mediaRegex.firstMatch(in: linkTag, range: NSRange(location: 0, length: tag.length)),
                   let range = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                    let media = tag.substring(with: range).lowercased()
                    if media.contains("prefers-color-scheme") {
                        // Compound queries are evaluated by the loaded page.
                        let range = NSRange(media.startIndex..., in: media)
                        guard let match = colorSchemeRegex.firstMatch(in: media, range: range),
                              let value = Range(match.range(at: 1), in: media) else { continue }
                        scheme = FaviconColorScheme(rawValue: String(media[value]))
                    }
                }
                if faviconCandidates.contains(where: { $0.link.url == url && $0.link.scheme == scheme }) { continue }
                
                // Calculate priority based on quality factors
                let priority = calculateIconPriority(
                    relValue: relValue,
                    hrefValue: decodedHrefValue,
                    linkTag: linkTag,
                    sizeRegex: sizeRegex
                )
                
                faviconCandidates.append((IconLink(url: url, scheme: scheme), priority))
            }
            
            // Sort by priority (highest first) and extract URLs
            faviconLinks = faviconCandidates.sorted { $0.priority > $1.priority }.map(\.link)
            
        } catch {
            Logger.shared.error(.persistence, "Error parsing favicon links from HTML: \(error)")
        }
        
        return faviconLinks
    }
    
    /// Calculate icon priority based on multiple quality factors
    nonisolated private static func calculateIconPriority(
        relValue: String,
        hrefValue: String,
        linkTag: String,
        sizeRegex: NSRegularExpression
    ) -> Int {
        var priority = 0
        
        // Base priority by rel attribute type
        if relValue.contains("apple-touch-icon") && !relValue.contains("precomposed") {
            priority += 120 // Highest priority - Apple touch icons are usually highest resolution
        } else if relValue.contains("apple-touch-icon-precomposed") {
            priority += 110 // High priority for precomposed apple icons
        } else if relValue == "icon" {
            priority += 100 // High priority for standard icon
        } else if relValue == "shortcut icon" {
            priority += 90 // Good priority for shortcut icon
        } else if relValue.contains("mask-icon") {
            priority += 30 // SVG mask icons
        } else {
            priority += 10 // Other icon types
        }
        
        // File format quality bonus (based on URL extension)
        let hrefLower = hrefValue.lowercased()
        if hrefLower.contains(".svg") {
            priority += 50 // SVG is vector, scales perfectly
        } else if hrefLower.contains(".png") {
            priority += 40 // PNG supports transparency, good quality
        } else if hrefLower.contains(".webp") {
            priority += 35 // Modern format, good compression
        } else if hrefLower.contains(".jpg") || hrefLower.contains(".jpeg") {
            priority += 20 // JPEG is lossy, not ideal for icons
        } else if hrefLower.contains(".ico") {
            priority += 30 // ICO can contain multiple sizes
        } else if hrefLower.contains(".gif") {
            priority += 15 // GIF is old format, limited colors
        }
        
        // Size quality analysis
        let tag = linkTag as NSString
        let sizeMatches = sizeRegex.matches(in: linkTag, options: [], range: NSRange(location: 0, length: tag.length))
        if let sizeMatch = sizeMatches.first, sizeMatch.numberOfRanges > 1 {
            // Extract size value from either quoted (group 1) or unquoted (group 2) capture
            let sizeValue: String
            if sizeMatch.numberOfRanges > 2 && sizeMatch.range(at: 2).location != NSNotFound {
                // Unquoted attribute
                sizeValue = tag.substring(with: sizeMatch.range(at: 2)).lowercased()
            } else {
                // Quoted attribute
                sizeValue = tag.substring(with: sizeMatch.range(at: 1)).lowercased()
            }
            
            // Parse size values to get numeric dimensions
            let sizeBonus = calculateSizeBonus(sizeValue)
            priority += sizeBonus
        } else {
            // No size specified - could be any size (slight penalty)
            priority -= 5
        }
        
        // Type attribute bonus (indicates explicit MIME type)
        if linkTag.lowercased().contains("type=") {
            priority += 10 // Explicit type is good
        }
        
        // Modern/quality indicators in filename
        if hrefLower.contains("favicon") {
            priority += 20 // Explicitly named favicon
        }
        if hrefLower.contains("icon") && !hrefLower.contains("apple") {
            priority += 15 // Generic icon naming
        }
        if hrefLower.contains("logo") {
            priority += 10 // Logo might be favicon
        }
        
        // Quality penalties
        if hrefLower.contains("android") || hrefLower.contains("chrome") {
            priority += 25 // Android/Chrome icons are usually high res
        }
        if hrefLower.contains("ms-") || hrefLower.contains("microsoft") {
            priority += 20 // Microsoft tile icons
        }
        
        return max(priority, 1) // Ensure minimum priority of 1
    }
    
    /// Calculate size quality bonus based on dimensions
    nonisolated private static func calculateSizeBonus(_ sizeValue: String) -> Int {
        // Extract numeric dimensions
        let components = sizeValue.components(separatedBy: CharacterSet(charactersIn: "x×*"))
        guard components.count == 2,
              let width = Int(components[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(components[1].trimmingCharacters(in: .whitespaces)),
              width == height else { // Only square icons
            return 0
        }
        
        let size = width
        
        // Optimal sizes for different use cases (higher bonus for better sizes)
        switch size {
        case 32:
            return 50 // Perfect for our 32x32 optimization target
        case 64:
            return 45 // Great quality, good for scaling down
        case 48:
            return 40 // Good intermediate size
        case 16:
            return 35 // Standard favicon size
        case 128:
            return 30 // High resolution, but might be overkill
        case 96:
            return 25 // Good size
        case 24:
            return 20 // Decent size
        case 256, 512:
            return 15 // Very high res, good for quality but large
        case 144, 152, 180:
            return 25 // Common mobile sizes
        case 192:
            return 20 // Android standard
        default:
            if size >= 1024 {
                return 5 // Too large, might be slow to download
            } else if size >= 128 {
                return 10 // Large but reasonable
            } else if size >= 32 {
                return 15 // Good range
            } else {
                return 5 // Too small, likely poor quality
            }
        }
    }
    
    /// An icon's data, checked to be an image and made small enough to keep
    /// (`optimizeFaviconData`), or nil.
    @concurrent private static func downloadFavicon(from url: URL, session: URLSession) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue(WebViewConfiguration.safariUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("1", forHTTPHeaderField: "DNT")
            request.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("image", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.timeoutInterval = 10.0

            // One byte past the limit tells an icon that's too big.
            guard let data = try await fetchPrefix(
                request,
                session: session,
                limit: CacheConfig.maxFaviconSize + 1,
                isWanted: { response in
                    response.statusCode == 200
                        && response.expectedContentLength <= Int64(CacheConfig.maxFaviconSize)
                }
            ) else {
                return nil
            }

            guard data.count > 0 else {
                return nil
            }

            guard data.count <= CacheConfig.maxFaviconSize else {
                return nil
            }
            
            return await optimizeFaviconData(data)
        } catch {
            return nil
        }
    }

    /// The start of a response's body, read off the main actor: at most
    /// `limit` bytes, ending with the first of `endMarkers` if one turns up.
    /// Nil when the headers show the response isn't `isWanted`. Either way
    /// the transfer stops there rather than running to the end.
    nonisolated private static func fetchPrefix(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        isWanted: @Sendable (HTTPURLResponse) -> Bool,
        endMarkers: [String] = []
    ) async throws -> Data? {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let httpResponse = response as? HTTPURLResponse, isWanted(httpResponse) else {
            return nil
        }

        let markers = endMarkers.map { Data($0.utf8) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
            if markers.contains(where: { $0.last == byte && data.suffix($0.count) == $0 }) { break }
        }
        return data
    }

    /// What's kept of an icon, decided by its pixels rather than its bytes:
    /// a bitmap of at most 64 px as it is, anything bigger or vector (a
    /// 180–512 px touch icon, an SVG, often fewer bytes than its 64 px PNG
    /// but up to 1 MB decoded) drawn at 64 px (32 pt at 2x) as a PNG. Nil
    /// when it isn't an image. Off the main actor.
    @concurrent private static func optimizeFaviconData(_ data: Data) async -> Data? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        if isSmallBitmap(image) { return data }
        
        let pixels = CacheConfig.iconPixelSize
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return data
        }
        
        // Fitted, not stretched, for the odd icon that isn't square.
        let side = CGFloat(pixels)
        let size = image.size
        let scale = size.width > 0 && size.height > 0 ? min(side / size.width, side / size.height) : 1
        let drawnSize = size.width > 0 && size.height > 0
            ? NSSize(width: size.width * scale, height: size.height * scale)
            : NSSize(width: side, height: side)
        let rect = NSRect(
            x: (side - drawnSize.width) / 2,
            y: (side - drawnSize.height) / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = NSSize(width: side / 2, height: side / 2)
        return bitmap.representation(using: .png, properties: [:]) ?? data
    }
    
    /// Whether every one of the image's representations is a bitmap of at
    /// most `iconPixelSize` (an ICO holds several sizes).
    nonisolated private static func isSmallBitmap(_ image: NSImage) -> Bool {
        let representations = image.representations
        return !representations.isEmpty && representations.allSatisfy {
            $0 is NSBitmapImageRep && max($0.pixelsWide, $0.pixelsHigh) <= CacheConfig.iconPixelSize
        }
    }
    
    /// The memory cache's cost for an image: its bitmaps' decoded bytes.
    nonisolated private static func decodedCost(of image: NSImage) -> Int {
        let bytes = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        return bytes > 0 ? bytes : CacheConfig.iconPixelSize * CacheConfig.iconPixelSize * 4
    }
    
    /// Stores an icon for its site, replacing one stored before (an icon
    /// looked up again, `revalidateIfStale`).
    private func saveFaviconToCache(data: Data, cacheKey: String) -> Bool {
        // No store (it couldn't be opened): the memory cache alone keeps it.
        guard let database else { return true }
        pendingData[cacheKey] = nil
        let now = Date()
        do {
            try database.run("""
                INSERT INTO icons (cache_key, data, created_at, last_accessed_at) VALUES (?1, ?2, ?3, ?3)
                ON CONFLICT (cache_key) DO UPDATE SET
                    data = excluded.data, created_at = excluded.created_at, last_accessed_at = excluded.last_accessed_at
                """, cacheKey, data, now)
        } catch {
            Logger.shared.error(.persistence, "Failed to store favicon: \(error)")
            return false
        }
        enforceMaxCacheSize(in: database)
        return true
    }
    
    /// Over `maxCacheSize`, drops the least recently used icons, and 50 more
    /// so this doesn't run on every new site. The one just stored is the
    /// most recently used.
    private func enforceMaxCacheSize(in database: SQLiteDatabase) {
        do {
            let count = try database.query("SELECT count(*) FROM icons") { $0.int(0) }.first ?? 0
            guard count > CacheConfig.maxCacheSize else { return }
            // Eviction goes by last use: bring it up to date first.
            writePendingChanges()
            let evicted = try database.query("""
                DELETE FROM icons WHERE cache_key IN (
                    SELECT cache_key FROM icons ORDER BY last_accessed_at LIMIT ?
                ) RETURNING cache_key
                """, count - CacheConfig.maxCacheSize + 50) { $0.string(0) }
            for cacheKey in evicted {
                memoryCache.removeObject(forKey: cacheKey as NSString)
            }
            Logger.shared.info(.persistence, "Evicted \(evicted.count) old favicons from cache")
        } catch {
            Logger.shared.error(.persistence, "Failed to enforce cache size limit: \(error)")
        }
    }
    
    private func performBackgroundCleanup() {
        guard let database else { return }
        writePendingChanges()
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -CacheConfig.maxUnusedDays, to: Date()) ?? Date()
        
        do {
            let removed = try database.query(
                "DELETE FROM icons WHERE last_accessed_at < ? RETURNING cache_key", cutoffDate
            ) { $0.string(0) }
            for cacheKey in removed {
                memoryCache.removeObject(forKey: cacheKey as NSString)
            }
            if !removed.isEmpty {
                try database.execute("PRAGMA incremental_vacuum")
                Logger.shared.info(.persistence, "Background cleanup removed \(removed.count) unused favicons")
            }
        } catch {
            Logger.shared.error(.persistence, "Background cleanup failed: \(error)")
        }
    }
    
    /// Decode HTML entities in a string (e.g., &amp; -> &, &lt; -> <, &gt; -> >)
    nonisolated private static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        
        // Common HTML entities
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        
        // Handle numeric entities (&#123; -> character)
        let numericEntityPattern = "&#(\\d+);"
        if let regex = try? NSRegularExpression(pattern: numericEntityPattern, options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            
            // Process matches in reverse order to avoid index shifting
            for match in matches.reversed() {
                if match.numberOfRanges > 1 {
                    let numberRange = match.range(at: 1)
                    let numberString = nsString.substring(with: numberRange)
                    
                    if let charCode = Int(numberString),
                       let unicode = UnicodeScalar(charCode) {
                        let character = String(Character(unicode))
                        let fullRange = match.range(at: 0)
                        result = (result as NSString).replacingCharacters(in: fullRange, with: character)
                    }
                }
            }
        }
        
        return result
    }
    
    isolated deinit {
        cleanupTimer?.invalidate()
        // Note: faviconURLSession is not invalidated here as it's a singleton
        // and the class is @MainActor isolated (deinit is nonisolated)
    }
}
