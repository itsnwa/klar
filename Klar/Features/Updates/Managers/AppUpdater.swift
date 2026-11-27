import AppKit
import Combine
import Sparkle

/// Keeps installed copies up to date with Sparkle, shown in Klar's own window instead of Sparkle's: Sparkle
/// checks the feed, downloads, verifies and installs, and Klar is its user driver, publishing one `state` for
/// the sidebar's card (`UpdateCard`), the command palette's Restart to Update row, the Klar menu and
/// Settings › General › Updates. It checks when Klar opens and every few hours (`SUScheduledCheckInterval`),
/// downloads an update as soon as it finds one, and Restart to Update installs it and opens Klar again; left
/// alone, it installs when Klar quits. While one waits, a newer version out meanwhile takes its place
/// (`becomeReady`). What's New opens in a tab afterwards (`WhatsNew`). A silent update (`Update.isSilent`)
/// shows only where someone looks for it, and installs when Klar quits. Only builds made by `ship` carry the
/// feed's address (`SUFeedURL`, from `KLAR_UPDATE_FEED`: the latest GitHub release's `appcast.xml`), so debug
/// builds and other people's builds never go looking for updates.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// A version on its way in.
    struct Update: Equatable {
        /// What people see, "1.3.6". Nil for an update Sparkle resumed without saying which.
        let version: String?
        /// Its first new feature's title, from the notes `ship` puts in the feed.
        let headline: String?
        /// Marked silent in the feed (`isSilent(inNotes:for:installed:)`): no card, and no palette row with nothing
        /// typed, so it installs when Klar quits without a word. The Klar menu and Settings still show it.
        var isSilent = false

        /// "Klar 1.3.6"
        var name: String { version.map { "Klar \($0)" } ?? "Klar’s update" }
    }

    enum State: Equatable {
        case idle
        /// A check someone started (Check for Updates…), and its answer, which clears itself.
        case checking
        case upToDate
        case failed(title: String, message: String)
        /// `expected` is 0 until the download's size is known.
        case downloading(Update, received: UInt64, expected: UInt64)
        /// Downloaded: being unpacked and checked, and the installer readied.
        case preparing(Update)
        case ready(Update)
        /// Klar is quitting to install it.
        case installing(Update)

        /// The update it's about.
        var update: Update? {
            switch self {
            case .downloading(let update, _, _), .preparing(let update), .ready(let update), .installing(let update): update
            case .idle, .checking, .upToDate, .failed: nil
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// The sidebar's card was closed: hidden until Klar opens again or someone checks for updates. The
    /// update still installs when Klar quits, and the command palette still offers it.
    @Published var isCardHidden = false
    @Published private(set) var canCheckForUpdates = false
    /// Whether this build can update itself at all.
    let isAvailable: Bool

    var readyUpdate: Update? {
        if case .ready(let update) = state { return update }
        return nil
    }

    /// Between a check and its answer, or an update and its install, when there's nothing to ask Sparkle.
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .preparing, .installing: true
        case .idle, .upToDate, .failed, .ready: false
        }
    }

    private var updater: SPUUpdater?
    private var canCheckObservation: NSKeyValueObservation?

    /// The update this session is about.
    private var update: Update?
    /// Its version as Sparkle compares versions (`sparkle:version`).
    private var build: String?
    /// Sparkle brought it back from before, downloaded or readied, instead of finding it in the feed: a newer
    /// one may be out since.
    private var isResumed = false
    /// Installs the ready update now: Sparkle's answer to its question, or its immediate install after
    /// downloading on its own.
    private var install: (() -> Void)?
    /// Gives the ready update up for a newer one: Sparkle's answer that stops its installer, which is waiting
    /// for Klar to quit.
    private var discard: (() -> Void)?
    /// Looks for a newer version while an update's ready.
    private var newerUpdateWatch: Task<Void, Never>?
    /// A newer version taking the ready update's place (`replaceReadyUpdate`), shown downloading meanwhile.
    private var replacement: Replacement?
    /// The version given up last for a newer one.
    private var replacedBuild: String?
    private var isUserInitiated = false
    private var receivedLength: UInt64 = 0
    private var expectedLength: UInt64 = 0
    /// The download's progress as last shown, so every chunk doesn't re-run the card.
    private var shownFraction: Double = 0
    private var clearMessage: Task<Void, Never>?

    /// How long an answer to a check stays up.
    private static let messageDuration: Duration = .seconds(6)

    private enum Replacement {
        /// Sparkle's letting the ready update go, ending its session.
        case lettingGo
        /// Checking again, which finds the newer version.
        case checking
    }

    init(feed: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) {
        isAvailable = !(feed ?? "").isEmpty
        super.init()
    }

    /// Called once the window is up, like the other background work.
    func start() {
        guard isAvailable, updater == nil else { return }

        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
        do {
            try updater.start()
        } catch {
            logError(.updates, "Couldn't start the updater: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        // Every launch, not only once the check interval has passed since the last check
        updater.checkForUpdatesInBackground()
    }

    /// Klar › Check for Updates… and Settings: the answer shows in the sidebar's card, so from the menu, the
    /// window in front shows its sidebar.
    func checkForUpdates(showingSidebar: Bool = true) {
        guard let updater else { return }
        isCardHidden = false
        reveal()
        if showingSidebar {
            showSidebar()
        }
        updater.checkForUpdates()
    }

    /// Restart to Update: installs the ready update, and Sparkle opens Klar again on it.
    func installUpdate() {
        guard case .ready(let update) = state, let install else { return }
        self.install = nil
        discard = nil
        newerUpdateWatch?.cancel()
        logInfo(.updates, "Restarting to install \(update.name)")
        show(.installing(update))
        install()
    }

    #if DEBUG
    /// Klar › Simulate an Update, in debug builds, which never update: the card, the palette row and the menu
    /// as an update would show them, without Sparkle. Restart to Update only ends it.
    func simulateUpdate() {
        let update = Update(version: "9.9.9", headline: ReleaseNotes.bundled.first { !$0.new.isEmpty }?.new.first?.title)
        let expected: UInt64 = 31_200_000
        isCardHidden = false
        showSidebar()
        Task { [weak self] in
            self?.show(.checking)
            try? await Task.sleep(for: .seconds(1))
            for step in 0...50 {
                self?.state = .downloading(update, received: expected * UInt64(step) / 50, expected: expected)
                try? await Task.sleep(for: .milliseconds(80))
            }
            self?.show(.preparing(update))
            try? await Task.sleep(for: .seconds(1))
            self?.install = { [weak self] in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self?.finish()
                }
            }
            self?.show(.ready(update))
        }
    }
    #endif

    /// Someone looked for updates: a silent one on its way shows as any other.
    private func reveal() {
        guard var update, update.isSilent else { return }
        update.isSilent = false
        self.update = update
        switch state {
        case .downloading(_, let received, let expected): state = .downloading(update, received: received, expected: expected)
        case .preparing: state = .preparing(update)
        case .ready: state = .ready(update)
        case .installing: state = .installing(update)
        case .idle, .checking, .upToDate, .failed: break
        }
    }

    private func showSidebar() {
        BrowserWindow.perform { session in
            if !session.sidebarStateManager.isVisible {
                session.sidebarStateManager.show()
            }
        }
    }

    private func show(_ newState: State) {
        clearMessage?.cancel()
        clearMessage = nil
        state = newState
        switch newState {
        case .upToDate, .failed:
            clearMessage = Task { [weak self] in
                try? await Task.sleep(for: Self.messageDuration)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        default:
            break
        }
    }

    /// Ready: Restart to Update installs it. It can wait days for that, and Sparkle doesn't look at the feed
    /// meanwhile (a check only brings back the update it has), so Klar does, every check interval, and a newer
    /// version takes its place (`replaceReadyUpdate`): restarting installs the newest, instead of one that's
    /// out of date, with the next found straight after.
    private func becomeReady(_ update: Update) {
        show(.ready(update))
        newerUpdateWatch?.cancel()
        guard discard != nil, let build, let updater, let feedURL = updater.feedURL else { return }
        let installed = Bundle.main.shortVersion
        // One from before may be out of date already, unless it's the one given up a moment ago, whose
        // installer hadn't stopped yet
        let looksNow = isResumed && build != replacedBuild
        // No more often than Sparkle checks at most
        let interval = Duration.seconds(max(updater.updateCheckInterval, 60 * 60))
        newerUpdateWatch = Task { [weak self] in
            if !looksNow {
                try? await Task.sleep(for: interval)
            }
            while !Task.isCancelled {
                if let newest = await UpdateFeed.newestVersion(at: feedURL),
                   SUStandardVersionComparator.default.compareVersion(build, toVersion: newest.build) == .orderedAscending {
                    self?.replaceReadyUpdate(with: Self.update(version: newest.version, notes: newest.notes, installed: installed))
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Sparkle lets the ready update go, its installer stopping, and once that session's over, Klar checks
    /// again (`checkForReplacement`), which finds the newer version and downloads it.
    private func replaceReadyUpdate(with newer: Update) {
        guard case .ready(let ready) = state, let discard else { return }
        var newer = newer
        // One that shows (revealed, or bringing this one along) keeps showing
        if !ready.isSilent {
            newer.isSilent = false
        }
        logInfo(.updates, "\(newer.name) is out, so it takes the place of \(ready.name)")
        self.discard = nil
        install = nil
        replacedBuild = build
        build = nil
        update = newer
        replacement = .lettingGo
        receivedLength = 0
        expectedLength = 0
        shownFraction = 0
        show(.downloading(newer, received: 0, expected: 0))
        discard()
    }

    /// The installer stops a moment after it's told to, and Sparkle looks for one once more as the session
    /// ends: a check before both are done would bring the old update back, or be turned down.
    private func checkForReplacement() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<20 {
                guard let self, replacement == .checking, let updater else { return }
                if !updater.sessionInProgress {
                    updater.checkForUpdatesInBackground()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.finish()
        }
    }

    /// Nothing to show any more.
    private func finish() {
        show(.idle)
        update = nil
        build = nil
        isResumed = false
        install = nil
        discard = nil
        newerUpdateWatch?.cancel()
        newerUpdateWatch = nil
        replacement = nil
        isUserInitiated = false
        receivedLength = 0
        expectedLength = 0
        shownFraction = 0
    }

    private func publishProgress() {
        guard let update, case .downloading = state else { return }
        let fraction = expectedLength > 0 ? min(Double(receivedLength) / Double(expectedLength), 1) : 0
        // Half a percent is finer than the card's bar shows
        guard fraction - shownFraction >= 0.005 || fraction == 1 && shownFraction < 1 else { return }
        shownFraction = fraction
        state = .downloading(update, received: receivedLength, expected: expectedLength)
    }

    private static func update(from item: SUAppcastItem) -> Update {
        update(version: item.displayVersionString, notes: item.itemDescription, installed: Bundle.main.shortVersion)
    }

    private static func update(version: String, notes: String?, installed: String) -> Update {
        Update(version: version, headline: headline(inNotes: notes, for: version),
               isSilent: isSilent(inNotes: notes, for: version, installed: installed))
    }

    /// The first new feature's title in the notes `ship` embeds in the feed: each version's notes are a
    /// `<section data-sparkle-version="…">`, their features `<ul class="new">` items, each `<b>Title</b><span>…`.
    nonisolated static func headline(inNotes html: String?, for version: String) -> String? {
        guard let html, let start = html.range(of: "data-sparkle-version=\"\(version)\"") else { return nil }
        let rest = html[start.upperBound...]
        let section = rest[..<(rest.range(of: "</section>")?.lowerBound ?? rest.endIndex)]
        guard let list = section.range(of: "<ul class=\"new\">"),
              let open = section[list.upperBound...].range(of: "<b>"),
              let close = section[open.upperBound...].range(of: "</b>") else { return nil }
        let title = section[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return title.isEmpty ? nil : title
    }

    /// Whether `version` and every version between it and the one installed are marked silent in the notes
    /// (`data-klar-silent` on their section, from `"silent": true` in ReleaseNotes.json): a silent update that
    /// also brings one skipped before isn't.
    nonisolated static func isSilent(inNotes html: String?, for version: String, installed: String) -> Bool {
        guard let html else { return false }
        var hasVersion = false
        for section in html.components(separatedBy: "<section ").dropFirst() {
            let attributes = section.prefix { $0 != ">" }
            guard let start = attributes.range(of: "data-sparkle-version=\""),
                  let end = attributes[start.upperBound...].firstIndex(of: "\"") else { continue }
            let sectionVersion = String(attributes[start.upperBound..<end])
            guard sectionVersion.compare(installed, options: .numeric) == .orderedDescending,
                  sectionVersion.compare(version, options: .numeric) != .orderedDescending else { continue }
            guard attributes.contains("data-klar-silent") else { return false }
            if sectionVersion == version {
                hasVersion = true
            }
        }
        return hasVersion
    }
}

// MARK: - Sparkle's user driver

extension AppUpdater: SPUUserDriver {
    /// Info.plist turns automatic checks on, so Sparkle doesn't ask; if it does, that's the answer.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        isUserInitiated = true
        // Takes over from a check for a newer update than the one that was ready
        replacement = nil
        show(.checking)
    }

    /// Downloads it right away, found by a check someone started or by the checks Klar makes itself.
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Klar's feed has none, but one that's only there to be read about can't be installed
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            return
        }
        var update = Self.update(from: appcastItem)
        // A check someone started shows it
        if isUserInitiated {
            update.isSilent = false
        }
        self.update = update
        build = appcastItem.versionString
        isResumed = state.stage != .notDownloaded
        replacement = nil
        isCardHidden = false
        logInfo(.updates, "Found \(update.name)\(update.isSilent ? ", silent" : "")")

        switch state.stage {
        case .installing:
            // Readied earlier: installing it now quits Klar, so that waits for Restart to Update
            install = { reply(.install) }
            // Stops its installer
            discard = { reply(.skip) }
            becomeReady(update)
        case .downloaded:
            show(.preparing(update))
            reply(.install)
        default:
            receivedLength = 0
            expectedLength = appcastItem.contentLength
            shownFraction = 0
            show(.downloading(update, received: 0, expected: expectedLength))
            reply(.install)
        }
    }

    // The notes are in the feed itself (`ship`), so there are none to download.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    /// Only for a check someone started.
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        switch reason {
        case .systemIsTooOld, .systemIsTooNew:
            // Sparkle's words say which macOS the newer version needs
            let error = error as NSError
            show(.failed(title: "Klar can’t update", message: error.localizedRecoverySuggestion ?? error.localizedDescription))
        default:
            show(.upToDate)
        }
    }

    /// A check someone started, or a download that was showing, failed. Klar's own checks try again later.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        logError(.updates, "Update failed: \(error.localizedDescription)")
        guard isUserInitiated else {
            finish()
            return
        }
        let title = update == nil ? "Couldn’t check for updates" : "Couldn’t update Klar"
        show(.failed(title: title, message: error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedLength = 0
        shownFraction = 0
        guard let update else { return }
        show(.downloading(update, received: 0, expected: expectedLength))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        publishProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        publishProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        show(.preparing(update ?? Update(version: nil, headline: nil)))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Ready: Restart to Update answers. Until then, quitting Klar installs it.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let update = update ?? Update(version: nil, headline: nil)
        self.update = update
        install = { reply(.install) }
        discard = { reply(.skip) }
        logInfo(.updates, "\(update.name) is ready")
        becomeReady(update)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        show(.installing(update ?? Update(version: nil, headline: nil)))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish()
    }

    /// Check for Updates… while an update's on its way: the card shows it.
    func showUpdateInFocus() {
        isCardHidden = false
        showSidebar()
    }

    /// Sparkle ends every session with this. An answer to a check stays up until it clears itself, and a
    /// newer update taking the ready one's place shows until it's found.
    func dismissUpdateInstallation() {
        switch state {
        case .upToDate, .failed:
            update = nil
            install = nil
            isUserInitiated = false
        default:
            guard replacement == nil else { return }
            finish()
        }
    }
}

// MARK: - Sparkle's delegate

extension AppUpdater: SPUUpdaterDelegate {
    /// Only after Sparkle downloaded an update on its own (`SUAutomaticallyUpdate`), which Klar leaves off so
    /// downloads show: ready all the same.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let update = Self.update(from: item)
        self.update = update
        install = immediateInstallHandler
        becomeReady(update)
        return true
    }

    /// Every session's end. One that let the ready update go for a newer one is followed by a check that finds it.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        switch replacement {
        case .lettingGo:
            replacement = .checking
            checkForReplacement()
        case .checking:
            // It found nothing to download after all
            finish()
        case nil:
            break
        }
    }
}

// MARK: - The feed, read by Klar

/// The newest version in the update feed that this Mac can run, which Klar reads itself while an update is
/// ready: Sparkle doesn't then.
nonisolated enum UpdateFeed {
    struct Version {
        /// `sparkle:version`, which versions are compared by.
        let build: String
        /// What people see, `sparkle:shortVersionString`.
        let version: String
        /// Its notes, as `ship` embeds them.
        let notes: String?
    }

    @concurrent static func newestVersion(at feedURL: URL) async -> Version? {
        let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parser = ItemParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }

        // As Sparkle compares them
        let comparator = SUStandardVersionComparator.default
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let newest = parser.items
            .filter { item in
                item.build != nil && item.channel == nil && !item.isInformational
                    && item.minimumSystemVersion.map { comparator.compareVersion($0, toVersion: system) != .orderedDescending } ?? true
            }
            .max { comparator.compareVersion($0.build ?? "", toVersion: $1.build ?? "") == .orderedAscending }
        guard let newest, let build = newest.build else { return nil }
        let version = newest.version ?? build
        return Version(build: build, version: version, notes: newest.notes)
    }

    /// The feed's `<item>`s, as `generate_appcast` writes them.
    private final class ItemParser: NSObject, XMLParserDelegate {
        struct Item {
            var build: String?
            var version: String?
            var minimumSystemVersion: String?
            var channel: String?
            var isInformational = false
            var notes: String?
        }

        private(set) var items: [Item] = []
        private var item: Item?
        /// How deep in the item the parser is: only its own elements count.
        private var depth = 0
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard item != nil else {
                if elementName == "item" {
                    item = Item()
                    depth = 0
                }
                return
            }
            depth += 1
            text = ""
            guard depth == 1 else { return }
            switch elementName {
            case "enclosure":
                // Where older feeds have the versions; elements of their own win
                if item?.build == nil {
                    item?.build = attributes["sparkle:version"]
                }
                if item?.version == nil {
                    item?.version = attributes["sparkle:shortVersionString"]
                }
            case "sparkle:informationalUpdate":
                item?.isInformational = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let current = item else { return }
            guard depth > 0 else {
                items.append(current)
                item = nil
                return
            }
            if depth == 1 {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch elementName {
                case "sparkle:version": item?.build = value
                case "sparkle:shortVersionString": item?.version = value
                case "sparkle:minimumSystemVersion": item?.minimumSystemVersion = value
                case "sparkle:channel": item?.channel = value
                case "description": item?.notes = text
                default: break
                }
            }
            depth -= 1
        }
    }
}
