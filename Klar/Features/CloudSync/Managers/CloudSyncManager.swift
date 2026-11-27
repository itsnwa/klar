import AppKit
import CloudKit
import Combine
import Security

/// Keeps Klar's saved tabs and folders, settings and extensions in the
/// user's private CloudKit database, and Klar's passwords in iCloud
/// Keychain (PasswordManager), while Settings › iCloud is on.
///
/// Each source (CloudSyncSource) hands over its data as records. For each
/// record this keeps what it last sent or received — values, the CKRecord's
/// system fields, when it changed — in CloudSync/, a state per CloudKit
/// environment (CloudSyncStore), next to CKSyncEngine's own state, and finds
/// local changes by comparing. A record that disappears is deleted from
/// iCloud only if the source had it earlier in this session; one iCloud has
/// that the source lacks at launch is given back to it. So a sidebar that
/// failed to load, or an extension whose download failed, never wipes iCloud.
///
/// Changes from other Macs are collected for a whole fetch and handed over
/// together, so a tab never arrives before its folder.
@MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    /// The CloudKit container: `KLAR_ICLOUD_CONTAINER` in Config/Klar.xcconfig, through Info.plist. Sync stays off
    /// in a build whose entitlements don't list it, or without one.
    static let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "KlarICloudContainer") as? String ?? ""
    private static let zoneID = CKRecordZone.ID(zoneName: "Klar", ownerName: CKCurrentUserDefaultName)
    /// When a record's values were set, written on every record; the newer
    /// side wins a conflict.
    private static let modifiedAtField = "klarModifiedAt"
    /// How long local changes collect before they're compared and queued:
    /// short, as open tabs show on other Macs once they're sent (the
    /// engine sends what's queued within half a second)
    private static let diffDelay: TimeInterval = 0.3
    private static let saveDelay: TimeInterval = 2
    /// Becoming active fetches if the last fetch is older than this — a
    /// fallback for missed pushes (CKSyncEngine registers for them itself).
    private static let activationFetchInterval: TimeInterval = 10

    enum Status: Equatable {
        case off
        /// On, but it can't run: no iCloud account, or a build without the
        /// iCloud entitlements.
        case unavailable(String)
        case syncing
        case idle
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastSyncDate: Date?
    /// The last error sync couldn't get past by retrying.
    @Published private(set) var problem: String?
    /// Why passwords stay on this Mac although sync is on.
    @Published private(set) var passwordsProblem: String?
    /// Whether Klar's passwords are in iCloud Keychain now.
    @Published private(set) var passwordsInICloud = false

    private var sources: [CloudSyncSourceKind: any CloudSyncSource] = [:]
    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var state = CloudSyncState()

    /// The record names each source had at its last comparison this session.
    private var reportedNames: [CloudSyncSourceKind: Set<String>] = [:]
    /// Records given back to their source this session, so each is tried once.
    private var restoredNames: Set<String> = []

    private struct FetchedRecord {
        let record: CloudSyncRecord
        let systemFields: Data
        let modifiedAt: Date
    }

    private var fetchedSaves: [String: FetchedRecord] = [:]
    /// Record name → record type.
    private var fetchedDeletions: [String: String] = [:]
    private var isFetching = false
    /// This Mac's first fetch finished without an error. Until then nothing
    /// is merged: merging after a failed fetch would upload this Mac's items
    /// as new ones next to iCloud's.
    private var initialFetchSucceeded = false
    private var isInitialFetchRunning = false
    /// The one retry of a failed first fetch, so activations while it
    /// fails don't start more.
    private var initialFetchRetry: DispatchWorkItem?
    /// The engine's latest state, until nothing fetched is waiting to be
    /// applied (or merged, on the first sync). Then it's written, so quitting
    /// before that fetches the same changes again.
    private var uncommittedEngineState: CKSyncEngine.State.Serialization?
    private var lastFetchDate: Date?

    private var diffWorkItems: [CloudSyncSourceKind: DispatchWorkItem] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    /// Waits for the screen to unlock, for a move of the passwords the
    /// locked keychain refused.
    private var unlockObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Setup

    func register(_ source: any CloudSyncSource, as kind: CloudSyncSourceKind) {
        sources[kind] = source
    }

    /// Follows Settings › iCloud from now on. Call once, after registering
    /// the sources, when the window is up.
    func start() {
        guard cancellables.isEmpty else { return }

        TOMLSettingsManager.shared.$syncWithICloud
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setEnabled(enabled)
            }
            .store(in: &cancellables)

        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.willTerminateNotification, object: nil
        ) { [weak self] _ in
            self?.flushForQuit()
        })
        notificationObservers.append(NotificationCenter.default.addMainObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil
        ) { [weak self] _ in
            self?.fetchIfStale()
        })
        // Klar usually became active before the window was up.
        if NSApp.isActive {
            fetchIfStale()
        }
    }

    /// Tells sync that a source saved changes. Call on the main thread.
    nonisolated static func localDataChanged(_ kind: CloudSyncSourceKind) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.scheduleDiff(kind) }
        } else {
            DispatchQueue.main.async {
                shared.scheduleDiff(kind)
            }
        }
    }

    /// Fetches and sends now (Settings › iCloud › Sync Now).
    func syncNow() {
        guard let engine else { return }
        guard state.hasMerged else {
            performInitialFetch()
            return
        }
        for kind in Array(diffWorkItems.keys) {
            diff(kind)
        }
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
            } catch {
                guard engine === self.engine else { return }
                problem = error.localizedDescription
                status = .idle
            }
        }
    }

    // MARK: - On and off

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            if engine == nil { turnOn() }
        } else if status != .off {
            turnOff()
        }
    }

    private func turnOn() {
        problem = nil
        guard Self.hasEntitlement("com.apple.developer.icloud-container-identifiers", containing: Self.containerIdentifier) else {
            // CloudKit throws an exception without it.
            status = .unavailable("This copy of Klar isn't signed for iCloud.")
            logWarning(.sync, "Sync is on, but Klar lacks the iCloud entitlements")
            return
        }
        logInfo(.sync, "Starting iCloud sync")
        container = CKContainer(identifier: Self.containerIdentifier)
        state = CloudSyncStore.load() ?? CloudSyncState()
        status = .syncing
        startEngine()
        if state.hasMerged {
            diffAllWhenReady()
        } else {
            performInitialFetch()
        }
        Task { await checkAccountStatus() }
        Task { await movePasswords(toICloud: true) }
    }

    /// Stops syncing and forgets what was synced; this Mac keeps its data,
    /// and so does iCloud. Turning sync on again merges the two.
    private func turnOff() {
        logInfo(.sync, "Stopping iCloud sync")
        stopEngine()
        container = nil
        state = CloudSyncState()
        CloudSyncStore.delete()
        status = .off
        problem = nil
        lastSyncDate = nil
        if passwordsInICloud {
            Task { await movePasswords(toICloud: false) }
        }
    }

    private func startEngine() {
        guard let container else { return }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state.engineState,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        if state.engineState == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        // What was waiting at the last quit, in case the engine's own list
        // of it wasn't written.
        let saves = state.entries
            .filter { $0.value.needsUpload }
            .map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID($0.key)) }
        let deletions = state.pendingDeletions
            .map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(Self.recordID($0)) }
        if !saves.isEmpty || !deletions.isEmpty {
            engine.state.add(pendingRecordZoneChanges: saves + deletions)
        }
    }

    private func stopEngine() {
        if let engine {
            Task { await engine.cancelOperations() }
        }
        engine = nil
        diffWorkItems.values.forEach { $0.cancel() }
        diffWorkItems.removeAll()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        reportedNames.removeAll()
        restoredNames.removeAll()
        fetchedSaves.removeAll()
        fetchedDeletions.removeAll()
        isFetching = false
        initialFetchSucceeded = false
        isInitialFetchRunning = false
        initialFetchRetry?.cancel()
        initialFetchRetry = nil
        uncommittedEngineState = nil
    }

    /// Starts over with an empty state, keeping this Mac's data: the next
    /// fetch merges it with what iCloud has.
    private func resetAndRestart() {
        stopEngine()
        state = CloudSyncState()
        CloudSyncStore.delete()
        startEngine()
    }

    /// Fetches everything iCloud has for this Mac's first sync, then merges.
    /// Tried again a minute after a failure, and on Sync Now.
    private func performInitialFetch() {
        guard let engine, !state.hasMerged, !isInitialFetchRunning else { return }
        initialFetchRetry?.cancel()
        initialFetchRetry = nil
        isInitialFetchRunning = true
        Task { [self] in
            defer {
                if engine === self.engine { isInitialFetchRunning = false }
            }
            do {
                try await engine.fetchChanges()
                guard engine === self.engine else { return }
                initialFetchSucceeded = true
                // Else didFetchChanges, still to come, merges.
                if !isFetching { applyFetchedChanges() }
            } catch {
                guard engine === self.engine else { return }
                logWarning(.sync, "First fetch from iCloud failed: \(error.localizedDescription)")
                problem = error.localizedDescription
                if status == .syncing { status = .idle }
                let retry = DispatchWorkItem { [weak self] in
                    self?.performInitialFetch()
                }
                initialFetchRetry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: retry)
            }
        }
    }

    /// For first launch's setup (Onboarding), before sync is on: nil when
    /// it couldn't run (no iCloud account, or a build not signed for iCloud),
    /// else whether another Mac keeps Klar in this account's iCloud already,
    /// its zone being there.
    func hasKlarDataInICloud() async -> Bool? {
        guard Self.hasEntitlement("com.apple.developer.icloud-container-identifiers", containing: Self.containerIdentifier) else { return nil }
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard (try? await container.accountStatus()) == .available else { return nil }
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: Self.zoneID)
            return true
        } catch {
            if (error as? CKError)?.code != .zoneNotFound {
                logWarning(.sync, "Couldn't look for Klar in iCloud: \(error.localizedDescription)")
            }
            return false
        }
    }

    private func checkAccountStatus() async {
        guard let container else { return }
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            guard container === self.container else { return }
            status = .unavailable(error.localizedDescription)
            return
        }
        guard container === self.container else { return }
        switch accountStatus {
        case .available:
            if case .unavailable = status { status = .syncing }
        case .noAccount:
            status = .unavailable("Sign in to iCloud in System Settings to sync.")
        case .restricted:
            status = .unavailable("iCloud is restricted on this Mac.")
        case .temporarilyUnavailable:
            status = .unavailable("iCloud is unavailable right now. Check your Apple Account in System Settings.")
        case .couldNotDetermine:
            status = .unavailable("Klar couldn't reach iCloud.")
        @unknown default:
            break
        }
    }

    private func movePasswords(toICloud: Bool) async {
        do {
            try await PasswordManager.shared.setUsesICloudKeychain(toICloud)
            passwordsInICloud = toICloud
            passwordsProblem = nil
        } catch PasswordManagerError.keychainStatus(errSecInteractionNotAllowed) {
            // iCloud Keychain can't be read while the Mac is locked (Klar
            // started, or sync was turned on, behind the lock screen).
            logInfo(.sync, "The keychain is locked: passwords move \(toICloud ? "to" : "from") iCloud Keychain once the Mac is unlocked")
            movePasswordsWhenUnlocked(toICloud: toICloud)
        } catch {
            // The store switched, so turning sync off moves them back.
            if case PasswordManagerError.notAllMoved = error {
                passwordsInICloud = toICloud
            }
            logError(.sync, "Couldn't move passwords \(toICloud ? "to" : "from") iCloud Keychain: \(error.localizedDescription)")
            passwordsProblem = toICloud ? error.localizedDescription : nil
        }
    }

    private func movePasswordsWhenUnlocked(toICloud: Bool) {
        guard unlockObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        unlockObserver = center.addMainObserver(forName: Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            guard let self, let observer = self.unlockObserver else { return }
            center.removeObserver(observer)
            self.unlockObserver = nil
            // Unless sync was turned on or off meanwhile
            guard (self.container != nil) == toICloud, self.passwordsInICloud != toICloud else { return }
            Task { await self.movePasswords(toICloud: toICloud) }
        }
    }

    private func fetchIfStale() {
        guard let engine, Date().timeIntervalSince(lastFetchDate ?? .distantPast) > Self.activationFetchInterval else {
            return
        }
        if state.hasMerged {
            Task { try? await engine.fetchChanges() }
        } else {
            performInitialFetch()
        }
    }

    private func flushForQuit() {
        guard engine != nil else { return }
        for kind in Array(diffWorkItems.keys) {
            diff(kind)
        }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        CloudSyncStore.saveNow(state)
    }

    // MARK: - Local changes

    private func scheduleDiff(_ kind: CloudSyncSourceKind) {
        guard engine != nil, state.hasMerged, diffWorkItems[kind] == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.diff(kind)
        }
        diffWorkItems[kind] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.diffDelay, execute: item)
    }

    /// Compares what the source holds with what was last sent or received,
    /// and queues the differences.
    ///
    /// `afterApplying`: the source just took changes from iCloud, and what
    /// it worked out from them (positions numbered again around an item
    /// this Mac doesn't have) becomes what was received, not a change to
    /// send. Sent, another Mac with other items numbered it back, and the
    /// two sent each other the same records over and over, each copy
    /// newer than a change made meanwhile, which it then undid. Records
    /// new here and removals are still sent.
    private func diff(_ kind: CloudSyncSourceKind, afterApplying: Bool = false) {
        diffWorkItems.removeValue(forKey: kind)?.cancel()
        guard let engine, state.hasMerged, let source = sources[kind] else { return }
        guard source.isReadyForSync else {
            scheduleDiff(kind)
            return
        }

        let local = source.syncRecords()
        let types = source.syncRecordTypes
        let now = Date()
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []

        for (name, record) in local where state.entries[name]?.record != record {
            if afterApplying, var entry = state.entries[name], !entry.needsUpload {
                entry.record = record
                state.entries[name] = entry
                continue
            }
            state.entries[name] = CloudSyncState.Entry(
                record: record,
                systemFields: state.entries[name]?.systemFields,
                modifiedAt: now,
                needsUpload: true
            )
            state.pendingDeletions.remove(name)
            changes.append(.saveRecord(Self.recordID(name)))
        }

        let reported = (reportedNames[kind] ?? []).union(source.syncDeletedRecordNames)
        var missing: [String: CloudSyncRecord] = [:]
        for (name, entry) in state.entries where local[name] == nil && types.contains(entry.record.type) {
            if reported.contains(name) {
                state.entries[name] = nil
                state.pendingDeletions.insert(name)
                changes.append(.deleteRecord(Self.recordID(name)))
            } else if !restoredNames.contains(name) {
                restoredNames.insert(name)
                missing[name] = entry.record
            }
        }
        reportedNames[kind] = Set(local.keys)

        if !changes.isEmpty {
            logDebug(.sync, "Queued \(changes.count) \(kind.rawValue) changes")
            engine.state.add(pendingRecordZoneChanges: changes)
        }
        if !changes.isEmpty || afterApplying {
            scheduleSave()
        }
        if !missing.isEmpty {
            logInfo(.sync, "Restoring \(missing.count) \(kind.rawValue) records from iCloud")
            source.applySyncChanges(saved: missing, deleted: [], isInitialMerge: false)
            diff(kind, afterApplying: true)
        }
    }

    private func diffAllWhenReady() {
        guard engine != nil else { return }
        guard sources.values.allSatisfy({ $0.isReadyForSync }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.diffAllWhenReady()
            }
            return
        }
        for kind in sources.keys {
            diff(kind)
        }
    }

    private func scheduleSave() {
        guard saveWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWorkItem = nil
            guard self.engine != nil else { return }
            CloudSyncStore.save(self.state)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: item)
    }

    // MARK: - Changes from iCloud

    private func bufferFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordID.zoneID == Self.zoneID else { continue }
            let name = record.recordID.recordName
            fetchedDeletions[name] = nil
            fetchedSaves[name] = FetchedRecord(
                record: Self.syncRecord(from: record),
                systemFields: Self.systemFields(of: record),
                modifiedAt: Self.modifiedAt(of: record)
            )
        }
        for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
            let name = deletion.recordID.recordName
            fetchedSaves[name] = nil
            fetchedDeletions[name] = deletion.recordType
        }
        if !isFetching {
            applyFetchedChanges()
        }
    }

    /// Hands what the last fetch brought to the sources. On this Mac's first
    /// sync, every source merges, even with nothing fetched.
    private func applyFetchedChanges() {
        guard engine != nil else { return }
        let isInitialMerge = !state.hasMerged
        if isInitialMerge {
            guard initialFetchSucceeded else { return }
        } else if fetchedSaves.isEmpty && fetchedDeletions.isEmpty {
            return
        }
        guard sources.values.allSatisfy({ $0.isReadyForSync }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isFetching else { return }
                self.applyFetchedChanges()
            }
            return
        }
        // Changes made here that aren't compared yet are this Mac's, sent
        // as such: what the sources work out from iCloud's below isn't.
        if !isInitialMerge {
            for kind in Array(diffWorkItems.keys) {
                diff(kind)
            }
        }

        var saved: [CloudSyncSourceKind: [String: CloudSyncRecord]] = [:]
        var deleted: [CloudSyncSourceKind: Set<String>] = [:]

        for (name, fetched) in fetchedSaves {
            guard let kind = kind(forRecordType: fetched.record.type) else { continue }
            // Deleted here, the deletion still on its way: an earlier save
            // of it coming back would bring it back on this Mac alone.
            if state.pendingDeletions.contains(name) { continue }
            if var entry = state.entries[name], entry.record == fetched.record {
                // Nothing new, e.g. this Mac's own save coming back.
                entry.systemFields = fetched.systemFields
                state.entries[name] = entry
                continue
            }
            if var entry = state.entries[name], entry.needsUpload, entry.modifiedAt > fetched.modifiedAt {
                // Changed here since: keep that, and send it as an update
                // of the record just fetched.
                entry.systemFields = fetched.systemFields
                state.entries[name] = entry
                continue
            }
            state.entries[name] = CloudSyncState.Entry(
                record: fetched.record,
                systemFields: fetched.systemFields,
                modifiedAt: fetched.modifiedAt,
                needsUpload: false
            )
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(Self.recordID(name))])
            saved[kind, default: [:]][name] = fetched.record
        }
        for (name, type) in fetchedDeletions {
            guard let kind = kind(forRecordType: type) else { continue }
            state.entries[name] = nil
            state.pendingDeletions.remove(name)
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(Self.recordID(name))])
            deleted[kind, default: []].insert(name)
        }
        fetchedSaves.removeAll()
        fetchedDeletions.removeAll()
        state.hasMerged = true
        commitEngineState()

        if isInitialMerge {
            logInfo(.sync, "Merging this Mac's data with iCloud's")
        }
        for (kind, source) in sources {
            let kindSaved = saved[kind] ?? [:]
            let kindDeleted = deleted[kind] ?? []
            // A source the fetch brought nothing for holds what it did
            guard isInitialMerge || !kindSaved.isEmpty || !kindDeleted.isEmpty else { continue }
            logDebug(.sync, "Applying \(kindSaved.count) changed and \(kindDeleted.count) deleted \(kind.rawValue) records")
            source.applySyncChanges(saved: kindSaved, deleted: kindDeleted, isInitialMerge: isInitialMerge)
            // Right away, so what the source holds now counts as reported.
            // The first sync's merge is sent: iCloud lacks what's only here.
            diff(kind, afterApplying: !isInitialMerge)
        }
        scheduleSave()
    }

    private func commitEngineState() {
        guard let engineState = uncommittedEngineState, state.hasMerged, !isFetching,
              fetchedSaves.isEmpty, fetchedDeletions.isEmpty else { return }
        state.engineState = engineState
        uncommittedEngineState = nil
        scheduleSave()
    }

    private func handleSentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard let engine else { return }
        var retries: [CKSyncEngine.PendingRecordZoneChange] = []
        var serverWins: [CloudSyncSourceKind: [String: CloudSyncRecord]] = [:]

        for record in sent.savedRecords {
            let name = record.recordID.recordName
            guard var entry = state.entries[name] else { continue }
            entry.systemFields = Self.systemFields(of: record)
            if let sentModifiedAt = record[Self.modifiedAtField] as? Date,
               abs(entry.modifiedAt.timeIntervalSince(sentModifiedAt)) < 0.001 {
                entry.needsUpload = false
            } else if entry.needsUpload {
                // Changed again while this save was on its way.
                retries.append(.saveRecord(record.recordID))
            }
            state.entries[name] = entry
        }

        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            let name = recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord, var entry = state.entries[name] else { continue }
                let serverModifiedAt = Self.modifiedAt(of: server)
                let serverRecord = Self.syncRecord(from: server)
                if serverModifiedAt > entry.modifiedAt, let kind = kind(forRecordType: server.recordType) {
                    state.entries[name] = CloudSyncState.Entry(
                        record: serverRecord,
                        systemFields: Self.systemFields(of: server),
                        modifiedAt: serverModifiedAt,
                        needsUpload: false
                    )
                    serverWins[kind, default: [:]][name] = serverRecord
                } else {
                    entry.systemFields = Self.systemFields(of: server)
                    state.entries[name] = entry
                    retries.append(.saveRecord(recordID))
                }
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                state.entries[name]?.systemFields = nil
                retries.append(.saveRecord(recordID))
            case .unknownItem:
                // Gone from the server: save it as a new record.
                state.entries[name]?.systemFields = nil
                retries.append(.saveRecord(recordID))
            default:
                if !Self.isRetriedByEngine(failure.error) {
                    logError(.sync, "Couldn't save \(name): \(failure.error.localizedDescription)")
                    problem = failure.error.localizedDescription
                }
            }
        }

        for recordID in sent.deletedRecordIDs {
            state.pendingDeletions.remove(recordID.recordName)
        }
        for (recordID, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem {
                state.pendingDeletions.remove(recordID.recordName)
            } else if !Self.isRetriedByEngine(error) {
                logError(.sync, "Couldn't delete \(recordID.recordName): \(error.localizedDescription)")
                problem = error.localizedDescription
            }
        }

        if !retries.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retries)
        }
        for (kind, records) in serverWins {
            sources[kind]?.applySyncChanges(saved: records, deleted: [], isInitialMerge: false)
            diff(kind, afterApplying: true)
        }
        scheduleSave()
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
            switch deletion.reason {
            case .deleted, .purged:
                // Klar's data was removed from iCloud (System Settings ›
                // Apple Account › iCloud). Don't upload it all again.
                logInfo(.sync, "Klar's iCloud data was removed; turning sync off")
                TOMLSettingsManager.shared.syncWithICloud = false
                problem = "Klar's data was removed from iCloud, so sync was turned off. Turn it on to upload this Mac's data again."
            case .encryptedDataReset:
                // iCloud reset its encryption keys: upload everything again.
                logInfo(.sync, "iCloud reset Klar's encrypted data; uploading it again")
                resetAndRestart()
                state.hasMerged = true
                diffAllWhenReady()
            @unknown default:
                break
            }
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            break
        case .signOut, .switchAccounts:
            // What was synced belongs to the other account. This Mac keeps
            // its data, which merges with the next account's.
            logInfo(.sync, "The iCloud account changed; starting sync over")
            resetAndRestart()
        @unknown default:
            break
        }
        performInitialFetch()
        Task { await checkAccountStatus() }
    }

    /// The record to save for a pending change: the latest values, on the
    /// server's last system fields.
    private func recordToSend(_ recordID: CKRecord.ID, syncEngine: CKSyncEngine) -> CKRecord? {
        guard syncEngine === engine, let entry = state.entries[recordID.recordName] else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let record = entry.systemFields.flatMap { Self.record(fromSystemFields: $0) }
            ?? CKRecord(recordType: entry.record.type, recordID: recordID)
        for (key, value) in entry.record.fields {
            record[key] = value.recordValue
        }
        // Fields the record no longer has. The record is made from system
        // fields alone, so it doesn't list the ones iCloud has: the source
        // names those that can go (a site's answer set back to Ask otherwise
        // stayed in iCloud, and came back).
        if let kind = kind(forRecordType: entry.record.type), let source = sources[kind] {
            for key in source.syncOptionalFields where entry.record.fields[key] == nil {
                record[key] = nil
            }
        }
        record[Self.modifiedAtField] = entry.modifiedAt as NSDate
        return record
    }

    private func markSyncing() {
        problem = nil
        status = .syncing
    }

    private func markIdle() {
        status = .idle
        lastSyncDate = Date()
    }

    // MARK: - Helpers

    private func kind(forRecordType type: String) -> CloudSyncSourceKind? {
        sources.first { $0.value.syncRecordTypes.contains(type) }?.key
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private static func syncRecord(from record: CKRecord) -> CloudSyncRecord {
        var fields: [String: CloudSyncValue] = [:]
        for key in record.allKeys() where key != modifiedAtField {
            if let value = record[key], let syncValue = CloudSyncValue(recordValue: value) {
                fields[key] = syncValue
            }
        }
        return CloudSyncRecord(type: record.recordType, fields: fields)
    }

    private static func modifiedAt(of record: CKRecord) -> Date {
        record[modifiedAtField] as? Date ?? record.modificationDate ?? .distantPast
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// Errors CKSyncEngine retries by itself.
    private static func isRetriedByEngine(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
             .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
            return true
        default:
            return false
        }
    }

    /// Whether Klar is signed with `entitlement`, holding `value` if given.
    private static func hasEntitlement(_ entitlement: String, containing value: String? = nil) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let granted = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else {
            return false
        }
        guard let value else { return true }
        return (granted as? [String])?.contains(value) == true
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            uncommittedEngineState = update.stateSerialization
            commitEngineState()
        case .accountChange(let change):
            handleAccountChange(change)
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes)
        case .fetchedRecordZoneChanges(let changes):
            bufferFetchedChanges(changes)
        case .sentDatabaseChanges(let changes):
            for failure in changes.failedZoneSaves where !Self.isRetriedByEngine(failure.error) {
                logError(.sync, "Couldn't create Klar's iCloud zone: \(failure.error.localizedDescription)")
                problem = failure.error.localizedDescription
            }
        case .sentRecordZoneChanges(let changes):
            handleSentChanges(changes)
        case .willFetchChanges:
            isFetching = true
            markSyncing()
        case .willSendChanges:
            markSyncing()
        case .didFetchRecordZoneChanges(let event):
            if let error = event.error, !Self.isRetriedByEngine(error) {
                logError(.sync, "Couldn't fetch from iCloud: \(error.localizedDescription)")
                problem = error.localizedDescription
            }
        case .didFetchChanges:
            isFetching = false
            lastFetchDate = Date()
            applyFetchedChanges()
            commitEngineState()
            markIdle()
        case .didSendChanges:
            markIdle()
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.recordToSend(recordID, syncEngine: syncEngine)
        }
    }
}
