import AppKit
import Foundation
import LocalAuthentication
import SwiftUI
import WebKit

/// Registers each window's anchor view + sidebar handle so
/// AutofillCoordinator can hang the save and pairing prompts off the URL
/// bar — even when the sidebar is collapsed.
@MainActor
final class AutofillAnchorRegistry: ObservableObject {
    static let shared = AutofillAnchorRegistry()

    /// Each window's URL bar, by its sidebar
    private let urlBars = NSMapTable<SidebarStateManager, NSView>.weakToWeakObjects()

    func register(urlBar view: NSView, sidebarState: SidebarStateManager) {
        if urlBars.object(forKey: sidebarState) !== view {
            urlBars.setObject(view, forKey: sidebarState)
        }
    }

    /// The sidebar of the browser window `window` is (or is a page of), else
    /// of the window in front
    func sidebarStateManager(in window: NSWindow? = nil) -> SidebarStateManager? {
        (BrowserWindowSession.session(for: window) ?? BrowserWindowSession.current).sidebarStateManager
    }

    /// That window's URL bar
    func urlBarView(in window: NSWindow? = nil) -> NSView? {
        sidebarStateManager(in: window).flatMap { urlBars.object(forKey: $0) }
    }
}

/// Invisible NSView pinned behind the URL bar in CurrentURLView. Hands a
/// reference to AutofillAnchorRegistry so popovers can anchor to it.
struct URLBarAnchorRegistration: NSViewRepresentable {
    let sidebarState: SidebarStateManager

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async {
            AutofillAnchorRegistry.shared.register(urlBar: view, sidebarState: sidebarState)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-register defensively — the view's window can change when the
        // sidebar mounts/unmounts (collapsed → floating transitions).
        AutofillAnchorRegistry.shared.register(urlBar: nsView, sidebarState: sidebarState)
    }
}

/// Drives the autofill content script in WebViewConfiguration.addAutofillBridgeScript:
/// accounts under sign-in boxes (Klar's own store, plus Apple's Passwords app
/// when enabled), verification codes from the Passwords app, My Card from
/// Contacts under contact boxes, and the prompt to save a new login.
@MainActor
final class AutofillCoordinator: NSObject, ObservableObject {
    static let shared = AutofillCoordinator()

    private enum FieldKind: String {
        case username, password, otp, contact
    }

    /// A detected field, tied to the frame WebKit says the message came
    /// from rather than the origin the page's script reports.
    private struct Field {
        let frame: WKFrameInfo
        let host: String
        /// The frame's URL, then the main frame's, for code lookups.
        let frameURLs: [String]
        /// In CSS pixels of the top page's viewport, or of `outerFrameURL`'s.
        let rect: CGRect
        /// The cross-origin frame `rect` is relative to, when the field's
        /// script couldn't reach the top page's viewport.
        let outerFrameURL: String?
        let kind: FieldKind
        /// For a contact field, the autocomplete tokens of the visible
        /// contact boxes in its form, i.e. what My Card would fill.
        let contactTypes: [String]
        /// Whether the box already had text when it was focused.
        let hasValue: Bool
        weak var webView: WKWebView?

        /// Whether the field's page is in a private tab, whose errors stay
        /// out of the log.
        var isPrivate: Bool {
            webView?.isPrivateBrowsing ?? false
        }

        /// The same box focused again, or reported by its key icon.
        func isSame(as other: Field) -> Bool {
            webView === other.webView && frameURLs == other.frameURLs
                && rect == other.rect && outerFrameURL == other.outerFrameURL
        }
    }

    private let suggestionPanel = AutofillSuggestionPanel()
    /// Hangs off the URL bar; shows the save prompt or the pairing prompt.
    private let urlBarPopover: NSPopover
    /// Prompt content last put on screen; see popoverDidClose.
    private weak var shownPrompt: NSViewController?
    private var popoverAnchorView: NSView?
    /// The sidebar the prompt holds open (FloatingSidebarBlocker), until it closes
    private weak var blockedSidebar: SidebarStateManager?
    /// Field the suggestions were last shown for, re-shown after pairing.
    private var lastField: Field?

    /// Host a saved login was just filled on, so submitting it doesn't
    /// prompt to save it again.
    private var lastFilledHost: String?

    /// Fills waiting on Touch ID or a password prompt. Closing that prompt
    /// hands focus back to the window, which focuses the still-empty box
    /// again; that must not reopen the suggestions.
    private var fillsInProgress = 0
    /// Bumped when a fill starts, so automatic suggestions already being
    /// looked up don't appear over it.
    private var fillGeneration = 0

    private static let neverSaveHostsDefaultsKey = "com.itsnwa.browser.passwords.neverSaveHosts"

    private var settings: TOMLSettingsManager { .shared }

    private override init() {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        self.urlBarPopover = popover
        super.init()
        popover.delegate = self
        ApplePasswordsManager.shared.onOneTimeCodeAvailable = { [weak self] in
            self?.refreshOneTimeCodesIfShown()
        }
    }

    // MARK: - Entry point from TabWebViewCoordinator

    func handle(name: String, body: Any, frame: WKFrameInfo, webView: WKWebView) {
        let origin = frame.securityOrigin
        guard origin.protocol == "https" || origin.protocol == "http", !origin.host.isEmpty else { return }

        switch name {
        case "autofillFieldFocused":
            guard let field = makeField(body: body, frame: frame, webView: webView), isEnabled(field.kind) else {
                return
            }
            // The script only shows its key icon when asked, so turning a
            // setting off takes effect on pages that are already open.
            evaluate("showIcon", payload: nil, in: field)
            // Suggestions already shown for this box stay; another box takes
            // their place.
            if suggestionPanel.isVisible {
                if let shown = lastField, shown.isSame(as: field) { return }
                suggestionPanel.dismiss()
            }
            // Only empty boxes offer suggestions on their own, and not while a
            // fill is underway: see fillsInProgress. The key icon still opens
            // them.
            guard !field.hasValue, fillsInProgress == 0 else { return }
            showSuggestions(for: field, automatic: true)
        case "autofillIconClicked":
            guard let field = makeField(body: body, frame: frame, webView: webView), isEnabled(field.kind) else {
                return
            }
            showSuggestions(for: field, automatic: false)
        case "autofillFormSubmitted":
            handleFormSubmitted(body: body, host: origin.host.lowercased(), webView: webView)
        default:
            logDebug(.passwords, "AutofillCoordinator: unknown message \(name)")
        }
    }

    /// A password manager's extension (1Password, Bitwarden, …) fills and
    /// saves sign-ins while it's on; Klar's own suggestions step aside so
    /// there aren't two key icons. Codes and My Card still come from Klar.
    private var isSignInFillingWithExtension: Bool {
        ExtensionManager.shared.enabledPasswordManagerName != nil
    }

    private func isEnabled(_ kind: FieldKind) -> Bool {
        switch kind {
        case .username, .password: return settings.fillSignIns && !isSignInFillingWithExtension
        case .otp: return settings.fillSignIns && settings.useApplePasswords
        case .contact: return settings.fillContactDetails && ContactCardProvider.shared.isAuthorized
        }
    }

    private func makeField(body: Any, frame: WKFrameInfo, webView: WKWebView) -> Field? {
        guard
            let dict = body as? [String: Any],
            let kind = (dict["fieldType"] as? String).flatMap(FieldKind.init),
            let rectDict = dict["rect"] as? [String: Any]
        else { return nil }

        let rect = CGRect(
            x: (rectDict["x"] as? NSNumber)?.doubleValue ?? 0,
            y: (rectDict["y"] as? NSNumber)?.doubleValue ?? 0,
            width: (rectDict["width"] as? NSNumber)?.doubleValue ?? 0,
            height: (rectDict["height"] as? NSNumber)?.doubleValue ?? 0
        )
        var frameURLs = [String]()
        for url in [frame.request.url, webView.url].compactMap({ $0?.absoluteString })
        where !frameURLs.contains(url) {
            frameURLs.append(url)
        }
        return Field(
            frame: frame,
            host: frame.securityOrigin.host.lowercased(),
            frameURLs: frameURLs,
            rect: rect,
            outerFrameURL: rectDict["frameURL"] as? String,
            kind: kind,
            contactTypes: dict["contactTypes"] as? [String] ?? [],
            hasValue: (dict["hasValue"] as? Bool) ?? false,
            webView: webView
        )
    }

    // MARK: - Suggestions

    /// Automatic (focus) suggestions only appear when there is something to
    /// offer; a click on the key icon always opens them.
    private func showSuggestions(for field: Field, automatic: Bool) {
        let generation = fillGeneration
        Task { @MainActor in
            switch field.kind {
            case .username, .password:
                await showSignInSuggestions(for: field, automatic: automatic, generation: generation)
            case .otp:
                await showOneTimeCodes(for: field, automatic: automatic, generation: generation)
            case .contact:
                await showContactCard(for: field, automatic: automatic, generation: generation)
            }
        }
    }

    /// Lookups take a moment; by the time they finish the user may have
    /// picked something to fill, which automatic suggestions must not cover.
    private func mayPresent(automatic: Bool, generation: Int) -> Bool {
        !automatic || (fillsInProgress == 0 && generation == fillGeneration)
    }

    /// Closes the suggestions as soon as the user picks one, before any
    /// authentication prompt, and holds off automatic ones until `endFill`.
    private func beginFill() {
        suggestionPanel.dismiss()
        fillsInProgress += 1
        fillGeneration += 1
    }

    private func endFill() {
        fillsInProgress -= 1
    }

    private func showSignInSuggestions(for field: Field, automatic: Bool, generation: Int) async {
        let saved = (try? await PasswordManager.shared.credentials(for: field.host)) ?? []

        var appleLogins: [ApplePasswordsLogin] = []
        var appleState: ApplePasswordsManager.State?
        if settings.useApplePasswords {
            let apple = ApplePasswordsManager.shared
            // A click starts the helper so the popover can offer to connect;
            // focusing a field never does.
            if !automatic { await apple.connect() }
            if apple.state == .paired {
                do {
                    appleLogins = try await apple.logins(forHost: field.host)
                } catch {
                    logError(.passwords, "Passwords app lookup failed: \(error.localizedDescription)", isPrivate: field.isPrivate)
                }
                // Klar's own entry for the same account wins.
                appleLogins.removeAll { login in
                    saved.contains { $0.username.caseInsensitiveCompare(login.username) == .orderedSame }
                }
            }
            appleState = apple.state
        }

        if automatic && saved.isEmpty && appleLogins.isEmpty { return }
        guard mayPresent(automatic: automatic, generation: generation), let webView = field.webView else { return }

        let view = PasswordPopoverView(
            host: field.host,
            savedCredentials: saved,
            appleLogins: appleLogins,
            applePasswordsState: appleState,
            onSelectSaved: { [weak self] credential in
                self?.fill(credential, into: field)
            },
            onSelectApple: { [weak self] login in
                self?.fill(login, into: field)
            },
            onConnectApple: { [weak self] in
                self?.beginPairing(from: webView)
            },
            onManage: { [weak self] in
                self?.suggestionPanel.dismiss()
                SettingsWindowController.shared.showSettings(category: .passwords)
            }
        )
        await present(view, for: field, automatic: automatic, generation: generation)
    }

    private func showOneTimeCodes(for field: Field, automatic: Bool, generation: Int) async {
        let apple = ApplePasswordsManager.shared
        if !automatic { await apple.connect() }

        var codes: [OneTimeCode] = []
        if apple.state == .paired {
            do {
                codes = try await apple.oneTimeCodes(frameURLs: field.frameURLs)
            } catch {
                logError(.passwords, "verification code lookup failed: \(error.localizedDescription)", isPrivate: field.isPrivate)
            }
        }
        if automatic && codes.isEmpty { return }
        guard mayPresent(automatic: automatic, generation: generation), let webView = field.webView else { return }

        let view = OneTimeCodePopoverView(
            host: field.host,
            codes: codes,
            passwordsState: apple.state,
            onSelect: { [weak self] code in
                self?.fill(code, into: field)
            },
            onConnect: { [weak self] in
                self?.beginPairing(from: webView)
            },
            onOpenPasswords: { [weak self] in
                self?.suggestionPanel.dismiss()
                ApplePasswordsManager.shared.openPasswordsApp(searching: field.host)
            }
        )
        await present(view, for: field, automatic: automatic, generation: generation)
    }

    private func showContactCard(for field: Field, automatic: Bool, generation: Int) async {
        guard let card = await ContactCardProvider.shared.card() else { return }
        // Only what the popover names goes to the page, even if the form
        // grows before the user picks it.
        let offer = card.offer(forFieldTypes: field.contactTypes)
        guard !offer.categories.isEmpty, mayPresent(automatic: automatic, generation: generation) else { return }

        let view = ContactCardPopoverView(card: card, categories: offer.categories) { [weak self] in
            guard let self else { return }
            self.suggestionPanel.dismiss()
            self.evaluate("fillContact", payload: offer.values, in: field)
        }
        await present(view, for: field, automatic: automatic, generation: generation)
    }

    /// A code just arrived in Messages or Mail; show it if the user is
    /// looking at the code suggestions.
    private func refreshOneTimeCodesIfShown() {
        guard suggestionPanel.isVisible, let field = lastField, field.kind == .otp else { return }
        showSuggestions(for: field, automatic: false)
    }

    /// Puts `view` on screen under the field, if it may still appear and the
    /// field can be placed.
    private func present<Content: View>(_ view: Content, for field: Field, automatic: Bool, generation: Int) async {
        guard let webView = field.webView, let anchor = await screenRect(of: field, automatic: automatic),
              let window = webView.window, mayPresent(automatic: automatic, generation: generation)
        else { return }
        lastField = field
        suggestionPanel.present(view: view, below: anchor, in: window, onDismiss: {})
    }

    /// The field on screen. In a cross-origin frame, that frame's place in
    /// the top page comes from the main frame, matched by its address. A
    /// frame that can't be placed: an icon click puts the suggestions under
    /// the pointer, which is on the icon, and automatic ones don't show.
    private func screenRect(of field: Field, automatic: Bool) async -> NSRect? {
        guard let webView = field.webView else { return nil }
        var rect = field.rect
        if let outerFrameURL = field.outerFrameURL {
            if let origin = await viewportOrigin(ofFrameAt: outerFrameURL, in: webView) {
                rect.origin.x += origin.x
                rect.origin.y += origin.y
            } else if automatic {
                return nil
            } else {
                return pointerAnchoredRect(for: field, in: webView)
            }
        }
        return AutofillSuggestionPanel.screenRect(forViewportRect: rect, in: webView)
    }

    /// Where the content of the top page's frame showing `url` starts in
    /// its viewport: the frame with that address, else the only one from
    /// its origin.
    private func viewportOrigin(ofFrameAt url: String, in webView: WKWebView) async -> CGPoint? {
        let js = """
            return Array.from(document.querySelectorAll('iframe, frame')).map((frame) => {
                const rect = frame.getBoundingClientRect();
                const style = getComputedStyle(frame);
                return {
                    src: frame.src,
                    x: rect.left + frame.clientLeft + (parseFloat(style.paddingLeft) || 0),
                    y: rect.top + frame.clientTop + (parseFloat(style.paddingTop) || 0)
                };
            });
            """
        guard let frames = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient) as? [[String: Any]]
        else { return nil }
        func origin(_ string: String) -> String? {
            guard let url = URL(string: string), let scheme = url.scheme, let host = url.host() else { return nil }
            return "\(scheme)://\(host):\(url.port ?? -1)"
        }
        let match = frames.first { $0["src"] as? String == url } ?? {
            let sameOrigin = frames.filter { ($0["src"] as? String).flatMap(origin) == origin(url) }
            return sameOrigin.count == 1 ? sameOrigin[0] : nil
        }()
        guard let match, let x = match["x"] as? NSNumber, let y = match["y"] as? NSNumber else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    /// The field worked out from the pointer on its key icon, which sits
    /// centred 17 CSS pixels in from its right edge (ICON_INSET plus half of
    /// ICON_SIZE in the script).
    private func pointerAnchoredRect(for field: Field, in webView: WKWebView) -> NSRect {
        let pointer = NSEvent.mouseLocation
        let zoom = webView.pageZoom
        let size = CGSize(width: field.rect.width * zoom, height: field.rect.height * zoom)
        return NSRect(
            x: pointer.x - size.width + 17 * zoom,
            y: pointer.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Closes the suggestions: another tab became active, or `webView` (if
    /// given) went to a new page under them.
    func dismissSuggestions(in webView: WKWebView? = nil) {
        guard suggestionPanel.isVisible else { return }
        if let webView, lastField?.webView !== webView { return }
        suggestionPanel.dismiss()
    }

    // MARK: - Filling

    private func fill(_ credential: SavedCredential, into field: Field) {
        beginFill()
        Task { @MainActor in
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                do {
                    let success = try await context.evaluatePolicy(
                        .deviceOwnerAuthenticationWithBiometrics,
                        localizedReason: "fill the password for \(credential.host)"
                    )
                    guard success else { return endFill() }
                } catch {
                    logDebug(.passwords, "biometric prompt cancelled or failed: \(error.localizedDescription)")
                    return endFill()
                }
            }

            do {
                let password = try await PasswordManager.shared.reveal(credential)
                await PasswordManager.shared.markUsed(credential)
                lastFilledHost = PasswordManager.normalize(host: field.host)
                evaluate("fill", payload: ["username": credential.username, "password": password], in: field) {
                    self.endFill()
                }
            } catch {
                logError(.passwords, "fill failed: \(error.localizedDescription)", isPrivate: field.isPrivate)
                endFill()
            }
        }
    }

    private func fill(_ login: ApplePasswordsLogin, into field: Field) {
        beginFill()
        Task { @MainActor in
            do {
                // Passwords asks for Touch ID or the login password itself.
                guard let password = try await ApplePasswordsManager.shared.password(for: login) else {
                    logDebug(.passwords, "no password returned for \(login.site)")
                    return endFill()
                }
                lastFilledHost = PasswordManager.normalize(host: field.host)
                evaluate("fill", payload: ["username": login.username, "password": password], in: field) {
                    self.endFill()
                }
            } catch {
                logError(.passwords, "Passwords app fill failed: \(error.localizedDescription)", isPrivate: field.isPrivate)
                endFill()
            }
        }
    }

    private func fill(_ code: OneTimeCode, into field: Field) {
        beginFill()
        Task { @MainActor in
            do {
                guard let value = try await ApplePasswordsManager.shared.codeToFill(code, frameURLs: field.frameURLs) else {
                    logDebug(.passwords, "no verification code returned for \(field.host)")
                    return endFill()
                }
                evaluate("fillOTP", payload: ["code": value], in: field) {
                    self.endFill()
                }
            } catch {
                logError(.passwords, "verification code fill failed: \(error.localizedDescription)", isPrivate: field.isPrivate)
                endFill()
            }
        }
    }

    /// Runs a `__klarAutofill` command in the frame the field belongs to, so
    /// a login looked up for that frame's origin can't land anywhere else.
    /// `completion` runs once the page has run it (or it couldn't be sent).
    private func evaluate(_ command: String, payload: [String: String]?, in field: Field, completion: (() -> Void)? = nil) {
        guard let webView = field.webView else {
            completion?()
            return
        }
        var argument = ""
        if let payload {
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            else {
                logError(.passwords, "could not encode \(command) payload", isPrivate: field.isPrivate)
                completion?()
                return
            }
            argument = json
        }
        let js = "if (window.__klarAutofill) { window.__klarAutofill.\(command)(\(argument)); }"
        webView.evaluateJavaScript(js, in: field.frame, in: .page) { [isPrivate = field.isPrivate] result in
            if case .failure(let error) = result {
                logError(.passwords, "\(command) script failed: \(error.localizedDescription)", isPrivate: isPrivate)
            }
            completion?()
        }
    }

    // MARK: - Saving

    private func handleFormSubmitted(body: Any, host frameHost: String, webView: WKWebView) {
        guard
            settings.offerToSavePasswords,
            !isSignInFillingWithExtension,
            let dict = body as? [String: Any],
            let password = dict["password"] as? String,
            !password.isEmpty
        else { return }

        let username = (dict["username"] as? String) ?? ""
        let host = PasswordManager.normalize(host: frameHost)

        // Suppress the prompt when the user just filled a saved login here.
        if lastFilledHost == host {
            lastFilledHost = nil
            return
        }
        if neverSaveHosts().contains(host) { return }

        Task { @MainActor in
            // Already saved in Klar with this password: nothing to offer.
            if let existing = (try? await PasswordManager.shared.credentials(for: host))?
                .first(where: { $0.username == username }),
               (try? await PasswordManager.shared.reveal(existing)) == password
            {
                return
            }
            // Accounts the Passwords app already holds are managed there.
            let apple = ApplePasswordsManager.shared
            if settings.useApplePasswords, apple.state == .paired,
               let logins = try? await apple.logins(forHost: frameHost),
               logins.contains(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame })
            {
                return
            }
            presentSavePrompt(host: host, username: username, password: password, webView: webView)
        }
    }

    private func presentSavePrompt(host: String, username: String, password: String, webView: WKWebView) {
        let isPrivate = webView.isPrivateBrowsing
        let view = SavePasswordPromptView(
            host: host,
            username: username,
            onSave: { [weak self] in
                Task { @MainActor in
                    do {
                        _ = try await PasswordManager.shared.save(host: host, username: username, password: password)
                    } catch {
                        logError(.passwords, "save failed: \(error.localizedDescription)", isPrivate: isPrivate)
                    }
                    self?.urlBarPopover.performClose(nil)
                }
            },
            onNever: { [weak self] in
                self?.addNeverSaveHost(host)
                self?.urlBarPopover.performClose(nil)
            },
            onDismiss: { [weak self] in
                self?.urlBarPopover.performClose(nil)
            }
        )
        let controller = NSHostingController(rootView: view)
        urlBarPopover.contentViewController = controller
        urlBarPopover.contentSize = NSSize(width: 300, height: username.isEmpty ? 92 : 116)
        showURLBarPopover(webViewFallback: webView)
    }

    /// Sites the user chose never to save passwords for. Synced with the
    /// settings (TOMLSettingsManager+CloudSync).
    static var neverSaveHosts: Set<String> {
        get {
            Set(UserDefaults.standard.array(forKey: neverSaveHostsDefaultsKey) as? [String] ?? [])
        }
        set {
            UserDefaults.standard.set(newValue.sorted(), forKey: neverSaveHostsDefaultsKey)
            CloudSyncManager.localDataChanged(.settings)
        }
    }

    private func neverSaveHosts() -> Set<String> {
        Self.neverSaveHosts
    }

    private func addNeverSaveHost(_ host: String) {
        Self.neverSaveHosts.insert(host)
    }

    // MARK: - Pairing prompt

    private func beginPairing(from webView: WKWebView) {
        suggestionPanel.dismiss()
        let view = PasswordPairingView(
            onPaired: { [weak self] in
                guard let self else { return }
                self.urlBarPopover.performClose(nil)
                if let field = self.lastField { self.showSuggestions(for: field, automatic: false) }
            },
            onCancel: { [weak self] in
                self?.urlBarPopover.performClose(nil)
            }
        )
        urlBarPopover.contentViewController = NSHostingController(rootView: view)
        showURLBarPopover(webViewFallback: webView)
    }

    // MARK: - URL bar popover

    private func showURLBarPopover(webViewFallback: WKWebView) {
        // Hold the floating sidebar open from the moment we decide to show the
        // prompt — `showPopoverAnchored` may reveal a collapsed sidebar and
        // wait 0.30s before actually showing the popover, and we don't want
        // FloatingSidebarManager to hide the sidebar in that gap. The
        // matching `endBlocking()` lives in `popoverDidClose`. Skip if the
        // popover is already shown so re-entrant calls don't over-count.
        if !urlBarPopover.isShown, let sidebar = AutofillAnchorRegistry.shared.sidebarStateManager(in: webViewFallback.presentationWindow) {
            if let blockedSidebar {
                FloatingSidebarBlocker.shared.endBlocking(blockedSidebar)
            }
            FloatingSidebarBlocker.shared.beginBlocking(sidebar)
            blockedSidebar = sidebar
        }
        showPopoverAnchored(webViewFallback: webViewFallback)
    }

    /// Anchors the prompt to the URL bar in the sidebar. If the sidebar is
    /// currently collapsed, animate the floating sidebar in first, then show
    /// the popover once the URL bar's NSView is laid out and visible.
    private func showPopoverAnchored(webViewFallback: WKWebView) {
        let registry = AutofillAnchorRegistry.shared
        let window = webViewFallback.presentationWindow

        guard let urlBar = registry.urlBarView(in: window), let sidebar = registry.sidebarStateManager(in: window) else {
            // No registry → fall back to upper-right of the web view.
            anchorPopoverToWebView(webViewFallback)
            return
        }

        let needsReveal = !sidebar.isVisible && !sidebar.isFloating
        if needsReveal {
            sidebar.showFloating()
        }

        // Wait for the sidebar's reveal animation to lay out the URL bar.
        // SidebarStateManager.showFloating animates over ~0.2s; add a small
        // buffer so the NSView has settled into its final frame before
        // NSPopover snapshots the rect.
        let delay: TimeInterval = needsReveal ? 0.30 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // Confirm the view is still in a window — sidebar could have
            // been dismissed or moved between scheduling and firing.
            guard urlBar.window != nil else {
                self.anchorPopoverToWebView(webViewFallback)
                return
            }
            self.showPopover(relativeTo: urlBar.bounds, of: urlBar)
        }
    }

    private func anchorPopoverToWebView(_ webView: WKWebView) {
        let anchor = ensurePopoverAnchorView(in: webView)
        let bounds = webView.bounds
        anchor.frame = NSRect(x: bounds.maxX - 12, y: 8, width: 1, height: 1)
        showPopover(relativeTo: anchor.bounds, of: anchor)
    }

    private func showPopover(relativeTo rect: NSRect, of view: NSView) {
        shownPrompt = urlBarPopover.contentViewController
        urlBarPopover.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private func ensurePopoverAnchorView(in webView: WKWebView) -> NSView {
        if let existing = popoverAnchorView, existing.superview === webView {
            return existing
        }
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        webView.addSubview(view)
        popoverAnchorView = view
        return view
    }
}

extension AutofillCoordinator: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        // The save prompt's callbacks hold the plaintext password, and the
        // pairing prompt's view cancels an unfinished pairing as it goes;
        // release them now rather than whenever the next prompt replaces
        // them. Skipped when a newer prompt was set up during the close
        // animation and is waiting to be shown. Synchronous (AppKit calls
        // this on main) so that check can't race the newer prompt's show.
        MainActor.assumeIsolated {
            if let content = urlBarPopover.contentViewController, content === shownPrompt {
                urlBarPopover.contentViewController = nil
            }
        }
        Task { @MainActor in
            if let blockedSidebar {
                FloatingSidebarBlocker.shared.endBlocking(blockedSidebar)
                self.blockedSidebar = nil
            }
        }
    }
}
