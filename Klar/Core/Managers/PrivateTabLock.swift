import AppKit
import LocalAuthentication
import Observation

/// Locks the private tabs while you're away, as Safari's Locked Private Browsing does: when the screen locks, the
/// screen saver starts, the displays or the Mac sleep, the user switches away from their Mac account, or Klar has
/// been in the background for `backgroundDelay` with no private tab playing sound or video; and from Window › Lock
/// Private Tabs. Settings › General › Privacy › Lock private tabs (`TOMLSettingsManager.lockPrivateTabs`, on by
/// default) turns the automatic locking off; the menu locks either way.
///
/// One lock for every private tab in every window, as they share one private session (its cookies, a site signed
/// in from one is in all): one opened while they're locked is locked too, and unlocking (Touch ID or the Mac's
/// password) unlocks them all. Turning the setting off, here or from another Mac, leaves them locked until then.
/// A locked tab's page is hidden, not suspended (what plays keeps playing), and so is everything else of it: title,
/// address, icon, color (`BrowserTab.isLocked`, read where a tab is shown). Closing one doesn't need unlocking; the
/// lock ends with the private session (`SpaceManager.endPrivateSession`).
@MainActor
@Observable
final class PrivateTabLock {
    static let shared = PrivateTabLock()

    /// How long Klar is in the background before the private tabs lock
    static let backgroundDelay: Duration = .seconds(5 * 60)

    private(set) var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            NotificationCenter.default.post(name: .privateTabsLockDidChange, object: nil)
        }
    }

    /// While Touch ID or the password is being asked for
    private(set) var isUnlocking = false

    @ObservationIgnored private var backgroundLock: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    private init() {}

    private static var hasPrivateTabs: Bool {
        BrowserWindowSession.allTabs.contains(where: \.isPrivate)
    }

    /// From `KlarApp.init`: watches for the Mac locking or sleeping and Klar going to the background.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributed.addMainObserver(forName: Notification.Name(name)) { [weak self] _ in
                self?.lockIfAway()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addMainObserver(forName: name) { [weak self] _ in
                self?.lockIfAway()
            }
        }

        let app = NotificationCenter.default
        app.addMainObserver(forName: NSApplication.didResignActiveNotification) { [weak self] _ in
            self?.startBackgroundLock()
        }
        app.addMainObserver(forName: NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.backgroundLock?.cancel()
            self?.backgroundLock = nil
        }
    }

    /// The user is away: locks if the setting says to and there's something to lock.
    private func lockIfAway() {
        guard TOMLSettingsManager.shared.lockPrivateTabs else { return }
        lock()
    }

    /// After `backgroundDelay` in the background, then again each time while a private tab plays sound or video.
    private func startBackgroundLock() {
        backgroundLock?.cancel()
        backgroundLock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundDelay)
                guard !Task.isCancelled, let self else { return }
                guard !NSApp.isActive else { return }
                if !BrowserWindowSession.allTabs.contains(where: { $0.isPrivate && $0.isPlayingMedia }) {
                    self.lockIfAway()
                    return
                }
            }
        }
    }

    /// Locks the private tabs, if any are open. From Window › Lock Private Tabs, and when the user is away.
    func lock() {
        guard !isLocked, Self.hasPrivateTabs else { return }
        isLocked = true
        TabWebViewCoordinator.privateTabsLocked()
        // An open command palette may list them
        for session in BrowserWindowSession.all where session.tabManager.showCommandPalette {
            session.tabManager.showCommandPalette = false
        }
        logInfo(.general, "Locked the private tabs")
    }

    /// Asks for Touch ID or the Mac's password, and unlocks every private tab if it's given.
    func unlock() {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        Task {
            defer { isUnlocking = false }
            let context = LAContext()
            context.localizedCancelTitle = "Cancel"
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your private tabs") {
                    isLocked = false
                    logInfo(.general, "Unlocked the private tabs")
                }
            } catch {
                // Cancelled, or not allowed: they stay locked
                logInfo(.general, "Private tabs stay locked: \(error.localizedDescription)")
            }
        }
    }

    /// The private session has ended (its last tab closed): nothing is left to lock.
    func privateSessionEnded() {
        backgroundLock?.cancel()
        backgroundLock = nil
        isLocked = false
    }
}

extension BrowserTab {
    /// A private tab while the private tabs are locked: nothing of it shows, its page, title, address or icon.
    var isLocked: Bool {
        isPrivate && PrivateTabLock.shared.isLocked
    }
}
