import Foundation

nonisolated struct SavedCredential: Identifiable, Hashable, Sendable {
    let id: UUID
    let host: String
    let username: String
    var displayName: String?
    let createdAt: Date
    var modifiedAt: Date
    var lastUsedAt: Date?

    var label: String {
        displayName?.isEmpty == false ? displayName! : host
    }
}

// Codable payload stored in the keychain item's generic data blob.
// The password itself lives in `kSecValueData`; this blob carries
// everything else so the keychain remains the single source of truth.
nonisolated struct CredentialMetadata: Codable, Sendable {
    let id: UUID
    let host: String?            // duplicated from kSecAttrAccount as a decode fallback
    let displayName: String?
    let createdAt: Date
    let modifiedAt: Date
    let lastUsedAt: Date?
}
