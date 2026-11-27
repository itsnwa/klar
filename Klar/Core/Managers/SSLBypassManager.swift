import Foundation
import Synchronization

/// Manages SSL certificate bypass for hosts where the user has chosen to proceed anyway.
/// Bypasses are session-based and cleared on app restart for security.
///
/// A bypass only answers Klar's own certificate challenges (`credential(for:)`,
/// from the tabs', popups', downloads' and favicons' handlers); nothing is added
/// to the user's trust settings, which would trust the certificate for every
/// app, and outlive Klar after a crash.
///
/// Used from any thread: URL sessions ask on their delegate queues.
nonisolated final class SSLBypassManager: Sendable {
    static let shared = SSLBypassManager()

    /// Hosts where SSL certificate errors should be bypassed (session-only)
    private let bypassedHosts = Mutex<Set<String>>([])

    private init() {}

    /// Add a host to the bypass list
    func addBypass(for host: String) {
        bypassedHosts.withLock { _ = $0.insert(host.lowercased()) }
        logDebug(.webView, "Added SSL bypass for host: \(host)")
    }

    /// Stop trusting a host (Stop Trusting in the website settings): its
    /// certificate errors show the error page again.
    func removeBypass(for host: String) {
        bypassedHosts.withLock { _ = $0.remove(host.lowercased()) }
        logDebug(.webView, "Removed SSL bypass for host: \(host)")
    }

    /// Check if SSL bypass is allowed for a given host
    func shouldBypassSSL(for host: String) -> Bool {
        bypassedHosts.withLock { $0.contains(host.lowercased()) }
    }

    /// Check if SSL bypass is allowed for a given URL
    func shouldBypassSSL(for url: URL) -> Bool {
        guard let host = url.host else { return false }
        return shouldBypassSSL(for: host)
    }

    /// The credential accepting the server's certificate, for a server trust
    /// challenge from a bypassed host; nil for anything else.
    func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        let protectionSpace = challenge.protectionSpace
        guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = protectionSpace.serverTrust,
              shouldBypassSSL(for: protectionSpace.host) else { return nil }
        logDebug(.webView, "🔓 Accepting certificate for: \(protectionSpace.host)")
        return URLCredential(trust: serverTrust)
    }
}

/// URLSession delegate that accepts server certificates for hosts in the bypass list
nonisolated final class SSLBypassSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - Session-level authentication (for session-wide challenges)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    // MARK: - Task-level authentication (for per-request challenges - this is what async/await uses)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    // MARK: - Shared authentication handling
    private func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let credential = SSLBypassManager.shared.credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
