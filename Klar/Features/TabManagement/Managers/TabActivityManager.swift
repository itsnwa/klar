import AppKit

/// Manages persistent tab activity tracking across app sessions
class TabActivityManager {
    static let shared = TabActivityManager()
    
    private let userDefaults = UserDefaults.standard
    private let tabActivityKey = "TabActivityHistory"
    private let maxHistorySize = 100
    
    /// How long after the last change the history is written out
    private let saveDelay: TimeInterval = 2
    
    // Tab activity history stored as [tabId: lastActiveTimestamp]
    private var tabActivityHistory: [String: Date] = [:]
    private var saveWorkItem: DispatchWorkItem?
    
    private init() {
        loadTabActivityHistory()
        NotificationCenter.default.addMainObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil
        ) { [weak self] _ in
            self?.saveNow()
        }
    }
    
    // MARK: - Public API
    
    /// Record that a tab was activated
    func recordTabActivity(for tabId: UUID) {
        tabActivityHistory[tabId.uuidString] = Date()
        scheduleSave()
    }
    
    /// Get the last active timestamp for a tab
    func getLastActiveTime(for tabId: UUID) -> Date? {
        return tabActivityHistory[tabId.uuidString]
    }
    
    /// Get tabs sorted by activity (most recent first)
    func getTabsSortedByActivity<T>(_ tabs: [T], getId: (T) -> UUID) -> [T] {
        return tabs.sorted { tab1, tab2 in
            let id1 = getId(tab1)
            let id2 = getId(tab2)
            
            let time1 = getLastActiveTime(for: id1) ?? Date.distantPast
            let time2 = getLastActiveTime(for: id2) ?? Date.distantPast
            
            return time1 > time2
        }
    }
    
    /// Remove activity tracking for a tab that no longer exists
    func removeTabActivity(for tabId: UUID) {
        guard tabActivityHistory.removeValue(forKey: tabId.uuidString) != nil else { return }
        scheduleSave()
    }
    
    /// Clean up old entries to prevent unlimited growth
    /// Returns whether any were removed
    @discardableResult
    private func cleanupOldEntries() -> Bool {
        guard tabActivityHistory.count > maxHistorySize else { return false }
        // Sort by timestamp and keep only the most recent entries
        let entriesToKeep = tabActivityHistory.sorted { $0.value > $1.value }.prefix(maxHistorySize)
        tabActivityHistory = Dictionary(uniqueKeysWithValues: Array(entriesToKeep))
        return true
    }
    
    /// Get activity-based tab history for command palette sorting
    func getTabHistoryOrder(_ tabIds: [UUID]) -> [UUID] {
        return tabIds.sorted { id1, id2 in
            let time1 = getLastActiveTime(for: id1) ?? Date.distantPast
            let time2 = getLastActiveTime(for: id2) ?? Date.distantPast
            return time1 > time2
        }
    }
    
    // MARK: - Persistence
    
    /// Several switches in a row (and the 3–4 records of a single one)
    /// write the history once.
    private func scheduleSave() {
        guard saveWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: item)
    }
    
    private func saveNow() {
        guard let saveWorkItem else { return }
        saveWorkItem.cancel()
        self.saveWorkItem = nil
        cleanupOldEntries()
        // Convert to string keys for UserDefaults storage
        let stringDict = tabActivityHistory.mapValues { $0.timeIntervalSince1970 }
        userDefaults.set(stringDict, forKey: tabActivityKey)
    }
    
    private func loadTabActivityHistory() {
        guard let stringDict = userDefaults.object(forKey: tabActivityKey) as? [String: Double] else {
            return
        }
        
        // Convert back to Date objects
        tabActivityHistory = stringDict.mapValues { Date(timeIntervalSince1970: $0) }
        
        // Clean up old entries on load
        if cleanupOldEntries() {
            scheduleSave()
        }
    }
} 