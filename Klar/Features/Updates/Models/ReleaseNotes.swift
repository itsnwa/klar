import Foundation

/// What changed in one version. `ReleaseNotes.json` lists them newest first, and the same
/// file feeds the What's New window and, through `ship`, the notes Sparkle shows before an update.
struct ReleaseNotes: Decodable, Equatable, Identifiable {
    /// A headline change, shown with its own symbol.
    struct Feature: Decodable, Equatable {
        /// An SF Symbol name.
        let symbol: String
        let title: String
        let detail: String
    }

    /// Notes still being written, which `ship` labels with the version it releases.
    static let unreleased = "unreleased"

    let version: String
    var new: [Feature] = []
    var improvements: [String] = []
    var fixes: [String] = []
    /// Installed without a word (`"silent": true`): no update card, and no What's New tab after it; its notes
    /// wait for the next update that's announced (`WhatsNew.recordLaunch`). `ship` marks it in the feed.
    var isSilent = false
    /// When these notes combine several versions, the oldest of them. `version` is the newest.
    var earliestVersion: String?

    var id: String { version }
    var isUnreleased: Bool { version == Self.unreleased }

    init(version: String, new: [Feature] = [], improvements: [String] = [], fixes: [String] = [], earliestVersion: String? = nil) {
        self.version = version
        self.new = new
        self.improvements = improvements
        self.fixes = fixes
        self.earliestVersion = earliestVersion
    }

    private enum CodingKeys: String, CodingKey { case version, new, improvements, fixes, silent }

    /// A version can leave out any of the three lists.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        new = try container.decodeIfPresent([Feature].self, forKey: .new) ?? []
        improvements = try container.decodeIfPresent([String].self, forKey: .improvements) ?? []
        fixes = try container.decodeIfPresent([String].self, forKey: .fixes) ?? []
        isSilent = try container.decodeIfPresent(Bool.self, forKey: .silent) ?? false
    }

    static let bundled: [ReleaseNotes] = load(from: Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"))

    static func load(from url: URL?) -> [ReleaseNotes] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ReleaseNotes].self, from: data)) ?? []
    }

    /// The notes for exactly this version.
    static func notes(for version: String, in all: [ReleaseNotes] = bundled) -> ReleaseNotes? {
        all.first { $0.version == version }
    }

    /// The newest released notes that aren't for a later version than this one.
    static func latest(upTo version: String, in all: [ReleaseNotes] = bundled) -> ReleaseNotes? {
        all.filter { !$0.isUnreleased && $0.version.compare(version, options: .numeric) != .orderedDescending }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    /// Everything released after `previous`, up to and including `version`, as one set of notes,
    /// so someone who skipped a few updates sees all of them. Without a `previous`, just `version`'s notes.
    static func since(_ previous: String?, upTo version: String, in all: [ReleaseNotes] = bundled) -> ReleaseNotes? {
        guard let previous else { return notes(for: version, in: all) }
        return combined(released(after: previous, upTo: version, in: all))
    }

    /// Each version's notes released after `previous`, up to and including `version`. Without a `previous`,
    /// just `version`'s.
    static func released(after previous: String?, upTo version: String, in all: [ReleaseNotes] = bundled) -> [ReleaseNotes] {
        guard let previous else { return notes(for: version, in: all).map { [$0] } ?? [] }
        return all.filter {
            !$0.isUnreleased
                && $0.version.compare(previous, options: .numeric) == .orderedDescending
                && $0.version.compare(version, options: .numeric) != .orderedDescending
        }
    }

    /// Several versions' notes merged list by list, newest first.
    static func combined(_ notes: [ReleaseNotes]) -> ReleaseNotes? {
        let newestFirst = notes.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        guard let newest = newestFirst.first, let oldest = newestFirst.last else { return nil }
        return ReleaseNotes(
            version: newest.version,
            new: newestFirst.flatMap(\.new),
            improvements: newestFirst.flatMap(\.improvements),
            fixes: newestFirst.flatMap(\.fixes),
            earliestVersion: newestFirst.count > 1 ? oldest.version : nil
        )
    }

    /// What Klar › What's New… opens. Development builds preview the notes still being written.
    static func forMenu(version: String, in all: [ReleaseNotes] = bundled) -> ReleaseNotes? {
        #if DEBUG
        if let draft = all.first(where: \.isUnreleased) { return draft }
        #endif
        return latest(upTo: version, in: all)
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Updates install with Restart to Update or when Klar quits, so the first launch afterwards is the moment
/// to say what changed: What's New opens in a tab (`WhatsNewPage`).
@MainActor
final class WhatsNew {
    static let shared = WhatsNew()
    static let lastVersionKey = "lastLaunchedVersion"
    /// The version launched before the silent updates installed since, whose notes wait for the next
    /// update that's announced.
    static let unannouncedSinceKey = "WhatsNewUnannouncedSince"

    /// What this launch has to say, opened once the window is up.
    private var launchPageURL: String?

    /// How this launch came about, as far as What's New is concerned.
    enum Launch: Equatable {
        case notUpdated
        /// The first launch after updating from `previous`, or from an unknown version.
        case updated(from: String?)
    }

    /// Records `version` as launched, and says whether it's newer than the version launched before.
    /// With no earlier record, only an install that already has Klar's data counts as updated:
    /// it ran a version from before this check existed, which one isn't known.
    static func launch(of version: String, isFreshInstall: Bool, defaults: UserDefaults = .standard) -> Launch {
        let previous = defaults.string(forKey: lastVersionKey)
        defaults.set(version, forKey: lastVersionKey)
        guard let previous else { return isFreshInstall ? .notUpdated : .updated(from: nil) }
        return version.compare(previous, options: .numeric) == .orderedDescending ? .updated(from: previous) : .notUpdated
    }

    /// Whether Klar has run on this Mac before: it keeps its settings in ~/.config/klar and
    /// everything else in Application Support. Only meaningful before either is written this launch.
    static var hasExistingData: Bool {
        let fileManager = FileManager.default
        let settings = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/klar/config.toml")
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(SidebarConfiguration.appSupportDirectoryName)
        return fileManager.fileExists(atPath: settings.path) || fileManager.fileExists(atPath: appSupport.path)
    }

    /// Called first thing at launch, before anything saves settings or data.
    func recordLaunch(defaults: UserDefaults = .standard) {
        let version = Bundle.main.shortVersion
        guard case .updated(let previous) = Self.launch(of: version, isFreshInstall: !Self.hasExistingData, defaults: defaults) else { return }
        // Everything since the version launched before, however many updates that skipped, and the silent
        // ones before it
        let since = defaults.string(forKey: Self.unannouncedSinceKey) ?? previous
        let missed = ReleaseNotes.released(after: since, upTo: version)
        guard !missed.isEmpty else { return }
        guard !missed.allSatisfy(\.isSilent) else {
            if let since {
                defaults.set(since, forKey: Self.unannouncedSinceKey)
            }
            return
        }
        defaults.removeObject(forKey: Self.unannouncedSinceKey)
        launchPageURL = WhatsNewPage.url(since: since)
    }

    /// Opens what changed since the last launch in a new tab in the window in front, once.
    func showLaunchNotes() {
        guard let launchPageURL else { return }
        self.launchPageURL = nil
        BrowserWindowSession.current.tabManager.showKlarPage(launchPageURL, where: WhatsNewPage.isPage)
    }

    static var menuNotes: ReleaseNotes? { ReleaseNotes.forMenu(version: Bundle.main.shortVersion) }

    /// Klar › What's New…: in a new tab, or the window's What's New tab when it has one.
    func showMenuNotes() {
        BrowserWindow.perform { session in
            session.tabManager.showKlarPage(WhatsNewPage.url(), where: WhatsNewPage.isPage)
        }
    }
}
