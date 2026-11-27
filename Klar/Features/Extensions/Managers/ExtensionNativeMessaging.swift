import Foundation
import WebKit

/// Connects extensions to the Mac apps they talk to (runtime.sendNativeMessage
/// and runtime.connectNative), e.g. 1Password's or Bitwarden's desktop app.
///
/// Apps register a native messaging host for each browser they support: a
/// JSON manifest naming the host's executable and the extension origins
/// allowed to start it. Klar reads the manifests Chrome, Edge, Brave, Arc,
/// Vivaldi, Opera and Chromium use, plus its own folder, and starts the host
/// the way Chrome does: with the calling extension's origin as its argument,
/// in the executable's folder, speaking length-prefixed JSON over stdio
/// (NativeMessagingConnection).
@MainActor
final class ExtensionNativeMessaging {
    enum Error: LocalizedError {
        case invalidHostName
        case hostNotFound(String)
        case hostExited

        var errorDescription: String? {
            switch self {
            case .invalidHostName: return "Invalid native messaging host name."
            case .hostNotFound(let name): return "Specified native messaging host not found: \(name)"
            case .hostExited: return "Native host has exited."
            }
        }
    }

    /// Where hosts are registered, most specific first. Paths starting with
    /// `~` are in the user's Library.
    private static let manifestFolders = [
        "~/Library/Application Support/Klar/NativeMessagingHosts",
        "~/Library/Application Support/Google/Chrome/NativeMessagingHosts",
        "/Library/Google/Chrome/NativeMessagingHosts",
        "~/Library/Application Support/Chromium/NativeMessagingHosts",
        "/Library/Application Support/Chromium/NativeMessagingHosts",
        "~/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
        "/Library/Microsoft/Edge/NativeMessagingHosts",
        "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "/Library/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "~/Library/Application Support/Arc/User Data/NativeMessagingHosts",
        "~/Library/Application Support/Dia/User Data/NativeMessagingHosts",
        "~/Library/Application Support/Vivaldi/NativeMessagingHosts",
        "/Library/Application Support/Vivaldi/NativeMessagingHosts",
        "~/Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts"
    ]

    private struct Host {
        let connection: NativeMessagingConnection
        let extensionID: String
    }

    /// Long-lived connections, kept until either side disconnects.
    private var ports: [ObjectIdentifier: (port: WKWebExtension.MessagePort, host: Host)] = [:]
    /// One-off sendNativeMessage hosts, kept until they reply or exit.
    private var oneShots: [ObjectIdentifier: Host] = [:]

    /// The executable of the host called `name` that `extensionID` may
    /// start, if one is registered.
    static func hostExecutable(named name: String, for extensionID: String) throws -> URL {
        // Chrome's rule for host names; it also keeps the name a file name.
        let isValid = !name.isEmpty
            && name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "_") })
            && !name.hasPrefix(".") && !name.hasSuffix(".") && !name.contains("..")
        guard isValid else { throw Error.invalidHostName }

        let origin = "chrome-extension://\(extensionID)/"
        for folder in manifestFolders {
            let path = (folder as NSString).expandingTildeInPath + "/\(name).json"
            guard
                let data = FileManager.default.contents(atPath: path),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                manifest["name"] as? String == name,
                (manifest["type"] as? String ?? "stdio") == "stdio",
                let origins = manifest["allowed_origins"] as? [String],
                origins.contains(origin),
                let executable = manifest["path"] as? String,
                executable.hasPrefix("/"),
                FileManager.default.isExecutableFile(atPath: executable)
            else { continue }
            return URL(fileURLWithPath: executable)
        }
        throw Error.hostNotFound(name)
    }

    /// runtime.sendNativeMessage: starts the host, sends one message, and
    /// replies with the first message back, then ends the host.
    func sendMessage(_ message: Any, toHost name: String, extensionID: String,
                     replyHandler: @escaping (Any?, Swift.Error?) -> Void) {
        let connection: NativeMessagingConnection
        do {
            connection = try start(host: name, extensionID: extensionID)
        } catch {
            return replyHandler(nil, error)
        }
        let key = ObjectIdentifier(connection)
        let reply = OneReply(replyHandler)
        connection.onMessage = { [weak self] data in
            DispatchQueue.main.async {
                guard !reply.hasReplied else { return }
                self?.oneShots.removeValue(forKey: key)?.connection.stop()
                do {
                    reply(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), nil)
                } catch {
                    reply(nil, error)
                }
            }
        }
        connection.onExit = { [weak self] in
            DispatchQueue.main.async {
                self?.oneShots.removeValue(forKey: key)
                reply(nil, Error.hostExited)
            }
        }
        oneShots[key] = Host(connection: connection, extensionID: extensionID)
        do {
            try connection.start()
            try connection.send(message)
        } catch {
            oneShots.removeValue(forKey: key)?.connection.stop()
            reply(nil, error)
        }
    }

    /// runtime.connectNative: a port to a host that runs until either side
    /// disconnects.
    func connect(_ port: WKWebExtension.MessagePort, extensionID: String, completionHandler: @escaping (Swift.Error?) -> Void) {
        guard let name = port.applicationIdentifier else { return completionHandler(Error.invalidHostName) }
        let connection: NativeMessagingConnection
        do {
            connection = try start(host: name, extensionID: extensionID)
        } catch {
            return completionHandler(error)
        }
        let key = ObjectIdentifier(port)

        connection.onMessage = { [weak port] data in
            DispatchQueue.main.async {
                guard let port, !port.isDisconnected,
                      let message = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
                port.sendMessage(message, completionHandler: nil)
            }
        }
        connection.onExit = { [weak self, weak port] in
            DispatchQueue.main.async {
                self?.ports.removeValue(forKey: key)
                if let port, !port.isDisconnected { port.disconnect(throwing: Error.hostExited) }
            }
        }
        port.messageHandler = { [weak connection] message, _ in
            do {
                try connection?.send(message ?? NSNull())
            } catch {
                logError(.extensions, "Couldn't write to native host \(name): \(error.localizedDescription)")
            }
        }
        port.disconnectHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.ports.removeValue(forKey: key)?.host.connection.stop()
            }
        }

        do {
            try connection.start()
        } catch {
            return completionHandler(error)
        }
        ports[key] = (port, Host(connection: connection, extensionID: extensionID))
        completionHandler(nil)
    }

    /// Ends the hosts an extension started, as it stops (turned off,
    /// removed, reloaded or updated). One-off hosts still waiting reply
    /// that the host exited, once it has.
    func disconnect(extensionID: String) {
        for (key, entry) in ports where entry.host.extensionID == extensionID {
            ports[key] = nil
            entry.host.connection.stop()
            entry.port.disconnect()
        }
        for host in oneShots.values where host.extensionID == extensionID {
            host.connection.stop()
        }
    }

    private func start(host name: String, extensionID: String) throws -> NativeMessagingConnection {
        let executable = try Self.hostExecutable(named: name, for: extensionID)
        logInfo(.extensions, "Starting native host \(name) for \(extensionID)")
        return NativeMessagingConnection(
            executableURL: executable,
            arguments: ["chrome-extension://\(extensionID)/"],
            workingDirectory: executable.deletingLastPathComponent()
        )
    }
}

/// A one-shot message's reply handler, called once: with the host's first
/// message, or when it exits or can't be started.
private final class OneReply {
    private var handler: ((Any?, Swift.Error?) -> Void)?

    init(_ handler: @escaping (Any?, Swift.Error?) -> Void) {
        self.handler = handler
    }

    var hasReplied: Bool { handler == nil }

    func callAsFunction(_ message: Any?, _ error: Swift.Error?) {
        let handler = handler
        self.handler = nil
        handler?(message, error)
    }
}
