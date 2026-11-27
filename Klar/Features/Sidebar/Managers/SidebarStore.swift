import Combine
import Foundation

/// The saved tabs, folders, pinned sites and spaces every window shows, and
/// which saved tab each browser tab is a page of. One for the app: each
/// window's `SidebarManager` reads and changes it, keeping that window's own
/// state (selection, expanded folders, and the page each saved tab has in
/// that window, `sidebarToBrowserTabMapping`).
///
/// A saved tab can be open in several windows, a page of its own in each.
/// Browser tab IDs are unique across windows, so which saved tab a page
/// belongs to is app-wide. A saved tab's `isUnloaded` says it's open in no
/// window. This is also what iCloud syncs (`SidebarStore+CloudSync`).
final class SidebarStore: ObservableObject {
    static let shared = SidebarStore()

    @Published var structure = SidebarStructure()

    /// The saved tab each browser tab, in any window, is a page of
    var browserToSidebarTabMapping: [UUID: UUID] = [:]

    /// A saved tab's page retitled itself (its ID). The title changes in
    /// `structure` without `lastUpdated`, so the sidebar doesn't reload: only
    /// that tab's row updates (`SidebarTabRowView`).
    let savedTabTitleDidChange = PassthroughSubject<UUID, Never>()

    private let persistenceManager = SidebarPersistenceManager.shared

    // Debounced save mechanism to reduce disk I/O
    private var saveTimer: Timer?
    private var hasPendingChanges = false

    private var notificationObservers: [NSObjectProtocol] = []

    private init() {
        loadStructure()
        setupNotificationListeners()

        // Fix any existing order property mismatches, but only save if changes were made
        if resyncOrderProperties() {
            save()
        }
    }

    isolated deinit {
        if hasPendingChanges {
            save()
        }
        saveTimer?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Every window's sidebar
    var sidebarManagers: [SidebarManager] {
        BrowserWindowSession.all.map(\.sidebarManager)
    }

    /// Whether a saved tab has a page in any window: what its `isUnloaded`
    /// follows
    func isOpenInAnyWindow(_ savedTabID: UUID) -> Bool {
        sidebarManagers.contains { $0.sidebarToBrowserTabMapping[savedTabID] != nil }
    }

    // MARK: - Loading

    private func loadStructure() {
        // First try to load from the normal persistence manager
        if let loadedStructure = persistenceManager.loadSidebarStructure() {
            var structure = loadedStructure

            // Validate and auto-repair structure if needed
            switch SidebarValidation.validateStructureIntegrity(structure) {
            case .success():
                break
            case .failure(let error):
                logWarning(.sidebar, "Structure validation failed: \(error.localizedDescription). Attempting auto-repair...")
                let repairActions = SidebarAutoRepair.repairStructure(&structure)
                for action in repairActions {
                    logInfo(.sidebar, "Auto-repair: \(action)")
                }
            }

            let migratedToSpaces = structure.migrateToSpaces()
            self.structure = structure
            if migratedToSpaces {
                save()
            }

            // Clean up any stuck loading states from persistence
            cleanupStuckLoadingStates()
        } else {
            // No saved structure (first launch), or it couldn't be read — the
            // persistence manager has then kept a copy of the unreadable
            // file. Start with the default structure.
            var defaultStructure = SidebarStructure()

            // The first space
            let defaultCollection = SidebarCollection.makeDefaultSpace()
            defaultStructure.collections[defaultCollection.id] = defaultCollection

            structure = defaultStructure

            // Save the default structure so it persists
            save()

            logInfo(.sidebar, "Created default sidebar structure with the '\(defaultCollection.title)' space")
        }
    }

    private func cleanupStuckLoadingStates() {
        var hasChanges = false
        var newStructure = structure

        // Reset isLoading to false for all tabs on app startup
        // Only active tabs that are actually loading should have isLoading = true
        for (tabID, tab) in newStructure.tabs {
            if tab.isLoading {
                var updatedTab = tab
                updatedTab.isLoading = false
                updatedTab.estimatedProgress = 0.0
                newStructure.tabs[tabID] = updatedTab
                hasChanges = true
                logDebug(.sidebar, "Reset stuck loading state for tab: \(tab.displayTitle)")
            }
        }

        if hasChanges {
            structure = newStructure
            save()
            logInfo(.sidebar, "Cleaned up stuck loading states for \(hasChanges ? "multiple" : "no") tabs")
        }
    }

    // MARK: - Saving

    /// Saves at once: for changes the user made
    func save() {
        // Cancel any pending debounced save
        saveTimer?.invalidate()
        saveTimer = nil
        hasPendingChanges = false

        persistenceManager.saveSidebarStructure(structure)
        CloudSyncManager.localDataChanged(.sidebar)
    }

    /// Saves after a pause: for frequent updates like tab state changes
    func saveDebounced() {
        hasPendingChanges = true

        // Cancel existing timer
        saveTimer?.invalidate()

        // Schedule save after configured interval of inactivity
        saveTimer = Timer.scheduledTimer(withTimeInterval: SidebarConfiguration.saveDebounceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save()
            }
        }
    }

    /// Writes out a pending debounced change and waits until every queued
    /// save is on disk. Call when the app is about to exit.
    func flushPendingSaves() {
        if hasPendingChanges {
            save()
        }
        persistenceManager.flushPendingSaves()
    }

    // MARK: - Order

    // Fix order properties to match current array positions
    // Returns true if changes were made, false if no changes needed
    @discardableResult
    func resyncOrderProperties() -> Bool {
        var changesMade = false

        // Fix root items
        for (index, itemID) in structure.rootItems.enumerated() {
            if var tab = structure.tabs[itemID] {
                if tab.order != index {
                    tab.order = index
                    structure.tabs[itemID] = tab
                    changesMade = true
                }
            } else if var folder = structure.folders[itemID] {
                if folder.order != index {
                    folder.order = index
                    structure.folders[itemID] = folder
                    changesMade = true
                }
            }
        }

        // Fix folder children
        for folder in structure.folders.values {
            for (index, childID) in folder.childrenIds.enumerated() {
                if var tab = structure.tabs[childID] {
                    if tab.order != index {
                        tab.order = index
                        structure.tabs[childID] = tab
                        changesMade = true
                    }
                } else if var childFolder = structure.folders[childID] {
                    if childFolder.order != index {
                        childFolder.order = index
                        structure.folders[childID] = childFolder
                        changesMade = true
                    }
                }
            }
        }

        if changesMade {
            logDebug(.sidebar, "Resynced order properties - changes were made")
        }

        return changesMade
    }

    // MARK: - Notifications

    private func setupNotificationListeners() {
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("ChangeFolderIcon"),
            object: nil
        ) { [weak self] notification in
            self?.handleChangeFolderIconNotification(notification)
        })
    }

    private func handleChangeFolderIconNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let folderIDString = userInfo["folderID"] as? String,
              let iconString = userInfo["icon"] as? String,
              let folderID = UUID(uuidString: folderIDString) else { return }

        // A symbol or icon from our predefined list, or any emoji
        let icomoji = Icomoji(iconString)
        let isEmoji: Bool = {
            if case .emoji = icomoji { return true }
            return false
        }()
        guard isEmoji || FolderIcons.isValidIcon(iconString) else {
            logWarning(.sidebar, "Invalid icon selected: \(iconString)")
            return
        }

        if var folder = structure.folders[folderID] {
            folder.icon = iconString
            structure.folders[folderID] = folder
            // Bump lastUpdated so dedupe filters in subscribers (notably
            // the AppKit sidebar's structure sink) see this as a real
            // change. Without this, the icon change publishes but the
            // dedupe suppresses it because lastUpdated is stale, and the
            // cell doesn't refresh until the next unrelated event.
            structure.lastUpdated = Date()
            save()
            logInfo(.sidebar, "Changed folder '\(folder.displayTitle)' icon to: \(iconString)")
        }
    }
}
