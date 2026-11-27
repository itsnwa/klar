import Foundation

private let sitePermissionRecordType = "SitePermission"
private let sitePermissionRecordPrefix = "site-"

/// Site permissions in iCloud (CloudSyncManager), one record per site with
/// answers, a field for each answer other than Ask. A site set back to Ask
/// for everything has no record, so it's deleted from iCloud.
@MainActor
extension SitePermissionsManager: CloudSyncSource {
    var syncRecordTypes: Set<String> {
        [sitePermissionRecordType]
    }

    var isReadyForSync: Bool {
        true
    }

    /// An answer set back to Ask is a field the record no longer has.
    var syncOptionalFields: Set<String> {
        Set(SitePermission.allCases.map(\.rawValue))
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        var records: [String: CloudSyncRecord] = [:]
        for (host, site) in decisions {
            records[sitePermissionRecordPrefix + host] = CloudSyncRecord(
                type: sitePermissionRecordType,
                fields: Dictionary(uniqueKeysWithValues: site.map { ($0.key.rawValue, CloudSyncValue.string($0.value.rawValue)) })
            )
        }
        return records
    }

    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        // A new Mac keeps its own sites as well; for a site both have,
        // iCloud's answers win.
        for (name, record) in saved {
            guard let host = Self.host(fromRecordName: name) else { continue }
            var site: [SitePermission: SitePermissionDecision] = [:]
            for permission in SitePermission.allCases {
                if let value = record[permission.rawValue]?.stringValue,
                   let decision = SitePermissionDecision(rawValue: value) {
                    site[permission] = decision
                }
            }
            replaceDecisionsFromSync(site, on: host)
        }
        for name in deleted {
            guard let host = Self.host(fromRecordName: name) else { continue }
            replaceDecisionsFromSync([:], on: host)
        }
    }

    private static func host(fromRecordName name: String) -> String? {
        guard name.hasPrefix(sitePermissionRecordPrefix) else { return nil }
        return String(name.dropFirst(sitePermissionRecordPrefix.count))
    }
}
