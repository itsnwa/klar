import Foundation
import AppKit
import UniformTypeIdentifiers
import WebKit

class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var filename: String
    @Published var fileSize: Int64 = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var progress: Double = 0.0
    @Published var state: DownloadState = .downloading
    @Published var downloadSpeed: Double = 0.0 // bytes per second
    @Published var destinationURL: URL?
    @Published var partialURL: URL? // .kldownload file during progress
    @Published var error: Error?
    @Published var systemIcon: NSImage

    private var lastUpdateTime: Date
    private var lastDownloadedBytes: Int64 = 0

    var wkDownload: WKDownload?
    var finderProgress: Progress? // NSProgress for Finder integration
    /// Whether the server lets a download continue from where it stopped,
    /// which pausing relies on.
    var canPause = false
    /// Where a paused or interrupted download continues from.
    var resumeData: Data?
    /// The data store of the tab it came from (a private tab's, a separate
    /// profile's), for resuming it once that tab is gone.
    var websiteDataStore: WKWebsiteDataStore?
    /// Its destination was picked in a save panel, which already asked
    /// about replacing a file there.
    var replacesExistingFile = false

    enum DownloadState {
        case downloading
        case paused
        case completed
        case failed
        case cancelled
    }

    init(url: URL, filename: String? = nil) {
        self.url = url
        let finalFilename = filename ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        self.filename = finalFilename
        self.lastUpdateTime = Date()

        // Get the system icon for this file type using the new API
        let fileExtension = URL(string: finalFilename)?.pathExtension.lowercased() ?? ""
        if !fileExtension.isEmpty,
           let contentType = UTType(filenameExtension: fileExtension) {
            self.systemIcon = NSWorkspace.shared.icon(for: contentType)
        } else {
            // Fallback to generic document icon
            self.systemIcon = NSWorkspace.shared.icon(for: .data)
        }
    }

    func updateProgress(downloadedBytes: Int64, totalBytes: Int64) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastUpdateTime)

        if timeDelta > 0.1 { // Update speed calculation every 100ms
            let bytesDelta = downloadedBytes - lastDownloadedBytes
            downloadSpeed = Double(bytesDelta) / timeDelta

            lastUpdateTime = now
            lastDownloadedBytes = downloadedBytes
        }

        self.downloadedBytes = downloadedBytes
        // -1 while the server hasn't said (no Content-Length)
        self.fileSize = max(totalBytes, 0)

        if totalBytes > 0 {
            self.progress = Double(downloadedBytes) / Double(totalBytes)
        }
    }

    /// Whether the download's total is known yet; without a Content-Length
    /// it's only known once the file is there.
    var hasKnownSize: Bool {
        fileSize > 0
    }

    var formattedFileSize: String {
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDownloadedBytes: String {
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedDownloadSpeed: String {
        if downloadSpeed < 1024 {
            return String(format: "%.0f B/sec", downloadSpeed)
        } else if downloadSpeed < 1024 * 1024 {
            return String(format: "%.1f KB/sec", downloadSpeed / 1024)
        } else if downloadSpeed < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/sec", downloadSpeed / (1024 * 1024))
        } else {
            return String(format: "%.1f GB/sec", downloadSpeed / (1024 * 1024 * 1024))
        }
    }
}
