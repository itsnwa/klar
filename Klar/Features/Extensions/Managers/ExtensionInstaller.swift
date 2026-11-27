import Foundation

/// Gets extension files onto disk: from the Chrome Web Store (verified
/// CRX3 packages, unpacked into a folder of Klar's), the store's update
/// service, and the lists of what other Chromium browsers have installed.
/// ExtensionManager decides what to load.
nonisolated enum ExtensionInstaller {
    static let webStoreHost = "chromewebstore.google.com"
    static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    private static let chromeVersion = ExtensionCompatibility.chromeVersion
    private static let userAgent = ExtensionCompatibility.chromeUserAgent
    private static let updateServiceURL = "https://clients2.google.com/service/update2/crx"

    enum Error: LocalizedError {
        case notInStore
        case download(String)
        case unzipFailed
        case noManifest
        case invalidManifest(String)

        var errorDescription: String? {
            switch self {
            case .notInStore: return "The Chrome Web Store doesn't have that extension."
            case .download(let reason): return "Couldn't download the extension: \(reason)"
            case .unzipFailed: return "Couldn't unpack the extension."
            case .noManifest: return "The folder has no manifest.json."
            case .invalidManifest(let reason): return "The extension's manifest.json can't be read: \(reason)"
            }
        }
    }

    // MARK: - Chrome Web Store

    /// The extension ID in a store link (…/detail/<name>/<id>, or the old
    /// chrome.google.com/webstore/detail/… form), or a bare ID.
    static func extensionID(fromLinkOrID text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if CRXFile.isValidExtensionID(trimmed) { return trimmed }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host == webStoreHost || host == "chrome.google.com" else { return nil }
        return url.pathComponents.last(where: CRXFile.isValidExtensionID)
    }

    /// Downloads the store's current version of `id`, checks its
    /// signatures, and unpacks it into a new folder of Klar's.
    static func downloadFromWebStore(id: String) async throws -> URL {
        let query = "response=redirect&acceptformat=crx3&prodversion=\(chromeVersion)&x=id%3D\(id)%26installsource%3Dondemand%26uc"
        guard let url = URL(string: "\(updateServiceURL)?\(query)") else { throw Error.notInStore }
        return try await downloadPackage(from: url, id: id)
    }

    /// Off the main actor: checking the package's signatures and writing
    /// its files take a while for a big extension.
    @concurrent private static func downloadPackage(from url: URL, id: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 204 || http.statusCode == 404
                    ? Error.notInStore
                    : Error.download("the store answered \(http.statusCode)")
            }
            data = body
        } catch let error as Error {
            throw error
        } catch {
            throw Error.download(error.localizedDescription)
        }
        // An unknown ID gets an empty answer rather than an error.
        guard !data.isEmpty else { throw Error.notInStore }

        let package = try CRXFile(data: data, expectedID: id, requireStoreSignature: true)
        let folder = ExtensionRecordStore.newFolder(for: id)
        do {
            try await unzip(package.archive, into: folder)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
                throw Error.noManifest
            }
            ExtensionCompatibility.prepare(folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        logInfo(.extensions, "Downloaded \(id) (\(data.count) bytes) into \(folder.lastPathComponent)")
        return folder
    }

    /// unzip leaves out entries that would land outside `folder` (absolute
    /// paths, `..`) with a warning, exit status 1.
    private static func unzip(_ archive: Data, into folder: URL) async throws {
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("klar-extension-\(UUID().uuidString).zip")
        try archive.write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", zipURL.path, "-d", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 || status == 1 else {
            logError(.extensions, "unzip exited with \(status)")
            throw Error.unzipFailed
        }
    }

    // MARK: - Updates

    struct AvailableUpdate {
        let id: String
        let version: String
        let packageURL: URL
    }

    /// Asks the store's update service which of `installed` (ID → version)
    /// have a newer version. The answer is parsed off the main actor.
    @concurrent static func checkForUpdates(_ installed: [String: String]) async throws -> [AvailableUpdate] {
        guard !installed.isEmpty else { return [] }
        var query = "response=updatecheck&acceptformat=crx3&prodversion=\(chromeVersion)"
        for (id, version) in installed.sorted(by: { $0.key < $1.key }) {
            let safeVersion = version.filter { $0.isNumber || $0 == "." }
            query += "&x=id%3D\(id)%26v%3D\(safeVersion.isEmpty ? "0" : safeVersion)%26uc"
        }
        guard let url = URL(string: "\(updateServiceURL)?\(query)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        let parser = UpdateResponseParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return [] }
        return parser.updates.filter { update in
            guard let current = installed[update.id] else { return false }
            return compareVersions(update.version, current) == .orderedDescending
        }
    }

    /// Downloads and unpacks an update found by checkForUpdates.
    static func download(_ update: AvailableUpdate) async throws -> URL {
        try await downloadPackage(from: update.packageURL, id: update.id)
    }

    /// Chrome versions are one to four dot-separated numbers.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `<app appid="…"><updatecheck status="ok" codebase="…" version="…"/></app>`
    private final class UpdateResponseParser: NSObject, XMLParserDelegate {
        var updates: [AvailableUpdate] = []
        private var currentID: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "app":
                currentID = attributes["appid"]
            case "updatecheck":
                guard let id = currentID, attributes["status"] == "ok",
                      let version = attributes["version"],
                      let codebase = attributes["codebase"].flatMap(URL.init(string:)),
                      codebase.scheme == "https" else { return }
                updates.append(AvailableUpdate(id: id, version: version, packageURL: codebase))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "app" { currentID = nil }
        }
    }

    // MARK: - Unpacked extensions

    /// The ID Chrome gives an unpacked extension: from the manifest's `key`
    /// if it has one, otherwise from the folder's path.
    static func unpackedExtensionID(for folder: URL) throws -> String {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { throw Error.noManifest }
        let manifest: [String: Any]
        do {
            manifest = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] ?? [:]
        } catch {
            throw Error.invalidManifest(error.localizedDescription)
        }
        if let key = manifest["key"] as? String, let keyData = Data(base64Encoded: key) {
            return CRXFile.extensionID(hashing: keyData)
        }
        return CRXFile.extensionID(hashing: Data(folder.standardizedFileURL.path.utf8))
    }

    // MARK: - Other browsers

    /// A store extension installed in another browser on this Mac.
    struct ForeignExtension: Identifiable, Hashable {
        let id: String
        let name: String
        let browsers: [String]
    }

    /// Chromium-based browsers' profile folders, under Application Support.
    private static let browserFolders: [(name: String, path: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Arc", "Arc/User Data"),
        ("Dia", "Dia/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Chromium", "Chromium")
    ]

    /// Extensions the user added from the Chrome Web Store in other browsers
    /// (any profile). Only names and IDs are read: installing reinstalls
    /// them fresh from the store.
    static func extensionsInOtherBrowsers() -> [ForeignExtension] {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var names: [String: String] = [:]
        var browsersByID: [String: [String]] = [:]

        for browser in browserFolders {
            let root = appSupport.appendingPathComponent(browser.path, isDirectory: true)
            guard let profiles = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
                let extensionsFolder = root.appendingPathComponent(profile).appendingPathComponent("Extensions")
                guard let ids = try? fileManager.contentsOfDirectory(atPath: extensionsFolder.path) else { continue }
                for id in ids where CRXFile.isValidExtensionID(id) {
                    guard let name = webStoreExtensionName(in: extensionsFolder.appendingPathComponent(id)) else { continue }
                    names[id] = names[id] ?? name
                    if browsersByID[id]?.contains(browser.name) != true {
                        browsersByID[id, default: []].append(browser.name)
                    }
                }
            }
        }

        return names.map { ForeignExtension(id: $0.key, name: $0.value, browsers: browsersByID[$0.key] ?? []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The display name of the newest version in an installed extension's
    /// folder, if the Chrome Web Store installed it (its manifest's
    /// `update_url` is the store's update service).
    private static func webStoreExtensionName(in folder: URL) -> String? {
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(atPath: folder.path),
              let newest = versions.filter({ !$0.hasPrefix(".") })
                .max(by: { compareVersions($0.components(separatedBy: "_")[0], $1.components(separatedBy: "_")[0]) == .orderedAscending })
        else { return nil }
        let versionFolder = folder.appendingPathComponent(newest)
        guard let data = fileManager.contents(atPath: versionFolder.appendingPathComponent("manifest.json").path),
              let manifest = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let updateURL = (manifest["update_url"] as? String).flatMap(URL.init(string:)),
              updateURL.host == "clients2.google.com",
              let name = manifest["name"] as? String else { return nil }
        return localized(name, in: versionFolder, defaultLocale: manifest["default_locale"] as? String)
    }

    /// Resolves a `__MSG_key__` name from the extension's _locales.
    private static func localized(_ value: String, in folder: URL, defaultLocale: String?) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        let preferred = Locale.preferredLanguages.flatMap { language -> [String] in
            let normalized = language.replacingOccurrences(of: "-", with: "_")
            return [normalized, String(normalized.prefix(while: { $0 != "_" }))]
        }
        for locale in preferred + [defaultLocale, "en"].compactMap({ $0 }) {
            let messagesURL = folder.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = FileManager.default.contents(atPath: messagesURL.path),
                  let messages = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
            else { continue }
            for (messageKey, entry) in messages where messageKey.lowercased() == key {
                if let message = (entry as? [String: Any])?["message"] as? String { return message }
            }
        }
        return value
    }
}
