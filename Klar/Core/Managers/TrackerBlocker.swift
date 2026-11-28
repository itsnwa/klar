import AppKit
import CryptoKit
import WebKit

/// Keeps known trackers out of every tab, with Safari's protections on top. Settings › General › Privacy › Block
/// trackers turns it all on and off (`TOMLSettingsManager.blockTrackers`); the gear in the URL bar lets one site's
/// trackers load (`allowedHosts`, by the host of the page in the tab, synced as a setting; from a private tab, for
/// the private session only, `privateAllowedHosts`). The page itself always loads, a tracker's own site too: only
/// what pages load from trackers is blocked.
///
/// - Two content rule lists, added to a tab's user content controller or taken off it as the tab's main frame
///   navigates (`prepare(_:for:then:)`, from `TabWebViewCoordinator`), so a change applies from the page's next
///   load; popups share their opener's controller, and follow it:
///   - EasyPrivacy's, the `TrackerBlockList` data asset, which `ship` brings up to date for every release
///     (`scripts/update_tracker_list.py`; Klar fetches no list itself). It's compiled once per version of the
///     asset (about a second, on WebKit's queue) into `WKContentRuleListStore.default()`, and looked up at later
///     launches (a millisecond).
///   - Safari's: the one macOS keeps for its Advanced Tracking and Fingerprinting Protection, mostly ad
///     exchanges' cookie syncing, which EasyPrivacy leaves to EasyList. WebPrivacy, a private framework, compiles
///     it into the same store (`loadAppleList`) and posts when macOS updates it. Without it (a macOS that renamed
///     the call), EasyPrivacy blocks on its own.
/// - Safari's Advanced Tracking and Fingerprinting Protection, the private `_networkConnectionIntegrityPolicy` of
///   the page's `WKWebpagePreferences` (`setProtections`, for each main frame navigation): in every tab, known
///   tracking parameters are taken off the addresses of pages opened (fbclid, gclid; not utm_ ones), when the
///   page opened or the one it's opened from has the protection, so a link from another site into an allowed one
///   loses them too; in private tabs, all of it, as in Safari's Private Browsing, fingerprinting protection
///   included (what canvas, audio and the like read back differs in each private session). Settings › General ›
///   Privacy › Fingerprinting protection (`TOMLSettingsManager.fingerprintingProtection`) gives every tab all of
///   it, as Safari's "in all browsing" does.
@MainActor
final class TrackerBlocker: ObservableObject {
    static let shared = TrackerBlocker()

    private static let assetName = "TrackerBlockList"
    /// The compiled list's identifier is this and the asset's hash, so a new
    /// list compiles once and an old one is removed.
    private static let identifierPrefix = "klar-trackers-"
    private static let allowedHostsDefaultsKey = "com.itsnwa.browser.trackers.allowedHosts"
    /// How long a page waits for the list while it's compiled (the first
    /// launch after an update) before it loads without it.
    private static let readyTimeout: Duration = .seconds(3)

    /// Hosts whose pages load their trackers.
    @Published private(set) var allowedHosts: Set<String>
    /// Hosts allowed from a private tab: kept in memory for the private
    /// session (`forgetPrivateAllowances`, from SpaceManager.endPrivateSession),
    /// so the sites stay out of what Klar keeps and syncs. They count in every
    /// tab until then, as SitePermissionsManager's private answers do.
    @Published private(set) var privateAllowedHosts: Set<String> = []

    private var easyPrivacy: WKContentRuleList?
    private var appleList: WKContentRuleList?
    private var isLoading = false
    private var isLoadingAppleList = false
    private var appleListObserver: (any NSObjectProtocol)?
    /// The controllers that have each list (by identifier), so it isn't sent
    /// to their pages again on every navigation (WebKit's controller doesn't say).
    private var controllersWithList: [String: NSHashTable<WKUserContentController>] = [:]

    private init() {
        allowedHosts = Set(UserDefaults.standard.stringArray(forKey: Self.allowedHostsDefaultsKey) ?? [])
    }

    private var isOn: Bool {
        TOMLSettingsManager.shared.blockTrackers
    }

    private var lists: [WKContentRuleList] {
        [easyPrivacy, appleList].compactMap { $0 }
    }

    /// Whether the site's trackers load (allowed from its settings popover).
    func allowsTrackers(on host: String) -> Bool {
        let host = host.lowercased()
        return allowedHosts.contains(host) || privateAllowedHosts.contains(host)
    }

    /// Whether trackers are blocked on a page at `url`.
    func blocksTrackers(at url: URL?) -> Bool {
        guard isOn else { return false }
        guard let host = url?.host else { return true }
        return !allowsTrackers(on: host)
    }

    /// Whether a content rule list notification is one of these lists' (not an
    /// extension's): WebKit names Safari's list's blocks the same way.
    static func isTrackerList(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix) || identifier.hasSuffix(".TrackingResourceRequestContentBlocker")
    }

    // MARK: Loading

    /// Loads the lists while it's on: at launch, and when it's turned on.
    func start() {
        guard isOn else { return }
        if easyPrivacy == nil, !isLoading {
            isLoading = true
            Task {
                easyPrivacy = await Self.loadEasyPrivacy()
                isLoading = false
                // Pages that loaded without it get it now, from their next load
                TabWebViewCoordinator.applyTrackerBlocking()
            }
        }
        if appleList == nil {
            loadAppleList()
        }
    }

    private static func loadEasyPrivacy() async -> WKContentRuleList? {
        guard let data = NSDataAsset(name: assetName)?.data,
              let store = WKContentRuleListStore.default() else {
            logError(.webView, "Tracker list not found")
            return nil
        }
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let identifier = identifierPrefix + hash

        if let list = try? await store.contentRuleList(forIdentifier: identifier) {
            return list
        }

        let started = ContinuousClock.now
        guard let json = await decompress(data) else {
            logError(.webView, "Couldn't decompress the tracker list")
            return nil
        }
        do {
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            logInfo(.webView, "Compiled the tracker list in \(ContinuousClock.now - started)")
            // Earlier versions' compiled lists
            for old in await store.availableIdentifiers() ?? [] where old.hasPrefix(identifierPrefix) && old != identifier {
                try? await store.removeContentRuleList(forIdentifier: old)
            }
            return list
        } catch {
            logError(.webView, "Couldn't compile the tracker list: \(error)")
            return nil
        }
    }

    /// Raw DEFLATE, which NSData's `.zlib` reads (update_tracker_list.py).
    @concurrent private static func decompress(_ data: Data) async -> String? {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return String(decoding: json, as: UTF8.self)
    }

    /// Safari's list, from WebPrivacy: `-[WPResources loadTrackerBlockerRuleListForStore:completionHandler:]`
    /// (`loadDefaultContentRuleListForStore:` in later WebKit), which compiles macOS's current list into the
    /// store, or looks it up there (about half a second the first time). Loaded again when WebPrivacy says its
    /// data changed, which replaces it in the controllers that have it.
    private func loadAppleList() {
        guard !isLoadingAppleList,
              let library = dlopen("/System/Library/PrivateFrameworks/WebPrivacy.framework/WebPrivacy", RTLD_NOW),
              let resources = NSClassFromString("WPResources") as? NSObject.Type,
              let shared = resources.value(forKey: "sharedInstance") as? NSObject,
              let store = WKContentRuleListStore.default() else {
            logInfo(.webView, "Safari's tracker list isn't available")
            return
        }
        let selectors = ["loadTrackerBlockerRuleListForStore:completionHandler:", "loadDefaultContentRuleListForStore:completionHandler:"]
        guard let selector = selectors.map({ Selector(($0)) }).first(where: { shared.responds(to: $0) }),
              let method = class_getInstanceMethod(type(of: shared), selector) else {
            logInfo(.webView, "Safari's tracker list isn't available")
            return
        }

        if appleListObserver == nil,
           let name = dlsym(library, "WPResourceDataChangedNotificationName")?.assumingMemoryBound(to: NSString.self).pointee {
            appleListObserver = NotificationCenter.default.addMainObserver(forName: Notification.Name(name as String)) { [weak self] _ in
                guard let self, isOn else { return }
                loadAppleList()
            }
        }

        typealias Load = @convention(c) (AnyObject, Selector, WKContentRuleListStore, @escaping @Sendable @convention(block) (WKContentRuleList?, NSError?) -> Void) -> Void
        isLoadingAppleList = true
        unsafeBitCast(method_getImplementation(method), to: Load.self)(shared, selector, store) { list, error in
            // On WebPrivacy's queue
            let failure = error.map { "\($0)" } ?? "no list"
            Task { @MainActor in
                let blocker = TrackerBlocker.shared
                blocker.isLoadingAppleList = false
                guard let list else {
                    logError(.webView, "Couldn't load Safari's tracker list: \(failure)")
                    return
                }
                blocker.appleList = list
                // A newer version replaces the one these have (same identifier)
                for controller in blocker.controllersWithList[list.identifier]?.allObjects ?? [] {
                    controller.add(list)
                }
                TabWebViewCoordinator.applyTrackerBlocking()
            }
        }
    }

    // MARK: Web views

    /// A new web view's configuration starts with the lists, while it's on.
    func install(on configuration: WKWebViewConfiguration) {
        guard isOn else { return }
        for list in lists {
            configuration.userContentController.add(list)
            controllers(with: list).add(configuration.userContentController)
        }
    }

    /// Before `webView`'s main frame loads `url`: adds the lists or takes them
    /// off for that page, then calls `ready`. While EasyPrivacy's list is still
    /// being compiled, the page waits for it (up to `readyTimeout`).
    func prepare(_ webView: WKWebView, for url: URL?, then ready: @escaping @MainActor () -> Void) {
        guard isLoading, blocksTrackers(at: url) else {
            apply(to: webView, for: url)
            ready()
            return
        }
        Task {
            let deadline = ContinuousClock.now + Self.readyTimeout
            while isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            apply(to: webView, for: url)
            ready()
        }
    }

    /// Adds the lists to the web view's controller, or takes them off, for a
    /// page at `url`. It applies from the next load.
    func apply(to webView: WKWebView, for url: URL?) {
        let controller = webView.configuration.userContentController
        let blocks = blocksTrackers(at: url)
        for list in lists {
            let controllers = controllers(with: list)
            let hasList = controllers.contains(controller)
            if blocks, !hasList {
                controller.add(list)
                controllers.add(controller)
            } else if !blocks, hasList {
                controller.remove(list)
                controllers.remove(controller)
            }
        }
    }

    private func controllers(with list: WKContentRuleList) -> NSHashTable<WKUserContentController> {
        if let controllers = controllersWithList[list.identifier] { return controllers }
        let controllers = NSHashTable<WKUserContentController>.weakObjects()
        controllersWithList[list.identifier] = controllers
        return controllers
    }

    // MARK: Safari's protections

    /// WebKit's `_WKWebsiteNetworkConnectionIntegrityPolicy` bits for Safari's Advanced Tracking and Fingerprinting
    /// Protection (all four are what WebKit's own `_networkConnectionIntegrityEnabled` turns on).
    private enum Protection {
        /// Trackers behind a site's own domain blocked, every limit on known fingerprinting scripts, and the
        /// referrer cut after a cross-site navigation (BaselineProtections)
        static let baseline: UInt = 1 << 0
        /// What canvas, audio and other APIs read back varies by session (FingerprintingProtections)
        static let fingerprinting: UInt = 1 << 6
        /// EnhancedNetworkPrivacy
        static let network: UInt = 1 << 7
        /// Known tracking parameters taken off the addresses of pages opened (LinkDecorationFiltering)
        static let linkFiltering: UInt = 1 << 8

        static let all = baseline | fingerprinting | network | linkFiltering
    }

    /// For a main frame navigation to `url`: Safari's protections on the page's preferences, all of them (as in
    /// Private Browsing) in private tabs, or in every tab with Settings › General › Privacy › Fingerprinting
    /// protection In all tabs; none on a site whose trackers are allowed. Other policy bits are kept.
    func setProtections(on preferences: WKWebpagePreferences, for url: URL?, isPrivate: Bool) {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let getSelector = Selector(("_networkConnectionIntegrityPolicy"))
        let setSelector = Selector(("_setNetworkConnectionIntegrityPolicy:"))
        guard let getMethod = class_getInstanceMethod(WKWebpagePreferences.self, getSelector),
              let setMethod = class_getInstanceMethod(WKWebpagePreferences.self, setSelector) else { return }

        let everywhere = TOMLSettingsManager.shared.fingerprintingProtection == .allTabs
        let wanted = !blocksTrackers(at: url) ? 0 : isPrivate || everywhere ? Protection.all : Protection.linkFiltering
        let policy = unsafeBitCast(method_getImplementation(getMethod), to: Getter.self)(preferences, getSelector)
        let updated = (policy & ~Protection.all) | wanted
        guard updated != policy else { return }
        unsafeBitCast(method_getImplementation(setMethod), to: Setter.self)(preferences, setSelector, updated)
    }

    // MARK: Sites

    /// From the site's settings popover: lets the trackers on `host`'s pages load, or blocks them again. From a
    /// private tab, allowing lasts for the private session only. Tabs showing it follow from their next load.
    func setAllowsTrackers(_ allows: Bool, on host: String, isPrivate: Bool) {
        let host = host.lowercased()
        if allows {
            if isPrivate {
                privateAllowedHosts.insert(host)
                TabWebViewCoordinator.applyTrackerBlocking()
            } else {
                setAllowedHosts(allowedHosts.union([host]))
            }
        } else {
            privateAllowedHosts.remove(host)
            setAllowedHosts(allowedHosts.subtracting([host]))
            TabWebViewCoordinator.applyTrackerBlocking()
        }
    }

    /// Saves and applies them, from the popover or iCloud
    /// (`TOMLSettingsManager+CloudSync`).
    func setAllowedHosts(_ hosts: Set<String>) {
        guard hosts != allowedHosts else { return }
        allowedHosts = hosts
        UserDefaults.standard.set(hosts.sorted(), forKey: Self.allowedHostsDefaultsKey)
        CloudSyncManager.localDataChanged(.settings)
        TabWebViewCoordinator.applyTrackerBlocking()
    }

    /// The last private tab closed.
    func forgetPrivateAllowances() {
        guard !privateAllowedHosts.isEmpty else { return }
        privateAllowedHosts = []
        TabWebViewCoordinator.applyTrackerBlocking()
    }

    /// Settings › General › Privacy › Block trackers changed: the open tabs
    /// follow from their next load.
    func settingChanged() {
        start()
        TabWebViewCoordinator.applyTrackerBlocking()
    }
}
