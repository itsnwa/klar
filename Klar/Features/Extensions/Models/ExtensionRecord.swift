import Foundation

/// What Klar remembers about an installed extension. WebKit keeps an
/// extension's own storage (keyed by the context's unique identifier, the
/// Chrome ID), but not which extensions are installed or what the user
/// granted them, so those live here, in ExtensionRecordStore.
nonisolated struct ExtensionRecord: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Installed from the Chrome Web Store; Klar owns its folder and
        /// keeps it updated.
        case webStore
        /// Loaded from a folder of the user's (developer mode); Klar reads it
        /// in place, and Reload picks up changes.
        case unpacked
    }

    /// The Chrome extension ID (32 letters a–p).
    let id: String
    var source: Source
    /// The folder holding manifest.json.
    var path: String
    var version: String?
    var isEnabled = true
    /// Shown in the URL bar rather than only in the puzzle menu.
    var isPinned = false
    var installedAt = Date()

    // What the user allowed or refused, with when each expires
    // (Date.distantFuture for never) — WKWebExtensionContext's
    // granted/denied permissions and match patterns, restored on each load.
    var grantedPermissions: [String: Date] = [:]
    var grantedMatchPatterns: [String: Date] = [:]
    var deniedPermissions: [String: Date] = [:]
    var deniedMatchPatterns: [String: Date] = [:]
    var hasRequestedOptionalAccessToAllHosts = false

    /// A store update that asks for more than the user allowed so far; it
    /// waits for the user's approval in Settings › Extensions.
    var pendingUpdateVersion: String?

    var folderURL: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// The origin extension pages have, and native messaging hosts list in
    /// `allowed_origins`.
    var origin: String { "chrome-extension://\(id)/" }
}

/// Reads and writes ~/Library/Application Support/Klar/Extensions/extensions.json,
/// next to the folders of store-installed extensions.
nonisolated enum ExtensionRecordStore {
    static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Klar/Extensions", isDirectory: true)
    }

    private static var fileURL: URL { directory.appendingPathComponent("extensions.json") }

    static func load() -> [ExtensionRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ExtensionRecord].self, from: data)
        } catch {
            logError(.extensions, "Couldn't read extensions.json: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ records: [ExtensionRecord]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            logError(.extensions, "Couldn't save extensions.json: \(error.localizedDescription)")
        }
    }

    /// A new folder for a store extension's files, e.g. `<id>/1a2b3c4d`. A
    /// fresh one per install or update, so the version in use is never
    /// overwritten while it's loaded.
    static func newFolder(for id: String) -> URL {
        directory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    }

    /// Whether `folder` is one of Klar's own (store installs), which Klar
    /// may delete — never an unpacked extension's folder.
    static func ownsFolder(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }
}
