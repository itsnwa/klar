import Foundation

/// Stand-ins for Chrome extension APIs WebKit doesn't have, so a store
/// extension that touches them still starts. Without them, a background
/// script that calls, say, `chrome.webNavigation.onHistoryStateUpdated
/// .addListener` while starting up stops there with a TypeError, before it
/// sets anything else up — iCloud Passwords never reached its Mac helper.
///
/// Klar writes `klar-compat.js` into each store extension's folder and runs
/// it before the extension's own code: first in each of its HTML pages, and
/// through a small wrapper for the background service worker (or first among
/// `background.scripts`). Unpacked extensions are left as their developer
/// wrote them.
nonisolated enum ExtensionCompatibility {
    /// Permissions whose APIs the stand-ins provide, so they aren't listed
    /// as unsupported.
    static let standInPermissions: Set<String> = ["privacy", "declarativeContent"]

    /// The Chrome Klar is to store extensions and the store's update
    /// service, which leaves out versions that need a newer Chrome.
    static let chromeVersion = "140.0.0.0"
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeVersion) Safari/537.36"

    /// The script message handler a popup's window.close() reaches
    /// (ExtensionPopupCloser).
    static let closePopupHandler = "klarCloseExtensionPopup"

    private static let scriptName = "klar-compat.js"
    private static let backgroundWrapperName = "klar-background.js"

    /// Adds the stand-ins to a store extension's folder, before WebKit reads
    /// it. Cheap once the folder has the current ones.
    static func prepare(_ folder: URL) {
        let scriptURL = folder.appendingPathComponent(scriptName)
        let current = Data(script.utf8)
        guard (try? Data(contentsOf: scriptURL)) != current else { return }
        do {
            try runBeforeBackground(in: folder)
            runBeforePages(in: folder)
            // Last, so a folder is only marked done once it's patched.
            try current.write(to: scriptURL, options: .atomic)
        } catch {
            logError(.extensions, "Couldn't add stand-ins to \(folder.path): \(error.localizedDescription)")
        }
    }

    /// Points the manifest's background at a wrapper that loads the
    /// stand-ins first; the extension's own files stay as they are.
    private static func runBeforeBackground(in folder: URL) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              var background = manifest["background"] as? [String: Any] else { return }
        var changed = false

        if let worker = background["service_worker"] as? String, worker != backgroundWrapperName {
            let paths = ["/\(scriptName)", "/" + worker.trimmingPrefix("./").trimmingPrefix("/")].map(javaScriptString)
            let wrapper = background["type"] as? String == "module"
                ? paths.map { "import \($0);" }.joined(separator: "\n")
                : "importScripts(\(paths.joined(separator: ", ")));"
            try Data((wrapper + "\n").utf8).write(to: folder.appendingPathComponent(backgroundWrapperName), options: .atomic)
            background["service_worker"] = backgroundWrapperName
            changed = true
        }
        if var scripts = background["scripts"] as? [String], scripts.first != scriptName {
            scripts.insert(scriptName, at: 0)
            background["scripts"] = scripts
            changed = true
        }
        guard changed else { return }

        manifest["background"] = background
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Loads the stand-ins first in each page with scripts: the popup,
    /// options, a background page, and pages the extension opens in tabs.
    private static func runBeforePages(in folder: URL) {
        let tag = "<script src=\"/\(scriptName)\"></script>"
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files where ["html", "htm"].contains(url.pathExtension.lowercased()) {
            guard var html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(scriptName),
                  let firstScript = html.range(of: "<script", options: .caseInsensitive) else { continue }
            // Right after <head>, or else just before the first script.
            let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive])
            html.insert(contentsOf: tag, at: head?.upperBound ?? firstScript.lowerBound)
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                logError(.extensions, "Couldn't add stand-ins to \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static func javaScriptString(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Only adds what's missing, so it does nothing once WebKit implements
    /// an API itself — but for the user agent, which says Chrome.
    private static let script = #"""
    // Added by Klar: stand-ins for Chrome extension APIs that Klar's engine
    // doesn't have, so code that uses them keeps running.
    (() => {
      "use strict";
      const roots = [...new Set([globalThis.chrome, globalThis.browser])].filter(Boolean);
      if (roots.length === 0) return;
      const permissions = new Set(roots[0].runtime?.getManifest?.()?.permissions ?? []);

      // These are Chrome extensions, so they're told they're in Chrome, as
      // the store is. WebKit's own user agent names no browser: a password
      // manager's popup stopped at that, and told it's Safari, it waited on
      // the native app of its Safari version. Requests keep WebKit's.
      const userAgent = \#(javaScriptString(chromeUserAgent));
      const navigatorValues = { userAgent, appVersion: userAgent.replace(/^Mozilla\//, ""), vendor: "Google Inc." };
      for (const [name, value] of Object.entries(navigatorValues)) {
        if (!(name in navigator)) continue;
        try {
          Object.defineProperty(Object.getPrototypeOf(navigator), name, { get: () => value, configurable: true });
        } catch {}
      }

      // A popup closes when its page calls window.close(), as in Chrome.
      // WebKit only lets a script close a window it opened, or one with no
      // history, which a popup that routes within itself has: a password
      // manager's stayed open after logging out, on a page whose background was gone.
      if (typeof window === "object") {
        const close = window.close;
        window.close = function () {
          globalThis.webkit?.messageHandlers?.[\#(javaScriptString(closePopupHandler))]?.postMessage(null);
          return close.call(this);
        };
      }

      // Chrome has the symbols that `using` declarations dispose with, and
      // compiled code that has them throws without them (a password
      // manager's unlock screen). The extension's own disposable objects take theirs.
      for (const name of ["dispose", "asyncDispose"]) {
        if (typeof Symbol[name] !== "symbol") {
          Object.defineProperty(Symbol, name, { value: Symbol(`Symbol.${name}`) });
        }
      }

      // WebKit runs an extension's service worker on the main thread, where
      // opening a WebSocket waits for the main thread to set it up: the
      // worker waits on itself for good, and turning the extension off and
      // on can't stop it (a password manager froze connecting to its
      // notifications server once logged in, its popup spinning until Klar quit). There a
      // socket fails as one to a server that can't be reached does.
      if (typeof ServiceWorkerGlobalScope === "function" && self instanceof ServiceWorkerGlobalScope) {
        class UnavailableWebSocket extends EventTarget {
          #readyState = 0;
          constructor(url) {
            super();
            const address = new URL(url, location.href);
            if (!["ws:", "wss:", "http:", "https:"].includes(address.protocol)) {
              throw new DOMException(`The URL's scheme must be either 'ws' or 'wss'.`, "SyntaxError");
            }
            this.url = address.href.replace(/^http/, "ws");
            setTimeout(() => {
              this.#readyState = 3;
              const error = new Event("error");
              this.dispatchEvent(error);
              this.onerror?.(error);
              const close = typeof CloseEvent === "function"
                ? new CloseEvent("close", { code: 1006, wasClean: false })
                : Object.assign(new Event("close"), { code: 1006, reason: "", wasClean: false });
              this.dispatchEvent(close);
              this.onclose?.(close);
            });
          }
          get readyState() { return this.#readyState; }
          get bufferedAmount() { return 0; }
          get protocol() { return ""; }
          get extensions() { return ""; }
          send() {
            if (this.#readyState === 0) throw new DOMException("WebSocket is still connecting.", "InvalidStateError");
          }
          close() {}
        }
        UnavailableWebSocket.prototype.binaryType = "blob";
        for (const [index, name] of ["CONNECTING", "OPEN", "CLOSING", "CLOSED"].entries()) {
          UnavailableWebSocket[name] = UnavailableWebSocket.prototype[name] = index;
        }
        globalThis.WebSocket = UnavailableWebSocket;
      }

      // WebKit hands out its API objects (chrome.scripting…) from a weak
      // cache: what's added to one is gone once it's collected, and the
      // next access makes another. The ones changed here are kept for good.
      const kept = new Set();
      Object.defineProperty(globalThis, Symbol("klar-compat"), { value: kept });
      const keep = (object) => void kept.add(object);

      const fill = (object, name, value) => {
        if (!object || object[name] != null) return;
        try {
          object[name] = value;
          keep(object);
        } catch {}
      };

      // An event that never fires.
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (listener) => void listeners.add(listener),
          removeListener: (listener) => void listeners.delete(listener),
          hasListener: (listener) => listeners.has(listener),
          hasListeners: () => listeners.size > 0,
        };
      };

      // Answers through the callback when there is one, else a promise.
      const reply = (value, callback) => {
        if (typeof callback !== "function") return Promise.resolve(value);
        queueMicrotask(() => callback(value));
      };
      const callbackIn = (args) => args.find((arg) => typeof arg === "function");

      for (const chrome of roots) {
        const events = {
          runtime: ["onSuspendCanceled", "onUpdateAvailable", "onRestartRequired"],
          tabs: ["onZoomChange"],
          windows: ["onBoundsChanged"],
          webNavigation: ["onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced", "onCreatedNavigationTarget"],
        };
        for (const [namespace, names] of Object.entries(events)) {
          for (const name of names) fill(chrome[namespace], name, event());
        }

        const toolbarAction = chrome.action ?? chrome.browserAction;
        fill(toolbarAction, "setBadgeTextColor", (...args) => reply(undefined, callbackIn(args)));

        // WebKit takes the world a script runs in as a plain string.
        fill(chrome.scripting, "ExecutionWorld", Object.freeze({ ISOLATED: "ISOLATED", MAIN: "MAIN" }));

        // WebKit throws for a permission it doesn't know (privacy, offscreen,
        // idle…), where Chrome answers: a password manager's popup stayed blank
        // after asking whether it may use privacy. One the manifest lists is
        // granted, as in Chrome; one it only may ask for isn't, and can't be.
        const unknownPermission = (error) => /'([^']+)' is not a valid permission/.exec(error?.message ?? "")?.[1];
        const without = (request, unknown) =>
          ({ ...request, permissions: (request.permissions ?? []).filter((permission) => permission !== unknown) });
        const permissionsAPI = chrome.permissions;
        const answerUnknown = (name, answer) => {
          const original = permissionsAPI?.[name];
          if (typeof original !== "function") return;
          try {
            permissionsAPI[name] = (request = {}, ...rest) => {
              try {
                return original.call(permissionsAPI, request, ...rest);
              } catch (error) {
                const unknown = unknownPermission(error);
                if (unknown == null) throw error;
                return answer(request, unknown, rest);
              }
            };
            keep(permissionsAPI);
          } catch {}
        };
        answerUnknown("contains", (request, unknown, rest) => permissions.has(unknown)
          ? permissionsAPI.contains(without(request, unknown), ...rest)
          : reply(false, callbackIn(rest)));
        answerUnknown("request", (request, unknown, rest) => reply(false, callbackIn(rest)));
        answerUnknown("remove", (request, unknown, rest) => permissionsAPI.remove(without(request, unknown), ...rest));

        // Browser settings read as off, and extensions can't change them.
        if (permissions.has("privacy")) {
          const setting = (value = false) => ({
            get: (...args) => reply({ value, levelOfControl: "not_controllable" }, callbackIn(args)),
            set: (...args) => reply(undefined, callbackIn(args)),
            clear: (...args) => reply(undefined, callbackIn(args)),
            onChange: event(),
          });
          const settings = (names) => Object.fromEntries(names.map((name) => [name, setting()]));
          fill(chrome, "privacy", {
            network: { networkPredictionEnabled: setting(), webRTCIPHandlingPolicy: setting("default") },
            services: settings([
              "alternateErrorPagesEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled",
              "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
              "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled",
              "spellingServiceEnabled", "translationServiceEnabled",
            ]),
            websites: settings([
              "adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled", "hyperlinkAuditingEnabled",
              "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
              "thirdPartyCookiesAllowed", "topicsEnabled",
            ]),
          });
        }

        // Rules aren't evaluated: an action meant to show only on matching
        // pages shows on every page.
        if (permissions.has("declarativeContent")) {
          const Options = class { constructor(options) { Object.assign(this, options); } };
          class ShowAction extends Options {}
          fill(chrome, "declarativeContent", {
            PageStateMatcher: class extends Options {},
            ShowAction,
            ShowPageAction: ShowAction,
            SetIcon: class extends Options {},
            RequestContentScript: class extends Options {},
            onPageChanged: {
              ...event(),
              addRules: (rules = [], callback) => {
                if (rules.some((rule) => rule.actions?.some((ruleAction) => ruleAction instanceof ShowAction))) {
                  toolbarAction?.enable?.();
                }
                return reply(rules, callback);
              },
              removeRules: (...args) => reply(undefined, callbackIn(args)),
              getRules: (...args) => reply([], callbackIn(args)),
            },
          });
        }
      }
    })();
    """#
}
