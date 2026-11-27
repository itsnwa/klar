import AppKit
import Foundation

enum ApplePasswordsError: Error, LocalizedError {
    case unavailable(String)
    case notPaired
    case timedOut
    case helperExited
    case requestFailed(Int)
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .notPaired: return "Klar isn't connected to Passwords."
        case .timedOut: return "Passwords didn't respond."
        case .helperExited: return "The connection to Passwords was lost."
        case .requestFailed(let status): return "Passwords couldn't complete the request (status \(status))."
        case .malformedReply: return "Passwords sent an unexpected reply."
        }
    }
}

/// Reads accounts and verification codes from Apple's Passwords app through
/// Apple's PasswordManagerBrowserExtensionHelper, the backend of the iCloud
/// Passwords extension for other browsers, speaking the same unofficial
/// native messaging protocol as that extension (transport in
/// NativeMessagingConnection, pairing and encryption in SRPSession).
///
/// The helper's parent launch constraint admits any process signed with
/// `com.apple.developer.web-browser.public-key-credential`, so Klar itself
/// must spawn it: the same binary launched from a shell is killed by AMFI.
///
/// Like the extension, Klar pairs once per helper process: the helper shows
/// a six-digit code and the user types it into Klar. The helper runs until
/// Klar quits, so that is once per launch, and only once Passwords is
/// actually wanted. Quitting hands the helper and the pairing over to the
/// Klar opened next, after an update too (ApplePasswordsHandover).
@MainActor
final class ApplePasswordsManager: ObservableObject {
    static let shared = ApplePasswordsManager()

    enum State: Equatable {
        /// The helper hasn't been needed yet this launch.
        case idle
        case connecting
        case unavailable(String)
        case notPaired
        /// Pairing has started and the helper is showing its code.
        case awaitingCode
        case paired
    }

    @Published private(set) var state: State = .idle

    /// Called when the helper reports a newly delivered verification code
    /// (Messages or Mail).
    var onOneTimeCodeAvailable: (() -> Void)?

    private enum Command: Int {
        case challengePIN = 2
        case getLoginNames = 4
        case getPassword = 5
        case passwordsDisabled = 9
        case reloginNeeded = 10
        case launchPasswordsApp = 13
        case hello = 14
        case oneTimeCodeAvailable = 15
        case getOneTimeCodes = 16
        case didFillOneTimeCode = 17
        case didCancelPairing = 19
    }

    private enum Action {
        static let search = 2
        static let ghostSearch = 5
    }

    private enum Status {
        static let success = 0
        static let noResults = 3
        static let invalidSession = 9
    }

    private struct PendingRequest {
        let id: Int
        let command: Command
        let tabID: Int?
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    /// Entry the helper lists for sites the user chose never to save.
    private static let neverSaveMarker = "Passwords\u{00A0}not\u{00A0}saved"
    private static let browserName = "Klar"
    private static let passwordsAppBundleID = "com.apple.Passwords"

    private static let helperManifestPaths = [
        "/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json",
        "/Library/Application Support/Mozilla/NativeMessagingHosts/com.apple.passwordmanager.json"
    ]
    private static let fallbackHelperPath =
        "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    /// Native messaging hosts get the calling extension's origin as their
    /// only argument; the helper refuses to start without one. This is the
    /// origin Chromium-based browsers pass. The helper names
    /// the client after the parent app, so its prompts still say "Klar".
    private static let helperLaunchArgument = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    private var connection: NativeMessagingConnection?
    private var connectTask: Task<Bool, Never>?
    private var capabilities: [String: Any] = [:]
    private var session: SRPSession?
    private var pairingSession: SRPSession?
    private var pending: [PendingRequest] = []
    private var nextRequestID = 1

    private init() {}

    // MARK: - Connection

    /// Launches the helper if needed. False when it can't run on this Mac.
    @discardableResult
    func connect() async -> Bool {
        if let connectTask { return await connectTask.value }
        switch state {
        case .notPaired, .awaitingCode, .paired: return true
        case .idle, .connecting, .unavailable: break
        }
        let task = Task { await launchHelper() }
        connectTask = task
        let connected = await task.value
        connectTask = nil
        return connected
    }

    /// Unpairs and ends the helper; the next use asks for a new code.
    func disconnect() {
        cancelPairing()
        connection?.stop()
        connection = nil
        session = nil
        pairingSession = nil
        failPendingRequests()
        state = .idle
    }

    private func launchHelper() async -> Bool {
        guard let helperURL = Self.helperURL() else {
            state = .unavailable("This Mac doesn't have the Passwords AutoFill helper for other browsers.")
            return false
        }
        state = .connecting

        let connection = NativeMessagingConnection(executableURL: helperURL, arguments: [Self.helperLaunchArgument])
        observe(connection)
        do {
            try connection.start()
        } catch {
            state = .unavailable("Couldn't start Passwords AutoFill: \(error.localizedDescription)")
            return false
        }
        self.connection = connection

        do {
            let reply = try await request(.hello, ["cmd": Command.hello.rawValue], timeout: 5)
            capabilities = reply["capabilities"] as? [String: Any] ?? [:]
            logDebug(.passwords, "helper capabilities: \(capabilities)")
            state = .notPaired
            return true
        } catch {
            logError(.passwords, "helper hello failed: \(error.localizedDescription)")
            connection.stop()
            self.connection = nil
            state = .unavailable("Passwords AutoFill didn't respond. It may not allow Klar to connect.")
            return false
        }
    }

    private func observe(_ connection: NativeMessagingConnection) {
        // Main-queue hops keep messages in the order the helper sent them.
        connection.onMessage = { [weak self] data in
            DispatchQueue.main.async { self?.receive(data) }
        }
        connection.onExit = { [weak self, weak connection] in
            DispatchQueue.main.async { self?.helperExited(connection) }
        }
    }

    /// The helper's executable, as registered by macOS for other browsers.
    private static func helperURL() -> URL? {
        for manifestPath in helperManifestPaths {
            guard
                let data = FileManager.default.contents(atPath: manifestPath),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let path = manifest["path"] as? String,
                FileManager.default.isExecutableFile(atPath: path)
            else { continue }
            return URL(fileURLWithPath: path)
        }
        guard FileManager.default.isExecutableFile(atPath: fallbackHelperPath) else { return nil }
        return URL(fileURLWithPath: fallbackHelperPath)
    }

    private func helperExited(_ exited: NativeMessagingConnection?) {
        guard let exited, exited === connection else { return }
        logError(.passwords, "helper exited")
        connection = nil
        session = nil
        pairingSession = nil
        failPendingRequests()
        // A launch that never got through hello reports .unavailable itself;
        // after that, the next use simply relaunches.
        if state != .connecting { state = .idle }
    }

    private func failPendingRequests() {
        let requests = pending
        pending.removeAll()
        requests.forEach { $0.continuation.resume(throwing: ApplePasswordsError.helperExited) }
    }

    // MARK: - Pairing

    /// Starts pairing; the helper then shows a six-digit code for the user
    /// to pass to `submitCode(_:)`.
    func beginPairing() async throws {
        guard await connect() else {
            if case .unavailable(let reason) = state { throw ApplePasswordsError.unavailable(reason) }
            throw ApplePasswordsError.helperExited
        }
        if state == .paired { return }

        let useBase64 = capabilities["shouldUseBase64"] as? Bool ?? false
        // Generating the key pair is a 3072-bit exponentiation.
        let session = await Task.detached(priority: .userInitiated) { SRPSession(useBase64: useBase64) }.value
        pairingSession = session

        let reply = try await request(.challengePIN, [
            "cmd": Command.challengePIN.rawValue,
            "msg": try Self.jsonString(["QID": "m0", "PAKE": try session.clientHello(), "HSTBRSR": Self.browserName])
        ], timeout: 10)
        guard pairingSession === session else { return } // cancelled meanwhile
        guard let pake = Self.dictionary(reply["payload"])?["PAKE"] as? String else {
            throw ApplePasswordsError.malformedReply
        }
        try session.receiveServerHello(pake)
        state = .awaitingCode
    }

    /// Completes pairing with the code the helper is showing. On a wrong
    /// code the helper drops the attempt, so pairing must begin again.
    func submitCode(_ code: String) async throws {
        guard state == .awaitingCode, let session = pairingSession else {
            throw ApplePasswordsError.notPaired
        }
        let proof = try await Task.detached(priority: .userInitiated) {
            try session.clientProof(code: code)
        }.value
        let reply = try await request(.challengePIN, [
            "cmd": Command.challengePIN.rawValue,
            "msg": try Self.jsonString(["QID": "m2", "PAKE": proof])
        ], timeout: 10)
        guard let pake = Self.dictionary(reply["payload"])?["PAKE"] as? String else {
            throw ApplePasswordsError.malformedReply
        }
        do {
            try session.receiveServerProof(pake)
        } catch {
            pairingSession = nil
            state = .notPaired
            throw error
        }
        self.session = session
        pairingSession = nil
        state = .paired
        logDebug(.passwords, "paired with Passwords")
    }

    func cancelPairing() {
        guard state == .awaitingCode || pairingSession != nil else { return }
        try? connection?.send(["cmd": Command.didCancelPairing.rawValue])
        pairingSession = nil
        if state == .awaitingCode { state = .notPaired }
    }

    // MARK: - Quitting

    /// Hands the helper and the pairing over to the Klar opened next, so it
    /// doesn't ask for a new code. Called as Klar quits.
    func handOver() {
        guard
            state == .paired, let connection, let pairing = session?.pairing,
            let capabilityData = try? JSONSerialization.data(withJSONObject: capabilities)
        else { return }
        ApplePasswordsHandover.handOver(connection, pairing: ApplePasswordsHandover.Pairing(
            session: pairing,
            capabilities: capabilityData,
            nextRequestID: nextRequestID
        ))
    }

    /// Takes over the helper and the pairing the Klar before this one handed
    /// over as it quit. Called once the window is up.
    func resumeHandedOverPairing() async {
        guard let handover = await Task.detached(priority: .userInitiated, operation: {
            ApplePasswordsHandover.takeOver()
        }).value else { return }
        let (connection, pairing) = handover
        // A helper started meanwhile would want a code of its own anyway.
        guard state == .idle, self.connection == nil else {
            connection.stop()
            return
        }
        observe(connection)
        do {
            try connection.start()
        } catch {
            connection.stop()
            return
        }
        self.connection = connection
        session = SRPSession(resuming: pairing.session)
        capabilities = (try? JSONSerialization.jsonObject(with: pairing.capabilities)) as? [String: Any] ?? [:]
        nextRequestID = pairing.nextRequestID
        state = .paired
        logDebug(.passwords, "kept the pairing with Passwords from the last launch")
    }

    /// Whether a message the helper sends while no Klar is listening leaves
    /// the pairing to keep: one that can be read and doesn't end it. For
    /// ApplePasswordsHandover's keeper.
    nonisolated static func leavesPairing(_ message: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
            let rawCommand = (object["cmd"] as? NSNumber)?.intValue
        else { return false }
        return rawCommand != Command.passwordsDisabled.rawValue && rawCommand != Command.reloginNeeded.rawValue
    }

    // MARK: - Logins

    /// Logins saved for a website. Passwords aren't included.
    func logins(forHost host: String) async throws -> [ApplePasswordsLogin] {
        let reply = try await encryptedRequest(
            .getLoginNames,
            queryID: "CmdGetLoginNames4URL",
            url: host,
            body: ["ACT": Action.ghostSearch, "URL": host]
        )
        return Self.entries(in: reply).compactMap { entry in
            guard
                let username = entry["USR"] as? String,
                username != Self.neverSaveMarker,
                let site = (entry["sites"] as? [String])?.first
            else { return nil }
            return ApplePasswordsLogin(username: username, site: site, customTitle: entry["customTitle"] as? String)
        }
    }

    /// The password for a login. Passwords may ask for Touch ID first.
    func password(for login: ApplePasswordsLogin) async throws -> String? {
        let reply = try await encryptedRequest(
            .getPassword,
            queryID: "CmdGetPassword4LoginName",
            url: login.site,
            body: ["ACT": Action.search, "URL": login.site, "USR": login.username],
            timeout: 120
        )
        let entries = Self.entries(in: reply).filter {
            ($0["sites"] as? [String])?.contains(login.site) ?? false
        }
        let entry = entries.first { $0["USR"] as? String == login.username } ?? entries.first
        return entry?["PWD"] as? String
    }

    // MARK: - Verification codes

    /// Codes for a frame: TOTP generators saved in Passwords, and codes that
    /// arrived in Messages or Mail. `frameURLs` lists the frame's URL first,
    /// then its ancestors'.
    func oneTimeCodes(frameURLs: [String]) async throws -> [OneTimeCode] {
        if capabilities["canFillOneTimeCodes"] as? Bool == false { return [] }
        let reply = try await encryptedRequest(
            .getOneTimeCodes,
            queryID: "CmdGetOneTimeCodes",
            body: ["ACT": Action.ghostSearch, "TYPE": "oneTimeCodes", "frameURLs": frameURLs]
        )
        return Self.entries(in: reply).map(OneTimeCode.init)
    }

    /// The code to fill for a listed one. TOTP entries are listed without
    /// one; Passwords generates the current code when asked to fill it.
    func codeToFill(_ code: OneTimeCode, frameURLs: [String]) async throws -> String? {
        guard code.isTOTP else { return code.code }
        var body: [String: Any] = ["ACT": Action.search, "TYPE": "oneTimeCodes", "frameURLs": frameURLs]
        if let username = code.username { body["username"] = username }
        let reply = try await encryptedRequest(
            .didFillOneTimeCode,
            queryID: "CmdDidFillOneTimeCode",
            body: body,
            timeout: 120
        )
        let generated = Self.entries(in: reply).map(OneTimeCode.init)
        return (generated.first { $0.username == code.username } ?? generated.first)?.code
    }

    // MARK: - Passwords app

    /// Opens the Passwords app, searching for `host` when there is one.
    func openPasswordsApp(searching host: String? = nil) {
        if let host, let connection,
           (try? connection.send(["cmd": Command.launchPasswordsApp.rawValue, "searchQueryURL": "https://\(host)"])) != nil {
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.passwordsAppBundleID) else {
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Messaging

    private func encryptedRequest(
        _ command: Command,
        queryID: String,
        url: String? = nil,
        body: [String: Any],
        timeout: TimeInterval = 10
    ) async throws -> [String: Any] {
        guard state == .paired, let session else { throw ApplePasswordsError.notPaired }
        let tabID = takeRequestID()
        var message: [String: Any] = [
            "cmd": command.rawValue,
            "tabId": tabID,
            "frameId": 0,
            "payload": try Self.jsonString(["QID": queryID, "SMSG": try session.seal(body)])
        ]
        if let url { message["url"] = url }

        let reply = try await request(command, message, tabID: tabID, timeout: timeout)
        guard self.session === session else { throw ApplePasswordsError.notPaired }
        let decrypted = try session.open(Self.dictionary(reply["payload"])?["SMSG"])
        let status = (decrypted["STATUS"] as? NSNumber)?.intValue ?? Status.success
        switch status {
        case Status.success, Status.noResults:
            return decrypted
        case Status.invalidSession:
            dropSession()
            throw ApplePasswordsError.notPaired
        default:
            throw ApplePasswordsError.requestFailed(status)
        }
    }

    private func request(
        _ command: Command,
        _ message: [String: Any],
        tabID: Int? = nil,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard let connection else { throw ApplePasswordsError.helperExited }
        let id = takeRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingRequest(id: id, command: command, tabID: tabID, continuation: continuation))
            do {
                try connection.send(message)
            } catch {
                resolve(id, with: .failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolve(id, with: .failure(ApplePasswordsError.timedOut))
            }
        }
    }

    private func resolve(_ id: Int, with result: sending Result<[String: Any], Error>) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(with: result)
    }

    private func receive(_ data: Data) {
        guard
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawCommand = (message["cmd"] as? NSNumber)?.intValue
        else {
            logError(.passwords, "unreadable message from helper")
            return
        }
        // Replies echo the request's tabId; answer the oldest match.
        let tabID = (message["tabId"] as? NSNumber)?.intValue
        if let index = pending.firstIndex(where: {
            $0.command.rawValue == rawCommand && ($0.tabID == nil || tabID == nil || $0.tabID == tabID)
        }) {
            pending.remove(at: index).continuation.resume(returning: message)
            return
        }

        switch Command(rawValue: rawCommand) {
        case .passwordsDisabled, .reloginNeeded:
            logDebug(.passwords, "helper ended the session (cmd \(rawCommand))")
            dropSession()
        case .oneTimeCodeAvailable:
            onOneTimeCodeAvailable?()
        default:
            logDebug(.passwords, "ignoring helper message cmd \(rawCommand)")
        }
    }

    private func dropSession() {
        session = nil
        pairingSession = nil
        if state == .paired || state == .awaitingCode { state = .notPaired }
    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    // MARK: - Helpers

    private static func entries(in reply: [String: Any]) -> [[String: Any]] {
        if let entries = reply["Entries"] as? [[String: Any]] { return entries }
        // Older helpers send Entry_0, Entry_1, … keys instead of an array.
        return reply.keys.filter { $0.hasPrefix("Entry_") }.sorted()
            .compactMap { reply[$0] as? [String: Any] }
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let string = value as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
