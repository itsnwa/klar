import AppKit
import Combine
import WebKit

/// Runs Chrome extensions on WebKit's own extension engine (WKWebExtension).
///
/// One WKWebExtensionController serves every web view: WebViewConfiguration
/// hands it to each tab's configuration, so content scripts and the
/// extension APIs reach every page. Each enabled extension is a loaded
/// WKWebExtensionContext whose unique identifier is its Chrome ID and whose
/// pages live at chrome-extension://<id>/, as in Chrome — so its storage
/// survives updates and native hosts recognise its origin.
///
/// Klar keeps the list of installed extensions and what the user granted
/// each in ExtensionRecordStore; WebKit keeps the extensions' own data.
/// Tabs and windows reach the extensions through ExtensionBrowserBridge,
/// the controller's delegate callbacks are in ExtensionManager+Delegate.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    static let shared = ExtensionManager()

    /// Password managers whose extension takes sign-in autofill over from
    /// Klar's own (AutofillCoordinator) while it's enabled.
    static let passwordManagerIDs: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // 1Password
        "nngceckbapebfimnlniiiahkandclblb", // Bitwarden
        "ghmbeldphafepmbegfdlkpapadhbakde", // Proton Pass
        "pejdijmoenmkgeppbflobdenhhabjlaj", // iCloud Passwords
        "hdokiejnpimakedhajhdlcegeplioahd", // LastPass
        "fdjamakpfbbddfjaooikfcpapjohcfmg", // Dashlane
        "oboonakemofpalcgghocfoadofidjkkk"  // KeePassXC-Browser
    ]

    static let urlScheme = "chrome-extension"

    /// An installed extension as Settings and the URL bar show it.
    struct Item: Identifiable {
        let record: ExtensionRecord
        /// Nil until its folder has been read, or if that failed.
        let webExtension: WKWebExtension?
        /// The running extension; nil while it's off or failed to start.
        let context: WKWebExtensionContext?
        let error: String?
        let isInstalling: Bool
        let name: String
        let version: String?
        let isPasswordManager: Bool

        var id: String { record.id }
    }

    let controller: WKWebExtensionController
    private(set) lazy var bridge = ExtensionBrowserBridge(controller: controller)
    let nativeMessaging = ExtensionNativeMessaging()

    /// Installed extensions, by name.
    @Published private(set) var items: [Item] = []
    /// Bumped (at most once per turn of the main queue) whenever an
    /// extension's toolbar action changes — icon, badge, title, enabled.
    @Published private(set) var actionsRevision = 0
    /// False at launch until the enabled extensions have started. Tabs get
    /// no web view before then (BrowserView), so the first pages load with
    /// their content scripts.
    @Published private(set) var hasStartedExtensions = false

    private var records: [ExtensionRecord] = []
    private var webExtensions: [String: WKWebExtension] = [:]
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var errors: [String: String] = [:]
    private var installing: Set<String> = []
    /// Being removed because they were removed on another Mac.
    private var removingForSync: Set<String> = []
    /// Installs from iCloud that failed this session, not tried again.
    private var failedSyncInstalls: Set<String> = []
    /// Store updates (ID → version) that couldn't be read this session:
    /// update checks don't download them again.
    private var failedUpdates: [String: String] = [:]
    private var didStart = false
    private var didReadExtensions = false
    private var isActionUpdateScheduled = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var updateTimer: Timer?

    /// The URL bar buttons popups hang from, by extension ID.
    private let actionAnchors = NSMapTable<NSString, NSView>.strongToWeakObjects()
    /// The puzzle button, for extensions that aren't pinned.
    weak var puzzleAnchor: NSView?

    private static let updateInterval: TimeInterval = 5 * 60 * 60
    /// How long tabs wait at most for the extensions to start.
    private static let startTimeout: TimeInterval = 2

    private override init() {
        // Extension pages and match patterns use Chrome's scheme, so code
        // that checks for chrome-extension:// URLs keeps working.
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.urlScheme)
        controller = WKWebExtensionController()
        super.init()
        controller.delegate = self
    }

    // MARK: - Startup

    /// Reads the list of installed extensions. Call once at launch, before
    /// any tab gets a web view; the extensions themselves start once the
    /// first window is up (attach(window:session:)).
    func start() {
        guard !didStart else { return }
        didStart = true

        records = ExtensionRecordStore.load()
        publishItems()
        observePermissionChanges()

        if !records.contains(where: \.isEnabled) {
            markExtensionsStarted()
        }
        // The window is normally up long before this. Pages don't wait
        // longer for an extension that's slow to start.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            self?.readExtensions()
            self?.markExtensionsStarted()
        }
    }

    /// A browser window, once SwiftUI has made it, with its session. The
    /// first time, starts the extensions.
    func attach(window: NSWindow, session: BrowserWindowSession) {
        bridge.attach(session: session)
        readExtensions()
    }

    /// Reads the installed extensions' folders and starts the enabled ones,
    /// once. Not at launch: loading an extension builds its background page
    /// on the main thread (about 70 ms each), which held up the window.
    private func readExtensions() {
        guard didStart, !didReadExtensions else { return }
        didReadExtensions = true

        Task {
            for record in records {
                await readExtension(record.id)
            }
            markExtensionsStarted()
            scheduleUpdateChecks()
        }
    }

    private func markExtensionsStarted() {
        if !hasStartedExtensions {
            hasStartedExtensions = true
        }
    }

    /// Reads an installed extension's folder and starts it if it's enabled.
    private func readExtension(_ id: String) async {
        guard let record = record(for: id) else { return }
        if record.source == .webStore {
            // Installs from before Klar had the stand-ins, or older ones.
            ExtensionCompatibility.prepare(record.folderURL)
        }
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: record.folderURL)
            webExtensions[id] = webExtension
            errors[id] = nil
            if record.isEnabled {
                try startContext(for: record, webExtension: webExtension)
            }
        } catch {
            errors[id] = error.localizedDescription
            logError(.extensions, "Couldn't start \(id): \(error.localizedDescription)")
        }
        publishItems()
    }

    private func startContext(for record: ExtensionRecord, webExtension: WKWebExtension) throws {
        stopContext(for: record.id)

        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id
        if let baseURL = URL(string: record.origin) {
            context.baseURL = baseURL
        }
        context.inspectionName = webExtension.displayName
        context.isInspectable = Self.isInspectable(record)

        context.grantedPermissions = Self.permissions(from: record.grantedPermissions)
        context.deniedPermissions = Self.permissions(from: record.deniedPermissions)
        context.grantedPermissionMatchPatterns = Self.matchPatterns(from: record.grantedMatchPatterns)
        context.deniedPermissionMatchPatterns = Self.matchPatterns(from: record.deniedMatchPatterns)
        context.hasRequestedOptionalAccessToAllHosts = record.hasRequestedOptionalAccessToAllHosts

        // Tabs and windows must be known before the context asks for them.
        bridge.activate()
        try controller.load(context)
        contexts[record.id] = context
        logInfo(.extensions, "Started \(webExtension.displayName ?? record.id) \(webExtension.version ?? "")")
    }

    private func stopContext(for id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        nativeMessaging.disconnect(extensionID: id)
        context.action(for: nil)?.closePopup()
        do {
            try controller.unload(context)
        } catch {
            logError(.extensions, "Couldn't stop \(id): \(error.localizedDescription)")
        }
    }

    // MARK: - Lookups

    /// Like web pages, store extensions can be inspected with web developer
    /// tools on (always in Debug builds); developers' own always.
    private static func isInspectable(_ record: ExtensionRecord) -> Bool {
        record.source == .unpacked || WebViewConfiguration.showsDeveloperTools
    }

    /// Web developer tools turned on or off.
    func updateInspectability() {
        for record in records {
            contexts[record.id]?.isInspectable = Self.isInspectable(record)
        }
    }

    func record(for id: String) -> ExtensionRecord? {
        records.first { $0.id == id }
    }

    func context(for id: String) -> WKWebExtensionContext? {
        contexts[id]
    }

    func isInstalling(_ id: String) -> Bool {
        installing.contains(id)
    }

    /// Enabled extensions, by name.
    var runningItems: [Item] {
        items.filter { $0.context != nil }
    }

    /// The name of an enabled password-manager extension, if there is one.
    var enabledPasswordManagerName: String? {
        runningItems.first(where: \.isPasswordManager)?.name
    }

    /// An extension's toolbar action as it stands for the active tab.
    func action(for id: String) -> WKWebExtension.Action? {
        contexts[id]?.action(for: bridge.activeTab)
    }

    /// The icon of the extension a chrome-extension:// page belongs to,
    /// shown as that page's favicon.
    func icon(forExtensionURL urlString: String) -> NSImage? {
        guard let url = URL(string: urlString), url.scheme == Self.urlScheme, let id = url.host else { return nil }
        return webExtensions[id]?.icon(for: NSSize(width: 32, height: 32))
    }

    private func publishItems() {
        items = records
            .map { record in
                let webExtension = webExtensions[record.id]
                return Item(
                    record: record,
                    webExtension: webExtension,
                    context: contexts[record.id],
                    error: errors[record.id],
                    isInstalling: installing.contains(record.id),
                    name: webExtension?.displayName ?? record.id,
                    version: webExtension?.displayVersion ?? webExtension?.version ?? record.version,
                    isPasswordManager: Self.passwordManagerIDs.contains(record.id)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func updateRecord(_ id: String, _ change: (inout ExtensionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        saveRecords()
    }

    private func saveRecords() {
        ExtensionRecordStore.save(records)
        CloudSyncManager.localDataChanged(.extensions)
    }

    // MARK: - Installing

    /// Downloads an extension from the Chrome Web Store, asks the user to
    /// approve what it can do, and adds it.
    func installFromWebStore(id: String) async {
        guard CRXFile.isValidExtensionID(id), record(for: id) == nil, !installing.contains(id) else { return }
        installing.insert(id)
        defer {
            installing.remove(id)
            publishItems()
        }

        do {
            let folder = try await ExtensionInstaller.downloadFromWebStore(id: id)
            let added: Bool
            do {
                added = try await install(folder: folder, id: id, source: .webStore, askFirst: true)
            } catch {
                Self.discardFolder(folder)
                throw error
            }
            if !added {
                Self.discardFolder(folder)
            }
        } catch {
            ExtensionPermissionPrompt.showError(error.localizedDescription)
        }
    }

    /// Developer mode: an extension in a folder of the user's, read in
    /// place. Like Chrome, it gets what it asks for without a prompt.
    func loadUnpacked(from folder: URL) async {
        do {
            let id = try ExtensionInstaller.unpackedExtensionID(for: folder)
            if let existing = record(for: id) {
                if existing.source == .unpacked, existing.path != folder.path {
                    updateRecord(id) { $0.path = folder.path }
                }
                await reload(id)
                return
            }
            _ = try await install(folder: folder, id: id, source: .unpacked, askFirst: false)
        } catch {
            ExtensionPermissionPrompt.showError(error.localizedDescription, title: "Couldn't load the extension")
        }
    }

    /// Adds the extension in `folder`, granting what its manifest asks for
    /// once the user agrees. False if they don't.
    private func install(
        folder: URL, id: String, source: ExtensionRecord.Source, askFirst: Bool,
        enabled: Bool = true, pinned: Bool = false
    ) async throws -> Bool {
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        if askFirst {
            guard await ExtensionPermissionPrompt.confirmInstall(webExtension) else { return false }
        }

        var record = ExtensionRecord(id: id, source: source, path: folder.path, version: webExtension.version)
        record.isEnabled = enabled
        record.isPinned = pinned
        Self.grantRequested(by: webExtension, to: &record)
        records.removeAll { $0.id == id }
        records.append(record)
        webExtensions[id] = webExtension
        errors[id] = nil
        saveRecords()

        if enabled {
            do {
                try startContext(for: record, webExtension: webExtension)
            } catch {
                errors[id] = error.localizedDescription
            }
        }
        publishItems()
        return true
    }

    /// What the manifest asks for up front: its permissions and sites,
    /// content scripts' included. Optional ones are asked for when used.
    private static func grantRequested(by webExtension: WKWebExtension, to record: inout ExtensionRecord) {
        for permission in webExtension.requestedPermissions {
            record.grantedPermissions[permission.rawValue] = .distantFuture
            record.deniedPermissions.removeValue(forKey: permission.rawValue)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            record.grantedMatchPatterns[pattern.string] = .distantFuture
            record.deniedMatchPatterns.removeValue(forKey: pattern.string)
        }
    }

    // MARK: - Managing

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let record = record(for: id), record.isEnabled != enabled else { return }
        updateRecord(id) { $0.isEnabled = enabled }
        if enabled {
            if let webExtension = webExtensions[id], let updated = self.record(for: id) {
                do {
                    try startContext(for: updated, webExtension: webExtension)
                    errors[id] = nil
                } catch {
                    errors[id] = error.localizedDescription
                }
            } else {
                Task { await readExtension(id) }
            }
        } else {
            stopContext(for: id)
        }
        publishItems()
    }

    func setPinned(_ pinned: Bool, for id: String) {
        updateRecord(id) { $0.isPinned = pinned }
        publishItems()
    }

    /// Reads the extension's folder again — for unpacked extensions, after
    /// the developer changed it. New permissions are granted, as in Chrome.
    func reload(_ id: String) async {
        guard let record = record(for: id) else { return }
        stopContext(for: id)
        webExtensions[id] = nil
        if record.source == .unpacked,
           let webExtension = try? await WKWebExtension(resourceBaseURL: record.folderURL) {
            updateRecord(id) { record in
                record.version = webExtension.version
                Self.grantRequested(by: webExtension, to: &record)
            }
        }
        await readExtension(id)
    }

    func confirmAndRemove(id: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let icon = item.webExtension?.icon(for: NSSize(width: 64, height: 64))
        guard await ExtensionPermissionPrompt.confirmRemoval(name: item.name, icon: icon) else { return }
        await remove(id)
    }

    /// Removes the extension with its data (storage) and, for store
    /// extensions, its files.
    func remove(_ id: String) async {
        guard let record = record(for: id) else { return }

        // Its storage, found through the running context when there is one.
        let types = WKWebExtensionController.allExtensionDataTypes
        var own: [WKWebExtension.DataRecord] = []
        if let context = contexts[id], let dataRecord = await controller.dataRecord(ofTypes: types, for: context) {
            own = [dataRecord]
        } else {
            own = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        }
        stopContext(for: id)
        if !own.isEmpty {
            await withCheckedContinuation { continuation in
                controller.removeData(ofTypes: types, from: own) {
                    continuation.resume()
                }
            }
        }

        if record.source == .webStore {
            Self.discardFolder(record.folderURL)
        }
        records.removeAll { $0.id == id }
        webExtensions[id] = nil
        errors[id] = nil
        saveRecords()
        publishItems()
        logInfo(.extensions, "Removed \(id)")
    }

    // MARK: - iCloud

    /// Whether the installed extensions have been read (start(tabManager:)).
    var hasLoadedRecords: Bool {
        didStart
    }

    /// Store extensions as they sync (ExtensionManager+CloudSync). Unpacked
    /// ones are folders on this Mac, so they stay here.
    var syncedRecords: [ExtensionRecord] {
        records.filter { $0.source == .webStore && !removingForSync.contains($0.id) }
    }

    /// Installs an extension added on another Mac. The user approved what it
    /// asks for there, so there's no prompt.
    func installFromSync(id: String, enabled: Bool, pinned: Bool) async {
        guard CRXFile.isValidExtensionID(id), record(for: id) == nil, !installing.contains(id),
              !failedSyncInstalls.contains(id) else { return }
        installing.insert(id)
        publishItems()
        defer {
            installing.remove(id)
            publishItems()
        }

        do {
            let folder = try await ExtensionInstaller.downloadFromWebStore(id: id)
            do {
                _ = try await install(folder: folder, id: id, source: .webStore, askFirst: false, enabled: enabled, pinned: pinned)
            } catch {
                Self.discardFolder(folder)
                throw error
            }
            logInfo(.extensions, "Installed \(id) from iCloud")
        } catch {
            failedSyncInstalls.insert(id)
            logError(.extensions, "Couldn't install \(id) from iCloud: \(error.localizedDescription)")
        }
    }

    /// Removes an extension removed on another Mac. It leaves what syncs at
    /// once, though removing its data takes a moment.
    func removeFromSync(_ id: String) {
        guard record(for: id)?.source == .webStore, !removingForSync.contains(id) else { return }
        removingForSync.insert(id)
        Task {
            await remove(id)
            removingForSync.remove(id)
        }
    }

    /// Deletes a store extension's version folder, and the extension's
    /// folder once it's empty. Never touches folders Klar doesn't own.
    private static func discardFolder(_ folder: URL) {
        guard ExtensionRecordStore.ownsFolder(folder) else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        let parent = folder.deletingLastPathComponent()
        if ExtensionRecordStore.ownsFolder(parent),
           (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fileManager.removeItem(at: parent)
        }
    }

    // MARK: - Actions, menus and commands

    /// Runs an extension's toolbar action for the active tab: opens its
    /// popup (anchored by presentActionPopup) or fires action.onClicked.
    func performAction(for id: String) {
        guard let context = contexts[id] else { return }
        context.performAction(for: bridge.activeTab)
    }

    func openOptionsPage(for id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        showExtensionPage(url)
    }

    /// Switches to a tab already showing `url` in the window in front,
    /// else opens one there.
    func showExtensionPage(_ url: URL) {
        BrowserWindow.perform { session in
            let tabManager = session.tabManager
            if let existing = tabManager.tabs.first(where: { $0.url == url.absoluteString }) {
                tabManager.switchToTab(existing)
            } else {
                _ = self.bridge.openTab(url: url, active: true)
            }
        }
    }

    /// A browser window closed, with its tabs
    func windowDidClose(_ session: BrowserWindowSession) {
        bridge.windowDidClose(session)
    }

    /// The URL bar button for `id`, which its popup hangs from.
    func registerActionAnchor(_ view: NSView, for id: String) {
        actionAnchors.setObject(view, forKey: id as NSString)
    }

    func actionAnchor(for id: String) -> NSView? {
        actionAnchors.object(forKey: id as NSString)
    }

    /// Extensions' items for a page's context menu.
    func contextMenuItems(for webView: WKWebView) -> [NSMenuItem] {
        guard !contexts.isEmpty, let tab = bridge.tab(showing: webView) else { return [] }
        return runningItems.compactMap(\.context).flatMap { $0.menuItems(for: tab) }
    }

    /// Runs the extension keyboard shortcut `event` matches, if any.
    func performCommand(for event: NSEvent) -> Bool {
        // Chrome's shortcuts always include ⌘, ⌥ or ⌃, so typing skips this.
        guard !contexts.isEmpty, !event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return false
        }
        for context in contexts.values where context.command(for: event) != nil {
            return context.performCommand(for: event)
        }
        return false
    }

    /// Coalesces action updates (a badge can change many times a second).
    func actionDidChange() {
        guard !isActionUpdateScheduled else { return }
        isActionUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isActionUpdateScheduled = false
            self.actionsRevision &+= 1
        }
    }

    // MARK: - Permissions

    private func observePermissionChanges() {
        let names: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification
        ]
        for name in names {
            notificationObservers.append(NotificationCenter.default.addMainObserver(
                forName: name, object: nil
            ) { [weak self] notification in
                guard let context = notification.object as? WKWebExtensionContext else { return }
                self?.savePermissions(of: context)
            })
        }
    }

    /// Records what the context currently allows, so the next launch
    /// restores it.
    private func savePermissions(of context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        guard contexts[id] === context else { return }
        updateRecord(id) { record in
            record.grantedPermissions = Self.storable(context.grantedPermissions)
            record.deniedPermissions = Self.storable(context.deniedPermissions)
            record.grantedMatchPatterns = Self.storable(context.grantedPermissionMatchPatterns)
            record.deniedMatchPatterns = Self.storable(context.deniedPermissionMatchPatterns)
            record.hasRequestedOptionalAccessToAllHosts = context.hasRequestedOptionalAccessToAllHosts
        }
    }

    private static func storable(_ permissions: [WKWebExtension.Permission: Date]) -> [String: Date] {
        Dictionary(permissions.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func storable(_ patterns: [WKWebExtension.MatchPattern: Date]) -> [String: Date] {
        Dictionary(patterns.map { ($0.key.string, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func permissions(from stored: [String: Date]) -> [WKWebExtension.Permission: Date] {
        Dictionary(stored.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func matchPatterns(from stored: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        var patterns: [WKWebExtension.MatchPattern: Date] = [:]
        for (string, date) in stored {
            if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                patterns[pattern] = date
            }
        }
        return patterns
    }

    // MARK: - Updates

    private func scheduleUpdateChecks() {
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        // Not right at launch, while Klar is restoring tabs.
        Task {
            try? await Task.sleep(for: .seconds(90))
            await checkForUpdates()
        }
    }

    /// Updates store extensions that have a newer version. An update that
    /// would be allowed more than the user agreed to waits for their
    /// approval in Settings › Extensions.
    func checkForUpdates() async {
        let installed = records
            .filter { $0.source == .webStore }
            .reduce(into: [String: String]()) { $0[$1.id] = $1.version ?? "0" }
        guard !installed.isEmpty else { return }
        do {
            for update in try await ExtensionInstaller.checkForUpdates(installed) {
                await apply(update, approved: false)
            }
        } catch {
            logWarning(.extensions, "Update check failed: \(error.localizedDescription)")
        }
    }

    /// Installs the waiting update of `id` after asking the user.
    func reviewPendingUpdate(for id: String) async {
        guard let record = record(for: id), record.source == .webStore else { return }
        do {
            let updates = try await ExtensionInstaller.checkForUpdates([id: record.version ?? "0"])
            if let update = updates.first {
                await apply(update, approved: true)
            } else {
                updateRecord(id) { $0.pendingUpdateVersion = nil }
                publishItems()
            }
        } catch {
            ExtensionPermissionPrompt.showError(error.localizedDescription, title: "Couldn't update the extension")
        }
    }

    private func apply(_ update: ExtensionInstaller.AvailableUpdate, approved: Bool) async {
        guard let record = record(for: update.id), !installing.contains(update.id) else { return }
        if !approved, record.pendingUpdateVersion == update.version || failedUpdates[update.id] == update.version { return }
        installing.insert(update.id)
        defer {
            installing.remove(update.id)
            publishItems()
        }

        let folder: URL
        let webExtension: WKWebExtension
        do {
            folder = try await ExtensionInstaller.download(update)
        } catch {
            // A package that doesn't verify or unpack is no better next
            // time; a download that failed may be.
            switch error {
            case ExtensionInstaller.Error.download: break
            default: failedUpdates[update.id] = update.version
            }
            logError(.extensions, "Couldn't download the update of \(update.id): \(error.localizedDescription)")
            if approved {
                ExtensionPermissionPrompt.showError(error.localizedDescription, title: "Couldn't update the extension")
            }
            return
        }
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: folder)
        } catch {
            Self.discardFolder(folder)
            failedUpdates[update.id] = update.version
            logError(.extensions, "Couldn't read \(update.id) \(update.version): \(error.localizedDescription)")
            if approved {
                ExtensionPermissionPrompt.showError(error.localizedDescription, title: "Couldn't update the extension")
            }
            return
        }
        failedUpdates[update.id] = nil

        let added = additions(of: webExtension, beyond: record)
        let needsApproval = !ExtensionPermissionPrompt.warnings(permissions: added.permissions, matchPatterns: added.matchPatterns).isEmpty
        if needsApproval {
            var agreed = false
            if approved {
                agreed = await ExtensionPermissionPrompt.confirmUpdate(
                    webExtension, newPermissions: added.permissions, newMatchPatterns: added.matchPatterns
                )
            }
            guard agreed else {
                Self.discardFolder(folder)
                if !approved {
                    updateRecord(update.id) { $0.pendingUpdateVersion = update.version }
                    logInfo(.extensions, "Update of \(update.id) to \(update.version) needs approval")
                }
                return
            }
        }

        let oldFolder = record.folderURL
        updateRecord(update.id) { record in
            record.path = folder.path
            record.version = webExtension.version
            record.pendingUpdateVersion = nil
            Self.grantRequested(by: webExtension, to: &record)
        }
        webExtensions[update.id] = webExtension
        if let updated = self.record(for: update.id), updated.isEnabled {
            do {
                try startContext(for: updated, webExtension: webExtension)
                errors[update.id] = nil
            } catch {
                errors[update.id] = error.localizedDescription
            }
        }
        Self.discardFolder(oldFolder)
        logInfo(.extensions, "Updated \(update.id) to \(update.version)")
    }

    /// What a new version asks for that the user hasn't allowed.
    private func additions(of webExtension: WKWebExtension, beyond record: ExtensionRecord)
        -> (permissions: Set<String>, matchPatterns: Set<WKWebExtension.MatchPattern>) {
        let permissions = Set(webExtension.requestedPermissions.map(\.rawValue))
            .subtracting(record.grantedPermissions.keys)
        let granted = Self.matchPatterns(from: record.grantedMatchPatterns).keys
        let matchPatterns = webExtension.allRequestedMatchPatterns.filter { pattern in
            !granted.contains { $0.matches(pattern) }
        }
        return (permissions, matchPatterns)
    }
}
