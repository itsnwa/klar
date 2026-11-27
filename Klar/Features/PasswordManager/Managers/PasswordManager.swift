import Foundation
import Security

nonisolated enum PasswordManagerError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case decodingFailed
    case credentialNotFound
    case iCloudKeychainUnavailable
    /// The store moved, but these items didn't.
    case notAllMoved(count: Int, firstError: Error)

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .decodingFailed:
            return "Could not decode keychain item metadata"
        case .credentialNotFound:
            return "Credential not found"
        case .iCloudKeychainUnavailable:
            return "This copy of Klar isn't signed for iCloud Keychain."
        case .notAllMoved(let count, let firstError):
            return "\(count == 1 ? "A password" : "\(count) passwords") couldn't be moved: \(firstError.localizedDescription)"
        }
    }
}

/// Klar's own password store, in the user's macOS keychain — in iCloud
/// Keychain while Settings › iCloud is on, which syncs it to the user's other
/// Macs. Accounts from Apple's Passwords app come alongside it from
/// ApplePasswordsManager.
nonisolated final class PasswordManager: ObservableObject, @unchecked Sendable {
    static let shared = PasswordManager()

    /// Scopes Klar's items inside the user's macOS keychain. Generic-password
    /// items are addressable by (service, account) — `kSecAttrService` is part
    /// of the primary key for that class, which is why the previous attempt
    /// to use `kSecClassInternetPassword + kSecAttrService` lost items: that
    /// attribute is silently ignored by the internet-password class.
    private static let serviceTag = "com.itsnwa.browser.passwords"

    /// `host|username` — `|` is uncommon in both. Stored host is also included
    /// in the metadata blob as a fallback for decoding.
    private static let accountSeparator = "|"

    private let queue = DispatchQueue(label: "com.itsnwa.browser.passwords.keychain", qos: .userInitiated)

    /// Where Klar's items are.
    enum Keychain: Sendable {
        /// The login keychain, on this Mac only.
        case login
        /// iCloud Keychain: the data protection keychain, synchronizable.
        case iCloud

        /// Part of every query.
        fileprivate var attributes: [CFString: Any] {
            switch self {
            case .login:
                return [:]
            case .iCloud:
                return [kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: true]
            }
        }

        /// Part of every new item.
        fileprivate var itemAttributes: [CFString: Any] {
            switch self {
            case .login:
                return [kSecAttrSynchronizable: false]
            case .iCloud:
                return attributes
            }
        }
    }

    /// Only used on `queue`.
    private var keychain: Keychain = .login

    private init() {}

    // MARK: - iCloud Keychain

    /// Moves Klar's items into iCloud Keychain, or copies them back to the
    /// login keychain — leaving iCloud's copies, since deleting a synced item
    /// deletes it on every Mac. Where both have an item, the more recently
    /// changed one wins. Called by CloudSyncManager when sync turns on or off.
    func setUsesICloudKeychain(_ useICloud: Bool) async throws {
        try await perform { [self] in
            if useICloud {
                do {
                    _ = try Self.fetchAll(in: .iCloud)
                } catch PasswordManagerError.keychainStatus(errSecMissingEntitlement) {
                    throw PasswordManagerError.iCloudKeychainUnavailable
                }
                // From here on, so what's moved shows even if an item fails.
                // One that does stays behind until the next try (each
                // launch with sync on), and the error is notAllMoved.
                keychain = .iCloud
                var failures: [Error] = []
                for credential in try Self.fetchAll(in: .login) {
                    do {
                        try Self.copy(credential, from: .login, to: .iCloud)
                        let status = SecItemDelete(Self.itemQuery(host: credential.host, username: credential.username, in: .login) as CFDictionary)
                        guard status == errSecSuccess || status == errSecItemNotFound else {
                            throw PasswordManagerError.keychainStatus(status)
                        }
                    } catch {
                        failures.append(error)
                    }
                }
                if let failure = failures.first {
                    throw PasswordManagerError.notAllMoved(count: failures.count, firstError: failure)
                }
            } else {
                keychain = .login
                var failures: [Error] = []
                for credential in (try? Self.fetchAll(in: .iCloud)) ?? [] {
                    do {
                        try Self.copy(credential, from: .iCloud, to: .login)
                    } catch {
                        failures.append(error)
                    }
                }
                if let failure = failures.first {
                    throw PasswordManagerError.notAllMoved(count: failures.count, firstError: failure)
                }
            }
        }
    }

    /// Writes `credential` with its password into `target`, unless `target`
    /// has a copy changed at least as recently.
    private static func copy(_ credential: SavedCredential, from source: Keychain, to target: Keychain) throws {
        guard let item = try fetchSingle(host: credential.host, username: credential.username, includeData: true, in: source) else {
            return
        }
        let existing = try fetchSingle(host: credential.host, username: credential.username, includeData: false, in: target)
        if let existing, existing.credential.modifiedAt >= item.credential.modifiedAt {
            return
        }
        try persist(item.credential, password: item.password, isUpdate: existing != nil, in: target)
    }

    // MARK: - Reads

    func credentials(for host: String) async throws -> [SavedCredential] {
        let host = Self.normalize(host: host)
        return try await perform { [self] in
            try Self.fetchAll(in: keychain).filter { $0.host == host }
        }
    }

    func reveal(_ credential: SavedCredential) async throws -> String {
        try await perform { [self] in
            guard let item = try Self.fetchSingle(host: credential.host, username: credential.username, includeData: true, in: keychain) else {
                throw PasswordManagerError.credentialNotFound
            }
            return item.password ?? ""
        }
    }

    func allCredentials() async throws -> [SavedCredential] {
        try await perform { [self] in try Self.fetchAll(in: keychain) }
    }

    // MARK: - Writes

    @discardableResult
    func save(host: String, username: String, password: String, displayName: String? = nil) async throws -> SavedCredential {
        let host = Self.normalize(host: host)
        return try await perform { [self] in
            if let existing = try Self.fetchSingle(host: host, username: username, includeData: false, in: keychain) {
                let updated = SavedCredential(
                    id: existing.credential.id,
                    host: existing.credential.host,
                    username: existing.credential.username,
                    displayName: displayName ?? existing.credential.displayName,
                    createdAt: existing.credential.createdAt,
                    modifiedAt: Date(),
                    lastUsedAt: existing.credential.lastUsedAt
                )
                try Self.persist(updated, password: password, isUpdate: true, in: keychain)
                return updated
            }

            let now = Date()
            let credential = SavedCredential(
                id: UUID(),
                host: host,
                username: username,
                displayName: displayName,
                createdAt: now,
                modifiedAt: now,
                lastUsedAt: nil
            )
            try Self.persist(credential, password: password, isUpdate: false, in: keychain)
            return credential
        }
    }

    func update(_ credential: SavedCredential, password: String? = nil) async throws {
        try await perform { [self] in
            var updated = credential
            updated.modifiedAt = Date()
            try Self.persist(updated, password: password, isUpdate: true, in: keychain)
        }
    }

    func delete(_ credential: SavedCredential) async throws {
        try await perform { [self] in
            let query = Self.itemQuery(host: credential.host, username: credential.username, in: keychain)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PasswordManagerError.keychainStatus(status)
            }
        }
    }

    func markUsed(_ credential: SavedCredential) async {
        var stamped = credential
        stamped.lastUsedAt = Date()
        try? await update(stamped)
    }

    // MARK: - Internals

    private func perform<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    fileprivate struct KeychainItem {
        var credential: SavedCredential
        var password: String?
    }

    private static func fetchAll(in keychain: Keychain) throws -> [SavedCredential] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceTag,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: false
        ].merging(keychain.attributes) { _, new in new }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw PasswordManagerError.keychainStatus(status)
        }

        return items.compactMap(decode).sorted { lhs, rhs in
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            return lhs.username.localizedStandardCompare(rhs.username) == .orderedAscending
        }
    }

    private static func fetchSingle(host: String, username: String, includeData: Bool, in keychain: Keychain) throws -> KeychainItem? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceTag,
            kSecAttrAccount: composeAccount(host: host, username: username),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
            kSecReturnData: includeData
        ].merging(keychain.attributes) { _, new in new }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            throw PasswordManagerError.keychainStatus(status)
        }
        guard let credential = decode(attrs) else { return nil }

        var password: String?
        if let data = attrs[kSecValueData as String] as? Data {
            password = String(data: data, encoding: .utf8)
        }
        return KeychainItem(credential: credential, password: password)
    }

    private static func persist(_ credential: SavedCredential, password: String?, isUpdate: Bool, in keychain: Keychain) throws {
        let metadata = CredentialMetadata(
            id: credential.id,
            host: credential.host,
            displayName: credential.displayName,
            createdAt: credential.createdAt,
            modifiedAt: credential.modifiedAt,
            lastUsedAt: credential.lastUsedAt
        )
        let metadataData = try JSONEncoder().encode(metadata)

        var attributes: [CFString: Any] = [
            kSecAttrLabel: "Klar — \(credential.host)",
            kSecAttrService: Self.serviceTag,
            kSecAttrAccount: composeAccount(host: credential.host, username: credential.username),
            kSecAttrGeneric: metadataData,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        if let password {
            attributes[kSecValueData] = Data(password.utf8)
        }

        if isUpdate {
            let query = Self.itemQuery(host: credential.host, username: credential.username, in: keychain)
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                // Caller asked for update but item was deleted underneath us. Add fresh.
                try add(attributes, in: keychain)
                return
            }
            guard status == errSecSuccess else {
                throw PasswordManagerError.keychainStatus(status)
            }
            return
        }

        try add(attributes, in: keychain)
    }

    private static func add(_ attributes: [CFString: Any], in keychain: Keychain) throws {
        var item = attributes.merging(keychain.itemAttributes) { _, new in new }
        item[kSecClass] = kSecClassGenericPassword
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PasswordManagerError.keychainStatus(status)
        }
    }

    private static func itemQuery(host: String, username: String, in keychain: Keychain) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceTag,
            kSecAttrAccount: composeAccount(host: host, username: username)
        ].merging(keychain.attributes) { _, new in new }
    }

    private static func composeAccount(host: String, username: String) -> String {
        "\(host)\(accountSeparator)\(username)"
    }

    private static func decompose(account: String) -> (host: String, username: String)? {
        guard let separatorIndex = account.firstIndex(of: Character(accountSeparator)) else {
            return nil
        }
        let host = String(account[..<separatorIndex])
        let username = String(account[account.index(after: separatorIndex)...])
        return (host, username)
    }

    private static func decode(_ attrs: [String: Any]) -> SavedCredential? {
        guard
            let metadataBlob = attrs[kSecAttrGeneric as String] as? Data,
            let metadata = try? JSONDecoder().decode(CredentialMetadata.self, from: metadataBlob)
        else {
            return nil
        }

        // Prefer the host stored in the metadata blob; fall back to splitting
        // the account if a legacy item didn't capture host metadata.
        let host: String
        let username: String
        if let storedHost = metadata.host, !storedHost.isEmpty,
           let account = attrs[kSecAttrAccount as String] as? String,
           let parsed = decompose(account: account)
        {
            host = storedHost
            username = parsed.username
        } else if let account = attrs[kSecAttrAccount as String] as? String,
                  let parsed = decompose(account: account)
        {
            host = parsed.host
            username = parsed.username
        } else {
            return nil
        }

        return SavedCredential(
            id: metadata.id,
            host: host,
            username: username,
            displayName: metadata.displayName,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            lastUsedAt: metadata.lastUsedAt
        )
    }

    static func normalize(host raw: String) -> String {
        var host = raw.lowercased()
        if let url = URL(string: raw), let urlHost = url.host?.lowercased() {
            host = urlHost
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
