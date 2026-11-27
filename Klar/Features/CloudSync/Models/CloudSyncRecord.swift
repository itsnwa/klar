import CloudKit
import Foundation
import Security

/// A field of a synced record. Kept to the three kinds every record type
/// needs, each mapping onto one CloudKit field type.
nonisolated enum CloudSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case date(Date)

    /// CloudKit has no booleans: stored as 0 or 1.
    static func bool(_ value: Bool) -> CloudSyncValue {
        .int(value ? 1 : 0)
    }

    /// A date to the whole second. CloudKit keeps milliseconds, so a date
    /// with more precision would never equal the one fetched back.
    static func seconds(_ date: Date) -> CloudSyncValue {
        .date(Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down)))
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        intValue.map { $0 != 0 }
    }

    var dateValue: Date? {
        if case .date(let value) = self { return value }
        return nil
    }

    var recordValue: CKRecordValue {
        switch self {
        case .string(let value): return value as NSString
        case .int(let value): return NSNumber(value: value)
        case .date(let value): return value as NSDate
        }
    }

    init?(recordValue: Any) {
        switch recordValue {
        case let value as String: self = .string(value)
        case let value as Date: self = .date(value)
        case let value as NSNumber: self = .int(value.intValue)
        default: return nil
        }
    }
}

/// One item as it syncs: its CloudKit record type and fields. Sources name
/// their records (`tab-<uuid>`, `setting-<key>`…); the name is the CKRecord's.
nonisolated struct CloudSyncRecord: Codable, Equatable, Sendable {
    var type: String
    var fields: [String: CloudSyncValue]

    subscript(field: String) -> CloudSyncValue? {
        fields[field]
    }
}

/// The kinds of data that sync, one source each.
enum CloudSyncSourceKind: String, CaseIterable {
    case sidebar
    case settings
    case extensions
    case sitePermissions
    case openTabs
    case explore
}

/// Data CloudSyncManager keeps in iCloud. The source hands over everything
/// it holds as records and takes the changes made on other Macs; the
/// manager works out what changed by comparing with what it last sent or
/// received.
@MainActor
protocol CloudSyncSource: AnyObject {
    /// The record types it owns.
    var syncRecordTypes: Set<String> { get }

    /// False while it can't take changes yet — the sidebar before its tabs
    /// are restored at launch.
    var isReadyForSync: Bool { get }

    /// Everything it holds now, by record name.
    func syncRecords() -> [String: CloudSyncRecord]

    /// Applies changes from iCloud. What `syncRecords()` returns differently
    /// afterwards (a position numbered again) stays on this Mac, unless it's
    /// the first sync's merge.
    /// `isInitialMerge`: this Mac's first sync — match its own items to the
    /// ones iCloud has rather than adding them twice.
    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool)

    /// Fields its records can be without. A record sent without one has it
    /// cleared in iCloud: a field that's only left out keeps its last value
    /// there, and comes back with the next fetch.
    var syncOptionalFields: Set<String> { get }

    /// Records it removed, whichever session: deleted from iCloud even when
    /// it never had them this session, which would otherwise bring them
    /// back. For what's removed often, and soon after launch: open tabs.
    var syncDeletedRecordNames: Set<String> { get }
}

extension CloudSyncSource {
    var syncOptionalFields: Set<String> { [] }
    var syncDeletedRecordNames: Set<String> { [] }
}

/// What CloudSyncManager remembers between launches, in
/// ~/Library/Application Support/Klar/CloudSync/ (CloudSyncStore).
nonisolated struct CloudSyncState: Codable, Sendable {
    struct Entry: Codable, Sendable {
        /// The values last sent or received.
        var record: CloudSyncRecord
        /// The CKRecord's system fields (change tag) from the server, so the
        /// next save is recognised as an update of it.
        var systemFields: Data?
        /// When these values were set, here or on another Mac; the newer
        /// side wins a conflict.
        var modifiedAt: Date
        /// Changed here and not yet saved to iCloud.
        var needsUpload: Bool
    }

    var engineState: CKSyncEngine.State.Serialization?
    var entries: [String: Entry] = [:]
    /// Deleted here and not yet in iCloud.
    var pendingDeletions: Set<String> = []
    /// Whether this Mac's first fetch has been applied (merged).
    var hasMerged = false
}

/// A state per CloudKit environment: a debug build syncs with Development,
/// a release with Production, and both keep their data in the same folder.
/// One state for both called records sent to one environment sent to the
/// other, which then never got them.
nonisolated enum CloudSyncStore {
    private static var folderURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Klar/CloudSync")
    }

    private static let fileURL = folderURL.appendingPathComponent("state-\(environment.lowercased()).json")

    /// This build's CloudKit environment: its entitlement, which a
    /// development-signed build is without.
    private static let environment: String = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil) else {
            return "Development"
        }
        return value as? String ?? (value as? [String])?.first ?? "Development"
    }()

    private static let queue = DispatchQueue(label: "Klar.CloudSync.save", qos: .utility)

    static func load() -> CloudSyncState? {
        // The state both environments shared: it can't be told apart, so
        // each starts over with a first sync, which matches by ID.
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent("state.json"))
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(CloudSyncState.self, from: data)
        } catch {
            logError(.sync, "Couldn't read the sync state: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes in the background, in order.
    static func save(_ state: CloudSyncState) {
        queue.async { write(state) }
    }

    /// Writes now and waits for earlier writes. For when the app quits.
    static func saveNow(_ state: CloudSyncState) {
        queue.sync { write(state) }
    }

    static func delete() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func write(_ state: CloudSyncState) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            logError(.sync, "Couldn't save the sync state: \(error.localizedDescription)")
        }
    }
}
