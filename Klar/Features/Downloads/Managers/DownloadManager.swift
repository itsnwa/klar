import Foundation
import SwiftUI
import WebKit
import AppKit
import Combine
import UniformTypeIdentifiers

class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var downloads: [DownloadItem] = []
    @Published var shouldShowDownloadAnimation = false
    @Published var downloadAnimationIcon: NSImage?
    @Published var downloadAnimationStartPoint = CGPoint(x: 0, y: 0)
    /// The window the animation shows in (its number): the one in front
    @Published private(set) var downloadAnimationWindowNumber: Int?
    /// Whether a download is in progress. `downloads` only publishes when
    /// the list changes, not when a download in it finishes, so this follows
    /// each item's state too, and publishes only when it changes.
    @Published private(set) var isDownloading = false
    /// The downloads in progress together, from 0 to 1, as they go (a few
    /// times a second): nil while none of their sizes is known. Not
    /// `@Published`, so only the view showing it updates, not every view
    /// observing the manager.
    let overallProgress = CurrentValueSubject<Double?, Never>(nil)
    private var downloadStatesObservation: AnyCancellable?

    // Track tabs that were opened specifically for downloads
    private var downloadTriggeredTabs: Set<UUID> = []

    // Track WKDownload → tab ID mappings for auto-close
    private var wkDownloadTabIds: [ObjectIdentifier: UUID] = [:]

    /// Where downloads started from Save Image As / Download Linked File As
    /// go: the file picked in the save panel.
    private var chosenDestinations: [ObjectIdentifier: URL] = [:]

    // Track KVO observations for WKDownload progress
    private var wkProgressObservations: [UUID: NSKeyValueObservation] = [:]

    /// Progress arrives once per network chunk — many times a second on a
    /// fast connection. The row and Finder's progress bar only need a few
    /// updates a second.
    private static let progressUpdateInterval: TimeInterval = 0.25
    private var lastProgressUpdate: [UUID: TimeInterval] = [:]

    /// Web views that only exist to resume a download whose tab has gone
    /// away (resuming needs some web view); kept until that download ends.
    private var resumeHostWebViews: [UUID: WKWebView] = [:]

    private var terminationObserver: NSObjectProtocol?

    /// Where downloads that have a name but no file yet will end up
    /// (getUniqueFilename).
    private var reservedDestinations: Set<String> = []

    override init() {
        super.init()
        // The list isn't kept across launches, so the partial files of
        // paused, interrupted or unfinished downloads could never be resumed.
        terminationObserver = NotificationCenter.default.addMainObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil
        ) { [weak self] _ in
            self?.removePartialFiles()
        }
        // `@Published` sends before it stores: read the items once it's in
        downloadStatesObservation = $downloads
            .map { items in
                Publishers.MergeMany(items.map { item in
                    item.$state.map { _ in () }.merge(with: item.$progress.map { _ in () })
                }).prepend(())
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let downloading = self.downloads.filter { $0.state == .downloading }
                if self.isDownloading == downloading.isEmpty {
                    self.isDownloading = !downloading.isEmpty
                }
                let progress = Self.combinedProgress(of: downloading)
                if self.overallProgress.value != progress {
                    self.overallProgress.send(progress)
                }
            }
    }

    private func removePartialFiles() {
        for item in downloads where item.state != .completed {
            if let partialURL = item.partialURL {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }
    }

    private var downloadDirectory: URL {
        let settingsPath = TOMLSettingsManager.shared.downloadLocation
        let downloadURL = URL(fileURLWithPath: settingsPath)

        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: downloadURL, withIntermediateDirectories: true, attributes: nil)

        return downloadURL
    }

    // MARK: - Download Tab Management

    /// Register a tab as being created specifically for a download
    func registerDownloadTab(_ tabId: UUID) {
        downloadTriggeredTabs.insert(tabId)
    }

    /// Check if a tab should be auto-closed after download starts
    private func shouldAutoCloseTab(_ tabId: UUID) -> Bool {
        return downloadTriggeredTabs.contains(tabId)
    }

    /// Close download-triggered tab after download starts
    private func closeDownloadTabIfNeeded(_ tabId: UUID) {
        if shouldAutoCloseTab(tabId) {
            downloadTriggeredTabs.remove(tabId)

            // Small delay to ensure download has properly started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CloseDownloadTab"),
                    object: nil,
                    userInfo: ["tabId": tabId.uuidString]
                )
            }
        }
    }

    // MARK: - WKDownload Setup

    /// Configure a WKDownload received from WebKit's navigation delegate.
    /// The actual download item is created later in decideDestinationUsing.
    /// `destination` is a file picked in a save panel; without one, it's
    /// named in the download folder.
    func setupWKDownload(_ download: WKDownload, fromTabId: UUID?, destination: URL? = nil) {
        download.delegate = self
        if let tabId = fromTabId {
            wkDownloadTabIds[ObjectIdentifier(download)] = tabId
        }
        if let destination {
            chosenDestinations[ObjectIdentifier(download)] = destination
        }
    }

    /// Mirrors the WKDownload's progress into the item (and Finder), a few
    /// times a second at most.
    private func observeProgress(of download: WKDownload, for downloadItem: DownloadItem) {
        let itemId = downloadItem.id
        let observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard let self, let item = self.downloads.first(where: { $0.id == itemId }) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let isComplete = progress.totalUnitCount > 0 && progress.completedUnitCount >= progress.totalUnitCount
                guard isComplete || now - (self.lastProgressUpdate[itemId] ?? 0) >= Self.progressUpdateInterval else { return }
                self.lastProgressUpdate[itemId] = now
                item.updateProgress(
                    downloadedBytes: progress.completedUnitCount,
                    totalBytes: progress.totalUnitCount
                )
                self.updateFinderProgress(for: item)
            }
        }
        wkProgressObservations[itemId] = observation
    }

    /// Stops tracking a download that won't make progress any more.
    private func stopTracking(_ downloadItem: DownloadItem) {
        wkProgressObservations.removeValue(forKey: downloadItem.id)
        lastProgressUpdate.removeValue(forKey: downloadItem.id)
        resumeHostWebViews.removeValue(forKey: downloadItem.id)
        releaseDestination(downloadItem.destinationURL)
    }

    // MARK: - Finder Progress Integration

    private func createFinderProgress(for downloadItem: DownloadItem) {
        guard let partialURL = downloadItem.partialURL else { return }

        // Ensure the file exists first - NSProgress needs an actual file
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil, attributes: nil)
        }

        // Create NSProgress for Finder integration
        let progress = Progress(parent: nil, userInfo: [
            ProgressUserInfoKey.fileOperationKindKey: Progress.FileOperationKind.downloading,
            ProgressUserInfoKey.fileURLKey: partialURL
        ])

        // Configure progress properties
        progress.kind = .file
        progress.isCancellable = true
        progress.isPausable = downloadItem.canPause
        progress.totalUnitCount = Self.finderTotalUnitCount(for: downloadItem)
        progress.completedUnitCount = downloadItem.downloadedBytes

        // Finder's cancel and pause buttons on the file act like the
        // sidebar's. (Handlers run on arbitrary threads.)
        progress.cancellationHandler = { [weak self, weak downloadItem] in
            DispatchQueue.main.async {
                guard let self, let downloadItem else { return }
                self.cancelDownload(downloadItem)
            }
        }
        progress.pausingHandler = { [weak self, weak downloadItem] in
            DispatchQueue.main.async {
                guard let self, let downloadItem else { return }
                self.pauseDownload(downloadItem)
            }
        }
        progress.resumingHandler = { [weak self, weak downloadItem] in
            DispatchQueue.main.async {
                guard let self, let downloadItem else { return }
                self.resumeDownload(downloadItem)
            }
        }

        // Publish to make visible in Finder
        progress.publish()

        // Store reference for updates
        downloadItem.finderProgress = progress
    }

    private func updateFinderProgress(for downloadItem: DownloadItem) {
        guard let progress = downloadItem.finderProgress else { return }

        // Update progress counts
        progress.totalUnitCount = Self.finderTotalUnitCount(for: downloadItem)
        progress.completedUnitCount = downloadItem.downloadedBytes
    }

    /// -1 is an indeterminate progress: the size isn't known yet.
    private static func finderTotalUnitCount(for downloadItem: DownloadItem) -> Int64 {
        downloadItem.hasKnownSize ? downloadItem.fileSize : -1
    }

    private func cleanupFinderProgress(for downloadItem: DownloadItem) {
        guard let progress = downloadItem.finderProgress else { return }

        // Unpublish and clean up
        progress.unpublish()
        downloadItem.finderProgress = nil
    }

    /// A download the page made itself (a blob, handed over as a data
    /// URL). Its item shows at once; decoding, possibly hundreds of MB,
    /// and writing happen off the main thread.
    func startDataURLDownload(dataUrl: String, filename: String, mimeType: String, originalUrl: String) {
        // Never the data URL itself: the item would hold the whole file as
        // its address for the session.
        let url = URL(string: originalUrl) ?? URL(string: "about:blank")!
        let downloadItem = DownloadItem(url: url, filename: filename)

        // Update system icon based on MIME type and filename
        if !filename.isEmpty {
            downloadItem.systemIcon = getSystemIcon(for: filename)
        } else if !mimeType.isEmpty {
            let fileExtension = getFileExtensionFromMimeType(mimeType)
            downloadItem.systemIcon = getSystemIcon(for: "download.\(fileExtension)")
        }

        downloads.insert(downloadItem, at: 0)
        triggerDownloadAnimation(for: downloadItem)

        let destinationURL = getUniqueFilename(for: downloadDirectory.appendingPathComponent(downloadItem.filename))

        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Self.decodeDataURL(dataUrl) else {
                logError(.general, "Failed to decode a data URL download")
                DispatchQueue.main.async {
                    self.releaseDestination(destinationURL)
                    downloadItem.state = .failed
                }
                return
            }

            do {
                try data.write(to: destinationURL, options: .withoutOverwriting)
                let size = Int64(data.count)
                DispatchQueue.main.async {
                    self.releaseDestination(destinationURL)
                    // Removed or cancelled while it was being written
                    guard downloadItem.state == .downloading else {
                        try? FileManager.default.removeItem(at: destinationURL)
                        return
                    }
                    downloadItem.destinationURL = destinationURL
                    downloadItem.fileSize = size
                    downloadItem.downloadedBytes = size
                    downloadItem.progress = 1.0
                    downloadItem.state = .completed
                }
            } catch {
                DispatchQueue.main.async {
                    self.releaseDestination(destinationURL)
                    downloadItem.error = error
                    downloadItem.state = .failed
                }
            }
        }
    }

    /// `data:[<mediatype>][;base64],<data>`: base64, or percent-encoded text.
    nonisolated private static func decodeDataURL(_ dataUrl: String) -> Data? {
        guard let comma = dataUrl.firstIndex(of: ",") else { return nil }
        let header = dataUrl[..<comma]
        let payload = dataUrl[dataUrl.index(after: comma)...]
        if header.lowercased().hasSuffix(";base64") {
            return Data(base64Encoded: Data(payload.utf8), options: .ignoreUnknownCharacters)
        }
        return String(payload).removingPercentEncoding.map { Data($0.utf8) }
    }

    // MARK: - Pause / Resume

    /// WebKit can't hold a download open while paused, so pausing cancels it
    /// keeping its resume data and partial file; resuming starts it again
    /// from there. Only offered when the server accepts range requests
    /// (`DownloadItem.canPause`): without that, cancelling loses the bytes.
    func pauseDownload(_ downloadItem: DownloadItem) {
        guard downloadItem.state == .downloading, downloadItem.canPause,
              let download = downloadItem.wkDownload else { return }

        // Set first: the delegate may report the cancellation as a failure.
        downloadItem.state = .paused
        stopTracking(downloadItem)
        download.cancel { [weak self] resumeData in
            // It may have finished, or been cancelled, meanwhile.
            guard let self, downloadItem.state == .paused else { return }
            if let resumeData {
                downloadItem.resumeData = resumeData
                downloadItem.finderProgress?.pause()
            } else {
                // The server didn't allow resuming after all.
                self.discardPartialDownload(downloadItem, state: .cancelled)
            }
        }
    }

    /// Resumes a paused download, or one interrupted by a network error
    /// that left resume data behind.
    func resumeDownload(_ downloadItem: DownloadItem) {
        guard downloadItem.state == .paused || downloadItem.state == .failed,
              let resumeData = downloadItem.resumeData else { return }

        // Resuming needs some web view; the one that started the download
        // may be gone (tab closed or suspended).
        let webView: WKWebView
        if let originalWebView = downloadItem.wkDownload?.webView {
            webView = originalWebView
        } else {
            // In the tab's data store: a private tab's download stays in
            // private browsing, a separate profile's keeps its cookies.
            let configuration = WKWebViewConfiguration()
            if let websiteDataStore = downloadItem.websiteDataStore {
                configuration.websiteDataStore = websiteDataStore
            }
            webView = WKWebView(frame: .zero, configuration: configuration)
            resumeHostWebViews[downloadItem.id] = webView
        }

        downloadItem.resumeData = nil
        downloadItem.error = nil
        downloadItem.state = .downloading
        // The old download is over; until the new one arrives there's
        // nothing to pause or cancel.
        downloadItem.wkDownload = nil
        webView.resumeDownload(fromResumeData: resumeData) { [weak self] download in
            // Cancelled or removed while it was starting.
            guard let self, downloadItem.state == .downloading else {
                download.cancel(nil)
                return
            }
            download.delegate = self
            downloadItem.wkDownload = download
            self.observeProgress(of: download, for: downloadItem)
            if let finderProgress = downloadItem.finderProgress {
                finderProgress.resume()
            } else {
                self.createFinderProgress(for: downloadItem)
            }
        }
    }

    /// Ends a download for good: removes its partial file and progress.
    private func discardPartialDownload(_ downloadItem: DownloadItem, state: DownloadItem.DownloadState) {
        downloadItem.state = state
        downloadItem.resumeData = nil
        downloadItem.websiteDataStore = nil
        if let partialURL = downloadItem.partialURL {
            try? FileManager.default.removeItem(at: partialURL)
            downloadItem.partialURL = nil
        }
        stopTracking(downloadItem)
        cleanupFinderProgress(for: downloadItem)
    }

    func cancelDownload(_ downloadItem: DownloadItem) {
        DispatchQueue.main.async {
            // E.g. Finder's cancel arriving just after the download finished
            guard downloadItem.state != .completed, downloadItem.state != .cancelled else { return }
            if downloadItem.state == .downloading {
                downloadItem.wkDownload?.cancel(nil)
            }
            self.discardPartialDownload(downloadItem, state: .cancelled)
        }
    }

    func removeDownload(_ downloadItem: DownloadItem) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == downloadItem.id }) else { return }

            if downloadItem.state != .completed {
                if downloadItem.state == .downloading {
                    downloadItem.wkDownload?.cancel(nil)
                }
                // Paused or interrupted downloads keep a partial file too.
                self.discardPartialDownload(
                    downloadItem,
                    state: downloadItem.state == .failed ? .failed : .cancelled
                )
            }

            self.stopTracking(downloadItem)
            self.cleanupFinderProgress(for: downloadItem)
            self.downloads.remove(at: index)
        }
    }

    func revealInFinder(_ downloadItem: DownloadItem) {
        guard let destinationURL = downloadItem.destinationURL else { return }
        NSWorkspace.shared.selectFile(destinationURL.path, inFileViewerRootedAtPath: "")
    }

    /// Downloads in progress. Computed when asked: as a stored `@Published`
    /// value it was recomputed — and re-rendered every view observing this
    /// manager — on each progress chunk.
    var activeDownloads: Int {
        downloads.filter { $0.state == .downloading }.count
    }

    /// By bytes, of those whose size is known.
    private static func combinedProgress(of items: [DownloadItem]) -> Double? {
        let sized = items.filter { $0.fileSize > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + $1.fileSize }
        let done = sized.reduce(Int64(0)) { $0 + min($1.downloadedBytes, $1.fileSize) }
        return Double(done) / Double(total)
    }

    /// A name in the downloads folder that no file has, nor a download
    /// under way: that one only has its `.kldownload` file so far, and one
    /// just started not even that. Two downloads of the same name (a link
    /// clicked twice) otherwise got the same file, and the second, failing,
    /// took the first's partial file with it. The name is kept for the
    /// caller until `releaseDestination`.
    private func getUniqueFilename(for originalURL: URL) -> URL {
        let originalName = originalURL.lastPathComponent
        let nameWithoutExtension = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension

        func isTaken(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("kldownload").path)
                || reservedDestinations.contains(url.path)
        }

        var counter = 1
        var finalURL = downloadDirectory.appendingPathComponent(originalName)

        while isTaken(finalURL) {
            let newName: String
            if fileExtension.isEmpty {
                newName = "\(nameWithoutExtension) \(counter)"
            } else {
                newName = "\(nameWithoutExtension) \(counter).\(fileExtension)"
            }
            finalURL = downloadDirectory.appendingPathComponent(newName)
            counter += 1
        }

        reservedDestinations.insert(finalURL.path)
        return finalURL
    }

    /// The download has ended, or stopped with its partial file in place:
    /// its name no longer needs keeping.
    private func releaseDestination(_ url: URL?) {
        guard let url else { return }
        reservedDestinations.remove(url.path)
    }

    // MARK: - Helper Methods

    /// Get file extension from MIME type
    func fileExtension(forMimeType mimeType: String) -> String {
        return getFileExtensionFromMimeType(mimeType)
    }

    /// Get file extension from MIME type
    private func getFileExtensionFromMimeType(_ mimeType: String) -> String {
        let trimmed = mimeType.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        // Common non-standard or aliased types the system DB doesn't always resolve.
        let aliases: [String: String] = [
            "audio/mp3": "mp3",
            "audio/mpeg3": "mp3",
            "audio/x-mpeg-3": "mp3",
            "application/x-zip-compressed": "zip",
            "text/x-vcalendar": "vcs"
        ]
        if let alias = aliases[trimmed] {
            return alias
        }

        if let utType = UTType(mimeType: trimmed),
           let ext = utType.preferredFilenameExtension {
            return ext
        }

        return "bin"
    }

    /// Get the macOS system icon for a given file extension
    func getSystemIcon(for filename: String) -> NSImage {
        let fileExtension = URL(string: filename)?.pathExtension.lowercased() ?? ""

        // Special handling for .kldownload files to show as "Klar Download"
        if fileExtension == "kldownload" {
            if let klarDownloadType = UTType("com.klar.download") {
                return NSWorkspace.shared.icon(for: klarDownloadType)
            }
        }

        // For known extensions, get the icon using NSWorkspace
        if !fileExtension.isEmpty,
           let contentType = UTType(filenameExtension: fileExtension) {
            return NSWorkspace.shared.icon(for: contentType)
        }

        // Fallback to generic document icon
        return NSWorkspace.shared.icon(for: .data)
    }

    func triggerDownloadAnimation(for downloadItem: DownloadItem) {
        // Capture current mouse position
        let mouseLocation = NSEvent.mouseLocation
        // Convert from screen coordinates to window coordinates
        if let window = NSApplication.shared.keyWindow {
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            // Flip Y coordinate since SwiftUI uses top-left origin
            let flippedY = window.frame.height - windowPoint.y
            downloadAnimationStartPoint = CGPoint(x: windowPoint.x, y: flippedY)
            downloadAnimationWindowNumber = window.windowNumber
        } else {
            // Fallback to center if no window
            downloadAnimationStartPoint = CGPoint(x: 400, y: 300)
        }

        // Get the system icon for this file type
        downloadAnimationIcon = getSystemIcon(for: downloadItem.filename)

        // Start animation
        shouldShowDownloadAnimation = true

        // Hide animation after completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.shouldShowDownloadAnimation = false
        }
    }
}

// MARK: - WKDownloadDelegate
extension DownloadManager: WKDownloadDelegate {
    /// A download from a host whose certificate error the user chose to
    /// visit anyway.
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let credential = SSLBypassManager.shared.credential(for: challenge) {
            return (.useCredential, credential)
        }
        return (.performDefaultHandling, nil)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let chosenDestination = chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
        let finalURL: URL
        if let chosenDestination {
            finalURL = chosenDestination
        } else {
            let filename = suggestedFilename.isEmpty ? "download" : suggestedFilename
            finalURL = getUniqueFilename(for: downloadDirectory.appendingPathComponent(filename))
        }
        let filename = finalURL.lastPathComponent
        let partialURL = finalURL.appendingPathExtension("kldownload")

        let url = download.originalRequest?.url ?? URL(string: "about:blank")!

        // A paused download is resumed with a range request, which needs the
        // server to accept ranges and identify the file version.
        let httpResponse = response as? HTTPURLResponse
        let acceptsRanges = httpResponse?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        let identifiesVersion = httpResponse?.value(forHTTPHeaderField: "ETag") != nil
            || httpResponse?.value(forHTTPHeaderField: "Last-Modified") != nil

        let downloadItem = DownloadItem(url: url, filename: filename)
        downloadItem.destinationURL = finalURL
        downloadItem.partialURL = partialURL
        downloadItem.wkDownload = download
        downloadItem.websiteDataStore = download.webView?.configuration.websiteDataStore
        downloadItem.replacesExistingFile = chosenDestination != nil
        downloadItem.canPause = acceptsRanges && identifiesVersion
        downloadItem.systemIcon = self.getSystemIcon(for: filename)

        self.observeProgress(of: download, for: downloadItem)

        self.downloads.insert(downloadItem, at: 0)
        self.triggerDownloadAnimation(for: downloadItem)

        // Close tab if it was created specifically for this download
        if let tabId = self.wkDownloadTabIds.removeValue(forKey: ObjectIdentifier(download)) {
            self.closeDownloadTabIfNeeded(tabId)
        }

        // Create Finder progress after short delay to ensure file exists
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.createFinderProgress(for: downloadItem)
        }

        return partialURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            guard let downloadItem = self.downloads.first(where: { $0.wkDownload === download }) else { return }

            // Rename from .kldownload to final destination. A file already
            // there is only replaced when the save panel asked about it.
            if let partialURL = downloadItem.partialURL, let finalURL = downloadItem.destinationURL {
                do {
                    if downloadItem.replacesExistingFile, FileManager.default.fileExists(atPath: finalURL.path) {
                        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
                    } else {
                        try FileManager.default.moveItem(at: partialURL, to: finalURL)
                    }
                } catch {
                    logError(.general, "Failed to rename completed download: \(error)", isPrivate: download.webView?.isPrivateBrowsing ?? false)
                    // The partial file stays, removed with the item.
                    downloadItem.error = error
                    downloadItem.state = .failed
                    downloadItem.websiteDataStore = nil
                    self.stopTracking(downloadItem)
                    self.cleanupFinderProgress(for: downloadItem)
                    return
                }

                // Without a Content-Length the size is only known now, and
                // the last progress update may have been skipped.
                if let size = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    downloadItem.fileSize = Int64(size)
                    downloadItem.downloadedBytes = Int64(size)
                }
            }

            downloadItem.partialURL = nil
            downloadItem.websiteDataStore = nil
            downloadItem.state = .completed
            downloadItem.progress = 1.0
            self.stopTracking(downloadItem)
            self.cleanupFinderProgress(for: downloadItem)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            // Failed before its destination was decided: a later download
            // at the same address mustn't get these.
            let key = ObjectIdentifier(download)
            self.chosenDestinations.removeValue(forKey: key)
            self.wkDownloadTabIds.removeValue(forKey: key)

            guard let downloadItem = self.downloads.first(where: { $0.wkDownload === download }),
                  downloadItem.state == .downloading else {
                // Paused or cancelled on purpose; already handled.
                return
            }

            downloadItem.error = error
            if let resumeData {
                // Interrupted (e.g. the network dropped): keep the partial
                // file so the download can be resumed from the sidebar. Its
                // Finder progress goes until then (resuming publishes a new
                // one); a non-pausable progress can't show it's stopped.
                downloadItem.state = .failed
                downloadItem.resumeData = resumeData
                self.stopTracking(downloadItem)
                self.cleanupFinderProgress(for: downloadItem)
            } else {
                self.discardPartialDownload(downloadItem, state: .failed)
            }
        }
    }
}
