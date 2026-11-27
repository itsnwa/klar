import Foundation
import AppKit
import CommonCrypto
import CryptoKit
import Security

/// Reads Dia's sidebar into an `ImportedSidebar`: each space's pinned tabs
/// and folders, and its favorites. Dia doesn't document it, so it's read
/// loosely: what it doesn't recognize is left out rather than failing.
///
/// Since Dia 1.55 the sidebar is `User Data/<profile>/tabs.db`, a GRDB
/// database encrypted with SQLCipher 4's defaults: 4096-byte pages, each
/// ending in 80 reserved bytes (a 16-byte IV, then an HMAC-SHA512), AES-256
/// in CBC mode, page 1 starting with the KDF salt in place of SQLite's
/// header string. Its raw key is HKDF-SHA256 of Chromium's Safe Storage key
/// (PBKDF2-SHA1 of the keychain's "Dia Safe Storage" secret, as for cookies),
/// salted with HMAC-SHA256 of the label `profile/<profile folder>/tabs`
/// under a key in Dia's binary (its `DatabaseEncryptionKeyDerivationFunction`).
/// Dia keeps it open, so recent changes are often only in its `-wal`.
///
/// `nodes` is the tree: per space a `favorites` and a `pinned_container`
/// node, and a `window` node per window with its open tabs. A `tab` holds a
/// `content_pane` (several in a split view), a `group` is a folder.
nonisolated enum DiaSidebarReader {
    enum ReadError: LocalizedError, Equatable {
        case notFound
        /// The keychain's password wasn't given.
        case denied
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notFound: return "Dia’s sidebar wasn’t found on this Mac."
            case .denied: return "Klar needs Dia’s key from your keychain to read its sidebar."
            case .unreadable: return "This version of Dia keeps its sidebar in a way Klar can’t read."
            }
        }
    }

    static var userDataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Dia/User Data")
    }

    /// Without asking for the key, so it's quick and silent.
    static var hasSidebar: Bool {
        !profileFolders().isEmpty
    }

    /// Asks macOS for Dia's key (the keychain asks the user the first time).
    static func read() throws -> ImportedSidebar {
        let profiles = profileFolders()
        guard !profiles.isEmpty else { throw ReadError.notFound }
        let rootKey = try safeStorageKey()

        var spaces: [ImportedSpace] = []
        var favorites: [ImportedTab] = []
        var seenFavorites: Set<String> = []
        var readAny = false
        for profile in profiles {
            let url = userDataURL.appending(path: profile).appending(path: "tabs.db")
            guard let bytes = decrypt(url, key: databaseKey(rootKey: rootKey, label: "profile/\(profile)/tabs")) else {
                logWarning(.sidebar, "Dia's \(profile)/tabs.db didn't decrypt")
                continue
            }
            do {
                let database = try SQLiteDatabase(deserializing: bytes)
                let sidebar = try read(database, profile: profile)
                readAny = true
                spaces += sidebar.spaces
                for tab in sidebar.favorites where seenFavorites.insert(tab.url).inserted {
                    favorites.append(tab)
                }
            } catch {
                logError(.sidebar, "Couldn't read Dia's \(profile)/tabs.db: \(error)")
            }
        }
        guard readAny else { throw ReadError.unreadable }
        return ImportedSidebar(source: .dia, spaces: spaces, favorites: favorites)
    }

    /// The Chromium profile folders with a sidebar, Default first.
    private static func profileFolders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userDataURL.path)) ?? []
        return names
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .filter { FileManager.default.fileExists(atPath: userDataURL.appending(path: $0).appending(path: "tabs.db").path) }
            .sorted { $0 == "Default" || $1 != "Default" && $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Key

    /// The HMAC key of Dia's DatabaseEncryptionKeyDerivationFunction.
    private static let saltKey = SymmetricKey(data: Data(base64Encoded: "iOe1Ue/XtonbieE/5m1nAgewvWQlePHRcKnoU10EyOM=")!)

    /// Chromium's Safe Storage key: PBKDF2-SHA1 of the keychain's secret.
    private static func safeStorageKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Dia Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ReadError.denied
        default:
            logError(.sidebar, "Couldn't get Dia's key from the keychain: \(status)")
            throw ReadError.unreadable
        }
        guard let secret = item as? Data, !secret.isEmpty else { throw ReadError.unreadable }

        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        let result = key.withUnsafeMutableBytes { output in
            secret.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), 16
                )
            }
        }
        guard result == kCCSuccess else { throw ReadError.unreadable }
        return key
    }

    private static func databaseKey(rootKey: Data, label: String) -> Data {
        let info = Data(label.utf8)
        let salt = Data(HMAC<SHA256>.authenticationCode(for: info, using: saltKey))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rootKey), salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Decrypting

    private static let pageSize = 4096
    private static let reservedSize = 80

    /// The database as plain SQLite, with the committed frames of its `-wal`
    /// in it; nil for a wrong key.
    private static func decrypt(_ url: URL, key: Data) -> Data? {
        guard let file = try? Data(contentsOf: url), file.count >= pageSize, file.count % pageSize == 0 else { return nil }
        var pages: [Int: Data] = [:]
        var pageCount = file.count / pageSize
        for index in 0..<pageCount {
            pages[index + 1] = file.subdata(in: index * pageSize..<(index + 1) * pageSize)
        }

        // A frame is a 24-byte header (page number, the page count after a
        // commit, the log's salt) and the page. Frames with another salt are
        // an older generation of the log; frames after the last commit, an
        // unfinished transaction.
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        if let wal = try? Data(contentsOf: walURL), wal.count > 32, bigEndian(wal, at: 8) == pageSize {
            let salt = wal.subdata(in: 16..<24)
            var pending: [Int: Data] = [:]
            var offset = 32
            while offset + 24 + pageSize <= wal.count, wal.subdata(in: offset + 8..<offset + 16) == salt {
                pending[bigEndian(wal, at: offset)] = wal.subdata(in: offset + 24..<offset + 24 + pageSize)
                let committedPageCount = bigEndian(wal, at: offset + 4)
                if committedPageCount > 0 {
                    pages.merge(pending) { $1 }
                    pending = [:]
                    pageCount = committedPageCount
                }
                offset += 24 + pageSize
            }
        }

        // A damaged log can claim more pages than there are
        guard pageCount >= 1, pageCount <= pages.count else { return nil }
        var database = Data(capacity: pageCount * pageSize)
        for number in 1...pageCount {
            guard let page = pages[number], let plain = decryptPage(page, isFirst: number == 1, key: key) else { return nil }
            database.append(plain)
        }

        // The right key makes page 1 SQLite's header: 4096-byte pages,
        // payload fractions 64, 32 and 32
        guard database[16] == 0x10, database[17] == 0, database[21] == 64, database[22] == 32, database[23] == 32 else { return nil }
        // Not WAL any more: the log is in it, and SQLite opens a WAL
        // database in memory only without
        database[18] = 1
        database[19] = 1
        return database
    }

    private static func decryptPage(_ page: Data, isFirst: Bool, key: Data) -> Data? {
        // Page 1 starts with the KDF salt instead of "SQLite format 3"
        let start = isFirst ? 16 : 0
        let body = page.subdata(in: start..<pageSize - reservedSize)
        let iv = page.subdata(in: pageSize - reservedSize..<pageSize - reservedSize + 16)
        var plain = Data(count: body.count)
        var moved = 0
        let status = plain.withUnsafeMutableBytes { output in
            body.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                key.baseAddress, key.count, iv.baseAddress,
                                input.baseAddress, body.count, output.baseAddress, body.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == body.count else { return nil }
        return (isFirst ? Data("SQLite format 3\0".utf8) : Data()) + plain + Data(count: reservedSize)
    }

    private static func bigEndian(_ data: Data, at offset: Int) -> Int {
        data.subdata(in: offset..<offset + 4).reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: - Reading

    private struct Node {
        let id: Int
        let kind: String
        let entityID: String
        let spaceID: String
    }

    private static func read(_ database: SQLiteDatabase, profile: String) throws -> (spaces: [ImportedSpace], favorites: [ImportedTab]) {
        var children: [Int: [Node]] = [:]
        var containers: [Node] = []
        let nodes = try database.query(
            "SELECT id, kind, entity_id, parent_id, space_id FROM nodes WHERE deleted_at IS NULL ORDER BY parent_id, \"order\""
        ) { row -> (Node, Int?) in
            let node = Node(id: row.int(0), kind: row.string(1) ?? "", entityID: row.string(2) ?? "", spaceID: row.string(4) ?? "")
            return (node, row.isNull(3) ? nil : row.int(3))
        }
        for (node, parentID) in nodes {
            if let parentID {
                children[parentID, default: []].append(node)
            } else {
                containers.append(node)
            }
        }

        let groups = try database.query("SELECT id, title, icon FROM tab_groups") { row in
            (row.string(0) ?? "", (title: row.string(1), icon: row.string(2)))
        }
        let groupsByID = Dictionary(groups, uniquingKeysWith: { first, _ in first })
        let panes = try database.query(
            "SELECT p.id, p.custom_title, w.url, w.title FROM content_panes p JOIN web_contents w ON w.content_pane_id = p.id"
        ) { row -> (String, ImportedTab)? in
            guard let id = row.string(0), let url = row.string(2), isImportable(url) else { return nil }
            let customTitle = row.string(1).flatMap { $0.isEmpty ? nil : $0 }
            let pageTitle = row.string(3).flatMap { $0.isEmpty ? nil : $0 }
            let title = pageTitle ?? customTitle ?? URL(string: url)?.host() ?? url
            return (id, ImportedTab(url: url, title: title, customTitle: customTitle == title ? nil : customTitle))
        }
        let panesByID = Dictionary(panes, uniquingKeysWith: { first, _ in first })

        // A split view's tabs one after another, Dia's own pages left out
        func items(in node: Node) -> [ImportedItem] {
            (children[node.id] ?? []).flatMap { child -> [ImportedItem] in
                switch child.kind {
                case "tab":
                    return items(in: child)
                case "content_pane":
                    return panesByID[child.entityID].map { [.tab($0)] } ?? []
                case "group":
                    let group = groupsByID[child.entityID]
                    let title = group?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Group"
                    return [.folder(title: title, icon: icon(from: group?.icon), items: items(in: child))]
                default:
                    return []
                }
            }
        }

        var favorites: [ImportedTab] = []
        for container in containers where container.kind == "favorites" {
            for case .tab(let tab) in items(in: container) {
                favorites.append(tab)
            }
        }

        var untitledCount = 0
        let spaces = try database.query("SELECT id, title, theme FROM spaces ORDER BY creation_date") { row -> ImportedSpace? in
            guard let id = row.string(0) else { return nil }
            let title: String
            if let name = row.string(1)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                title = name
            } else {
                untitledCount += 1
                title = "Space \(untitledCount)"
            }
            let pinned = containers.filter { $0.kind == "pinned_container" && $0.spaceID == id }.flatMap(items(in:))
            return ImportedSpace(
                id: "\(profile)/\(id)",
                title: title,
                icon: .letter,
                color: color(fromTheme: row.string(2)),
                usesSeparateProfile: profile != "Default",
                items: pinned
            )
        }
        return (spaces, favorites)
    }

    /// Web pages and files; not Dia's own pages.
    private static func isImportable(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// `{"emoji": "👋"}`, or `{"symbol": "sunHorizon"}` with Dia's own
    /// symbol names, kept if SF Symbols has one by that name.
    private static func icon(from json: String?) -> Icomoji? {
        guard let data = json?.data(using: .utf8),
              let icon = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let emoji = icon["emoji"] as? String, !emoji.isEmpty {
            return .emoji(emoji)
        }
        if let name = icon["symbol"] as? String, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return .symbol(name)
        }
        return nil
    }

    /// Dia's themes are names; neutral, its default, is left to Klar.
    private static func color(fromTheme theme: String?) -> SpaceColor? {
        switch theme {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "pink": return .pink
        case "purple": return .purple
        default: return nil
        }
    }
}
