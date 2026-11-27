import Foundation
import Combine

/// Browsing history, in a SQLite database of its own
/// (`History.sqlite`): one row per address, with its title, visit count and
/// last visit.
///
/// Every read and write runs on one serial queue: page loads never wait on
/// the main thread, and writes are serialized. Titles and addresses are
/// searched through an FTS5 trigram index, which finds text anywhere in them
/// without scanning the table.
@MainActor
final class HistoryManager: ObservableObject {
    /// The history of the shared profile: every space without one of its own.
    static let shared = HistoryManager(directory: HistoryManager.historyDirectory)

    /// The history of each space with a separate profile, loaded when first used.
    private static var profiles: [UUID: HistoryManager] = [:]

    /// The history of a separate profile, or the shared one for nil.
    static func forProfile(_ profileID: UUID?) -> HistoryManager {
        guard let profileID else { return shared }
        if let history = profiles[profileID] {
            return history
        }
        let history = HistoryManager(directory: profileDirectory(profileID))
        profiles[profileID] = history
        return history
    }

    /// Deletes a separate profile's history store.
    static func deleteProfile(_ profileID: UUID) {
        let history = profiles.removeValue(forKey: profileID)
        history?.cleanupTimer?.invalidate()
        let directory = profileDirectory(profileID)
        guard let history else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        history.recentEntries = []
        history.store.close {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Application Support/Klar
    private nonisolated static var historyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klar", isDirectory: true)
    }

    private nonisolated static func profileDirectory(_ profileID: UUID) -> URL {
        historyDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    /// The most recently visited entries, newest first.
    @Published private(set) var recentEntries: [HistoryEntryData] = []

    /// What changed, for a list that holds more than `recentEntries` (the
    /// History list), so it can follow without fetching everything again.
    let changes = PassthroughSubject<HistoryChange, Never>()

    private let store: HistoryStore
    private var cleanupTimer: Timer?
    /// Numbers the refetches of `recentEntries`, so an older one landing
    /// late can't bring back an entry deleted since.
    private var recentEntriesGeneration = 0

    // MARK: - Initialization

    private init(directory: URL) {
        // Opened on the store's queue, ahead of anything else enqueued
        // there, so launch doesn't wait on it.
        store = HistoryStore { Self.openDatabase(in: directory) }

        let generation = nextRecentEntriesGeneration()
        store.async { [weak self] database in
            let recent = Self.fetchRecentEntries(in: database)
            Task { @MainActor [weak self] in
                self?.applyRecentEntries(recent, generation: generation)
            }
        }

        schedulePeriodicCleanup()
    }

    // MARK: - Public API

    /// Records a visit to `url` (main public interface).
    func addHistoryEntry(url: String, title: String) {
        // Validate URL is not empty and is a valid URL
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else {
            logWarning(.history, "Skipping invalid or empty URL: '\(url)'")
            return
        }

        guard !Self.shouldIgnoreURL(trimmedURL) else {
            return
        }

        let domain = Self.extractDomainFromURL(trimmedURL)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? domain ?? "Untitled" : trimmedTitle

        // Final validation - ensure we have both URL and title
        guard !finalTitle.isEmpty else {
            return
        }

        store.async { [weak self] database in
            guard let entry = Self.recordVisit(url: trimmedURL, title: finalTitle, in: database) else { return }
            Task { @MainActor [weak self] in
                self?.noteVisit(entry)
            }
        }
    }

    /// History entries whose title or URL contain `searchText`, most visited
    /// first; the most recent entries when it's empty. The store is searched
    /// off the main thread.
    func getURLSuggestions(for searchText: String, limit: Int = 8) async -> [HistoryEntryData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !query.isEmpty else {
            return Array(recentEntries.prefix(limit))
        }

        return await store.perform(or: []) { database in
            Self.searchEntries(matching: query, order: .mostVisited, limit: limit, in: database)
        }
    }

    /// A site's earlier searches: entries whose title or URL contain
    /// `prefix` (its address up to the words) and each of `words`, as typed
    /// or percent-encoded as in an address, most visited first. A word under
    /// three characters can't be looked up in the index, so it's left out:
    /// the caller checks the words read back from each address anyway.
    func siteSearches(prefix: String, words: [String], limit: Int) async -> [HistoryEntryData] {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty else { return [] }

        let wordForms = words.map { word in
            [word, word.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters)]
                .compactMap { $0 }
                .reduce(into: [String]()) { forms, form in
                    if !forms.contains(form) { forms.append(form) }
                }
        }.filter { forms in
            forms.allSatisfy { $0.unicodeScalars.count >= 3 }
        }

        return await store.perform(or: []) { database in
            guard prefix.unicodeScalars.count >= 3 else {
                return Self.searchEntries(matching: prefix, order: .mostVisited, limit: limit, in: database)
            }
            let expression = ([[prefix]] + wordForms)
                .map { forms in "(" + forms.map(Self.ftsPhrase).joined(separator: " OR ") + ")" }
                .joined(separator: " AND ")
            return Self.fetchEntries("""
                SELECT pages.url, pages.title, last_visited_at, visit_count
                FROM pages_search JOIN pages ON pages.id = pages_search.rowid
                WHERE pages_search MATCH ?
                ORDER BY \(SearchOrder.mostVisited.rawValue) LIMIT ?
                """, [expression, limit], in: database)
        }
    }

    /// What an address leaves as it is (RFC 3986's unreserved characters)
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    /// Entries last visited before `date` (all when nil), newest first, `limit`
    /// at a time: the pages of the full History list.
    func entries(visitedBefore date: Date?, limit: Int) async -> [HistoryEntryData] {
        await store.perform(or: []) { database in
            Self.fetchEntries("""
                SELECT url, title, last_visited_at, visit_count FROM pages
                WHERE last_visited_at < ?
                ORDER BY last_visited_at DESC LIMIT ?
                """, [date ?? Date.distantFuture, limit], in: database)
        }
    }

    /// Entries whose title or URL contain `query`, newest first: the History
    /// list's search.
    func searchEntries(matching query: String, limit: Int) async -> [HistoryEntryData] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return await store.perform(or: []) { database in
            Self.searchEntries(matching: query, order: .newest, limit: limit, in: database)
        }
    }

    /// Clear all history
    func clearHistory() {
        recentEntries = []
        let generation = nextRecentEntriesGeneration()
        store.async { [weak self] database in
            Self.deleteAllHistory(in: database)
            // A visit recorded just before may already have reached the list.
            let recent = Self.fetchRecentEntries(in: database)
            Task { @MainActor [weak self] in
                self?.applyRecentEntries(recent, generation: generation)
            }
        }
        // Its refetch is queued after the deletion.
        changes.send(.reloaded)
    }

    /// Removes the entry for the entry's URL.
    func removeEntry(_ entry: HistoryEntryData) {
        let url = entry.url
        // Off the lists right away; the refetch below fills the gap it leaves.
        if recentEntries.contains(where: { $0.url == url }) {
            recentEntries.removeAll { $0.url == url }
        }
        changes.send(.removed(url: url))

        let generation = nextRecentEntriesGeneration()
        store.async { [weak self] database in
            Self.deleteEntry(withURL: url, in: database)
            let recent = Self.fetchRecentEntries(in: database)
            Task { @MainActor [weak self] in
                self?.applyRecentEntries(recent, generation: generation)
            }
        }
    }

    // MARK: - Recent Entries

    private func nextRecentEntriesGeneration() -> Int {
        recentEntriesGeneration &+= 1
        return recentEntriesGeneration
    }

    /// Applies a refetch of the recent entries unless a newer one was started.
    private func applyRecentEntries(_ entries: [HistoryEntryData], generation: Int) {
        guard generation == recentEntriesGeneration else { return }
        recentEntries = entries
    }

    /// Moves a just-visited entry to the front of `recentEntries` — the same
    /// as refetching the most recent entries, without the fetch.
    private func noteVisit(_ entry: HistoryEntryData) {
        // A reload, say: nothing the History list shows has changed.
        if let first = recentEntries.first,
           first.url == entry.url,
           first.title == entry.title,
           Calendar.current.isDate(first.visitedAt, inSameDayAs: entry.visitedAt) {
            return
        }

        var entries = recentEntries
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        if entries.count > HistoryConfig.recentEntriesLimit {
            entries.removeLast(entries.count - HistoryConfig.recentEntriesLimit)
        }
        recentEntries = entries
        changes.send(.visited(entry))
    }

    // MARK: - Database (run on the store's queue)

    /// Version 1: a row per address, and the trigram index of their titles
    /// and addresses, kept up to date by triggers. Visits aren't kept one by
    /// one: nothing shows them, and an entry expires with its last visit.
    private nonisolated static let schema = """
        CREATE TABLE pages (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            visit_count INTEGER NOT NULL,
            first_visited_at REAL NOT NULL,
            last_visited_at REAL NOT NULL
        );
        CREATE INDEX pages_by_last_visit ON pages (last_visited_at);

        CREATE VIRTUAL TABLE pages_search USING fts5 (
            title, url,
            content = 'pages', content_rowid = 'id',
            tokenize = 'trigram remove_diacritics 1'
        );
        CREATE TRIGGER pages_inserted AFTER INSERT ON pages BEGIN
            INSERT INTO pages_search (rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        CREATE TRIGGER pages_deleted AFTER DELETE ON pages BEGIN
            INSERT INTO pages_search (pages_search, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
        END;
        CREATE TRIGGER pages_retitled AFTER UPDATE OF title ON pages WHEN old.title IS NOT new.title BEGIN
            INSERT INTO pages_search (pages_search, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
            INSERT INTO pages_search (rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        """

    /// Opens (or creates) the database in `directory`, bringing in what the
    /// Core Data store there had. Nil if it can't be opened: history is then
    /// off until the next launch.
    private nonisolated static func openDatabase(in directory: URL) -> SQLiteDatabase? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try SQLiteDatabase(url: directory.appendingPathComponent("History.sqlite"))
            if try database.userVersion() < 1 {
                try database.transaction {
                    try database.execute(schema)
                    try database.setUserVersion(1)
                }
            }
            importCoreDataHistory(in: directory, into: database)
            return database
        } catch {
            logError(.history, "Failed to open history: \(error)")
            return nil
        }
    }

    /// Brings in the history Klar kept with Core Data (`HistoryDataModel.sqlite`
    /// in the same folder), in one transaction, then deletes that store. Rows
    /// for the same address, left by an old per-launch hash, are merged. If
    /// it fails, the old store stays, and is tried again next launch.
    private nonisolated static func importCoreDataHistory(in directory: URL, into database: SQLiteDatabase) {
        let legacyURL = directory.appendingPathComponent("HistoryDataModel.sqlite")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        do {
            try database.run("ATTACH DATABASE ? AS legacy", legacyURL.path)
            let imported: Int
            do {
                let hasEntries = try !database.query(
                    "SELECT 1 FROM legacy.sqlite_master WHERE name = 'ZHISTORYENTRY'"
                ) { _ in true }.isEmpty
                // Oldest first, so the newest row's title and date are kept.
                imported = try !hasEntries ? 0 : database.transaction {
                    try database.run("""
                        INSERT INTO pages (url, title, visit_count, first_visited_at, last_visited_at)
                        SELECT ZURL, COALESCE(ZTITLE, ''), MAX(ZVISITCOUNT, 1),
                               COALESCE(ZCREATEDAT, ZLASTVISITEDAT), ZLASTVISITEDAT
                        FROM legacy.ZHISTORYENTRY
                        WHERE ZURL IS NOT NULL AND ZURL != '' AND ZLASTVISITEDAT IS NOT NULL
                        ORDER BY ZLASTVISITEDAT
                        ON CONFLICT (url) DO UPDATE SET
                            title = excluded.title,
                            visit_count = visit_count + excluded.visit_count,
                            first_visited_at = MIN(first_visited_at, excluded.first_visited_at),
                            last_visited_at = excluded.last_visited_at
                        """)
                }
            } catch {
                _ = try? database.run("DETACH DATABASE legacy")
                throw error
            }
            try database.run("DETACH DATABASE legacy")

            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: legacyURL.path + suffix)
            }
            // Core Data's merge of those duplicate rows, no longer needed.
            UserDefaults.standard.removeObject(forKey: "HistoryDuplicateEntriesMerged")
            UserDefaults.standard.removeObject(forKey: "HistoryDuplicateMergeAttempts")
            logInfo(.history, "Imported \(imported) history entries from Core Data")
        } catch {
            logError(.history, "Failed to import Core Data history: \(error)")
        }
    }

    /// One statement: a new address is inserted, a known one counted again.
    private nonisolated static func recordVisit(url: String, title: String, in database: SQLiteDatabase) -> HistoryEntryData? {
        let now = Date()
        do {
            let visitCount = try database.query("""
                INSERT INTO pages (url, title, visit_count, first_visited_at, last_visited_at)
                VALUES (?1, ?2, 1, ?3, ?3)
                ON CONFLICT (url) DO UPDATE SET
                    title = excluded.title,
                    visit_count = visit_count + 1,
                    last_visited_at = excluded.last_visited_at
                RETURNING visit_count
                """, url, title, now) { $0.int(0) }.first ?? 1

            return HistoryEntryData(
                id: HistoryEntryData.stableID(for: url),
                url: url,
                title: title,
                visitedAt: now,
                visitCount: visitCount
            )
        } catch {
            logError(.history, "Failed to add history visit: \(error)")
            return nil
        }
    }

    private enum SearchOrder: String {
        /// The palette's suggestions
        case mostVisited = "visit_count DESC, last_visited_at DESC"
        /// The History list
        case newest = "last_visited_at DESC"
    }

    /// Entries whose title or URL contain `query`, ignoring case and accents.
    private nonisolated static func searchEntries(matching query: String, order: SearchOrder, limit: Int, in database: SQLiteDatabase) -> [HistoryEntryData] {
        // The index is of three-character pieces, so it can't find a shorter
        // query: that scans the table, LIKE ignoring case only for ASCII.
        if query.unicodeScalars.count >= 3 {
            return fetchEntries("""
                SELECT pages.url, pages.title, last_visited_at, visit_count
                FROM pages_search JOIN pages ON pages.id = pages_search.rowid
                WHERE pages_search MATCH ?
                ORDER BY \(order.rawValue) LIMIT ?
                """, [ftsPhrase(query), limit], in: database)
        }

        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return fetchEntries("""
            SELECT url, title, last_visited_at, visit_count FROM pages
            WHERE title LIKE ?1 ESCAPE '\\' OR url LIKE ?1 ESCAPE '\\'
            ORDER BY \(order.rawValue) LIMIT ?2
            """, ["%\(escaped)%", limit], in: database)
    }

    /// One quoted phrase: the text as typed, not FTS query syntax.
    private nonisolated static func ftsPhrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private nonisolated static func fetchRecentEntries(in database: SQLiteDatabase) -> [HistoryEntryData] {
        fetchEntries("""
            SELECT url, title, last_visited_at, visit_count FROM pages
            ORDER BY last_visited_at DESC LIMIT ?
            """, [HistoryConfig.recentEntriesLimit], in: database)
    }

    /// Runs a query selecting url, title, last_visited_at and visit_count.
    private nonisolated static func fetchEntries(_ sql: String, _ values: [SQLiteValue?], in database: SQLiteDatabase) -> [HistoryEntryData] {
        do {
            return try database.query(sql, values) { HistoryEntryData(row: $0) }
        } catch {
            logError(.history, "Failed to fetch history: \(error)")
            return []
        }
    }

    private nonisolated static func deleteEntry(withURL url: String, in database: SQLiteDatabase) {
        do {
            try database.run("DELETE FROM pages WHERE url = ?", url)
        } catch {
            logError(.history, "Failed to remove history entry: \(error)")
        }
    }

    private nonisolated static func deleteAllHistory(in database: SQLiteDatabase) {
        do {
            let deleted = try database.run("DELETE FROM pages")
            try database.execute("PRAGMA incremental_vacuum")
            logInfo(.history, "Cleared \(deleted) history entries")
        } catch {
            logError(.history, "Failed to clear history: \(error)")
        }
    }

    // MARK: - Maintenance and Cleanup

    private func schedulePeriodicCleanup() {
        // First a minute after launch: Klar is rarely open for the 24 hours
        // the interval alone takes, and history then never expired.
        let timer = Timer(
            fire: Date().addingTimeInterval(HistoryConfig.launchCleanupDelay),
            interval: HistoryConfig.cleanupInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performMaintenance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func performMaintenance() {
        let generation = nextRecentEntriesGeneration()
        // Settings › General › Remove history items
        let cutoffDate = TOMLSettingsManager.shared.historyRetention.cutoffDate()
        store.async { [weak self] database in
            let removedAny = Self.removeExpiredHistory(before: cutoffDate, in: database)
            // Refetched either way: this refetch supersedes any still pending.
            let recent = Self.fetchRecentEntries(in: database)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyRecentEntries(recent, generation: generation)
                if removedAny {
                    self.changes.send(.reloaded)
                }
            }
        }
    }

    /// Removes entries last visited before `cutoffDate` (none when it's nil:
    /// history is then only removed by hand) and the oldest over the limit.
    /// Returns whether it removed any.
    private nonisolated static func removeExpiredHistory(before cutoffDate: Date?, in database: SQLiteDatabase) -> Bool {
        do {
            let removed = try database.transaction {
                var count = 0
                if let cutoffDate {
                    count += try database.run("DELETE FROM pages WHERE last_visited_at < ?", cutoffDate)
                }
                count += try database.run("""
                    DELETE FROM pages WHERE id IN (
                        SELECT id FROM pages ORDER BY last_visited_at DESC LIMIT -1 OFFSET ?
                    )
                    """, HistoryConfig.maxHistoryEntries)
                return count
            }
            // Returns the freed pages to the file system.
            try database.execute("PRAGMA incremental_vacuum; PRAGMA optimize;")
            logInfo(.history, "History maintenance completed, removed \(removed) entries")
            return removed > 0
        } catch {
            logError(.history, "History maintenance failed: \(error)")
            return false
        }
    }

    // MARK: - Utility Methods

    private nonisolated static func shouldIgnoreURL(_ url: String) -> Bool {
        let ignoredPatterns = [
            "about:",
            "chrome:",
            "safari:",
            "data:",
            "javascript:",
            "file://",
        ]

        return ignoredPatterns.contains { url.hasPrefix($0) }
    }

    private nonisolated static func extractDomainFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }
}

/// A change to a profile's history, as `HistoryManager.changes` sends it.
nonisolated enum HistoryChange: Sendable {
    /// A page was visited: its entry is now the newest.
    case visited(HistoryEntryData)
    /// An entry was removed by hand.
    case removed(url: String)
    /// Anything else (cleared, expired): fetch again.
    case reloaded
}

/// The history database and the serial queue it's used on. The database is
/// only touched on that queue.
nonisolated private final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.itsnwa.browser.history", qos: .userInitiated)
    /// Nil if it couldn't be opened (logged), or once closed.
    private var database: SQLiteDatabase?

    init(open: @escaping @Sendable () -> SQLiteDatabase?) {
        queue.async { [self] in
            database = open()
        }
    }

    /// Runs `body` on the queue, if the database is open.
    func async(_ body: @escaping @Sendable (SQLiteDatabase) -> Void) {
        queue.async { [self] in
            guard let database else { return }
            body(database)
        }
    }

    /// Runs `body` on the queue and returns its result; `fallback` if the
    /// database isn't open.
    func perform<T: Sendable>(or fallback: T, _ body: @escaping @Sendable (SQLiteDatabase) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: database.map(body) ?? fallback)
            }
        }
    }

    /// Closes the database, then runs `completion` on the queue.
    func close(then completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            database?.close()
            database = nil
            completion()
        }
    }
}

// MARK: - Configuration

nonisolated private enum HistoryConfig {
    /// A backstop, not the limit: how long history is kept is the user's
    /// setting (HistoryRetention). The 10,000 this was is under a year for
    /// anyone visiting more than 27 new pages a day.
    static let maxHistoryEntries = 100_000
    static let recentEntriesLimit = 50
    static let cleanupInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    static let launchCleanupDelay: TimeInterval = 60
}

/// FNV-1a over the UTF-8 bytes: the same every launch, unlike `hashValue`,
/// which is seeded randomly per process.
nonisolated private func fnv1a(_ string: String, offsetBasis: UInt64 = 0xcbf29ce484222325) -> UInt64 {
    var hash = offsetBasis
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}

// MARK: - Data Models

/// History entry for UI display
nonisolated struct HistoryEntryData: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: String
    let title: String
    let visitedAt: Date
    let visitCount: Int

    init(id: UUID = UUID(), url: String, title: String, visitedAt: Date, visitCount: Int) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visitCount = visitCount
    }

    static func == (lhs: HistoryEntryData, rhs: HistoryEntryData) -> Bool {
        return lhs.url == rhs.url
    }
}

nonisolated extension HistoryEntryData {
    /// An ID derived from the URL, so it's the same every launch (history
    /// keeps one entry per URL).
    static func stableID(for url: String) -> UUID {
        let high = fnv1a(url)
        let low = fnv1a(url, offsetBasis: 0x84222325cbf29ce4)
        return withUnsafeBytes(of: (high, low)) { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// From a row of url, title, last_visited_at and visit_count.
    fileprivate init?(row: SQLiteRow) {
        guard let url = row.string(0), !url.isEmpty else { return nil }
        let title = row.string(1) ?? ""
        self.init(
            id: Self.stableID(for: url),
            url: url,
            title: title.isEmpty ? "Untitled" : title,
            visitedAt: row.date(2) ?? Date(),
            visitCount: row.int(3)
        )
    }
}
