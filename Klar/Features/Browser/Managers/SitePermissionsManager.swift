import Foundation
import AppKit
import WebKit

/// What a site has to ask for before using it.
enum SitePermission: String, CaseIterable {
    case camera
    case microphone
    case location

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        }
    }
}

enum SitePermissionDecision: String, CaseIterable {
    case ask
    case allow
    case block

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }
}

/// Each site's answers for camera, microphone and location. An answer to
/// the prompt is kept until it's changed in the site's settings popover
/// (WebsiteSettingsView), and syncs with iCloud
/// (SitePermissionsManager+CloudSync). Keyed by the host of the page in the
/// tab, which is what the prompt and the popover name, also when a frame in
/// it asks. Shared by every profile.
@MainActor
final class SitePermissionsManager: ObservableObject {
    static let shared = SitePermissionsManager()

    private static let defaultsKey = "com.itsnwa.browser.sitePermissions"

    /// Host → its answers other than Ask.
    @Published private(set) var decisions: [String: [SitePermission: SitePermissionDecision]]

    /// Answers given in private tabs: kept in memory, for the private
    /// session only (SpaceManager.endPrivateSession), so the sites stay out
    /// of what Klar keeps. They count in every tab until then.
    private var privateDecisions: [String: [SitePermission: SitePermissionDecision]] = [:]

    /// Prompts on screen, by host and what they ask for, with everyone
    /// waiting for the answer.
    private var pendingPrompts: [String: [(Bool) -> Void]] = [:]

    private init() {
        decisions = Self.load()
    }

    func decision(for permission: SitePermission, on host: String) -> SitePermissionDecision {
        let host = host.lowercased()
        return decisions[host]?[permission] ?? privateDecisions[host]?[permission] ?? .ask
    }

    func forgetPrivateDecisions() {
        guard !privateDecisions.isEmpty else { return }
        objectWillChange.send()
        privateDecisions = [:]
    }

    func setDecision(_ decision: SitePermissionDecision, for permission: SitePermission, on host: String) {
        setDecisions([permission: decision], on: host)
    }

    /// Replaces a site's answers with iCloud's, without telling sync.
    func replaceDecisionsFromSync(_ site: [SitePermission: SitePermissionDecision], on host: String) {
        let site = site.filter { $0.value != .ask }
        guard decisions[host] ?? [:] != site else { return }
        decisions[host] = site.isEmpty ? nil : site
        save()
    }

    private func setDecisions(_ changes: [SitePermission: SitePermissionDecision], on host: String) {
        let host = host.lowercased()
        var site = decisions[host] ?? [:]
        for (permission, decision) in changes {
            site[permission] = decision == .ask ? nil : decision
        }
        guard site != decisions[host] ?? [:] else { return }
        decisions[host] = site.isEmpty ? nil : site
        save()
        CloudSyncManager.localDataChanged(.sitePermissions)
    }

    /// Calls back with whether `host` may use all of `permissions`: at once
    /// when it has answers for them, otherwise once the user answers a sheet
    /// on `webView`'s window. The answer is kept. A request for what's
    /// already being asked waits for that answer instead of asking again.
    func requestAccess(
        to permissions: [SitePermission],
        on host: String,
        from webView: WKWebView,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = webView.url, Self.canAsk(from: url) else {
            completion(false)
            return
        }
        let host = host.lowercased()
        guard !permissions.contains(where: { decision(for: $0, on: host) == .block }) else {
            completion(false)
            return
        }
        let unanswered = permissions.filter { decision(for: $0, on: host) == .ask }
        guard let first = unanswered.first else {
            completion(true)
            return
        }

        // A locked private tab's page can't ask: the prompt would name its
        // site (PrivateTabLock). Refused for now, not remembered
        if PrivateTabLock.shared.isLocked, !webView.configuration.websiteDataStore.isPersistent {
            completion(false)
            return
        }

        let key = host + " " + unanswered.map(\.rawValue).joined(separator: ",")
        if pendingPrompts[key] != nil {
            pendingPrompts[key]?.append(completion)
            return
        }
        pendingPrompts[key] = [completion]
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent

        let alert = NSAlert()
        alert.messageText = "Allow “\(host)” to use your \(Self.describe(unanswered))?"
        alert.informativeText = isPrivate
            ? "Klar remembers your answer until your private tabs are closed."
            : "Klar remembers your answer. You can change it in the website settings, from the gear in the address bar."
        alert.icon = NSImage(systemSymbolName: first.symbol + ".circle", accessibilityDescription: first.title)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")

        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            let allowed = response == .alertFirstButtonReturn
            logDebug(.webView, "\(host) \(allowed ? "allowed" : "blocked") \(Self.describe(unanswered))")
            let answers = Dictionary(uniqueKeysWithValues: unanswered.map { ($0, allowed ? SitePermissionDecision.allow : .block) })
            if isPrivate {
                self.objectWillChange.send()
                self.privateDecisions[host, default: [:]].merge(answers) { _, new in new }
            } else {
                self.setDecisions(answers, on: host)
            }
            for waiting in self.pendingPrompts.removeValue(forKey: key) ?? [] {
                waiting(allowed)
            }
        }
        if let window = webView.presentationWindow {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    /// Whether a page may ask: a secure one, as browsers count them — HTTPS,
    /// or this Mac itself (`localhost`, `*.localhost`, 127.x.x.x, ::1) for
    /// local development. Answers are kept by host, so an HTTP page — which
    /// anyone on the network can change — never gets what its HTTPS site was
    /// allowed. (Location is Klar's own bridge, offered to every page.)
    nonisolated static func canAsk(from url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        switch url.scheme {
        case "https":
            return true
        case "http":
            return host == "localhost" || host.hasSuffix(".localhost")
                || host == "::1" || host == "[::1]"
                || (host.hasPrefix("127.") && host.split(separator: ".").count == 4
                    && host.split(separator: ".").allSatisfy { UInt8($0) != nil })
        default:
            return false
        }
    }

    /// "camera", "camera and microphone".
    private static func describe(_ permissions: [SitePermission]) -> String {
        permissions.map { $0.title.lowercased() }.joined(separator: " and ")
    }

    // MARK: - Persistence

    private static func load() -> [String: [SitePermission: SitePermissionDecision]] {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: String]] ?? [:]
        var decisions: [String: [SitePermission: SitePermissionDecision]] = [:]
        for (host, values) in stored {
            var site: [SitePermission: SitePermissionDecision] = [:]
            for (key, value) in values {
                guard let permission = SitePermission(rawValue: key),
                      let decision = SitePermissionDecision(rawValue: value),
                      decision != .ask else { continue }
                site[permission] = decision
            }
            if !site.isEmpty {
                decisions[host] = site
            }
        }
        return decisions
    }

    private func save() {
        let stored = decisions.mapValues { site in
            Dictionary(uniqueKeysWithValues: site.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
    }
}
