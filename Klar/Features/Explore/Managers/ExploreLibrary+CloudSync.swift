import Foundation

private let explorePageRecordType = "ExplorePage"
private let explorePageRecordPrefix = "explore-"

/// Explore's collection in iCloud (CloudSyncManager), a record per answer, `explore-<uuid>`: what was asked
/// about which page, by whom and when, and the sites found, as JSON.
@MainActor
extension ExploreLibrary: CloudSyncSource {
    var syncRecordTypes: Set<String> {
        [explorePageRecordType]
    }

    var isReadyForSync: Bool {
        true
    }

    /// Answers from before sites had names, or about a page with none
    var syncOptionalFields: Set<String> {
        ["siteName"]
    }

    func syncRecords() -> [String: CloudSyncRecord] {
        var records: [String: CloudSyncRecord] = [:]
        for answer in answers.values {
            guard let sites = Self.encode(answer.sites) else { continue }
            var fields: [String: CloudSyncValue] = [
                "question": .string(answer.question.rawValue),
                "source": .string(answer.source),
                "sourceTitle": .string(answer.sourceTitle),
                "provider": .string(answer.provider),
                "date": .seconds(answer.date),
                "sites": .string(sites),
            ]
            if let siteName = answer.siteName {
                fields["siteName"] = .string(siteName)
            }
            records[explorePageRecordPrefix + answer.id.uuidString] = CloudSyncRecord(type: explorePageRecordType, fields: fields)
        }
        return records
    }

    /// A new Mac keeps its own answers as well: they're different ones.
    func applySyncChanges(saved: [String: CloudSyncRecord], deleted: Set<String>, isInitialMerge: Bool) {
        let answers = saved.compactMap { name, record -> ExplorePage.Answer? in
            guard let id = Self.id(fromRecordName: name),
                  let question = record["question"]?.stringValue.flatMap(ExplorePage.Question.init(rawValue:)),
                  let source = record["source"]?.stringValue, ExplorePage.isWebAddress(source),
                  let sites = record["sites"]?.stringValue.flatMap(Self.decode) else { return nil }
            return ExplorePage.Answer(
                id: id,
                question: question,
                source: source,
                sourceTitle: record["sourceTitle"]?.stringValue ?? ExplorePage.displayHost(of: source),
                siteName: record["siteName"]?.stringValue,
                provider: record["provider"]?.stringValue ?? "AI",
                date: record["date"]?.dateValue ?? Date(),
                // As this Mac would keep them: web addresses only
                sites: Self.checked(sites, question: question, source: source)
            )
        }
        applyFromSync(saved: answers, deleted: Set(deleted.compactMap(Self.id(fromRecordName:))))
    }

    private static func id(fromRecordName name: String) -> UUID? {
        guard name.hasPrefix(explorePageRecordPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(explorePageRecordPrefix.count)))
    }

    /// The same text for the same sites, so an unchanged answer is never sent again
    private static func encode(_ sites: [ExplorePage.Site]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(sites)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decode(_ text: String) -> [ExplorePage.Site]? {
        try? JSONDecoder().decode([ExplorePage.Site].self, from: Data(text.utf8))
    }
}
