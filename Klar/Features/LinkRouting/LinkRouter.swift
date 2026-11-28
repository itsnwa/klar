import AppKit

/// A link opened from another app (a click in Mail or Slack, `open`, a
/// file from Finder) and the app it came from, when that's known.
nonisolated struct ExternalLink: Sendable {
    let address: String
    /// The sending app's bundle identifier
    let sourceApp: String?
}

/// Where links from other apps open (Settings › Links): the space of the
/// first route a link matches, else the default space, else the space in
/// front; in a window already showing that space, else the window in front.
/// A page already open in that space is switched to instead of opened
/// again. Links wrapped in a redirect are matched, and usually opened, by
/// where they lead (`LinkRedirects`).
@MainActor
final class LinkRouter {
    static let shared = LinkRouter()

    private var settings: TOMLSettingsManager { .shared }

    struct Destination {
        /// What the tab opens
        let address: String
        /// The space it opens in; nil for the space in front
        let spaceID: UUID?
        /// The route that sent it there
        let route: LinkRoute?
    }

    // MARK: - Routing

    /// Where a link goes, by the routes, the default space and redirects.
    func destination(for link: ExternalLink) -> Destination {
        var address = link.address
        var matched = URL(string: link.address)
        if let url = matched, let unwrapped = LinkRedirects.unwrap(url) {
            matched = unwrapped.destination
            if unwrapped.opensDirectly {
                address = unwrapped.destination.absoluteString
            }
        }

        let spaces = SpaceManager.shared
        if let url = matched,
           let route = settings.linkRoutes.first(where: { spaces.space(withID: $0.spaceID) != nil && $0.matches(url, from: link.sourceApp) }) {
            return Destination(address: address, spaceID: route.spaceID, route: route)
        }
        let defaultSpace = settings.linkDefaultSpaceID.flatMap { spaces.space(withID: $0) }?.id
        return Destination(address: address, spaceID: defaultSpace, route: nil)
    }

    /// Opens a link from another app where it goes, bringing its window
    /// forward. Returns false when there's no browser window to open it in.
    @discardableResult
    func open(_ link: ExternalLink) -> Bool {
        if let sourceApp = link.sourceApp {
            rememberSourceApp(sourceApp)
        }
        let destination = destination(for: link)
        let session = destination.spaceID.flatMap(session(showing:)) ?? BrowserWindowSession.current
        guard let window = session.window else { return false }
        let tabManager = session.tabManager
        let spaceID = destination.spaceID ?? session.spaceSelection.currentSpaceID

        logDebug(.tabManagement, "Link from \(link.sourceApp ?? "another app") opens \(destination.address) in space \(spaceID?.uuidString ?? "in front")\(destination.route == nil ? "" : " by a route")")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if settings.reuseOpenTabsForLinks,
           let key = SavedTabCleanup.comparableKey(for: destination.address),
           let itemID = openItem(showing: key, inSpace: spaceID, in: session) {
            logDebug(.tabManagement, "Link from another app shows the tab already at its page")
            session.sidebarManager.selectItem(itemID)
        } else if let active = tabManager.activeTab, active.isEmpty,
                  destination.spaceID == nil || SpaceManager.shared.spaceID(of: active) == destination.spaceID {
            // The window's empty tab takes it
            tabManager.navigateToURL(destination.address)
        } else {
            let tabID = tabManager.createNewTab(url: destination.address, isExternalURL: true, inSpace: destination.spaceID)
            if destination.route == nil {
                rememberUnroutedTab(tabID, address: destination.address, sourceApp: link.sourceApp)
            }
        }

        // The link's page takes over: close the palette, which the empty
        // start screen opens on its own and which would otherwise stay open
        // over the page.
        if tabManager.showCommandPalette {
            tabManager.showCommandPalette = false
            tabManager.isNewTabMode = false
        }
        return true
    }

    /// A window showing the space, the one last in front first.
    private func session(showing spaceID: UUID) -> BrowserWindowSession? {
        if BrowserWindowSession.current.window != nil, BrowserWindowSession.current.spaceSelection.currentSpaceID == spaceID {
            return BrowserWindowSession.current
        }
        return BrowserWindowSession.open.first { $0.spaceSelection.currentSpaceID == spaceID }
    }

    /// A tab in the window already at the page, as the sidebar selects it:
    /// a regular tab in the space, a saved tab in it (by its page here, else
    /// its saved address) or a pinned site. Private tabs aren't reused.
    private func openItem(showing key: String, inSpace spaceID: UUID?, in session: BrowserWindowSession) -> UUID? {
        let tabManager = session.tabManager
        let structure = SidebarStore.shared.structure
        let pages = session.sidebarManager.sidebarToBrowserTabMapping
        let savedTabPages = Set(pages.values)
        let tabsByID = Dictionary(tabManager.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func isAtPage(_ address: String) -> Bool {
            SavedTabCleanup.comparableKey(for: address) == key
        }
        func savedTabIsAtPage(_ savedTab: SidebarTab) -> Bool {
            let address = pages[savedTab.id].flatMap { tabsByID[$0]?.url } ?? savedTab.url
            return !address.isEmpty && isAtPage(address)
        }

        if let spaceID {
            let regular = session.spaceSelection.tabs(inSpace: spaceID).first { tab in
                !savedTabPages.contains(tab.id) && !tab.isPrivate && !tab.isEmpty
                    && !tabManager.isEmptyPane(tab) && isAtPage(tab.url)
            }
            if let regular {
                return regular.id
            }
            if let saved = structure.tabs.values.first(where: { $0.collectionID == spaceID && savedTabIsAtPage($0) }) {
                return saved.id
            }
        }
        return structure.pinnedItems.first { id in
            structure.tabs[id].map(savedTabIsAtPage) ?? false
        }
    }

    // MARK: - Spaces changing

    /// A space removed by hand: its routes go with it, and links no route
    /// matches open in the space in front again if it was theirs. (A space
    /// that's only missing here, not yet synced, keeps its routes: they're
    /// skipped until it's here.)
    func spaceWasDeleted(_ id: UUID) {
        settings.linkRoutes.removeAll { $0.spaceID == id }
        if settings.linkDefaultSpaceID == id {
            settings.linkDefaultSpaceID = nil
        }
    }

    /// iCloud's first sync matched a space here to one with another ID.
    func spaceWasRekeyed(from oldID: UUID, to newID: UUID) {
        settings.linkRoutes = settings.linkRoutes.map { route in
            var route = route
            if route.spaceID == oldID {
                route.spaceID = newID
            }
            return route
        }
        if settings.linkDefaultSpaceID == oldID {
            settings.linkDefaultSpaceID = newID
        }
    }

    // MARK: - Apps links come from

    private static let sourceAppsKey = "LinkSenderApps"

    /// The apps that sent links lately, the latest first: what Settings
    /// offers for a route's app.
    var recentSourceApps: [String] {
        UserDefaults.standard.stringArray(forKey: Self.sourceAppsKey) ?? []
    }

    private func rememberSourceApp(_ bundleID: String) {
        var apps = recentSourceApps.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        apps.insert(bundleID, at: 0)
        UserDefaults.standard.set(Array(apps.prefix(8)), forKey: Self.sourceAppsKey)
    }

    /// The app that sent an Apple Event: the process it came from, read
    /// as it's handled (a short-lived sender may be gone later). Nil for
    /// one without a bundle (`open` in a shell) or Klar itself.
    static func sourceApp(of event: NSAppleEventDescriptor) -> String? {
        // The sender's process ID, as a number (`typeUInt32`); through
        // LaunchServices it's still the process that opened the link.
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0,
              let bundleID = appBundleID(ofProcess: pid_t(pid)),
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return bundleID
    }

    /// The app a process is: the outermost app bundle its executable is in
    /// (an app's helper process counts as the app), else what macOS says
    /// it runs as.
    private static func appBundleID(ofProcess pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            var appPath = ""
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                appPath += "/" + component
                if component.hasSuffix(".app") {
                    if let bundleID = Bundle(path: appPath)?.bundleIdentifier {
                        return bundleID
                    }
                    break
                }
            }
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - Suggesting a route

    private struct UnroutedTab {
        let host: String
        let openedAt: Date
    }

    /// Tabs opened from other apps by no route, lately
    private var unroutedTabs: [UUID: UnroutedTab] = [:]
    /// Hosts a route was offered for this launch
    private var offeredHosts: Set<String> = []
    /// How long after a link opens moving its tab offers a route
    private let suggestionWindow: TimeInterval = 10 * 60

    private func rememberUnroutedTab(_ tabID: UUID, address: String, sourceApp: String?) {
        let now = Date()
        unroutedTabs = unroutedTabs.filter { now.timeIntervalSince($0.value.openedAt) < suggestionWindow }
        guard let host = URL(string: address)?.host(percentEncoded: false),
              let domain = LinkRoute.domain(from: host) else { return }
        unroutedTabs[tabID] = UnroutedTab(host: domain, openedAt: now)
    }

    /// A tab is moved to another space by hand: one a link from another app
    /// opened a little while ago offers to always open its site there.
    func tabWillMove(_ tab: BrowserTab, toSpace spaceID: UUID, in tabManager: TabManager) {
        guard let unrouted = unroutedTabs.removeValue(forKey: tab.id),
              Date().timeIntervalSince(unrouted.openedAt) < suggestionWindow,
              !offeredHosts.contains(unrouted.host),
              let space = SpaceManager.shared.space(withID: spaceID),
              !settings.linkRoutes.contains(where: { $0.match == .domain && $0.app == nil && LinkRoute.domain(from: $0.pattern) == unrouted.host })
        else { return }
        offeredHosts.insert(unrouted.host)

        let host = unrouted.host
        tabManager.toastManager.showToast(
            message: "Always open \(host) in \(space.name)?",
            description: "For links from other apps",
            type: .info,
            icon: "arrow.triangle.branch",
            action: ToastAction(title: "Always") { [weak self] in
                self?.settings.linkRoutes.append(LinkRoute(match: .domain, pattern: host, app: nil, spaceID: spaceID))
            },
            duration: 8
        )
    }
}
