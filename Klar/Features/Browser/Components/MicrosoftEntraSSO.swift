import AuthenticationServices
import WebKit

/// Single sign-on for Microsoft work and school accounts on a Mac managed
/// with Intune, as other browsers do it. Conditional Access
/// policies that require a registered or compliant device check the device
/// at sign-in; without proof of it, Microsoft sends people to "Enroll your
/// device". The Microsoft Enterprise SSO plug-in (in Intune's Company Portal)
/// hands browsers that proof as request headers for Microsoft's sign-in
/// hosts, through its `get_sso_cookies` operation.
///
/// The plug-in only answers browsers whose Apple Team ID is on Microsoft's
/// own list, which Klar isn't on; others get
/// "the teamId … is not allowed". Once it says no, it isn't asked again
/// this launch. On such a Mac, Klar gets SSO through
/// WebKit's own Extensible SSO (on in every WKWebView), once the admin adds
/// `com.itsnwa.browser` to the plug-in's `AppAllowList`.
///
/// WKWebView can only add headers to a load it starts, so a top-level
/// navigation to a sign-in host is cancelled and loaded again with them.
/// Frames can't be loaded that way; a sign-in that needs the device in a
/// frame falls back to a top-level one, which gets them.
@MainActor
enum MicrosoftEntraSSO {
    private static let authorityHosts: Set<String> = [
        "login.microsoft.com",
        "login.microsoftonline.com",
        "sts.windows.net",
        "login.partner.microsoftonline.cn",
        "login.chinacloudapi.cn",
        "login.microsoftonline.us",
        "login-us.microsoftonline.com",
    ]

    private static let identityProviderURL = URL(string: "https://login.microsoftonline.com/common")!

    /// The plug-in's public key for browser requests (MSAL's).
    private static let brokerKey = "kSiiehqi0sbYWxT2zOmV-rv8B3QRNsUKcU3YPc122121"

    /// How long a sign-in page waits for the plug-in before loading without it.
    private static let timeout: TimeInterval = 5

    /// The URL each web view is loading again with the headers, let through
    /// once so a lookup that came back empty doesn't start over.
    private static let resentURLs = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

    /// Whether the plug-in turned Klar down, so sign-in pages aren't held up asking again.
    private static var isDeclined = false

    static func isAuthority(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return authorityHosts.contains(host)
    }

    /// Takes over a top-level navigation to a Microsoft sign-in host when the
    /// plug-in is set up on this Mac: cancels it and loads the request again
    /// with the plug-in's headers. Returns false for navigations it leaves to
    /// the caller.
    static func handle(_ navigationAction: WKNavigationAction, in webView: WKWebView, decisionHandler: (WKNavigationActionPolicy) -> Void) -> Bool {
        let request = navigationAction.request
        guard let url = request.url, url.scheme == "https", isAuthority(url),
              navigationAction.targetFrame?.isMainFrame == true,
              webView.configuration.websiteDataStore.isPersistent else { return false }

        if let resent = resentURLs.object(forKey: webView) {
            resentURLs.removeObject(forKey: webView)
            if resent as URL == url { return false }
        }

        if isDeclined { return false }

        // A form sent to the sign-in page can only be sent again with its body.
        if (request.httpMethod ?? "GET") != "GET" && request.httpBody == nil { return false }

        let provider = ASAuthorizationSingleSignOnProvider(identityProvider: identityProviderURL)
        guard provider.canPerformAuthorization else { return false }

        decisionHandler(.cancel)
        Task { [weak webView] in
            let headers = await ssoHeaders(for: url, from: provider)
            guard let webView else { return }
            var resentRequest = request
            for (name, value) in headers {
                resentRequest.setValue(value, forHTTPHeaderField: name)
            }
            resentURLs.setObject(url as NSURL, forKey: webView)
            webView.load(resentRequest)
        }
        return true
    }

    /// The device's (and the signed-in user's) headers for `url`, empty when
    /// the plug-in has none or doesn't answer in time.
    private static func ssoHeaders(for url: URL, from provider: ASAuthorizationSingleSignOnProvider) async -> [String: String] {
        let request = provider.createRequest()
        request.requestedOperation = ASAuthorization.OpenIDOperation(rawValue: "get_sso_cookies")
        request.isUserInterfaceEnabled = false
        request.authorizationOptions = [
            URLQueryItem(name: "sso_url", value: url.absoluteString),
            URLQueryItem(name: "types_of_header", value: "0"),
            URLQueryItem(name: "broker_key", value: brokerKey),
            URLQueryItem(name: "msg_protocol_ver", value: "4"),
        ]

        let ssoRequest = SSORequest()
        let authorization = await ssoRequest.perform(request, timeout: timeout)
        if let error = ssoRequest.error {
            isDeclined = true
            logError(.webView, "Microsoft Entra SSO: the SSO extension declined (\(error)); not asking again this launch")
        }
        guard let credential = authorization?.credential as? ASAuthorizationSingleSignOnCredential,
              let ssoCookies = credential.authenticatedResponse?.value(forHTTPHeaderField: "sso_cookies"),
              let json = try? JSONSerialization.jsonObject(with: Data(ssoCookies.utf8)) as? [String: Any] else {
            return [:]
        }

        // {"device_headers": [{"header": {name: value}}], "prt_headers": [...]}
        var headers: [String: String] = [:]
        for key in ["device_headers", "prt_headers"] {
            for entry in json[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry["header"] as? [String: String] ?? [:] {
                    headers[name] = value
                }
            }
        }
        return headers
    }
}

/// One request to the plug-in, ended by its answer or the timeout.
@MainActor
private final class SSORequest: NSObject, ASAuthorizationControllerDelegate {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorization?, Never>?
    /// What the plug-in answered with instead of an authorization, if it did.
    private(set) var error: Error?

    func perform(_ request: ASAuthorizationRequest, timeout: TimeInterval) async -> ASAuthorization? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // The controller holds its delegate weakly; this holds both until the end.
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            self.controller = controller
            controller.performRequests()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                self.finish(nil)
            }
        }
    }

    // AppSSO answers on a queue of its own (the plug-in's error on a global
    // queue), so these are nonisolated and go over to the main actor.
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            self.finish(authorization)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            if self.continuation != nil { self.error = error }
            self.finish(nil)
        }
    }

    private func finish(_ authorization: ASAuthorization?) {
        continuation?.resume(returning: authorization)
        continuation = nil
        controller = nil
    }
}
