import Foundation
import AppKit
import Combine
import notify

// MARK: - Models

nonisolated struct ReadingListItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let previewText: String?
    let dateAdded: Date
    let dateLastViewed: Date?
    let isUnread: Bool
}

enum ReadingListPermissionState: Equatable {
    case unknown
    case granted
    case denied
    case fileMissing
}

enum ReadingListError: LocalizedError {
    case unsupportedURL
    case addFailed(String)
    case fileAccessDenied
    case writeFailed(String)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Only web pages can be added to the Reading List."
        case .addFailed(let detail):
            return "Couldn't add to Reading List: \(detail)"
        case .fileAccessDenied:
            return "Klar needs Full Disk Access to modify Safari's Reading List."
        case .writeFailed(let detail):
            return "Failed to update Reading List: \(detail)"
        case .itemNotFound:
            return "Item not found in Reading List."
        }
    }
}

// MARK: - Manager

@MainActor
final class SafariReadingListManager: ObservableObject {
    static let shared = SafariReadingListManager()

    @Published private(set) var items: [ReadingListItem] = []
    @Published private(set) var permissionState: ReadingListPermissionState = .unknown

    private var membershipSet: Set<String> = []

    private let parseQueue = DispatchQueue(label: "com.klar.readinglist.parse", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.klar.readinglist.write", qos: .userInitiated)

    private var fsSource: DispatchSourceFileSystemObject?
    private var fsFileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?

    private static let plistRelativePath = "Library/Safari/Bookmarks.plist"

    private init() {}

    // MARK: - Path

    static func bookmarksPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(plistRelativePath)
    }

    // MARK: - Public API

    func contains(url: String) -> Bool {
        membershipSet.contains(Self.normalize(url: url))
    }

    /// Safari's Reading List only takes web pages.
    nonisolated static func canAdd(url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// App-activation hook. A re-read is only needed until access works (the
    /// user may just have granted Full Disk Access); from then on the file
    /// watcher catches every change. Re-reading the whole multi-megabyte
    /// Bookmarks.plist on every Cmd-Tab back to Klar was pure churn.
    func refreshOnActivation() async {
        guard permissionState != .granted || fsSource == nil else { return }
        await refresh()
    }

    /// Force a re-read of Bookmarks.plist. Safe to call repeatedly; only emits if content changed.
    func refresh() async {
        let plistURL = Self.bookmarksPlistURL()

        let result: Result<[ReadingListItem], ReadingListError> = await withCheckedContinuation { continuation in
            parseQueue.async {
                let parsed = Self.readAndParse(plistURL: plistURL)
                continuation.resume(returning: parsed)
            }
        }

        switch result {
        case .success(let parsedItems):
            if permissionState != .granted { permissionState = .granted }
            applyItemsIfChanged(parsedItems)
            // Without access (Full Disk Access granted after launch, or no
            // Bookmarks.plist yet) the watcher couldn't open the file.
            startWatching()
        case .failure(let error):
            switch error {
            case .fileAccessDenied:
                // Once, as access is found missing: every refresh until it's
                // granted (each activation, each list shown) finds it again.
                if permissionState != .denied {
                    permissionState = .denied
                    logWarning(.readingList, "Reading List unavailable: \(error.localizedDescription)")
                }
            default:
                if !FileManager.default.fileExists(atPath: plistURL.path) {
                    if permissionState != .fileMissing { permissionState = .fileMissing }
                    applyItemsIfChanged([])
                } else {
                    logWarning(.readingList, "Couldn't read the Reading List: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Begin watching Bookmarks.plist. Idempotent.
    func startWatching() {
        guard fsSource == nil else { return }
        let plistPath = Self.bookmarksPlistURL().path
        let fd = open(plistPath, O_EVTONLY)
        guard fd >= 0 else {
            logDebug(.readingList, "Cannot open Bookmarks.plist for watching: errno=\(errno)")
            return
        }
        fsFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: parseQueue
        )
        // On parseQueue: Sendable, or Swift 6 would trap there (a closure
        // written here is otherwise the main actor's).
        source.setEventHandler { @Sendable [weak self] in
            let event = source.data
            let isDeleteOrRename = event.contains(.delete) || event.contains(.rename)
            Task { @MainActor in
                guard let self = self else { return }
                if isDeleteOrRename {
                    self.restartWatcher()
                }
                self.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { @Sendable in
            close(fd)
        }
        fsSource = source
        source.resume()
        logDebug(.readingList, "FSEvents watcher started for Bookmarks.plist")
    }

    func stopWatching() {
        fsSource?.cancel()
        fsSource = nil
        fsFileDescriptor = -1
    }

    // MARK: - Add (Safari's service)

    /// Adds through Safari's own "Add to Reading List" service (its Services
    /// menu item), run so that Safari stays where it is: no Automation
    /// permission (which the hardened runtime would refuse without the Apple
    /// Events entitlement) and no Full Disk Access. Safari has to be running
    /// for it, so one that isn't is opened hidden first. The system's share
    /// extension, Share › Add to Reading List, is only the fallback: it
    /// sends Safari an Apple Event that brings it to the front.
    func addToReadingList(url: String, title: String) async throws {
        guard Self.canAdd(url: url), let pageURL = URL(string: url) else {
            throw ReadingListError.unsupportedURL
        }

        if await !SafariReadingListService.add(pageURL) {
            guard let service = NSSharingService(named: .addToSafariReadingList),
                  service.canPerform(withItems: [pageURL]) else {
                throw ReadingListError.addFailed("The Reading List isn't available on this Mac.")
            }
            logWarning(.readingList, "Safari's Add to Reading List service failed; adding with the share extension")
            try await ReadingListShare.perform(service, with: pageURL)
        }

        // Without access the list can't be read, so there's nothing to show it in.
        guard permissionState == .granted else { return }

        let optimistic = ReadingListItem(
            id: UUID(),
            url: url,
            title: title.isEmpty ? (URL(string: url)?.host ?? url) : title,
            previewText: nil,
            dateAdded: Date(),
            dateLastViewed: nil,
            isUnread: true
        )
        if !contains(url: url) {
            var newItems = items
            newItems.insert(optimistic, at: 0)
            applyItems(newItems)
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.refresh()
        }
    }

    // MARK: - Mark as read / unread (direct plist write)

    func markAs(read: Bool, url: String) async throws {
        let plistURL = Self.bookmarksPlistURL()
        let normalized = Self.normalize(url: url)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    let data = try Data(contentsOf: plistURL, options: .uncached)
                    let plistObject = try PropertyListSerialization.propertyList(
                        from: data,
                        options: [.mutableContainersAndLeaves],
                        format: nil
                    )
                    guard let root = plistObject as? NSMutableDictionary else {
                        continuation.resume(throwing: ReadingListError.writeFailed("Unexpected plist root"))
                        return
                    }

                    var didUpdate = false
                    Self.updateReadState(read: read, matchingNormalizedURL: normalized, fromNode: root, didUpdate: &didUpdate)

                    guard didUpdate else {
                        continuation.resume(throwing: ReadingListError.itemNotFound)
                        return
                    }

                    try Self.writeBookmarks(root, to: plistURL)
                    continuation.resume(returning: ())
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain,
                       [257, 513].contains(error.code) {
                        continuation.resume(throwing: ReadingListError.fileAccessDenied)
                    } else if error is ReadingListError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: ReadingListError.writeFailed(error.localizedDescription))
                    }
                }
            }
        }

        // Optimistic local update so UI reflects the change immediately.
        let updated = items.map { item -> ReadingListItem in
            guard Self.normalize(url: item.url) == normalized else { return item }
            let newDateLastViewed: Date? = read ? Date() : nil
            let newIsUnread: Bool = !read
            return ReadingListItem(
                id: item.id,
                url: item.url,
                title: item.title,
                previewText: item.previewText,
                dateAdded: item.dateAdded,
                dateLastViewed: newDateLastViewed,
                isUnread: newIsUnread
            )
        }
        applyItems(updated)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.refresh()
        }
    }

    // MARK: - Remove (direct plist write)

    func removeFromReadingList(url: String) async throws {
        let plistURL = Self.bookmarksPlistURL()
        let normalized = Self.normalize(url: url)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    let data = try Data(contentsOf: plistURL, options: .uncached)
                    var format = PropertyListSerialization.PropertyListFormat.binary
                    let plistObject = try PropertyListSerialization.propertyList(
                        from: data,
                        options: [.mutableContainersAndLeaves],
                        format: &format
                    )
                    guard let root = plistObject as? NSMutableDictionary else {
                        continuation.resume(throwing: ReadingListError.writeFailed("Unexpected plist root"))
                        return
                    }

                    var didRemove = false
                    Self.removeItem(matchingNormalizedURL: normalized, fromNode: root, didRemove: &didRemove)

                    guard didRemove else {
                        continuation.resume(throwing: ReadingListError.itemNotFound)
                        return
                    }

                    try Self.writeBookmarks(root, to: plistURL)
                    continuation.resume(returning: ())
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain,
                       [257, 513].contains(error.code) {
                        continuation.resume(throwing: ReadingListError.fileAccessDenied)
                    } else if error is ReadingListError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: ReadingListError.writeFailed(error.localizedDescription))
                    }
                }
            }
        }

        let removalSnapshot = items.filter { Self.normalize(url: $0.url) != normalized }
        applyItems(removalSnapshot)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.refresh()
        }
    }

    // MARK: - Helpers

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func restartWatcher() {
        stopWatching()
        startWatching()
    }

    private func applyItemsIfChanged(_ newItems: [ReadingListItem]) {
        // Compare every field: an optimistic placeholder (random UUID) has to
        // give way to the parsed entry, and Safari fills in a new page's title
        // and preview text a moment after it's added.
        guard newItems != items else { return }
        applyItems(newItems)
    }

    private func applyItems(_ newItems: [ReadingListItem]) {
        items = newItems
        membershipSet = Set(newItems.map { Self.normalize(url: $0.url) })
    }

    /// Scheme and host are case-insensitive but the rest of a URL isn't, so
    /// only those are lowercased; a trailing slash doesn't matter.
    nonisolated private static func normalize(url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") {
            s.removeLast()
        }
        guard var components = URLComponents(string: s) else { return s }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? s
    }

    // MARK: - Plist Writing

    /// Safari's bookmarks framework posts this Darwin notification after it
    /// changes Bookmarks.plist so other processes using it (Safari, the
    /// iCloud sync agent) reload the file.
    nonisolated private static let bookmarksFileChangedNotification = "com.apple.bookmarks.BookmarksFileChanged"

    /// Replaces Bookmarks.plist atomically, then posts the change
    /// notification so Safari and iCloud sync pick up the edit instead of
    /// overwriting it with the copy they hold in memory (a running Safari
    /// updates right away).
    nonisolated private static func writeBookmarks(_ root: NSMutableDictionary, to plistURL: URL) throws {
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )

        let tmpURL = plistURL.deletingLastPathComponent()
            .appendingPathComponent("Bookmarks.plist.klar.tmp")
        try? FileManager.default.removeItem(at: tmpURL)
        try serialized.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(plistURL, withItemAt: tmpURL)

        notify_post(bookmarksFileChangedNotification)
    }

    // MARK: - Plist Parsing

    nonisolated private static func readAndParse(plistURL: URL) -> Result<[ReadingListItem], ReadingListError> {
        do {
            let data = try Data(contentsOf: plistURL, options: .uncached)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = plist as? [String: Any] else {
                return .success([])
            }
            let items = parseReadingListItems(from: root)
            return .success(items)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                if [257, 513].contains(error.code) {
                    return .failure(.fileAccessDenied)
                }
                if error.code == 260 {
                    return .failure(.writeFailed("File missing"))
                }
            }
            logWarning(.readingList, "Failed to read Bookmarks.plist: \(error.localizedDescription)")
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    nonisolated private static func parseReadingListItems(from root: [String: Any]) -> [ReadingListItem] {
        guard let readingListNode = findReadingListNode(in: root) else { return [] }
        guard let children = readingListNode["Children"] as? [[String: Any]] else { return [] }

        var result: [ReadingListItem] = []
        for child in children {
            guard let urlString = child["URLString"] as? String, !urlString.isEmpty else { continue }
            let uuidString = child["WebBookmarkUUID"] as? String ?? child["UUID"] as? String
            let id = uuidString.flatMap { UUID(uuidString: $0) } ?? UUID()

            var title: String = ""
            if let uri = child["URIDictionary"] as? [String: Any],
               let t = uri["title"] as? String, !t.isEmpty {
                title = t
            }
            let nonSync = child["ReadingListNonSync"] as? [String: Any]
            if title.isEmpty, let t = nonSync?["Title"] as? String, !t.isEmpty {
                title = t
            }
            if title.isEmpty {
                title = URL(string: urlString)?.host ?? urlString
            }

            let previewText: String? = {
                if let p = nonSync?["PreviewText"] as? String, !p.isEmpty { return p }
                if let rl = child["ReadingList"] as? [String: Any],
                   let p = rl["PreviewText"] as? String, !p.isEmpty { return p }
                return nil
            }()

            let readingListMeta = child["ReadingList"] as? [String: Any]

            let dateAdded: Date = {
                if let interval = readingListMeta?["DateAdded"] as? Double {
                    return Date(timeIntervalSinceReferenceDate: interval)
                }
                if let date = readingListMeta?["DateAdded"] as? Date {
                    return date
                }
                return .distantPast
            }()

            let dateLastViewed: Date? = {
                if let interval = readingListMeta?["DateLastViewed"] as? Double {
                    return Date(timeIntervalSinceReferenceDate: interval)
                }
                if let date = readingListMeta?["DateLastViewed"] as? Date {
                    return date
                }
                return nil
            }()

            let isUnread: Bool = {
                guard let lastViewed = dateLastViewed else { return true }
                return lastViewed < dateAdded
            }()

            result.append(ReadingListItem(
                id: id,
                url: urlString,
                title: title,
                previewText: previewText,
                dateAdded: dateAdded,
                dateLastViewed: dateLastViewed,
                isUnread: isUnread
            ))
        }

        result.sort { $0.dateAdded > $1.dateAdded }
        return result
    }

    nonisolated private static func findReadingListNode(in node: [String: Any]) -> [String: Any]? {
        if let title = node["Title"] as? String,
           title == "com.apple.ReadingList" {
            return node
        }
        if let children = node["Children"] as? [[String: Any]] {
            for child in children {
                if let found = findReadingListNode(in: child) {
                    return found
                }
            }
        }
        return nil
    }

    nonisolated private static func updateReadState(read: Bool, matchingNormalizedURL normalized: String, fromNode node: NSMutableDictionary, didUpdate: inout Bool) {
        if let title = node["Title"] as? String, title == "com.apple.ReadingList",
           let children = node["Children"] as? NSMutableArray {
            for case let child as NSMutableDictionary in children {
                guard let urlString = child["URLString"] as? String,
                      normalize(url: urlString) == normalized else { continue }
                // ReadingList holds DateAdded/DateLastViewed.
                let readingListMeta: NSMutableDictionary
                if let existing = child["ReadingList"] as? NSMutableDictionary {
                    readingListMeta = existing
                } else {
                    readingListMeta = NSMutableDictionary()
                    child["ReadingList"] = readingListMeta
                }
                if read {
                    readingListMeta["DateLastViewed"] = Date().timeIntervalSinceReferenceDate
                } else {
                    readingListMeta.removeObject(forKey: "DateLastViewed")
                }
                didUpdate = true
                return
            }
            return
        }
        if let children = node["Children"] as? NSMutableArray {
            for case let child as NSMutableDictionary in children {
                updateReadState(read: read, matchingNormalizedURL: normalized, fromNode: child, didUpdate: &didUpdate)
                if didUpdate { return }
            }
        }
    }

    nonisolated private static func removeItem(matchingNormalizedURL normalized: String, fromNode node: NSMutableDictionary, didRemove: inout Bool) {
        if let title = node["Title"] as? String, title == "com.apple.ReadingList",
           let children = node["Children"] as? NSMutableArray {
            for index in (0..<children.count).reversed() {
                if let child = children[index] as? NSMutableDictionary,
                   let urlString = child["URLString"] as? String,
                   normalize(url: urlString) == normalized {
                    children.removeObject(at: index)
                    didRemove = true
                }
            }
            return
        }
        if let children = node["Children"] as? NSMutableArray {
            for case let child as NSMutableDictionary in children {
                removeItem(matchingNormalizedURL: normalized, fromNode: child, didRemove: &didRemove)
                if didRemove { return }
            }
        }
    }
}

// MARK: - Commands

extension SafariReadingListManager {
    /// Adds a page for a menu or palette command and reports the outcome in
    /// a toast, so a failure doesn't go unnoticed.
    func addToReadingList(url: String, title: String, reportingTo toastManager: ToastManager) {
        Task {
            do {
                try await addToReadingList(url: url, title: title)
                toastManager.showToast(message: "Saved to Reading List", type: .info, icon: "eyeglasses")
            } catch {
                Self.reportFailure(error, to: toastManager)
            }
        }
    }

    /// Removes a page for a menu or palette command and reports the outcome
    /// in a toast.
    func removeFromReadingList(url: String, reportingTo toastManager: ToastManager) {
        Task {
            do {
                try await removeFromReadingList(url: url)
                toastManager.showToast(message: "Removed from Reading List", type: .info, icon: "eyeglasses.slash")
            } catch {
                Self.reportFailure(error, to: toastManager)
            }
        }
    }

    static func reportFailure(_ error: Error, to toastManager: ToastManager) {
        toastManager.showToast(
            message: "Reading List error",
            description: error.localizedDescription,
            type: .error,
            icon: "exclamationmark.triangle.fill"
        )
    }
}

// MARK: - Safari's service

/// Safari's "Add to Reading List" service (`NSServices` in its Info.plist,
/// `-[ServicesProvider addToReadingList:userData:error:]`): it adds each web
/// address on the pasteboard, and fetches the page's title and preview.
@MainActor
private enum SafariReadingListService {
    private static let bundleIdentifier = "com.apple.Safari"
    private static let message = "addToReadingList"

    /// The Safari Klar opened for an add, which it quits again
    private static var openedSafari: NSRunningApplication?
    private static var quitTask: Task<Void, Never>?

    /// Whether the page went to Safari
    static func add(_ url: URL) async -> Bool {
        guard await finishedLaunchingSafari() else { return false }

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        let sent = performService(with: pasteboard)
        // The request is on its way when the call returns: Safari reads the
        // pasteboard a moment later, so it's kept a while
        Task {
            try? await Task.sleep(for: .seconds(30))
            pasteboard.releaseGlobally()
        }
        if sent {
            quitOpenedSafariLater()
        }
        return sent
    }

    /// Quits the Safari Klar opened once it has saved the pages it was
    /// given (Bookmarks.plist written since the last), and had a while
    /// more, in which iCloud sync (its own agent) writes back the page's
    /// record. Not one that's been brought out meanwhile. Without Full Disk
    /// Access the file can't be seen, so the while alone; Safari saves as
    /// it quits.
    private static func quitOpenedSafariLater() {
        guard let safari = openedSafari else { return }
        let addedAt = Date.now
        quitTask?.cancel()
        quitTask = Task {
            let bookmarks = SafariReadingListManager.bookmarksPlistURL()
            let deadline = addedAt.addingTimeInterval(120)
            var saved = false
            while !saved, !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let modified = try? bookmarks.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    break
                }
                saved = modified > addedAt
            }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, openedSafari === safari else { return }
            openedSafari = nil
            guard !safari.isTerminated, safari.isHidden, !safari.isActive else { return }
            safari.terminate()
        }
    }

    /// AppKit's service runner, a step under `NSPerformService`
    /// (`+[NSServiceMaster internalRunService:pboard:requestingApp:flags:cancelledHint:]`,
    /// with the service from `copyServiceForAppIdentifier:messageName:`).
    /// `NSPerformService` first hands Klar's activation to Safari, as for
    /// any service that returns nothing, and asks it to unhide, so Safari
    /// comes to the front. Flag 1 leaves it hidden, and without the
    /// activation it can't come forward.
    private static func performService(with pasteboard: NSPasteboard) -> Bool {
        let copySelector = NSSelectorFromString("copyServiceForAppIdentifier:messageName:")
        let runSelector = NSSelectorFromString("internalRunService:pboard:requestingApp:flags:cancelledHint:")
        guard let serviceMaster = NSClassFromString("NSServiceMaster"),
              let metaclass = object_getClass(serviceMaster),
              class_respondsToSelector(metaclass, copySelector),
              class_respondsToSelector(metaclass, runSelector) else {
            logWarning(.readingList, "AppKit's service runner isn't there")
            return false
        }
        typealias CopyService = @convention(c) (AnyClass, Selector, NSString, NSString) -> Unmanaged<AnyObject>?
        typealias RunService = @convention(c) (AnyClass, Selector, AnyObject, NSPasteboard, NSString?, UInt, UnsafePointer<ObjCBool>) -> Unmanaged<AnyObject>?
        let copyService = unsafeBitCast(class_getMethodImplementation(metaclass, copySelector), to: CopyService.self)
        let runService = unsafeBitCast(class_getMethodImplementation(metaclass, runSelector), to: RunService.self)

        guard let service = copyService(serviceMaster, copySelector, bundleIdentifier as NSString, message as NSString)?.takeRetainedValue() else {
            return false
        }
        var cancelled = ObjCBool(false)
        guard let result = runService(serviceMaster, runSelector, service, pasteboard, nil, 1, &cancelled)?.takeUnretainedValue() as? NSDictionary else {
            return false
        }
        // A failure says so (success off, an error code); a sent request is
        // often an empty answer
        return (result["success"] as? Bool) != false && result["errorCode"] == nil
    }

    /// Safari, once it has finished launching (its service answers from
    /// then on). One that isn't running is opened hidden, in the background,
    /// and quit again after the add.
    private static func finishedLaunchingSafari() async -> Bool {
        var safari = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
        if safari == nil {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            do {
                safari = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                openedSafari = safari
            } catch {
                logWarning(.readingList, "Couldn't open Safari for the Reading List: \(error.localizedDescription)")
                return false
            }
        }
        guard let safari else { return false }

        let deadline = Date.now.addingTimeInterval(10)
        while !safari.isFinishedLaunching, !safari.isTerminated, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return safari.isFinishedLaunching
    }
}

// MARK: - Share service bridge

/// Turns the share service's delegate callbacks into an async result. The
/// service holds its delegate weakly, so a share keeps itself alive until
/// one of the callbacks arrives.
@MainActor
private final class ReadingListShare: NSObject, NSSharingServiceDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var keepAlive: ReadingListShare?

    static func perform(_ service: NSSharingService, with url: URL) async throws {
        let share = ReadingListShare()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            share.continuation = continuation
            share.keepAlive = share
            service.delegate = share
            service.perform(withItems: [url])
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.success(()))
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(.failure(ReadingListError.addFailed(error.localizedDescription)))
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        keepAlive = nil
    }
}
