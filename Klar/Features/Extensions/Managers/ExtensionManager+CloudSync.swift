import Foundation

private let extensionRecordType = "Extension"
private let extensionRecordPrefix = "extension-"

/// Store extensions in iCloud (CloudSyncManager): which are installed, and
/// whether each is on and pinned. Another Mac installs the ones it's missing
/// from the Chrome Web Store, and removes ones removed elsewhere. Unpacked
/// extensions, and what each extension stores, stay on their Mac.
extension ExtensionManager: CloudSyncSource {
    var syncRecordTypes: Set<String> {
        [extensionRecordType]
    }

    var isReadyForSync: Bool {
        hasLoadedRecords
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        var records: [String: CloudSyncRecord] = [:]
        for record in syncedRecords {
            records[extensionRecordPrefix + record.id] = CloudSyncRecord(type: extensionRecordType, fields: [
                "isEnabled": .bool(record.isEnabled),
                "isPinned": .bool(record.isPinned)
            ])
        }
        return records
    }

    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        for (name, syncRecord) in saved {
            guard let id = Self.extensionID(fromRecordName: name) else { continue }
            let enabled = syncRecord["isEnabled"]?.boolValue ?? true
            let pinned = syncRecord["isPinned"]?.boolValue ?? false
            if let record = record(for: id) {
                // An unpacked copy with the same ID is this Mac's own.
                guard record.source == .webStore else { continue }
                setEnabled(enabled, for: id)
                if record.isPinned != pinned {
                    setPinned(pinned, for: id)
                }
            } else {
                Task { await installFromSync(id: id, enabled: enabled, pinned: pinned) }
            }
        }
        for name in deleted {
            guard let id = Self.extensionID(fromRecordName: name) else { continue }
            removeFromSync(id)
        }
    }

    private static func extensionID(fromRecordName name: String) -> String? {
        guard name.hasPrefix(extensionRecordPrefix) else { return nil }
        return String(name.dropFirst(extensionRecordPrefix.count))
    }
}
