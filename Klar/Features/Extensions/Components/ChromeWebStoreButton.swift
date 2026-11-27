import Foundation
import WebKit

/// Puts an "Add to Klar" button on Chrome Web Store extension pages. The
/// store only offers its own install button to Chrome, so Klar adds one of
/// its own: a script in an isolated content world (the store's scripts
/// can't see or press it) that asks Klar for the extension's state and
/// installs or removes it through a reply handler. Klar checks that the
/// message really comes from the store's main frame before acting.
@MainActor
final class ChromeWebStoreButton: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ChromeWebStoreButton()

    private static let messageName = "klarWebStore"
    private static let contentWorld = WKContentWorld.world(name: "KlarWebStore")

    static func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(shared, contentWorld: contentWorld, name: messageName)
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: contentWorld
        ))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https",
              origin.host == ExtensionInstaller.webStoreHost,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let id = body["id"] as? String, CRXFile.isValidExtensionID(id) else {
            return (nil, "Not allowed")
        }

        let manager = ExtensionManager.shared
        switch action {
        case "state":
            break
        case "install":
            await manager.installFromWebStore(id: id)
        case "remove":
            await manager.confirmAndRemove(id: id)
        default:
            return (nil, "Unknown action")
        }
        return (state(of: id), nil)
    }

    private func state(of id: String) -> String {
        let manager = ExtensionManager.shared
        if manager.isInstalling(id) { return "installing" }
        return manager.record(for: id) == nil ? "absent" : "installed"
    }

    /// The store is a single-page app, so the script follows URL changes by
    /// polling (cheap, and only on the store) rather than patching history,
    /// which an isolated world can't see the page use anyway.
    private static let script = #"""
    (function() {
        if (location.hostname !== 'chromewebstore.google.com' || window.__klarWebStore) return;
        window.__klarWebStore = true;

        const handler = window.webkit.messageHandlers.klarWebStore;
        let button = null;
        let shownID = null;

        function currentID() {
            const match = location.pathname.match(/\/detail\/(?:[^\/]+\/)?([a-p]{32})(?:\/|$)/);
            return match ? match[1] : null;
        }

        function makeButton() {
            const b = document.createElement('button');
            const s = b.style;
            s.position = 'fixed';
            s.top = '76px';
            s.right = '24px';
            s.zIndex = '2147483647';
            s.padding = '10px 22px';
            s.border = 'none';
            s.borderRadius = '20px';
            s.font = '500 14px/20px "Google Sans", system-ui, -apple-system, sans-serif';
            s.color = '#fff';
            s.background = '#0b57d0';
            s.boxShadow = '0 1px 3px rgba(0,0,0,0.3)';
            s.cursor = 'pointer';
            b.addEventListener('click', onClick);
            document.documentElement.appendChild(b);
            return b;
        }

        function render(state) {
            if (!button) button = makeButton();
            button.dataset.state = state;
            button.disabled = state === 'installing';
            button.style.opacity = state === 'installing' ? '0.7' : '1';
            button.style.background = state === 'installed' ? '#5f6368' : '#0b57d0';
            button.textContent = state === 'installed' ? 'Remove from Klar'
                : state === 'installing' ? 'Adding…' : 'Add to Klar';
        }

        async function send(action, id) {
            try {
                return await handler.postMessage({ action: action, id: id });
            } catch (e) {
                return null;
            }
        }

        async function onClick(event) {
            event.preventDefault();
            event.stopPropagation();
            const id = shownID;
            if (!id || !button) return;
            const action = button.dataset.state === 'installed' ? 'remove' : 'install';
            if (action === 'install') render('installing');
            const state = await send(action, id);
            if (id === shownID && state) render(state);
        }

        async function refresh() {
            const id = currentID();
            if (id === shownID) return;
            shownID = id;
            if (!id) {
                if (button) { button.remove(); button = null; }
                return;
            }
            const state = await send('state', id);
            if (id === shownID && state) render(state);
        }

        refresh();
        setInterval(refresh, 700);
        document.addEventListener('visibilitychange', async function() {
            if (document.visibilityState !== 'visible' || !shownID) return;
            const state = await send('state', shownID);
            if (state) render(state);
        });
    })();
    """#
}
